// Production demo cleanup (docs/PRODUCTION_DEMO_MODE.md): which repository
// each mode uses, that Supabase builds never show seeded data, that the
// demo keeps it, the "not available yet" gate, and the team controller's
// captain / delete / member-removal rules. No network, no database.
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/config/club_features.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_team_repository.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/membership/join_club_controller.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/features/rankings/rankings_providers.dart';
import 'package:criceco/shared/widgets/backend_pending.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

Future<ProviderContainer> _container({required bool supabase, bool memberships = false, List<Override> extra = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final db = FakeDb();
  final auth = FakeAuth(db);
  final clubs = FakeClubDb(db);
  final m = FakeMembershipDb(db, clubs);
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    if (supabase) ...[
      backendConfigProvider.overrideWithValue(_supabase),
      authGatewayProvider.overrideWithValue(auth),
      profileGatewayProvider.overrideWithValue(db),
      clubGatewayProvider.overrideWithValue(clubs),
      membershipGatewayProvider.overrideWithValue(m),
      teamGatewayProvider.overrideWithValue(FakeTeamDb(m)),
    ],
    membershipsEnabledProvider.overrideWithValue(memberships),
    ...extra,
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('repository selection', () {
    test('memory mode (demo): the seeded demo data, as before', () async {
      final c = await _container(supabase: false);
      expect(await c.read(matchRepositoryProvider).clubMatches(), isNotEmpty);
      expect(await c.read(matchRepositoryProvider).playerMatches(), isNotEmpty);
      expect(await c.read(groundRepositoryProvider).grounds(), isNotEmpty);
      expect(await c.read(tournamentRepositoryProvider).tournaments(), isNotEmpty);
      expect(await c.read(challengeRepositoryProvider).challenges(), isNotEmpty);
      expect(await c.read(huntRepositoryProvider).posts(), isNotEmpty);
      expect(c.read(walletRepositoryProvider).clubWalletBalance, SeedData.walletStartingBalance);
      expect(c.read(teamRepositoryProvider), isA<InMemoryTeamRepository>());
      expect(c.read(playerStatsProvider('Ali Raza')).hasRecord, isTrue);
      expect(await c.read(clubRepositoryProvider).otherClubs(), isNotEmpty);
    });

    test('Supabase mode: nothing seeded, nothing invented', () async {
      final c = await _container(supabase: true);
      final matches = c.read(matchRepositoryProvider);
      expect(await matches.clubMatches(), isEmpty);
      expect(await matches.playerMatches(), isEmpty);
      expect((await matches.performance()).matches, 0);
      expect(await c.read(groundRepositoryProvider).grounds(), isEmpty);
      expect(c.read(reservationRepositoryProvider).holds, isEmpty);
      expect(await c.read(tournamentRepositoryProvider).tournaments(), isEmpty);
      expect(await c.read(challengeRepositoryProvider).challenges(), isEmpty);
      expect(await c.read(challengeRepositoryProvider).matchSeekers(), isEmpty);
      expect(await c.read(huntRepositoryProvider).posts(), isEmpty);
      expect(await c.read(huntRepositoryProvider).openPlayers(), isEmpty);
      for (final role in UserRole.values) {
        expect(await c.read(notificationRepositoryProvider).forRole(role), isEmpty);
      }
      final wallet = c.read(walletRepositoryProvider);
      expect(wallet.clubWalletBalance, 0);
      expect(wallet.ledger, isEmpty);
      expect(await c.read(clubRepositoryProvider).otherClubs(), isEmpty);
    });

    test('Supabase mode: player statistics are "not recorded", never generated', () async {
      final c = await _container(supabase: true);
      final s = c.read(playerStatsProvider('Ali Raza'));
      expect(s.hasRecord, isFalse);
      expect(s.skill, isNull);
      expect(s.rating, '—');
      expect(s.verified, isFalse);
      expect(s.form, isEmpty);
      final pool = c.read(squadPlayerStatsProvider(('', 'Ali Raza', 'Bowler', PlayerAvailability.available)));
      expect(pool.hasRecord, isFalse);
      expect(pool.position, 'Bowler');
      expect(pool.category, SquadCategory.bowler);
    });

    test('teams: unavailable without the switch, Supabase with it', () async {
      final off = await _container(supabase: true);
      expect(off.read(teamRepositoryProvider), isA<UnavailableTeamRepository>());
      final on = await _container(supabase: true, memberships: true);
      expect(on.read(teamRepositoryProvider), isA<SupabaseTeamRepository>());
    });
  });

  group('backend modules and club features', () {
    test('memory: every module (demo data)', () {
      final m = BackendModules.of(const BackendConfig.memory());
      expect(m.isDemo, isTrue);
      expect(BackendModule.values.every(m.has), isTrue);
    });

    test('Supabase: none without the switch; memberships and teams with it', () {
      final off = BackendModules.of(_supabase, memberships: false);
      expect(off.isDemo, isFalse);
      expect(BackendModule.values.any(off.has), isFalse);
      final on = BackendModules.of(_supabase, memberships: true);
      expect(on.has(BackendModule.memberships), isTrue);
      expect(on.has(BackendModule.teams), isTrue);
      expect(on.has(BackendModule.matches), isFalse);
      expect(on.has(BackendModule.payments), isFalse);
    });

    test('join by code follows the switch in Supabase builds', () {
      expect(ClubFeatures.of(const BackendConfig.memory()).joinByCode, isTrue);
      expect(ClubFeatures.of(_supabase, memberships: false).joinByCode, isFalse);
      expect(ClubFeatures.of(_supabase, memberships: true).joinByCode, isTrue);
    });
  });

  group('"not available yet" gate', () {
    Future<void> pump(WidgetTester tester, {required bool supabase}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          if (supabase) backendConfigProvider.overrideWithValue(_supabase),
          membershipsEnabledProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: BackendModuleScreen(
            module: BackendModule.matches,
            title: 'Upcoming Matches',
            fallbackLocation: '/club',
            child: Scaffold(body: Text('real screen')),
          ),
        ),
      ));
    }

    testWidgets('Supabase: the notice in place of the screen', (tester) async {
      await pump(tester, supabase: true);
      expect(find.byKey(const Key('backendPending.matches')), findsOneWidget);
      expect(find.text(BackendModules.pendingTitle), findsOneWidget);
      expect(find.textContaining('no sample data'), findsOneWidget);
      expect(find.text('real screen'), findsNothing);
      expect(find.text('Upcoming Matches'), findsOneWidget);
    });

    testWidgets('demo: the screen itself', (tester) async {
      await pump(tester, supabase: false);
      expect(find.text('real screen'), findsOneWidget);
      expect(find.byKey(const Key('backendPending.matches')), findsNothing);
    });
  });

  group('join controller with stored requests (switch on)', () {
    late FakeDb db;
    late FakeAuth auth;
    late FakeClubDb clubs;
    late FakeMembershipDb m;
    late ProviderContainer c;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      db = FakeDb();
      auth = FakeAuth(db);
      clubs = FakeClubDb(db);
      m = FakeMembershipDb(db, clubs);
      c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        backendConfigProvider.overrideWithValue(_supabase),
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(clubs),
        membershipGatewayProvider.overrideWithValue(m),
        teamGatewayProvider.overrideWithValue(FakeTeamDb(m)),
        membershipsEnabledProvider.overrideWithValue(true),
      ]);
      addTearDown(c.dispose);
    });

    test('send → pending; owner approves → refresh shows approved; decline and cancel', () async {
      final owner = auth.addUser('owner@example.com', 'Cricket@123');
      auth.current = owner;
      db.completeProfile(owner.id);
      final club = await c.read(clubRepositoryProvider).createClub(
          accountId: owner.id, name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);
      final player = auth.addUser('player@example.com', 'Cricket@123');
      db.completeProfile(player.id);
      auth.current = player;

      final join = c.read(joinClubProvider.notifier);
      expect(await join.blockReason('QQQQQQ'), contains('No club found'));
      final sent = await join.send(club.code);
      expect(sent.status, JoinRequestStatus.pending);
      expect(c.read(joinClubProvider)?.id, sent.id);
      // The database refuses a second request (the screens show its reason).
      await expectLater(c.read(clubRepositoryProvider).requestToJoin(club.code), throwsA(isA<ClubMembershipException>()));

      // The owner approves elsewhere; the player's "Check Status" sees it.
      auth.current = owner;
      final r = (await c.read(clubRepositoryProvider).joinRequests(club.id)).single;
      await c.read(clubRepositoryProvider).decideJoinRequest(club.id, r.id, approve: true, at: DateTime(2026));
      auth.current = player;
      expect((await join.refresh())?.status, JoinRequestStatus.approved);
      expect((await c.read(clubRepositoryProvider).myMemberships()).single.clubName, 'Lahore Lions CC');

      // A second club declines; cancel only clears it from the screen.
      final owner2 = auth.addUser('owner2@example.com', 'Cricket@123');
      auth.current = owner2;
      db.completeProfile(owner2.id);
      final club2 = await c.read(clubRepositoryProvider).createClub(
          accountId: owner2.id, name: 'Karachi Kings', city: 'Karachi', type: ClubType.professional);
      auth.current = player;
      await join.send(club2.code);
      auth.current = owner2;
      final r2 = (await c.read(clubRepositoryProvider).joinRequests(club2.id)).single;
      await c
          .read(clubRepositoryProvider)
          .decideJoinRequest(club2.id, r2.id, approve: false, reason: 'Full squad', at: DateTime(2026));
      auth.current = player;
      final declined = await join.refresh();
      expect(declined?.status, JoinRequestStatus.declined);
      expect(declined?.declineReason, 'Full squad');
      await join.cancel();
      expect(c.read(joinClubProvider), isNull);

      // A pending request is withdrawn in the database by Cancel.
      final owner3 = auth.addUser('owner3@example.com', 'Cricket@123');
      auth.current = owner3;
      db.completeProfile(owner3.id);
      final club3 = await c.read(clubRepositoryProvider).createClub(
          accountId: owner3.id, name: 'Multan Sultans', city: 'Multan', type: ClubType.professional);
      auth.current = player;
      await join.send(club3.code);
      await join.cancel();
      expect(m.requests.last['status'], 'cancelled');
    });
  });

  group('no demo club anywhere in Supabase builds', () {
    test('player club info and rankings never fall back to the demo club', () async {
      final c = await _container(supabase: true);
      final club = c.read(playerClubProvider);
      expect(club.code, 'No club yet');
      expect(club.code, isNot(SeedData.demoJoinCode));
      expect(club.city, isEmpty);
      // No own club → no roster at all (never the demo club's players).
      final seedNames = {for (final p in SeedData(DateTime(2026, 11, 16)).squad) p.name};
      final inputs = await c.read(rankingInputsProvider.future);
      expect(inputs.where((i) => seedNames.contains(i.name)), isEmpty);
    });

    test('the demo keeps its club tag', () async {
      final c = await _container(supabase: false);
      expect(c.read(playerClubProvider).code, SeedData.demoJoinCode);
    });
  });

  group('team creation when the squad save fails (Supabase, switch on)', () {
    test('the team is kept and listed; the error says the squad wasn\'t saved', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = FakeDb();
      final auth = FakeAuth(db);
      final clubs = FakeClubDb(db);
      final m = FakeMembershipDb(db, clubs);
      final owner = auth.addUser('owner@example.com', 'Cricket@123');
      auth.current = owner;
      db.completeProfile(owner.id);
      Club? created; // the club, read lazily by currentClubProvider below
      final c = ProviderContainer(overrides: [
        currentClubProvider.overrideWith((ref) => created),
        sharedPreferencesProvider.overrideWithValue(prefs),
        backendConfigProvider.overrideWithValue(_supabase),
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(clubs),
        membershipGatewayProvider.overrideWithValue(m),
        teamGatewayProvider.overrideWithValue(FakeTeamDb(m)),
        membershipsEnabledProvider.overrideWithValue(true),
      ]);
      addTearDown(c.dispose);
      created = await c.read(clubRepositoryProvider).createClub(
          accountId: owner.id, name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);

      await c.read(teamsProvider.future);
      await expectLater(
        c.read(teamsProvider.notifier).create(
          name: 'First XI',
          format: MatchFormat.t20,
          members: const [TeamMember(playerId: 'not-a-member', selection: SelectionRole.playing)],
        ),
        throwsA(isA<TeamSquadNotSavedException>().having((e) => e.message, 'message', contains('wasn’t saved'))),
      );
      final listed = c.read(teamsProvider).value!;
      expect(listed.single.name, 'First XI'); // known to the app: no "name exists" on retry
      expect(listed.single.members, isEmpty);
    });
  });

  group('team controller (demo repositories)', () {
    late ProviderContainer c;
    late Club club;

    setUp(() async {
      club = SeedData(DateTime(2026, 11, 16)).ownClub;
      c = await _container(supabase: false, extra: [currentClubProvider.overrideWithValue(club)]);
    });

    /// The first demo team with three pool players as its squad.
    Future<Team> teamWithSquad() async {
      final teams = await c.read(teamsProvider.future);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final team = teams.first;
      await c.read(teamsProvider.notifier).saveMembers(team.id, [
        for (final p in pool.take(3)) TeamMember(playerId: p.id, selection: SelectionRole.playing),
      ]);
      return c.read(teamsProvider.notifier).byId(team.id)!;
    }

    test('captain and vice-captain: set, moved, cleared; never the same person', () async {
      final team = await teamWithSquad();
      final a = team.members[0].playerId, b = team.members[1].playerId;
      final ctrl = c.read(teamsProvider.notifier);
      await ctrl.setLeaders(team.id, captainId: a, viceCaptainId: b);
      expect(ctrl.byId(team.id)!.captainId, a);
      expect(ctrl.byId(team.id)!.viceCaptainId, b);
      await expectLater(ctrl.setLeaders(team.id, captainId: a, viceCaptainId: a), throwsA(isA<TeamRuleException>()));
      await expectLater(
        ctrl.setLeaders(team.id, captainId: 'not-in-squad', viceCaptainId: null),
        throwsA(isA<TeamRuleException>()),
      );
      await ctrl.setLeaders(team.id, captainId: null, viceCaptainId: null);
      expect(ctrl.byId(team.id)!.captainId, isNull);
      expect(ctrl.byId(team.id)!.viceCaptainId, isNull);
    });

    test('taking the captain out of the squad clears the captaincy', () async {
      final team = await teamWithSquad();
      final a = team.members[0].playerId;
      final ctrl = c.read(teamsProvider.notifier);
      await ctrl.setLeaders(team.id, captainId: a, viceCaptainId: null);
      await ctrl.saveMembers(team.id, [for (final m in team.members) if (m.playerId != a) m]);
      expect(ctrl.byId(team.id)!.captainId, isNull);
    });

    test('delete (archive) removes the team from My Teams', () async {
      final team = await teamWithSquad();
      final ctrl = c.read(teamsProvider.notifier);
      await ctrl.archive(team.id);
      expect(ctrl.byId(team.id), isNull);
      expect(await c.read(teamRepositoryProvider).teams(club.id), isNot(contains(predicate<Team>((t) => t.id == team.id))));
    });

    test('a player who leaves the club leaves every team (demo)', () async {
      final team = await teamWithSquad();
      final a = team.members[0].playerId;
      final ctrl = c.read(teamsProvider.notifier);
      await ctrl.setLeaders(team.id, captainId: a, viceCaptainId: null);
      await ctrl.dropPlayer(a);
      final after = ctrl.byId(team.id)!;
      expect(after.members.map((m) => m.playerId), isNot(contains(a)));
      expect(after.captainId, isNull);
      expect(c.read(sessionProvider).isAuthenticated, isFalse); // no session needed
    });
  });
}
