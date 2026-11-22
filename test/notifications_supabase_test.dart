// M3 P2: the notifications data layer (migration 25) — row mapping, request
// building, error translation, the CRICECO_NOTIFICATIONS switch and the
// wording adapter, on a fake gateway that returns rows shaped like the real
// database functions'. The SQL itself is verified by
// supabase/tests/local/20 and 20b on a disposable Postgres.
import 'dart:io';

import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/match_row_mapper.dart';
import 'package:criceco/data/supabase/notification_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_notification_repository.dart';
import 'package:criceco/features/notifications/notifications_controller.dart';
import 'package:criceco/features/notifications/server_notification_adapter.dart';
import 'package:criceco/shared/widgets/ce_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'notifications_fakes.dart';

GatewayConstraintException refusal(String sqlState, String message) =>
    GatewayConstraintException(sqlState: sqlState, message: message);

Future<Object?> errorOf(Future<Object?> call) =>
    call.then<Object?>((_) => null, onError: (Object e) => e);

/// A `my_notifications` row (migration 25's shape).
Map<String, dynamic> row(
  String id,
  String type, {
  Map<String, Object?> params = const {},
  String createdAt = '2026-11-22T10:00:00.123456+00:00',
  String? readAt,
  String? clubId = 'club-a',
  String? matchId,
  String? subjectId,
}) => {
  'notification_id': id,
  'type': type,
  'params': params,
  'club_id': clubId,
  'match_id': matchId,
  'subject_id': subjectId,
  'created_at': createdAt,
  'read_at': readAt,
};

ServerNotification note(
  String type, {
  UserRole role = UserRole.player,
  Map<String, Object?> params = const {},
  String? matchId,
  String? subjectId,
}) => NotificationRowMapper.notification(
  role,
  row('n-$type', type, params: params, matchId: matchId, subjectId: subjectId),
)!;

/// The type codes of migration 25's `notifications_type_check`.
/// The notification types as the database defines them now: the LAST
/// `notifications_type_check` across the migrations (25, then 28 …).
List<String> migrationTypeCodes() {
  final files =
      Directory('supabase/migrations')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  String? check;
  for (final f in files) {
    for (final m in RegExp(
      r"notifications_type_check check \(type in \(([^)]*)\)\)",
    ).allMatches(f.readAsStringSync())) {
      check = m.group(1);
    }
  }
  return [
    for (final m in RegExp(r"'([a-z_]+)'").allMatches(check!)) m.group(1)!,
  ];
}

void main() {
  group('NotificationRowMapper', () {
    test(
      'a full row: ids, inbox, type, parameters, times, its exact cursor',
      () {
        final n = NotificationRowMapper.notification(
          UserRole.clubOwner,
          row(
            'n1',
            'join_request_received',
            params: {'club_name': 'Note Lions', 'person_name': 'Ali Khan'},
            readAt: '2026-11-22T11:00:00+00:00',
            subjectId: 'req-1',
          ),
        )!;
        expect(n.id, 'n1');
        expect(n.role, UserRole.clubOwner);
        expect(n.type, ServerNotificationType.joinRequestReceived);
        expect(n.text('person_name'), 'Ali Khan');
        expect(n.clubId, 'club-a');
        expect(n.matchId, isNull);
        expect(n.subjectId, 'req-1');
        expect(
          n.createdAt,
          DateTime.utc(2026, 11, 22, 10, 0, 0, 123, 456).toLocal(),
        );
        expect(n.isRead, isTrue);
        // The server's own text, microseconds and all (never re-formatted).
        expect(
          n.cursor,
          const NotificationCursor('2026-11-22T10:00:00.123456+00:00', 'n1'),
        );
      },
    );

    test(
      'knows exactly the database types (26 since migration 28), both ways',
      () {
        final codes = migrationTypeCodes();
        expect(codes, hasLength(26));
        expect(codes.toSet(), hasLength(ServerNotificationType.values.length));
        for (final code in codes) {
          final n = NotificationRowMapper.notification(
            UserRole.player,
            row('x', code),
          );
          expect(n, isNotNull, reason: code);
          expect(NotificationRowMapper.typeCode(n!.type), code);
        }
      },
    );

    test('a type from a newer server is skipped, not an error', () {
      expect(
        NotificationRowMapper.notification(
          UserRole.player,
          row('x', 'tournament_reminder'),
        ),
        isNull,
      );
    });

    test('a broken row is a format error, never a guess', () {
      for (final broken in [
        row('x', '')..remove('type'),
        row('x', 'announcement')..['params'] = 'oops',
        row('x', 'announcement')..remove('created_at'),
        row('x', 'announcement')..['notification_id'] = null,
        row('x', 'announcement')..['read_at'] = 'yesterday',
      ]) {
        expect(
          () => NotificationRowMapper.notification(UserRole.player, broken),
          throwsA(isA<MatchRowFormatException>()),
        );
      }
    });

    test('missing params are an empty map', () {
      final n = NotificationRowMapper.notification(
        UserRole.player,
        row('x', 'announcement')..['params'] = null,
      )!;
      expect(n.params, isEmpty);
    });

    test('a short page is the last; a full one continues after its last row — skipped types too', () {
      final short = NotificationRowMapper.page(UserRole.player, [
        row('a', 'announcement'),
      ], 2);
      expect(short.items, hasLength(1));
      expect(short.next, isNull);
      final full = NotificationRowMapper.page(UserRole.player, [
        row('a', 'announcement'),
        row(
          'b',
          'something_new',
          createdAt: '2026-11-21T09:00:00.000001+00:00',
        ),
      ], 2);
      expect(full.items.map((n) => n.id), ['a']);
      expect(
        full.next,
        const NotificationCursor('2026-11-21T09:00:00.000001+00:00', 'b'),
      );
    });

    test('announcements: record, audience codes, the publish result', () {
      final a = NotificationRowMapper.announcement({
        'announcement_id': 'ann-1',
        'club_id': 'club-a',
        'club_name': 'Note Lions',
        'title': 'Nets on Friday',
        'message': 'Bring your kit.',
        'audience': 'players',
        'created_at': '2026-11-22T10:00:00+00:00',
        'recipient_count': null,
      });
      expect(
        (a.title, a.audience, a.recipientCount),
        ('Nets on Friday', AnnouncementAudience.players, null),
      );
      expect(
        () => NotificationRowMapper.announcement({
          'announcement_id': 'x',
          'club_id': 'c',
          'club_name': 'n',
          'title': 't',
          'message': 'm',
          'audience': 'everyone',
          'created_at': '2026-11-22T10:00:00+00:00',
        }),
        throwsA(isA<MatchRowFormatException>()),
      );
      for (final a in AnnouncementAudience.values) {
        expect([
          'all',
          'players',
          'staff',
        ], contains(NotificationRowMapper.audienceCode(a)));
      }
      final p = NotificationRowMapper.published({
        'announcement_id': 'ann-2',
        'recipient_count': 16,
      });
      expect((p.id, p.recipientCount), ('ann-2', 16));
    });
  });

  group('SupabaseNotificationInboxRepository', () {
    late FakeNotificationsDb db;
    late SupabaseNotificationInboxRepository repo;
    setUp(() {
      db = FakeNotificationsDb();
      repo = SupabaseNotificationInboxRepository(db: db);
    });

    test('a page asks for the role'
        's inbox; the next one continues after the cursor', () async {
      db.pages.add([
        row('a', 'announcement'),
        row('b', 'lineup_selected', createdAt: '2026-11-21T08:00:00.5+00:00'),
      ]);
      final first = await repo.page(UserRole.player, limit: 2);
      expect(db.calls.last.params, {
        'p_inbox': 'player',
        'p_before': null,
        'p_before_id': null,
        'p_limit': 2,
      });
      expect(first.items, hasLength(2));
      await repo.page(UserRole.clubOwner, after: first.next, limit: 500);
      expect(db.calls.last.params, {
        'p_inbox': 'club_owner',
        'p_before': '2026-11-21T08:00:00.5+00:00',
        'p_before_id': 'b',
        'p_limit': 100,
      });
      await repo.page(UserRole.player, limit: 0);
      expect(db.calls.last.params['p_limit'], 1);
    });

    test('unread count per inbox', () async {
      db.unread = 4;
      expect(await repo.unreadCount(UserRole.clubOwner), 4);
      expect(db.calls.single.params, {'p_inbox': 'club_owner'});
    });

    test(
      'mark read: unique ids, none = no call, more than 200 in batches',
      () async {
        expect(await repo.markRead(const []), 0);
        expect(await repo.markRead(const ['']), 0);
        expect(db.calls, isEmpty);
        expect(await repo.markRead(['a', 'b', 'a']), 2);
        expect(db.calls.single.params, {
          'p_ids': ['a', 'b'],
        });
        db.calls.clear();
        expect(
          await repo.markRead([for (var i = 0; i < 450; i++) 'id$i']),
          450,
        );
        expect(
          [for (final c in db.calls) (c.params['p_ids']! as List).length],
          [200, 200, 50],
        );
      },
    );

    test(
      'mark all read up to the newest one shown (its exact server time)',
      () async {
        db.markAllResult = 7;
        expect(
          await repo.markAllRead(
            UserRole.player,
            upTo: const NotificationCursor(
              '2026-11-22T10:00:00.123456+00:00',
              'n9',
            ),
          ),
          7,
        );
        expect(db.calls.single.params, {
          'p_inbox': 'player',
          'p_up_to': '2026-11-22T10:00:00.123456+00:00',
        });
        await repo.markAllRead(UserRole.clubOwner);
        expect(db.calls.last.params, {
          'p_inbox': 'club_owner',
          'p_up_to': null,
        });
      },
    );

    test(
      'refusals and failures become app errors — never the raw text',
      () async {
        for (final (failure, expected) in [
          (
            refusal('42501', 'notification: not authenticated'),
            isA<NotSignedInException>(),
          ),
          (
            refusal('22023', 'notification: invalid'),
            isA<NotificationRuleException>(),
          ),
          (const GatewayNetworkException(), isA<BackendUnavailableException>()),
        ]) {
          db.failOn['my_notifications'] = failure;
          expect(await errorOf(repo.page(UserRole.player)), expected);
        }
        db.failOn.clear();
        db.pages.add([row('a', 'announcement')..remove('created_at')]);
        expect(
          await errorOf(repo.page(UserRole.player)),
          isA<BackendOperationException>(),
        );
      },
    );
  });

  group('SupabaseAnnouncementServerRepository', () {
    late FakeNotificationsDb db;
    late SupabaseAnnouncementServerRepository repo;
    setUp(() {
      db = FakeNotificationsDb();
      repo = SupabaseAnnouncementServerRepository(db: db);
    });

    test('publish sends the club, text and audience code; returns id and recipient count', () async {
      final p = await repo.publish(
        clubId: 'club-a',
        title: 'Nets',
        message: 'Friday',
        audience: AnnouncementAudience.staff,
      );
      expect(db.calls.single.params, {
        'p_club_id': 'club-a',
        'p_title': 'Nets',
        'p_message': 'Friday',
        'p_audience': 'staff',
      });
      expect((p.id, p.recipientCount), ('ann-1', 3));
    });

    test('one announcement; gone = "no longer available"', () async {
      expect(
        await errorOf(repo.announcement('ann-9')),
        isA<NotificationRuleException>(),
      );
      db.announcementRows = [
        {
          'announcement_id': 'ann-9',
          'club_id': 'club-a',
          'club_name': 'Note Lions',
          'title': 'T',
          'message': 'M',
          'audience': 'all',
          'created_at': '2026-11-22T10:00:00+00:00',
          'recipient_count': 16,
        },
      ];
      expect((await repo.announcement('ann-9')).recipientCount, 16);
      expect(db.calls.last.params, {'p_announcement_id': 'ann-9'});
    });

    test('the club list, limit kept to 1–100', () async {
      await repo.clubAnnouncements('club-a', limit: 1000);
      expect(db.calls.single.params, {'p_club_id': 'club-a', 'p_limit': 100});
    });

    test('the server'
        's refusals, in words people can act on', () async {
      for (final (message, text) in [
        ('announcement: invalid title', 'Enter a title (up to 60 characters).'),
        (
          'announcement: invalid message',
          'Enter a message (up to 280 characters).',
        ),
        ('announcement: invalid audience', 'Choose who gets the announcement.'),
        (
          'announcement: too many',
          'Your club has sent 20 announcements in the last 24 hours — please try again later.',
        ),
        (
          'announcement: something new',
          "Some announcement details aren't valid — please check and try again",
        ),
      ]) {
        db.failOn['publish_club_announcement'] = refusal(
          message.contains('too many') ? 'P0001' : '22023',
          message,
        );
        final e = await errorOf(
          repo.publish(
            clubId: 'c',
            title: 't',
            message: 'm',
            audience: AnnouncementAudience.all,
          ),
        );
        expect(
          e,
          isA<NotificationRuleException>().having(
            (e) => e.message,
            'message',
            text,
          ),
          reason: message,
        );
      }
      db.failOn['publish_club_announcement'] = refusal(
        '42501',
        'announcement: not allowed',
      );
      expect(
        await errorOf(
          repo.publish(
            clubId: 'c',
            title: 't',
            message: 'm',
            audience: AnnouncementAudience.all,
          ),
        ),
        isA<PermissionDeniedException>(),
      );
    });
  });

  group('CRICECO_NOTIFICATIONS switch and providers', () {
    final supabase = BackendConfig.parse(
      backend: 'supabase',
      supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
      supabasePublishableKey: 'sb_publishable_test_0000000000000000',
    );

    test('the switch is off by default', () {
      expect(kNotificationsBuild, isFalse);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(notificationsEnabledProvider), isFalse);
    });

    test(
      'live only on Supabase with the memberships AND notifications switches',
      () {
        for (final config in [supabase, const BackendConfig.memory()]) {
          for (final memberships in [true, false]) {
            for (final notifications in [true, false]) {
              expect(
                BackendModules.notificationsLive(
                  config,
                  memberships: memberships,
                  notifications: notifications,
                ),
                config.isSupabase && memberships && notifications,
              );
            }
          }
        }
      },
    );

    test('the inbox and announcement screens come with the switch (P3), never without it', () {
      for (final (memberships, notifications) in [
        (true, true),
        (true, false),
        (false, true),
      ]) {
        final modules = BackendModules.of(
          supabase,
          memberships: memberships,
          matches: true,
          results: true,
          notifications: notifications,
        );
        final live = memberships && notifications;
        expect(modules.has(BackendModule.notifications), live);
        expect(modules.has(BackendModule.announcements), live);
      }
      // The demo keeps every module, as before.
      expect(
        BackendModules.of(const BackendConfig.memory())
            .has(BackendModule.notifications),
        isTrue,
      );
    });

    ProviderContainer container({
      required BackendConfig config,
      required bool notifications,
      bool memberships = true,
    }) {
      final c = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(config),
          membershipsEnabledProvider.overrideWithValue(memberships),
          notificationsEnabledProvider.overrideWithValue(notifications),
          // Reading the gateway while notifications aren't live is a failure.
          notificationsGatewayProvider.overrideWith(
            (ref) => notifications && memberships && config.isSupabase
                ? FakeNotificationsDb()
                : throw StateError(
                    'notifications gateway used with the switch off',
                  ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('Supabase with both switches → the Supabase repositories', () {
      final c = container(config: supabase, notifications: true);
      expect(c.read(notificationsBackendLiveProvider), isTrue);
      expect(
        c.read(notificationInboxRepositoryProvider),
        isA<SupabaseNotificationInboxRepository>(),
      );
      expect(
        c.read(announcementServerRepositoryProvider),
        isA<SupabaseAnnouncementServerRepository>(),
      );
    });

    for (final (name, config, notifications, memberships) in [
      ('Supabase without the notifications switch', supabase, false, true),
      ('Supabase without the memberships switch', supabase, true, false),
      ('the demo', const BackendConfig.memory(), true, true),
    ]) {
      test(
        '$name → unavailable: nothing listed, the gateway never read',
        () async {
          final c = container(
            config: config,
            notifications: notifications,
            memberships: memberships,
          );
          expect(c.read(notificationsBackendLiveProvider), isFalse);
          final inbox = c.read(notificationInboxRepositoryProvider);
          expect(inbox, isA<UnavailableNotificationInboxRepository>());
          expect((await inbox.page(UserRole.player)).items, isEmpty);
          expect(await inbox.unreadCount(UserRole.clubOwner), 0);
          expect(await inbox.markRead(['a']), 0);
          expect(await inbox.markAllRead(UserRole.player), 0);
          final ann = c.read(announcementServerRepositoryProvider);
          expect(ann, isA<UnavailableAnnouncementServerRepository>());
          expect(await ann.clubAnnouncements('c'), isEmpty);
          expect(
            await errorOf(
              ann.publish(
                clubId: 'c',
                title: 't',
                message: 'm',
                audience: AnnouncementAudience.all,
              ),
            ),
            isA<ModuleUnavailableException>(),
          );
        },
      );
    }

    test('the app never writes notifications: no table write, only the inbox functions', () {
      final offenders = <String>[];
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final name in [
          "from('notifications')",
          'notification_add',
          "from('club_announcements')",
        ]) {
          if (src.contains(name)) offenders.add('${f.path}: $name');
        }
      }
      expect(offenders, isEmpty);
    });
  });

  group('ServerNotificationAdapter', () {
    const full = {
      'club_name': 'Note Lions',
      'opponent_name': 'Note Kings',
      'person_name': 'Ali Khan',
      'role': 'coach',
      'format': 't20',
      'proposed_date': '2026-12-02',
      'venue_name': 'Note Ground',
      'starts_at': '2026-12-02T05:00:00+00:00',
      'selection': 'playing',
      'result': 'won',
      'title': 'Nets on Friday',
    };

    test(
      'every type, in both inboxes: wording, a known icon, the row kept',
      () {
        for (final code in migrationTypeCodes()) {
          for (final role in UserRole.values) {
            final n = note(
              code,
              role: role,
              params: full,
              matchId: 'm1',
              subjectId: 's1',
            );
            final item = ServerNotificationAdapter.item(n);
            expect(item.id, n.id);
            expect(item.role, role);
            expect(item.createdAt, n.createdAt);
            expect(item.title.trim(), isNotEmpty, reason: code);
            expect(item.subtitle.trim(), isNotEmpty, reason: code);
            expect(
              CeIcons.byKey.containsKey(item.icon),
              isTrue,
              reason: '$code: ${item.icon}',
            );
            expect(item.title, isNot(contains('null')), reason: code);
            expect(item.subtitle, isNot(contains('null')), reason: code);
          }
        }
      },
    );

    test('missing parameters get neutral words — no gaps, no "null"', () {
      for (final code in migrationTypeCodes()) {
        final item = ServerNotificationAdapter.item(note(code));
        expect(
          '${item.title} ${item.subtitle}',
          isNot(contains('null')),
          reason: code,
        );
        expect(item.title.trim(), isNotEmpty, reason: code);
      }
    });

    test('every target opens a route inside its own inbox', () {
      for (final code in migrationTypeCodes()) {
        for (final role in UserRole.values) {
          final target = ServerNotificationAdapter.item(
            note(
              code,
              role: role,
              params: full,
              matchId: 'm1',
              subjectId: 's1',
            ),
          ).target;
          final location = notificationLocation(target);
          if (location == null) continue;
          expect(
            role == UserRole.player
                ? Routes.isPlayerLocation(location)
                : Routes.isClubLocation(location),
            isTrue,
            reason: '$code ($role) → $location',
          );
        }
      }
    });

    test('a join request names the person and opens the request', () {
      final item = ServerNotificationAdapter.item(
        note(
          'join_request_received',
          role: UserRole.clubOwner,
          params: full,
          subjectId: 'req-1',
        ),
      );
      expect(item.title, 'Join request from Ali Khan');
      expect(item.subtitle, 'Note Lions');
      expect(
        notificationLocation(item.target),
        Routes.joinRequestProfile('req-1'),
      );
    });

    test('a deleted account is "Deleted player" (D11)', () {
      final item = ServerNotificationAdapter.item(
        note(
          'join_request_received',
          role: UserRole.clubOwner,
          params: {'club_name': 'Note Lions', 'person_deleted': true},
          subjectId: 'r',
        ),
      );
      expect(item.title, 'Join request from Deleted player');
    });

    test('approval names the role; removal stays neutral', () {
      expect(
        ServerNotificationAdapter.item(
          note('join_request_approved', params: full),
        ).subtitle,
        'You are now a coach at Note Lions',
      );
      expect(
        ServerNotificationAdapter.item(
          note(
            'join_request_approved',
            params: {'club_name': 'X', 'role': 'player'},
          ),
        ).subtitle,
        'You are now a player at X',
      );
      final removed = ServerNotificationAdapter.item(
        note('removed_from_club', params: {'club_name': 'Note Lions'}),
      );
      expect(
        (removed.title, removed.subtitle, removed.target),
        (
          'Club membership ended',
          'You are no longer a member of Note Lions',
          null,
        ),
      );
    });

    test('results from the recipient'
        's side, opening the scorecard in their inbox', () {
      final won = ServerNotificationAdapter.item(
        note(
          'result_published',
          role: UserRole.clubOwner,
          params: full,
          matchId: 'm1',
        ),
      );
      expect(won.title, 'Note Lions won against Note Kings');
      expect(won.tone, NotificationTone.green);
      expect(notificationLocation(won.target), Routes.clubMatchResult('m1'));
      final lost = ServerNotificationAdapter.item(
        note(
          'result_published',
          params: {...full, 'result': 'lost'},
          matchId: 'm1',
        ),
      );
      expect(lost.title, 'Note Lions lost to Note Kings');
      expect(notificationLocation(lost.target), Routes.matchScorecard('m1'));
      expect(
        ServerNotificationAdapter.item(
          note(
            'result_corrected',
            params: {...full, 'result': 'tied'},
            matchId: 'm1',
          ),
        ).subtitle,
        'The official result was corrected',
      );
    });

    test('line-up notices: captain, substitute, changed, dropped', () {
      String title(String type, Map<String, Object?> p) =>
          ServerNotificationAdapter.item(note(type, params: p, matchId: 'm1'))
              .title;
      expect(
        title('lineup_selected', {'selection': 'playing', 'leader': 'captain'}),
        'You’re captain of the Playing XI',
      );
      expect(
        title('lineup_selected', {
          'selection': 'playing',
          'leader': 'vice_captain',
        }),
        'You’re vice-captain of the Playing XI',
      );
      expect(
        title('lineup_selected', {'selection': 'sub'}),
        'You’re a substitute',
      );
      expect(
        title('lineup_changed', {
          'selection': 'playing',
          'previous_selection': 'sub',
        }),
        'You’re now in the Playing XI',
      );
      expect(
        title('lineup_dropped', {'previous_selection': 'sub'}),
        'You’re no longer in the line-up',
      );
      expect(
        notificationLocation(
          ServerNotificationAdapter.item(note('lineup_selected', matchId: 'm1'))
              .target,
        ),
        Routes.playerMatchDetails('m1'),
      );
    });

    test('challenges show their terms; announcements open in place', () {
      final c = ServerNotificationAdapter.item(
        note('challenge_received', role: UserRole.clubOwner, params: full),
      );
      expect(c.title, 'Challenge from Note Kings');
      expect(c.subtitle, startsWith('T20 · '));
      expect(c.subtitle, endsWith(' · Note Ground'));
      final a = ServerNotificationAdapter.item(
        note('announcement', params: full, subjectId: 'ann-1'),
      );
      expect(a.subtitle, 'Note Lions · Nets on Friday');
      expect(
        a.target,
        isA<AnnouncementTarget>().having(
          (t) => t.announcementId,
          'id',
          'ann-1',
        ),
      );
    });

    test('the reminders (migration 28): wording and where they lead', () {
      final match = ServerNotificationAdapter.item(
        note('match_reminder', params: full, matchId: 'm1'),
      );
      expect(match.title, 'Your match is coming up');
      expect(match.subtitle, startsWith('Note Lions vs Note Kings · '));
      expect(match.subtitle, endsWith(' · Note Ground'));
      expect(
        notificationLocation(match.target),
        Routes.playerMatchDetails('m1'),
      );
      final owner = ServerNotificationAdapter.item(
        note(
          'match_reminder',
          role: UserRole.clubOwner,
          params: full,
          matchId: 'm1',
        ),
      );
      expect(
        notificationLocation(owner.target),
        Routes.matchManagement(MatchTab.scheduled),
      );
      final expires = {...full, 'expires_at': '2026-12-01T07:30:00+00:00'};
      final challenge = ServerNotificationAdapter.item(
        note('challenge_expiring', role: UserRole.clubOwner, params: expires),
      );
      expect(challenge.title, 'Challenge from Note Kings expires soon');
      expect(challenge.subtitle, startsWith('Answer by '));
      expect(notificationLocation(challenge.target), Routes.myChallenges);
      final offer = ServerNotificationAdapter.item(
        note('ownership_expiring', params: expires),
      );
      expect(offer.title, 'Ownership offer expires soon');
      expect(
        offer.subtitle,
        startsWith('Ali Khan offered you Note Lions · Answer by '),
      );
      expect(notificationLocation(offer.target), Routes.ownershipOffers);
      expect(
        NotificationCategory.of(ServerNotificationType.ownershipExpiring),
        NotificationCategory.membership,
        reason: 'always on',
      );
    });

    test('no target without its id', () {
      expect(
        ServerNotificationAdapter.item(
          note('join_request_received', role: UserRole.clubOwner),
        ).target,
        isNull,
      );
      expect(
        ServerNotificationAdapter.item(note('result_published')).target,
        isNull,
      );
      expect(
        ServerNotificationAdapter.item(note('announcement')).target,
        isNull,
      );
    });

    test('a target never leaves its inbox (a Club Owner screen from the Player inbox is dropped)', () {
      expect(
        ServerNotificationAdapter.item(
          note('join_request_received', subjectId: 'r1'),
        ).target,
        isNull,
      );
      expect(
        ServerNotificationAdapter.item(
          note('ownership_offered', role: UserRole.clubOwner, params: full),
        ).target,
        isNull,
      );
    });
  });
}
