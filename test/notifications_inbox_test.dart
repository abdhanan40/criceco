// M3 P3: the inbox, the dashboard panel, the unread badge and club
// announcements on the SERVER inbox (migration 25, the CRICECO_NOTIFICATIONS
// switch): server read state, paging, refresh on open / pull-down / resume,
// and announcements published and read through the server — on a fake
// gateway with rows shaped like the database functions'. The demo inbox keeps
// its own tests (support_screens_test, club_core_test).
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/club/announcements/announcements.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/notifications/notifications_controller.dart';
import 'package:criceco/features/notifications/notifications_resume_refresh.dart';
import 'package:criceco/features/notifications/notifications_screen.dart';
import 'package:criceco/features/notifications/notifications_sheet.dart';
import 'package:criceco/features/notifications/server_inbox_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);
final _now = DateTime.utc(2026, 11, 22, 12);

/// A `my_notifications` row, [minutes] old.
Map<String, dynamic> row(
  String id,
  String type, {
  int minutes = 5,
  Map<String, Object?> params = const {
    'club_name': 'Note Lions',
    'opponent_name': 'Note Kings',
  },
  String? matchId,
  String? subjectId,
  bool read = false,
}) => {
  'notification_id': id,
  'type': type,
  'params': params,
  'club_id': 'club-a',
  'match_id': matchId,
  'subject_id': subjectId,
  'created_at': _now.subtract(Duration(minutes: minutes)).toIso8601String(),
  'read_at': read ? _now.toIso8601String() : null,
};

List<Map<String, dynamic>> firstPage() => [
  row(
    'n-lineup',
    'lineup_selected',
    params: const {
      'club_name': 'Note Lions',
      'opponent_name': 'Note Kings',
      'selection': 'playing',
      'leader': 'captain',
    },
    matchId: 'm1',
    minutes: 2,
  ),
  row(
    'n-ann',
    'announcement',
    params: const {'club_name': 'Note Lions', 'title': 'Nets on Friday'},
    subjectId: 'ann-1',
    minutes: 3,
  ),
  row('n-old', 'match_cancelled', matchId: 'm2', minutes: 60 * 30, read: true),
];

/// 30 rows (a full page: there may be more).
List<Map<String, dynamic>> fullPage() => [
  for (var i = 0; i < 30; i++)
    row('p1-$i', 'lineup_selected', matchId: 'm$i', minutes: 10 + i),
];

class _World {
  final db = FakeNotificationsDb();
  bool live = true;
  UserRole role = UserRole.player;
  final members = <ClubMember>[
    const ClubMember(
      id: 'mem-owner',
      name: 'Owner',
      role: MemberRole.owner,
      playingRole: PlayerRole.batsman,
    ),
    const ClubMember(
      id: 'mem-1',
      name: 'Ali',
      role: MemberRole.player,
      playingRole: PlayerRole.bowler,
    ),
    const ClubMember(
      id: 'mem-2',
      name: 'Bilal',
      role: MemberRole.player,
      playingRole: PlayerRole.batsman,
    ),
    const ClubMember(id: 'mem-3', name: 'Coach', role: MemberRole.coach),
  ];

  Future<List<Override>> overrides() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(_supabase),
      membershipsEnabledProvider.overrideWithValue(true),
      notificationsEnabledProvider.overrideWithValue(live),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      notificationsGatewayProvider.overrideWith(
        (ref) => live
            ? db
            : throw StateError(
                'notifications gateway used with the switch off',
              ),
      ),
      currentAccountProvider.overrideWithValue(null),
      currentClubProvider.overrideWithValue(
        const Club(
          id: 'club-a',
          name: 'Note Lions',
          city: 'Lahore',
          type: ClubType.corporate,
          code: 'ABC001',
        ),
      ),
      clubMembersProvider.overrideWith((ref) async => members),
      activeRoleProvider.overrideWithValue(role),
    ];
  }

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: await overrides());
    addTearDown(c.dispose);
    return c;
  }

  int calls(String fn) => db.calls.where((c) => c.fn == fn).length;
  Map<String, Object?> last(String fn) =>
      db.calls.lastWhere((c) => c.fn == fn).params;
}

/// The app shell for widget tests: a home with buttons that open the panel
/// and the create-announcement sheet, the Notifications screen, and stand-in
/// destinations.
Future<_World> _pump(
  WidgetTester tester, {
  String location = '/',
  void Function(_World w)? before,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final w = _World();
  before?.call(w);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Column(
            children: [
              TextButton(
                onPressed: () => showNotificationsSheet(context, w.role),
                child: const Text('Open panel'),
              ),
              TextButton(
                onPressed: () => showCreateAnnouncementSheet(context),
                child: const Text('New announcement'),
              ),
              // The bell badge.
              Consumer(
                builder: (_, ref, _) => Text(
                  'badge ${ref.watch(unreadNotificationCountProvider(w.role))}',
                ),
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: Routes.notifications,
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/player/matches/:id',
        builder: (_, s) => Text('match ${s.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: await w.overrides(),
      child: NotificationsResumeRefresh(
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return w;
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.text('Open panel'));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('notifications.panel')), findsOneWidget);
}

void main() {
  group('server inbox (provider level)', () {
    test('rows in the app'
        's wording; unread from the server'
        's read state; the count covers unloaded pages', () async {
      final w = _World()..db.pages.add(firstPage());
      w.db.unread = 5;
      final c = await w.container();
      final items = await c.read(
        roleNotificationsProvider(UserRole.player).future,
      );
      expect(items.map((n) => n.title), [
        'You’re captain of the Playing XI',
        'Club Announcement',
        'Match cancelled',
      ]);
      expect(c.read(unreadNotificationIdsProvider(UserRole.player)), {
        'n-lineup',
        'n-ann',
      });
      expect(c.read(unreadNotificationCountProvider(UserRole.player)), 5);
      expect(w.last('my_notifications'), {
        'p_inbox': 'player',
        'p_before': null,
        'p_before_id': null,
        'p_limit': 30,
      });
    });

    test(
      'marking one read: at once, then on the server; a refusal is undone',
      () async {
        final w = _World()..db.pages.add(firstPage());
        w.db.unread = 5;
        final c = await w.container();
        await c.read(serverInboxProvider(UserRole.player).future);
        final inbox = c.read(serverInboxProvider(UserRole.player).notifier);
        await inbox.markRead('n-lineup');
        expect(w.last('mark_notifications_read'), {
          'p_ids': ['n-lineup'],
        });
        expect(c.read(unreadNotificationIdsProvider(UserRole.player)), {
          'n-ann',
        });
        expect(c.read(unreadNotificationCountProvider(UserRole.player)), 4);
        await inbox.markRead('n-lineup'); // already read: no second call
        await inbox.markRead('n-old');
        expect(w.calls('mark_notifications_read'), 1);

        w.db.failOn['mark_notifications_read'] =
            const GatewayNetworkException();
        await inbox.markRead('n-ann');
        expect(c.read(unreadNotificationIdsProvider(UserRole.player)), {
          'n-ann',
        }, reason: 'undone');
        expect(c.read(unreadNotificationCountProvider(UserRole.player)), 4);
      },
    );

    test('"mark all read" up to the newest shown; the count comes back from the server', () async {
      final w = _World()..db.pages.add(firstPage());
      w.db.unread = 5;
      final c = await w.container();
      await c.read(serverInboxProvider(UserRole.player).future);
      w.db.unread = 1; // one arrived meanwhile
      await c.read(serverInboxProvider(UserRole.player).notifier).markAllRead();
      expect(w.last('mark_all_notifications_read'), {
        'p_inbox': 'player',
        'p_up_to': firstPage().first['created_at'],
      });
      expect(c.read(unreadNotificationIdsProvider(UserRole.player)), isEmpty);
      expect(c.read(unreadNotificationCountProvider(UserRole.player)), 1);
    });

    test('"mark all read" refused: everything as it was, and the caller hears of it', () async {
      final w = _World()..db.pages.add(firstPage());
      w.db.unread = 5;
      final c = await w.container();
      await c.read(serverInboxProvider(UserRole.player).future);
      w.db.failOn['mark_all_notifications_read'] =
          const GatewayNetworkException();
      await expectLater(
        c.read(serverInboxProvider(UserRole.player).notifier).markAllRead(),
        throwsA(anything),
      );
      expect(c.read(unreadNotificationIdsProvider(UserRole.player)), {
        'n-lineup',
        'n-ann',
      });
      expect(c.read(unreadNotificationCountProvider(UserRole.player)), 5);
    });

    test(
      'older pages are appended after the last row, once each, until the end',
      () async {
        final w = _World()
          ..db.pages.addAll([
            fullPage(),
            [fullPage().last, row('p2-a', 'announcement', minutes: 100)],
          ]);
        final c = await w.container();
        await c.read(serverInboxProvider(UserRole.player).future);
        expect(
          c.read(notificationPagingProvider(UserRole.player)).hasMore,
          isTrue,
        );
        await c.read(serverInboxProvider(UserRole.player).notifier).loadMore();
        expect(w.last('my_notifications'), {
          'p_inbox': 'player',
          'p_before': fullPage().last['created_at'],
          'p_before_id': 'p1-29',
          'p_limit': 30,
        });
        final ids = (await c.read(
          roleNotificationsProvider(UserRole.player).future,
        )).map((n) => n.id).toList();
        expect(ids, hasLength(31));
        expect(ids.last, 'p2-a');
        expect(
          c.read(notificationPagingProvider(UserRole.player)).hasMore,
          isFalse,
        );
        await c.read(serverInboxProvider(UserRole.player).notifier).loadMore();
        expect(w.calls('my_notifications'), 2, reason: 'nothing more to load');
      },
    );

    test('a failed older page keeps the list and can be tried again', () async {
      final w = _World()..db.pages.add(fullPage());
      final c = await w.container();
      await c.read(serverInboxProvider(UserRole.player).future);
      w.db.failOn['my_notifications'] = const GatewayNetworkException();
      await expectLater(
        c.read(serverInboxProvider(UserRole.player).notifier).loadMore(),
        throwsA(anything),
      );
      expect(c.read(notificationPagingProvider(UserRole.player)), (
        hasMore: true,
        loading: false,
      ));
      expect(
        (await c.read(roleNotificationsProvider(UserRole.player).future)),
        hasLength(30),
      );
    });

    test(
      'refresh shows the new first page; a failed refresh keeps what was shown',
      () async {
        final w = _World()..db.pages.add(firstPage());
        final c = await w.container();
        await c.read(serverInboxProvider(UserRole.player).future);
        w.db.pages.add([
          row('n-new', 'challenge_received', minutes: 1),
          ...firstPage(),
        ]);
        w.db.unread = 3;
        await c.read(serverInboxProvider(UserRole.player).notifier).refresh();
        expect(
          (await c.read(roleNotificationsProvider(UserRole.player).future))
              .first
              .id,
          'n-new',
        );
        expect(c.read(unreadNotificationCountProvider(UserRole.player)), 3);

        w.db.failOn['my_notifications'] = const GatewayNetworkException();
        await expectLater(
          c.read(serverInboxProvider(UserRole.player).notifier).refresh(),
          throwsA(anything),
        );
        expect(
          (await c.read(roleNotificationsProvider(UserRole.player).future))
              .first
              .id,
          'n-new',
        );
      },
    );

    test('the two inboxes are separate requests', () async {
      final w = _World()
        ..db.pages.addAll([
          firstPage(),
          [row('o1', 'challenge_received')],
        ]);
      final c = await w.container();
      await c.read(roleNotificationsProvider(UserRole.player).future);
      await c.read(roleNotificationsProvider(UserRole.clubOwner).future);
      expect(
        [
          for (final call in w.db.calls)
            if (call.fn == 'my_notifications') call.params['p_inbox'],
        ],
        ['player', 'club_owner'],
      );
      expect(
        w.db.calls
            .where((c) => c.fn == 'notification_unread_count')
            .map((c) => c.params['p_inbox']),
        ['player', 'club_owner'],
      );
    });

    test(
      'without the switch: the demo-style inbox, the server never asked',
      () async {
        final w = _World()..live = false;
        final c = await w.container();
        expect(
          await c.read(roleNotificationsProvider(UserRole.player).future),
          isEmpty,
        );
        expect(c.read(unreadNotificationCountProvider(UserRole.player)), 0);
        expect(c.read(notificationPagingProvider(UserRole.player)), (
          hasMore: false,
          loading: false,
        ));
        expect(w.db.calls, isEmpty);
      },
    );
  });

  group('the panel on the server inbox', () {
    testWidgets('rows, the server'
        's "N new" and unread dots; the badge is the server count', (
      tester,
    ) async {
      await _pump(
        tester,
        before: (w) => w
          ..db.pages.add(firstPage())
          ..db.unread = 7,
      );
      await _openPanel(tester);
      expect(find.text('You’re captain of the Playing XI'), findsOneWidget);
      expect(find.text('Note Lions · Nets on Friday'), findsOneWidget);
      expect(find.text('7 new'), findsOneWidget);
      expect(
        find.byKey(const Key('notifications.panel.dot.n-lineup')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('notifications.panel.dot.n-old')),
        findsNothing,
      );
      expect(find.text('badge 7'), findsOneWidget);
    });

    testWidgets(
      'opening a row marks it read on the server and opens its screen',
      (tester) async {
        final w = await _pump(
          tester,
          before: (w) => w
            ..db.pages.add(firstPage())
            ..db.unread = 2,
        );
        await _openPanel(tester);
        await tester.tap(find.text('You’re captain of the Playing XI'));
        await tester.pumpAndSettle();
        expect(w.last('mark_notifications_read'), {
          'p_ids': ['n-lineup'],
        });
        expect(find.text('match m1'), findsOneWidget);
      },
    );

    testWidgets('re-opening the panel shows what arrived (refresh on open)', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        before: (w) => w..db.pages.add(firstPage()),
      );
      await _openPanel(tester);
      expect(find.text('Challenge from Note Kings'), findsNothing);
      Navigator.of(tester.element(find.byKey(const Key('notifications.panel'))))
          .pop();
      await tester.pumpAndSettle();
      w.db.pages.add([
        row('n-new', 'challenge_received', minutes: 1),
        ...firstPage(),
      ]);
      await _openPanel(tester);
      expect(find.text('Challenge from Note Kings'), findsOneWidget);
    });

    testWidgets('Mark all read: saved on the server; the dots and "N new" go', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        before: (w) => w
          ..db.pages.add(firstPage())
          ..db.unread = 2,
      );
      await _openPanel(tester);
      w.db.unread = 0;
      await tester.tap(find.byKey(const Key('notifications.panel.markAll')));
      await tester.pumpAndSettle();
      expect(w.calls('mark_all_notifications_read'), 1);
      expect(
        find.byKey(const Key('notifications.panel.newBadge')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('notifications.panel.dot.n-lineup')),
        findsNothing,
      );
      expect(find.text('badge 0'), findsOneWidget);
    });

    testWidgets('"Show older notifications" loads the next page', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        before: (w) => w
          ..db.pages.addAll([
            fullPage(),
            fullPage(),
            [row('p2-a', 'announcement', minutes: 100)],
          ]),
      );
      await _openPanel(tester);
      final more = find.byKey(const Key('notifications.more'));
      await tester.scrollUntilVisible(
        more,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(w.last('my_notifications')['p_before_id'], 'p1-29');
      expect(more, findsNothing, reason: 'the last page');
    });

    testWidgets('a failed first load: "Couldn'
        't load", then Retry', (tester) async {
      final w = await _pump(
        tester,
        before: (w) =>
            w.db.failOn['my_notifications'] = const GatewayNetworkException(),
      );
      await _openPanel(tester);
      expect(find.text("Couldn't load notifications"), findsOneWidget);
      w.db.failOn.clear();
      w.db.pages.add(firstPage());
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('You’re captain of the Playing XI'), findsOneWidget);
    });

    testWidgets('an announcement opens in place, read from the server', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        before: (w) {
          w.db.pages.add(firstPage());
          w.db.announcementRows = [
            {
              'announcement_id': 'ann-1',
              'club_id': 'club-a',
              'club_name': 'Note Lions',
              'title': 'Nets on Friday',
              'message': 'Bring your kit — 5 PM at the ground.',
              'audience': 'all',
              'created_at': _now.toIso8601String(),
              'recipient_count': null,
            },
          ];
        },
      );
      await _openPanel(tester);
      await tester.tap(find.text('Club Announcement'));
      await tester.pumpAndSettle();
      expect(w.last('club_announcement'), {'p_announcement_id': 'ann-1'});
      expect(find.text('Bring your kit — 5 PM at the ground.'), findsOneWidget);
      expect(w.last('mark_notifications_read'), {
        'p_ids': ['n-ann'],
      });
    });

    testWidgets('an announcement that is gone says so', (tester) async {
      await _pump(tester, before: (w) => w.db.pages.add(firstPage()));
      await _openPanel(tester);
      await tester.tap(find.text('Club Announcement'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('This announcement is no longer available.'),
        findsOneWidget,
      );
    });
  });

  group('the Notifications screen on the server inbox', () {
    testWidgets('pull-down refreshes; Mark all read is saved', (tester) async {
      final w = await _pump(
        tester,
        location: Routes.notifications,
        before: (w) => w
          ..db.pages.add(firstPage())
          ..db.unread = 2,
      );
      expect(find.text('You’re captain of the Playing XI'), findsOneWidget);
      w.db.pages.add([
        row('n-new', 'challenge_received', minutes: 1),
        ...firstPage(),
      ]);
      await tester.fling(
        find.text('You’re captain of the Playing XI'),
        const Offset(0, 400),
        1200,
      );
      await tester.pumpAndSettle();
      expect(find.text('Challenge from Note Kings'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notifications.markAll')));
      await tester.pumpAndSettle();
      expect(w.calls('mark_all_notifications_read'), 1);
    });

    testWidgets('a failed pull-down keeps the list and says so', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        location: Routes.notifications,
        before: (w) => w.db.pages.add(firstPage()),
      );
      w.db.failOn['my_notifications'] = const GatewayNetworkException();
      await tester.fling(
        find.text('You’re captain of the Playing XI'),
        const Offset(0, 400),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text("Couldn't refresh notifications — please try again"),
        findsOneWidget,
      );
      expect(find.text('You’re captain of the Playing XI'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });

  group('refresh when the app resumes', () {
    testWidgets('a loaded inbox catches up on resume (the badge too)', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        before: (w) => w
          ..db.pages.add(firstPage())
          ..db.unread = 1,
      );
      expect(find.text('badge 1'), findsOneWidget);
      w.db.unread = 4;
      w.db.pages.add(firstPage());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('badge 4'), findsOneWidget);
      expect(w.calls('notification_unread_count'), 2);
    });

    testWidgets('without the switch, resuming asks the server nothing', (
      tester,
    ) async {
      final w = await _pump(tester, before: (w) => w.live = false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(w.db.calls, isEmpty);
    });
  });

  group('club announcements through the server', () {
    Future<_World> openCreate(
      WidgetTester tester, {
      void Function(_World w)? before,
    }) async {
      final w = await _pump(
        tester,
        before: (w) {
          w.role = UserRole.clubOwner;
          before?.call(w);
        },
      );
      await tester.tap(find.text('New announcement'));
      await tester.pumpAndSettle();
      expect(find.text('Create Announcement'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('announcement.title')),
        'Nets on Friday',
      );
      await tester.enterText(
        find.byKey(const Key('announcement.message')),
        'Bring your kit.',
      );
      await tester.pumpAndSettle();
      return w;
    }

    testWidgets('the estimate leaves out the author; the server'
        's count is shown', (tester) async {
      final w = await openCreate(
        tester,
        before: (w) =>
            w.db.published = {'announcement_id': 'ann-9', 'recipient_count': 3},
      );
      expect(
        find.text('Goes to 3 members'),
        findsOneWidget,
        reason: 'owner excluded, like the server',
      );
      await tester.tap(find.text('Publish').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(w.last('publish_club_announcement'), {
        'p_club_id': 'club-a',
        'p_title': 'Nets on Friday',
        'p_message': 'Bring your kit.',
        'p_audience': 'all',
      });
      expect(find.text('Announcement published to 3 members.'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('a server refusal says what to do', (tester) async {
      await openCreate(
        tester,
        before: (w) {
          w.db.failOn['publish_club_announcement'] =
              const GatewayConstraintException(
                sqlState: 'P0001',
                message: 'announcement: too many',
              );
        },
      );
      await tester.tap(find.text('Publish').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text(
          'Your club has sent 20 announcements in the last 24 hours — please try again later.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Create Announcement'),
        findsOneWidget,
        reason: 'the sheet stays open',
      );
      await tester.pumpAndSettle();
    });
  });
}
