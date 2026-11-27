// M8 (migration 33, the CRICECO_PLAYER_HUNT switch): Player Hunt and Playing
// Opportunities on the server — listing, posts, interest, Available Players,
// invites and their answer — through the real repository, controllers and
// screens on FakeHuntDb; the three hunt notifications' wording and routing.
// No network, no database. Switch OFF: today's behaviour, no call made.
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/hunt_row_mapper.dart';
import 'package:criceco/data/supabase/notification_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_hunt_repository.dart';
import 'package:criceco/features/club/hunt/player_hunt_controller.dart';
import 'package:criceco/features/club/screens/player_hunt_screen.dart';
import 'package:criceco/features/notifications/notifications_controller.dart'
    show notificationLocation;
import 'package:criceco/features/notifications/push/push_messaging.dart';
import 'package:criceco/features/notifications/push/push_ui.dart';
import 'package:criceco/features/notifications/server_notification_adapter.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/features/player/screens/open_matches_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'discovery_hunt_fakes.dart';
import 'match_fakes.dart';
import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

final _now = DateTime.utc(2026, 11, 20, 6);

class _World {
  _World._(
    this.auth,
    this.clubDb,
    this.mdb,
    this.hdb,
    this.owner,
    this.ownerB,
    this.player,
    this.clubA,
    this.clubB,
  );

  final FakeAuth auth;
  final FakeClubDb clubDb;
  final FakeMatchDb mdb;
  final FakeHuntDb hdb;
  final AuthUser owner, ownerB, player;
  final String clubA, clubB;

  static _World create() {
    final db = FakeDb();
    final auth = FakeAuth(db);
    final clubDb = FakeClubDb(db);
    final mdb = FakeMatchDb(auth, clubDb);
    final a = auth.addUser('a@example.com', 'Cricket@123');
    final b = auth.addUser('b@example.com', 'Cricket@123');
    final p = auth.addUser('p@example.com', 'Cricket@123');
    final clubA = mdb.addClub(a.id, 'Lahore Lions', shortName: 'LL');
    final clubB = mdb.addClub(b.id, 'Karachi Kings', city: 'Karachi');
    final hdb = FakeHuntDb(auth, owners: {clubA: a.id, clubB: b.id});
    auth.current = a;
    return _World._(auth, clubDb, mdb, hdb, a, b, p, clubA, clubB);
  }

  Club get ownClub => Club(
    id: clubA,
    name: 'Lahore Lions',
    city: 'Lahore',
    type: ClubType.corporate,
    code: 'ABC001',
  );

  Future<List<Override>> overrides({
    bool hunt = true,
    bool asPlayer = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    if (asPlayer) auth.current = player;
    final me = asPlayer ? player : owner;
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(_supabase),
      membershipsEnabledProvider.overrideWithValue(true),
      matchesEnabledProvider.overrideWithValue(true),
      playerHuntEnabledProvider.overrideWithValue(hunt),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      authGatewayProvider.overrideWithValue(auth),
      clubGatewayProvider.overrideWithValue(clubDb),
      membershipGatewayProvider.overrideWithValue(
        FakeMembershipDb(clubDb.db, clubDb),
      ),
      matchGatewayProvider.overrideWithValue(mdb),
      huntGatewayProvider.overrideWithValue(hdb),
      currentAccountProvider.overrideWithValue(
        UserAccount(
          id: me.id,
          fullName: asPlayer ? 'Hamza Ali' : 'Ali Raza',
          contactMethod: ContactMethod.email,
          city: 'Lahore',
          playerProfile: const PlayerProfile(
            role: PlayerRole.batsman,
            isWicketkeeper: true,
          ),
        ),
      ),
      currentClubProvider.overrideWithValue(asPlayer ? null : ownClub),
    ];
  }

  Future<ProviderContainer> container({
    bool hunt = true,
    bool asPlayer = false,
  }) async {
    final c = ProviderContainer(
      overrides: await overrides(hunt: hunt, asPlayer: asPlayer),
    );
    addTearDown(c.dispose);
    return c;
  }
}

Future<void> _settled(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('rows', () {
    test(
      'a post: short name, Pakistan date, HH:MM, budget, the caller\'s flags',
      () {
        final p = HuntRowMapper.post({
          ...huntPostRow(
            'p1',
            'c1',
            'Karachi Kings',
            role: 'all_rounder',
            budget: 'from_2000_to_5000',
            time: '14:30',
          ),
          'club_short_name': 'KK',
          'interested': true,
        });
        expect(
          (p.id, p.clubId, p.clubName, p.clubAbbr),
          ('p1', 'c1', 'KK', 'K'),
        );
        expect(
          (p.role, p.format, p.playersNeeded),
          (HuntRole.allRounder, MatchFormat.t20, 2),
        );
        expect(
          (p.location, p.date, p.time, p.budget),
          (
            'Lahore',
            DateTime(2026, 11, 25),
            '14:30',
            HuntBudget.from2000to5000,
          ),
        );
        expect(
          (p.interested, p.isMyClub, p.isOpen, p.interestCount),
          (true, false, true, null),
        );
        final any = HuntRowMapper.post(
          huntPostRow(
            'p2',
            'c1',
            'X',
            city: null,
            date: null,
            time: null,
            status: 'closed',
          ),
        );
        expect(
          (any.location, any.date, any.time, any.isOpen),
          (null, null, null, false),
        );
      },
    );

    test('publish parameters: codes, date, time, budget; blank notes none', () {
      final params = HuntRowMapper.publishParams(
        'club-1',
        PlayerHuntPost(
          id: 'x',
          clubId: 'club-1',
          clubName: 'LL',
          clubAbbr: 'LL',
          role: HuntRole.wicketKeeper,
          format: MatchFormat.odi,
          playersNeeded: 3,
          date: DateTime(2026, 12, 2),
          time: '09:00',
          budget: HuntBudget.under2000,
          notes: '  ',
        ),
      );
      expect(params, {
        'p_club_id': 'club-1',
        'p_role': 'wicket_keeper',
        'p_format': 'odi',
        'p_players_needed': 3,
        'p_city': null,
        'p_match_date': '2026-12-02',
        'p_match_time': '09:00',
        'p_budget': 'under_2000',
        'p_notes': null,
      });
    });

    test('Available Players: no phone; figures only when shared; the invite status', () {
      final shared = HuntRowMapper.openPlayer(
        openPlayerRow('u1', 'Shan', inviteStatus: 'declined'),
      );
      expect(
        (
          shared.role,
          shared.city,
          shared.inviteStatus,
          shared.availabilityLabel,
        ),
        (HuntRole.bowler, 'Lahore', HuntInviteStatus.declined, 'Available Now'),
      );
      expect(
        (
          shared.figures!.matches,
          shared.figures!.wickets,
          shared.figures!.economy,
        ),
        (7, 9, 6.1),
      );
      final hidden = HuntRowMapper.openPlayer(
        openPlayerRow('u2', 'Zia', statsVisible: false, member: true),
      );
      expect(
        (hidden.figures, hidden.isMember, hidden.inviteStatus),
        (null, true, null),
      );
    });

    test('invites both ways; an interest with the phone only when shared', () {
      final mine = HuntRowMapper.playerInvite(
        myInviteRow('i1', 'Karachi Kings'),
      );
      expect(
        (
          mine.clubName,
          mine.postRole,
          mine.postFormat,
          mine.postDate,
          mine.status,
        ),
        (
          'Karachi Kings',
          HuntRole.allRounder,
          MatchFormat.odi,
          DateTime(2026, 11, 28),
          HuntInviteStatus.pending,
        ),
      );
      final i = HuntRowMapper.interest({
        'interest_id': 'x1',
        'post_id': 'p1',
        'user_id': 'u1',
        'full_name': 'Shan',
        'avatar_path': null,
        'role': 'bowler',
        'city': 'Lahore',
        'phone': null,
        'created_at': '2026-11-20T05:00:00+00:00',
        'stats_visible': false,
      });
      expect(
        (i.name, i.role, i.phone, i.figures),
        ('Shan', HuntRole.bowler, null, null),
      );
    });
  });

  group('switch', () {
    test(
      'OFF: an empty in-memory repository, the module unavailable, no call',
      () async {
        final w = _World.create();
        final c = await w.container(hunt: false);
        expect(c.read(huntRepositoryProvider), isA<InMemoryHuntRepository>());
        expect(
          c.read(backendModulesProvider).has(BackendModule.playerHunt),
          isFalse,
        );
        expect(await c.read(huntRepositoryProvider).posts(), isEmpty);
        expect(await c.read(huntRepositoryProvider).myListing(), isNull);
        expect(await c.read(myHuntInvitesProvider.future), isEmpty);
        expect(await c.read(huntInterestsProvider.future), isEmpty);
        expect(w.hdb.calls, isEmpty);
      },
    );

    test('ON: the server repository and the module', () async {
      final w = _World.create();
      final c = await w.container();
      expect(c.read(huntRepositoryProvider), isA<SupabaseHuntRepository>());
      expect(
        c.read(backendModulesProvider).has(BackendModule.playerHunt),
        isTrue,
      );
    });
  });

  group('owner: Find Player', () {
    test('post a requirement: the server\'s parameters; Your Published Slots from club_hunt_posts', () async {
      final w = _World.create();
      w.hdb.posts.add(
        huntPostRow(
          'old',
          w.clubA,
          'Lahore Lions',
          status: 'closed',
          mine: true,
        ),
      );
      final c = await w.container();
      expect(
        await c.read(playerHuntProvider.future),
        isEmpty,
        reason: 'closed posts are not shown',
      );
      expect(w.hdb.count('club_hunt_posts'), 1);
      final error = await c
          .read(playerHuntProvider.notifier)
          .publish(
            HuntDraft(
              role: HuntRole.bowler,
              playersNeeded: 2,
              location: 'Lahore',
              date: DateTime(2026, 11, 25),
              time: '14:00',
            ),
          );
      expect(error, isNull);
      expect(w.hdb.calls.lastWhere((x) => x.fn == 'publish_hunt_post').params, {
        'p_club_id': w.clubA,
        'p_role': 'bowler',
        'p_format': 't20',
        'p_players_needed': 2,
        'p_city': 'Lahore',
        'p_match_date': '2026-11-25',
        'p_match_time': '14:00',
        'p_budget': 'any',
        'p_notes': null,
      });
      expect(c.read(myHuntPostsProvider).single.id, startsWith('post-'));
      // The server's own limits come back as friendly text.
      w.hdb.failOn['publish_hunt_post'] = const GatewayConstraintException(
        sqlState: 'P0001',
        message: 'hunt: too many posts',
      );
      expect(
        await c
            .read(playerHuntProvider.notifier)
            .publish(const HuntDraft(role: HuntRole.batsman)),
        HuntTexts.tooManyPosts,
      );
    });

    test('Remove Slot closes the post on the server', () async {
      final w = _World.create();
      w.hdb.posts.add(huntPostRow('p1', w.clubA, 'Lahore Lions', mine: true));
      final c = await w.container();
      await c.read(playerHuntProvider.future);
      await c.read(playerHuntProvider.notifier).remove('p1');
      expect(w.hdb.calls.last.fn, 'close_hunt_post');
      expect(w.hdb.calls.last.params, {'p_post_id': 'p1'});
      expect(c.read(myHuntPostsProvider), isEmpty);
    });

    test(
      'interested players by post; accepted invites with the phone',
      () async {
        final w = _World.create();
        w.hdb.interestRows.addAll([
          for (final (id, post) in [('x1', 'p1'), ('x2', 'p1'), ('x3', 'p2')])
            {
              'interest_id': id,
              'post_id': post,
              'user_id': 'u-$id',
              'full_name': 'Player $id',
              'avatar_path': null,
              'role': 'bowler',
              'city': 'Lahore',
              'phone': id == 'x1' ? '+923001234567' : null,
              'created_at': '2026-11-20T05:00:00+00:00',
              'stats_visible': false,
            },
        ]);
        w.hdb.invites
          ..add({
            'invite_id': 'i1',
            'club_id': w.clubA,
            'user_id': 'u9',
            'status': 'accepted',
            'phone': '+923009999999',
            'created_at': '2026-11-20T05:00:00+00:00',
            'expires_at': null,
          })
          ..add({
            'invite_id': 'i2',
            'club_id': w.clubA,
            'user_id': 'u8',
            'status': 'pending',
            'created_at': '2026-11-20T05:00:00+00:00',
            'expires_at': null,
          });
        final c = await w.container();
        final byPost = await c.read(huntInterestsProvider.future);
        expect(byPost['p1']!.map((i) => i.id), ['x1', 'x2']);
        expect(byPost['p1']!.first.phone, '+923001234567');
        final accepted = await c.read(acceptedHuntInvitesProvider.future);
        expect(accepted.single.phone, '+923009999999');
      },
    );

    test('Available Players: the owner\'s list; standing invites known; Invite with feedback', () async {
      final w = _World.create();
      w.hdb.players
        ..add(openPlayerRow('u1', 'Shan', inviteStatus: 'pending'))
        ..add(openPlayerRow('u2', 'Zia'))
        ..add(openPlayerRow('u3', 'Old', inviteStatus: 'expired'));
      final c = await w.container();
      final players = await c.read(openPlayersProvider.future);
      expect(players.map((p) => p.name), ['Shan', 'Zia', 'Old']);
      expect(c.read(huntRepositoryProvider).invitedPlayerIds(w.clubA), {'u1'});
      final ctrl = c.read(invitedPlayersProvider.notifier);
      expect(await ctrl.send('u2'), isNull);
      expect(w.hdb.calls.last.params, {
        'p_club_id': w.clubA,
        'p_user_id': 'u2',
        'p_post_id': null,
      });
      expect(c.read(invitedPlayersProvider), contains('u2'));
      expect(
        await ctrl.send('u2'),
        HuntTexts.alreadyInvited,
        reason: 'never sent twice',
      );
      expect(w.hdb.count('invite_hunt_player'), 1);
      w.hdb.failOn['invite_hunt_player'] = const GatewayConstraintException(
        sqlState: 'P0001',
        message: 'hunt: too many invites',
      );
      expect(await ctrl.send('u3'), HuntTexts.tooManyInvites);
    });

    test(
      'a player (no club) gets no Available Players — and no call',
      () async {
        final w = _World.create();
        final c = await w.container(asPlayer: true);
        expect(await c.read(openPlayersProvider.future), isEmpty);
        expect(w.hdb.count('hunt_open_players'), 0);
      },
    );
  });

  group('player: Playing Opportunities', () {
    test('the listing is read from the server, and saved with role and city; a refusal goes back', () async {
      final w = _World.create();
      w.hdb.listings[w.player.id] = {
        'listed': true,
        'role': 'batsman',
        'city': 'Lahore',
        'visible': true,
      };
      final c = await w.container(asPlayer: true);
      c.read(playerAvailabilityProvider);
      await _settled(() => c.read(playerAvailabilityProvider).openToOffers);
      expect(c.read(playerAvailabilityProvider).openToOffers, isTrue);
      expect(
        await c
            .read(playerAvailabilityProvider.notifier)
            .setOpenToOffers(false),
        isNull,
      );
      expect(w.hdb.calls.last.params, {
        'p_listed': false,
        'p_role': null,
        'p_city': null,
      });
      expect(
        await c.read(playerAvailabilityProvider.notifier).setOpenToOffers(true),
        isNull,
      );
      expect(w.hdb.calls.last.params, {
        'p_listed': true,
        'p_role': 'wicket_keeper',
        'p_city': 'Lahore',
      });
      w.hdb.failOn['set_my_hunt_listing'] = const GatewayConstraintException(
        sqlState: 'P0001',
        message: 'hunt: player profile required',
      );
      expect(
        await c
            .read(playerAvailabilityProvider.notifier)
            .setOpenToOffers(false),
        HuntTexts.profileRequired,
      );
      expect(
        c.read(playerAvailabilityProvider).openToOffers,
        isTrue,
        reason: 'unchanged',
      );
    });

    test('I\'m Interested / withdraw on the server; the server\'s flag shows it; own club refused', () async {
      final w = _World.create();
      w.hdb.posts
        ..add(huntPostRow('p1', w.clubB, 'Karachi Kings'))
        ..add(huntPostRow('p2', w.clubB, 'Karachi Kings', role: 'batsman'));
      w.hdb.interests['p2'] = {w.player.id};
      final c = await w.container(asPlayer: true);
      await c.read(huntPostsProvider.future);
      expect(c.read(huntInterestProvider), {'p2'});
      expect(await c.read(huntInterestProvider.notifier).express('p1'), isNull);
      expect(w.hdb.interests['p1'], {w.player.id});
      expect(c.read(huntInterestProvider), {'p1', 'p2'});
      expect(
        await c.read(huntInterestProvider.notifier).withdraw('p2'),
        isNull,
      );
      expect(c.read(huntInterestProvider), {'p1'});
      w.hdb.posts.first['status'] = 'closed';
      await c.read(huntInterestProvider.notifier).withdraw('p1');
      expect(
        await c.read(huntInterestProvider.notifier).express('p1'),
        HuntTexts.postClosed,
      );
    });

    test('invites: listed; accepting never joins the club; an answered one refused', () async {
      final w = _World.create();
      w.hdb.myInviteRows.add(myInviteRow('i1', 'Karachi Kings'));
      final c = await w.container(asPlayer: true);
      final invites = await c.read(myHuntInvitesProvider.future);
      expect(invites.single.status, HuntInviteStatus.pending);
      final status = await c
          .read(huntRepositoryProvider)
          .respondInvite('i1', accept: true);
      expect(status, HuntInviteStatus.accepted);
      expect(
        w.clubDb.clubs.values.map((r) => r['name']),
        isNot(contains('anything new')),
      );
      final again = await c
          .read(huntRepositoryProvider)
          .respondInvite('i1', accept: false)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((again! as HuntRuleException).message, HuntTexts.inviteAnswered);
    });
  });

  test(
    'every hunt refusal gets its own text; access refusals are the usual ones',
    () {
      Exception map(String state, String m) => SupabaseErrorMapper.map(
        GatewayConstraintException(sqlState: state, message: m),
      );
      for (final (state, reason, text) in [
        ('P0001', 'duplicate post', HuntTexts.duplicate),
        ('P0001', 'too many open posts', HuntTexts.tooManyOpen),
        ('P0001', 'too many posts', HuntTexts.tooManyPosts),
        ('P0001', 'too many interests', HuntTexts.tooManyInterests),
        ('P0001', 'too many invites', HuntTexts.tooManyInvites),
        ('22023', 'invalid players needed', HuntTexts.players),
        ('22023', 'invalid player', HuntTexts.playerUnavailable),
        ('22023', 'cannot invite yourself', HuntTexts.self),
        ('22023', 'invalid date', HuntTexts.date),
        ('22023', 'city required', HuntTexts.cityRequired),
        ('P0001', 'already a member', HuntTexts.alreadyMember),
        ('P0001', 'invite declined recently', HuntTexts.declinedRecently),
        ('P0002', 'invite not found', HuntTexts.inviteGone),
        ('P0001', 'own club', HuntTexts.ownClub),
        ('P0001', 'something new', HuntTexts.generic),
      ]) {
        final e = map(state, 'hunt: $reason');
        expect(e, isA<HuntRuleException>(), reason: reason);
        expect((e as HuntRuleException).message, text, reason: reason);
      }
      expect(
        map('42501', 'hunt: not allowed'),
        isA<PermissionDeniedException>(),
      );
      expect(
        map('42501', 'hunt: not authenticated'),
        isA<NotSignedInException>(),
      );
      expect(
        map('P0002', 'hunt: profile not found'),
        isA<ProfileNotFoundException>(),
      );
    },
  );

  group('notifications', () {
    ServerNotification note(
      String type,
      UserRole role,
      Map<String, Object?> params,
    ) => NotificationRowMapper.notification(role, {
      'notification_id': 'n1',
      'type': type,
      'params': params,
      'club_id': 'c1',
      'match_id': null,
      'subject_id': 's1',
      'created_at': '2026-11-20T05:00:00+00:00',
      'read_at': null,
    })!;

    test('wording as the push templates; categories; deleted player', () {
      final invite = ServerNotificationAdapter.item(
        note('hunt_invite_received', UserRole.player, {
          'club_name': 'Karachi Kings',
          'hunt_role': 'all_rounder',
          'format': 't20',
          'match_date': '2026-12-02',
        }),
      );
      expect(invite.title, 'Playing invite from Karachi Kings');
      expect(invite.subtitle, 'All-Rounder · T20 · 2 Dec');
      expect(
        ServerNotificationAdapter.item(
          note('hunt_invite_received', UserRole.player, {}),
        ).subtitle,
        'Open Playing Opportunities to answer',
      );
      final interest = ServerNotificationAdapter.item(
        note('hunt_interest_received', UserRole.clubOwner, {
          'club_name': 'Lahore Lions',
          'person_name': 'Shan',
          'hunt_role': 'bowler',
        }),
      );
      expect(
        (interest.title, interest.subtitle),
        ('Shan is interested in playing', 'Bowler'),
      );
      expect(
        ServerNotificationAdapter.item(
          note('hunt_interest_received', UserRole.clubOwner, {
            'club_name': 'Lahore Lions',
          }),
        ).subtitle,
        'Lahore Lions',
      );
      final accepted = ServerNotificationAdapter.item(
        note('hunt_invite_accepted', UserRole.clubOwner, {
          'club_name': 'Lahore Lions',
          'person_deleted': true,
        }),
      );
      expect(
        (accepted.title, accepted.subtitle),
        (
          'Deleted player accepted your invite',
          'Lahore Lions · See Player Hunt',
        ),
      );
      expect(
        NotificationCategory.of(ServerNotificationType.huntInviteReceived),
        NotificationCategory.membership,
      );
      expect(
        NotificationCategory.of(ServerNotificationType.huntInterestReceived),
        NotificationCategory.joinRequests,
      );
      expect(
        NotificationCategory.of(ServerNotificationType.huntInviteAccepted),
        NotificationCategory.joinRequests,
      );
    });

    test('the five tournament types (migration 35): templates\' wording, owner targets, categories', () {
      final received = ServerNotificationAdapter.item(
        note('tournament_registration_received', UserRole.clubOwner, {
          'tournament_id': 't1',
          'tournament_name': 'Winter Cup',
          'applicant_name': 'Karachi Kings',
          'team_name': 'KK XI',
        }),
      );
      expect(
        (received.title, received.subtitle),
        ('Tournament entry from Karachi Kings', 'Winter Cup · KK XI'),
      );
      expect(
        notificationLocation(received.target),
        Routes.teamRequestDetail('t1', 's1'),
      );
      final approved = ServerNotificationAdapter.item(
        note('tournament_registration_approved', UserRole.clubOwner, {}),
      );
      expect(
        (approved.title, approved.subtitle),
        ('Tournament entry approved', 'See My Registrations'),
      );
      expect(
        notificationLocation(approved.target),
        Routes.registrationDetails('s1'),
      );
      final fixtures = ServerNotificationAdapter.item(
        note('tournament_fixtures_published', UserRole.clubOwner, {
          'tournament_name': 'Winter Cup',
          'round_name': 'Quarter-finals',
          'start_date': '2026-12-05',
        }),
      );
      expect(fixtures.subtitle, 'Winter Cup · Quarter-finals · Starts 5 Dec');
      expect(
        NotificationCategory.of(
          ServerNotificationType.tournamentRegistrationReceived,
        ),
        NotificationCategory.joinRequests,
      );
      expect(
        NotificationCategory.of(ServerNotificationType.tournamentTeamRemoved),
        NotificationCategory.challenges,
      );
      expect(
        NotificationCategory.of(
          ServerNotificationType.tournamentFixturesPublished,
        ),
        NotificationCategory.matches,
      );
    });

    test('a push tap opens the right hunt screen, in its own role', () {
      PushTap tap(String type, UserRole role) => PushTap(
        notificationId: 'n1',
        type: type,
        role: role,
        subjectId: 's1',
        clubId: 'c1',
      );
      expect(
        pushLocation(tap('hunt_invite_received', UserRole.player)),
        Routes.openMatches,
      );
      expect(
        pushLocation(tap('hunt_interest_received', UserRole.clubOwner)),
        Routes.playerHunt,
      );
      expect(
        pushLocation(tap('hunt_invite_accepted', UserRole.clubOwner)),
        HuntTab.available.location,
      );
      // Never across inboxes: the inbox instead.
      expect(
        pushLocation(tap('hunt_invite_received', UserRole.clubOwner)),
        Routes.notifications,
      );
      expect(
        pushLocation(tap('hunt_interest_received', UserRole.player)),
        Routes.notifications,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Screens
  // ---------------------------------------------------------------------------
  group('screens (Player Hunt on)', () {
    Future<_World> pump(
      WidgetTester tester,
      String location, {
      bool asPlayer = false,
      void Function(_World w)? before,
    }) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final w = _World.create();
      before?.call(w);
      final overrides = await w.overrides(asPlayer: asPlayer);
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: Routes.openMatches,
            builder: (_, _) => const OpenMatchesScreen(),
          ),
          GoRoute(
            path: Routes.playerHunt,
            builder: (_, s) => PlayerHuntScreen(
              tab: HuntTab.parse(s.uri.queryParameters['tab']),
            ),
          ),
          GoRoute(
            path: Routes.playerHome,
            builder: (_, _) => const Scaffold(body: Text('player home')),
          ),
          GoRoute(
            path: Routes.clubHome,
            builder: (_, _) => const Scaffold(body: Text('club home')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp.router(
            theme: AppTheme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return w;
    }

    testWidgets(
      'Playing Opportunities: an invite answered "I\'m Interested" (contact, never joining)',
      (tester) async {
        final w = await pump(
          tester,
          Routes.openMatches,
          asPlayer: true,
          before: (w) {
            w.hdb.myInviteRows.add(myInviteRow('i1', 'Karachi Kings'));
            w.hdb.posts.add(huntPostRow('p1', w.clubB, 'Karachi Kings'));
          },
        );
        expect(find.text('Your Invites · 1'), findsOneWidget);
        expect(find.text('Playing invite from Karachi Kings'), findsOneWidget);
        expect(
          find.text('All-Rounder · ODI · 28 Nov · Karachi'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('huntInvite.i1.accept')));
        await tester.pumpAndSettle();
        expect(
          find.text('Invite accepted — Karachi Kings can now contact you'),
          findsOneWidget,
        );
        expect(
          w.hdb.calls.where((x) => x.fn == 'respond_hunt_invite').single.params,
          {'p_invite_id': 'i1', 'p_accept': true},
        );
        expect(
          find.byKey(const Key('huntInvite.i1.accept')),
          findsNothing,
          reason: 'answered',
        );

        // A post: I'm Interested → Interest Sent.
        await tester.tap(find.text('Bowler'));
        await tester.pumpAndSettle();
        await tester.tap(find.text("I'm Interested"));
        await tester.pumpAndSettle();
        expect(w.hdb.interests['p1'], {w.player.id});
        expect(find.text('Interest Sent'), findsOneWidget);
      },
    );

    testWidgets(
      'Find Player: a published slot with its interested players (phone only when shared)',
      (tester) async {
        await pump(
          tester,
          Routes.playerHunt,
          before: (w) {
            w.hdb.posts.add(
              huntPostRow(
                'p1',
                w.clubA,
                'Lahore Lions',
                mine: true,
                interestCount: 1,
              ),
            );
            w.hdb.interestRows.add({
              'interest_id': 'x1',
              'post_id': 'p1',
              'user_id': 'u1',
              'full_name': 'Shan Masood',
              'avatar_path': null,
              'role': 'bowler',
              'city': 'Lahore',
              'phone': '+923001234567',
              'created_at': '2026-11-20T05:00:00+00:00',
              'stats_visible': false,
            });
          },
        );
        expect(find.textContaining('Your Published Slots · 1'), findsOneWidget);
        expect(find.text('1 interested'), findsOneWidget);
        expect(find.text('Shan Masood'), findsOneWidget);
        expect(find.text('Bowler · Lahore · +923001234567'), findsOneWidget);
      },
    );

    testWidgets(
      'Available Players: Invite sends once, says so; Invited / Member chips',
      (tester) async {
        final w = await pump(
          tester,
          HuntTab.available.location,
          before: (w) {
            w.hdb.players
              ..add(openPlayerRow('u1', 'Shan'))
              ..add(openPlayerRow('u2', 'Zia', inviteStatus: 'declined'))
              ..add(openPlayerRow('u3', 'Imad', member: true));
          },
        );
        await tester.tap(find.byKey(const Key('hunt.city')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lahore').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('hunt.role')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bowler').last);
        await tester.pumpAndSettle();
        expect(find.text('DECLINED'), findsOneWidget);
        expect(find.text('MEMBER'), findsOneWidget);
        await tester.tap(find.text('Invite'));
        await tester.pumpAndSettle();
        expect(find.text('Invite sent to Shan'), findsOneWidget);
        expect(w.hdb.count('invite_hunt_player'), 1);
        expect(find.text('Invite'), findsNothing);
        expect(find.text('INVITED'), findsOneWidget);
      },
    );
  });
}
