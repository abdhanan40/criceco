// M4 integrity & security hardening (app half): Player Hunt shown only where
// it has a backend, the status sheet's truthful save feedback, match times on
// a Pakistan clock whatever the device's zone, join-request applicants
// without a cricket profile, and teams' optimistic concurrency
// (`p_expected_version`, 40001 "team: changed elsewhere"). No network, no
// database.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/account_error_text.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/pakistan_time.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_club_overlay.dart';
import 'package:criceco/data/supabase/match_row_mapper.dart';
import 'package:criceco/data/supabase/membership_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_team_repository.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:criceco/features/account/personal_details_form.dart';
import 'package:criceco/features/club/requests/join_requests_controller.dart';
import 'package:criceco/features/club/screens/join_request_profile_screen.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/matches/widgets/match_schedule_sheet.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// The modules of a production Supabase build with every switch on: Player
/// Hunt still has no backend there.
final _productionModules = BackendModules.of(
  _supabase,
  memberships: true,
  matches: true,
  results: true,
  notifications: true,
);

final _now = DateTime(2026, 9, 23, 10);

/// The whole app, signed in as the demo player on the Player Home. [modules]
/// replaces the build's backend modules (the repositories stay in memory).
Future<ProviderContainer> _pumpPlayer(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(375 * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ...overrides,
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const CricEcoApp()),
  );
  await tester.pumpAndSettle();
  await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
  final nav = c
      .read(roleControllerProvider.notifier)
      .continueAs(UserRole.player);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await tester.pumpAndSettle();
}

Future<void> _openStatusSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav.center')));
  await tester.pumpAndSettle();
}

Finder _switchOf(String key) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(Switch));

/// Counts Player Hunt listings ("open to offers").
class _CountingHunt extends InMemoryHuntRepository {
  _CountingHunt() : super.empty();
  int listings = 0;

  @override
  Future<void> setListed(OpenPlayer me, {required bool listed}) {
    listings++;
    return super.setListed(me, listed: listed);
  }
}

/// The server's availability record, answered when the test says so —
/// or refused.
class _ServerAvailability implements PlayerAvailabilityRepository {
  Completer<void>? gate;
  AccountException? refuse;
  int saves = 0;

  @override
  Future<PlayerAvailabilityRecord?> mine() async => null;

  @override
  Future<PlayerAvailabilityRecord> setMine(
    PlayerAvailabilityRecord record,
  ) async {
    saves++;
    if (gate case final g?) await g.future;
    if (refuse case final e?) throw e;
    return record;
  }

  @override
  Future<List<ClubMemberAvailability>> clubAvailability(String clubId) async =>
      const [];
}

void main() {
  // -------------------------------------------------------------------------
  group('Pakistan time', () {
    test('an instant reads on a Pakistan clock, however it is represented', () {
      final utc = DateTime.utc(2026, 11, 23, 5); // 10:00 in Pakistan
      final local = utc.toLocal(); // the same instant in the device's zone
      for (final t in [utc, local]) {
        final pk = PakistanTime.wallClock(t);
        expect(
          (pk.year, pk.month, pk.day, pk.hour, pk.minute),
          (2026, 11, 23, 10, 0),
        );
        expect(t.inPakistan, pk);
      }
    });

    test(
      'a device in another zone (UTC−5, UTC+10) sees the same Pakistan time',
      () {
        // The same instant as a device elsewhere would hold it: its local wall
        // clock differs, the Pakistan reading doesn't — only UTC is used.
        final instant = DateTime.utc(
          2026,
          11,
          23,
          19,
          30,
        ); // 00:30 on the 24th in Pakistan
        final newYork = instant.subtract(
          const Duration(hours: 5),
        ); // 14:30 there
        final sydney = instant.add(
          const Duration(hours: 10),
        ); // 05:30 on the 24th there
        expect(
          (newYork.hour, sydney.hour),
          (14, 5),
          reason: 'device wall clocks differ',
        );
        final pk = instant.inPakistan;
        expect((pk.day, pk.hour, pk.minute), (24, 0, 30));
        expect(
          PakistanTime.dateOf(instant),
          DateTime(2026, 11, 24),
          reason: 'past midnight in Pakistan',
        );
        expect(MatchRowMapper.karachiDate(instant), DateTime(2026, 11, 24));
      },
    );

    test(
      'a Pakistan date and time picked → the instant sent (UTC−5 h), and back',
      () {
        final at = PakistanTime.instant(2026, 11, 24, 10);
        expect(at, DateTime.utc(2026, 11, 24, 5));
        expect(MatchRowMapper.instantCode(at), '2026-11-24T05:00:00.000Z');
        expect(
          MatchRowMapper.proposeParams('m1', at, 'V', null)['p_starts_at'],
          '2026-11-24T05:00:00.000Z',
        );
        // Round trip through the wall clock, whatever its zone flag.
        expect(PakistanTime.instantOf(at.inPakistan), at);
        expect(PakistanTime.instantOf(DateTime(2026, 11, 24, 10)), at);
        // Late evening in Pakistan is the same UTC day; early morning the day before.
        expect(
          PakistanTime.instant(2026, 11, 24, 23, 59),
          DateTime.utc(2026, 11, 24, 18, 59),
        );
        expect(
          PakistanTime.instant(2026, 11, 24, 2),
          DateTime.utc(2026, 11, 23, 21),
        );
      },
    );

    test(
      'a server timestamp shows as Pakistan time on match cards and sheets',
      () {
        final row = {'starts_at': '2026-11-23T05:00:00.000Z'};
        final t = MatchRowMapper.time(row, 'starts_at');
        expect(
          t.isAtSameMomentAs(DateTime.utc(2026, 11, 23, 5)),
          isTrue,
          reason: 'kept as an instant',
        );
        expect(matchWhen(t), 'Mon, 23 Nov 2026 · 10:00 AM');
        expect(
          matchWhen(DateTime.utc(2026, 11, 23, 19, 30)),
          'Tue, 24 Nov 2026 · 12:30 AM',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  group('Player Hunt only where it has a backend', () {
    testWidgets(
      'production build: Playing Opportunities says "Not available yet" (route and quick action)',
      (tester) async {
        final c = await _pumpPlayer(
          tester,
          overrides: [
            backendModulesProvider.overrideWithValue(_productionModules),
          ],
        );
        expect(_productionModules.has(BackendModule.matches), isTrue);
        expect(_productionModules.has(BackendModule.playerHunt), isFalse);

        // The dashboard quick action opens the gated route.
        final action = find.text('Playing Opportunities');
        await tester.ensureVisible(action.first);
        await tester.pumpAndSettle();
        await tester.tap(action.first);
        await tester.pumpAndSettle();
        expect(c.read(routerProvider).state.uri.path, Routes.openMatches);
        expect(
          find.byKey(const Key('backendPending.playerHunt')),
          findsOneWidget,
        );
        expect(find.text(BackendModules.pendingTitle), findsOneWidget);

        // A deep link too.
        await _go(tester, c, Routes.playerHome);
        await _go(tester, c, Routes.openMatches);
        expect(
          find.byKey(const Key('backendPending.playerHunt')),
          findsOneWidget,
        );
      },
    );

    testWidgets('demo: Playing Opportunities is the real screen', (
      tester,
    ) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.openMatches);
      expect(find.byKey(const Key('backendPending.playerHunt')), findsNothing);
      expect(find.text('Playing Opportunities'), findsWidgets);
    });

    testWidgets(
      'production build: no "Available for Playing Opportunities" or "Open for Matches"',
      (tester) async {
        final c = await _pumpPlayer(
          tester,
          overrides: [
            backendModulesProvider.overrideWithValue(_productionModules),
          ],
        );
        await _go(tester, c, Routes.availability);
        expect(
          find.text('Choose your Status'),
          findsOneWidget,
          reason: 'the Availability screen itself',
        );
        expect(find.byKey(const Key('availability.listed')), findsNothing);
        expect(find.text('Available for Playing Opportunities'), findsNothing);

        await _go(tester, c, Routes.playerHome);
        await _openStatusSheet(tester);
        expect(find.byKey(const Key('status.sheet')), findsOneWidget);
        expect(find.byKey(const Key('status.available')), findsOneWidget);
        expect(find.byKey(const Key('status.openForMatches')), findsNothing);
        expect(find.text('Open for Matches'), findsNothing);
      },
    );

    testWidgets('demo: both listing controls are still there', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.availability);
      expect(find.byKey(const Key('availability.listed')), findsOneWidget);
      await _go(tester, c, Routes.playerHome);
      await _openStatusSheet(tester);
      expect(find.byKey(const Key('status.openForMatches')), findsOneWidget);
    });

    for (final huntOn in [false, true]) {
      testWidgets(
        'saving personal details ${huntOn ? 're-lists' : 'never lists'} the player '
        '(Player Hunt ${huntOn ? 'on' : 'off'})',
        (tester) async {
          final hunt = _CountingHunt();
          late WidgetRef widgetRef;
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final c = ProviderContainer(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              huntRepositoryProvider.overrideWithValue(hunt),
              if (!huntOn)
                backendModulesProvider.overrideWithValue(_productionModules),
            ],
          );
          addTearDown(c.dispose);
          await c
              .read(sessionProvider.notifier)
              .signIn(identifier: 'x', password: 'y');
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: MaterialApp(
                home: Consumer(
                  builder: (_, ref, _) {
                    widgetRef = ref;
                    return const SizedBox();
                  },
                ),
              ),
            ),
          );
          // Listed earlier (only possible where Player Hunt exists; forced here).
          await c
              .read(playerAvailabilityProvider.notifier)
              .setOpenToOffers(true);
          expect(hunt.listings, 1);
          final editor = PersonalDetailsEditor()
            ..load(c.read(currentAccountProvider));
          addTearDown(editor.dispose);
          editor.name.text = 'Ali Raza Khan';
          await savePersonalDetails(widgetRef, editor);
          expect(c.read(currentAccountProvider)!.fullName, 'Ali Raza Khan');
          expect(hunt.listings, huntOn ? 2 : 1);
        },
      );
    }
  });

  // -------------------------------------------------------------------------
  group('Set Your Status: success shown only once saved', () {
    Future<(ProviderContainer, _ServerAvailability)> pump(
      WidgetTester tester,
    ) async {
      final server = _ServerAvailability();
      final c = await _pumpPlayer(
        tester,
        overrides: [
          backendModulesProvider.overrideWithValue(_productionModules),
          matchesBackendLiveProvider.overrideWithValue(true),
          playerAvailabilityRepositoryProvider.overrideWithValue(server),
        ],
      );
      return (c, server);
    }

    testWidgets(
      'a refusal: no "Saved", the server\'s reason as a toast, the switch as it was',
      (tester) async {
        final (c, server) = await pump(tester);
        server.refuse = const BackendUnavailableException();
        await _openStatusSheet(tester);
        expect(
          tester.widget<Switch>(_switchOf('status.available')).value,
          isTrue,
        );

        await tester.tap(_switchOf('status.available'));
        await tester.pump();
        await tester.pump();
        expect(server.saves, 1);
        expect(find.byKey(const Key('status.saved')), findsNothing);
        expect(find.textContaining('Saved ·'), findsNothing);
        expect(
          find.text(const BackendUnavailableException().message),
          findsOneWidget,
        );
        expect(
          c.read(playerAvailabilityProvider).status,
          PlayerAvailability.available,
        );
        expect(
          tester.widget<Switch>(_switchOf('status.available')).value,
          isTrue,
        );
        await tester.pumpAndSettle(const Duration(seconds: 5));
      },
    );

    testWidgets(
      'a save on its way: no confirmation and no second save; then "Saved"',
      (tester) async {
        final (c, server) = await pump(tester);
        server.gate = Completer<void>();
        await _openStatusSheet(tester);
        await tester.tap(_switchOf('status.available'));
        await tester.pump();
        expect(server.saves, 1);
        expect(
          find.byKey(const Key('status.saved')),
          findsNothing,
          reason: 'not stored yet',
        );
        expect(
          tester.widget<Switch>(_switchOf('status.available')).onChanged,
          isNull,
          reason: 'one save at a time',
        );

        server.gate!.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('Saved · Marked unavailable this week'),
          findsOneWidget,
        );
        expect(
          c.read(playerAvailabilityProvider).status,
          PlayerAvailability.unavailable,
        );
        expect(
          tester.widget<Switch>(_switchOf('status.available')).onChanged,
          isNotNull,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  group('join request from someone without a cricket profile', () {
    Map<String, dynamic> row({Object? role, Object? age}) => {
      'request_id': 'r1',
      'full_name': 'Sana Iqbal',
      'applicant_age': age,
      'city': 'Lahore',
      'player_role': role,
      'batting_style': null,
      'bowling_style': null,
      'phone': null,
      'status': 'pending',
      'created_at': DateTime(2026, 11, 20).toIso8601String(),
    };

    test('mapper: no role, styles or age invented', () {
      final r = MembershipRowMapper.joinRequestFromRow(
        row(),
        now: DateTime(2026, 11, 26),
      );
      expect(r.role, isNull);
      expect(r.battingStyle, isNull);
      expect(r.bowlingStyle, isNull);
      expect(r.age, isNull);
      final withProfile = MembershipRowMapper.joinRequestFromRow({
        ...row(role: 'bowler', age: 24),
        'bowling_style': 'right_arm_fast',
      }, now: DateTime(2026, 11, 26));
      expect(
        (withProfile.role, withProfile.bowlingStyle, withProfile.age),
        (PlayerRole.bowler, BowlingStyle.rightArmFast, 24),
      );
      expect(withProfile.battingStyle, isNull);
    });

    test('through the repository (fakes): the stored request has no cricket fields', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = FakeDb();
      final auth = FakeAuth(db);
      final clubs = FakeClubDb(db);
      final members = FakeMembershipDb(db, clubs);
      final repo = SupabaseClubRepository(
        auth: auth,
        db: clubs,
        overlay: LocalClubOverlay(prefs),
        local: InMemoryClubRepository(SeedData(DateTime(2026, 11, 16))),
        membership: members,
      );
      final owner = auth.addUser('owner@example.com', 'Cricket@123');
      auth.current = owner;
      db.completeProfile(owner.id);
      final club = await repo.createClub(
        accountId: owner.id,
        name: 'Lahore Lions CC',
        city: 'Lahore',
        type: ClubType.corporate,
      );
      final applicant = auth.addUser('fan@example.com', 'Cricket@123');
      auth.current = applicant;
      db.completeProfile(applicant.id); // no player profile
      await repo.requestToJoin(club.code);
      auth.current = owner;
      final r = (await repo.joinRequests(club.id)).single;
      expect((r.role, r.battingStyle, r.bowlingStyle), (null, null, null));
    });

    testWidgets('the profile shows "Not set" and no age', (tester) async {
      final request = MembershipRowMapper.joinRequestFromRow(
        row(),
        now: DateTime(2026, 11, 26),
      );
      final router = GoRouter(
        initialLocation: '/r',
        routes: [
          GoRoute(
            path: '/r',
            builder: (_, _) => const JoinRequestProfileScreen(requestId: 'r1'),
          ),
          GoRoute(
            path: Routes.joinRequests,
            builder: (_, _) => const Scaffold(body: Text('requests')),
          ),
        ],
      );
      addTearDown(router.dispose);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            joinRequestsProvider.overrideWith(() => _FixedRequests([request])),
          ],
          child: MaterialApp.router(
            theme: AppTheme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sana Iqbal'), findsOneWidget);
      expect(find.text('Lahore'), findsWidgets);
      expect(
        find.text('Not set'),
        findsNWidgets(3),
        reason: 'batting, bowling, playing role',
      );
      expect(
        find.text('Age'),
        findsNothing,
        reason: 'unknown: never a made-up 0',
      );
      expect(find.text('0'), findsNothing);
      expect(find.text('Batsman'), findsNothing);
      expect(find.text('Right-handed'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('teams: optimistic concurrency (save_team p_expected_version)', () {
    test('save parameters carry the version read; none known → not sent', () {
      final team = Team(
        id: 't1',
        clubId: 'c1',
        name: 'First XI',
        format: MatchFormat.t20,
        createdAt: DateTime(2026),
      );
      expect(team.version, 1, reason: 'memory mode default');
      expect(
        MembershipRowMapper.saveParams(
          team.copyWith(version: 7),
        )['p_expected_version'],
        7,
      );
      final unknown = MembershipRowMapper.teamFromRow({
        'id': 't1',
        'club_id': 'c1',
        'name': 'X',
        'format': 't20',
      });
      expect(unknown.version, isNull);
      expect(
        MembershipRowMapper.saveParams(unknown)
            .containsKey('p_expected_version'),
        isFalse,
        reason: 'a server without versions never gets an unknown parameter',
      );
      final read = MembershipRowMapper.teamFromRow({
        'id': 't1',
        'club_id': 'c1',
        'name': 'X',
        'format': 't20',
        'version': 4,
      });
      expect(read.version, 4);
      expect(read.copyWith(name: 'Y').version, 4);
    });

    test('40001 "team: changed elsewhere" → TeamChangedElsewhereException (a TeamRuleException)', () {
      final e = SupabaseErrorMapper.map(
        const GatewayConstraintException(
          sqlState: '40001',
          message: 'team: changed elsewhere',
        ),
      );
      expect(e, isA<TeamChangedElsewhereException>());
      expect(e, isA<TeamRuleException>());
      expect(
        (e as AccountException).message,
        contains('changed on another device'),
      );
      expect(
        accountErrorText(e, fallback: 'x'),
        'This team was changed on another device — it has been reloaded. Please make your change again.',
      );
      // Other team refusals keep their texts.
      expect(
        SupabaseErrorMapper.map(
          const GatewayConstraintException(
            sqlState: '23505',
            message: 'team: duplicate name',
          ),
        ),
        isA<TeamRuleException>().having(
          (x) => x.message,
          'message',
          'A team with this name already exists',
        ),
      );
    });

    test('in memory: saves as before', () async {
      final repo = InMemoryTeamRepository(SeedData(DateTime(2026, 11, 16)));
      final t = await repo.create(
        clubId: 'c1',
        name: 'First XI',
        format: MatchFormat.t20,
      );
      final saved = await repo.save(t.copyWith(name: 'Firsts'));
      expect(saved.name, 'Firsts');
      expect(saved.version, 1);
    });

    group('Supabase (fakes)', () {
      late FakeDb db;
      late FakeAuth auth;
      late FakeClubDb clubs;
      late FakeMembershipDb members;
      late FakeTeamDb teamDb;
      late ProviderContainer c;
      late Club club;

      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        db = FakeDb();
        auth = FakeAuth(db);
        clubs = FakeClubDb(db);
        members = FakeMembershipDb(db, clubs);
        teamDb = FakeTeamDb(members);
        final owner = auth.addUser('owner@example.com', 'Cricket@123');
        auth.current = owner;
        db.completeProfile(owner.id);
        Club? created;
        c = ProviderContainer(
          overrides: [
            currentClubProvider.overrideWith((ref) => created),
            sharedPreferencesProvider.overrideWithValue(prefs),
            backendConfigProvider.overrideWithValue(_supabase),
            authGatewayProvider.overrideWithValue(auth),
            profileGatewayProvider.overrideWithValue(db),
            clubGatewayProvider.overrideWithValue(clubs),
            membershipGatewayProvider.overrideWithValue(members),
            teamGatewayProvider.overrideWithValue(teamDb),
            membershipsEnabledProvider.overrideWithValue(true),
          ],
        );
        addTearDown(c.dispose);
        created = await c
            .read(clubRepositoryProvider)
            .createClub(
              accountId: owner.id,
              name: 'Lahore Lions CC',
              city: 'Lahore',
              type: ClubType.corporate,
            );
        club = created;
      });

      Future<Team> firstXi() async {
        await c.read(teamsProvider.future);
        await c
            .read(teamsProvider.notifier)
            .create(name: 'First XI', format: MatchFormat.t20);
        return c.read(teamsProvider).value!.single;
      }

      test('each save sends the version it was made from; the saved version comes back', () async {
        final team = await firstXi();
        expect(team.version, 1);
        await c
            .read(teamsProvider.notifier)
            .setLeaders(team.id, captainId: null, viceCaptainId: null);
        expect(teamDb.saveParams.single['p_expected_version'], 1);
        expect(c.read(teamProvider(team.id))!.version, 2);
        await c.read(teamsProvider.notifier).saveMembers(team.id, const []);
        expect(teamDb.saveParams.last['p_expected_version'], 2);
        expect(c.read(teamProvider(team.id))!.version, 3);
      });

      test('changed on another device: refused, the teams are reloaded, the message asks to redo it', () async {
        final team = await firstXi();
        // Another device renames it meanwhile (version 1 → 2).
        final other = SupabaseTeamRepository(db: teamDb);
        await other.save(
          (await other.teams(club.id)).single.copyWith(name: 'Lions First XI'),
        );
        expect(
          c.read(teamProvider(team.id))!.name,
          'First XI',
          reason: 'this device still has the old copy',
        );

        await expectLater(
          c
              .read(teamsProvider.notifier)
              .setLeaders(team.id, captainId: null, viceCaptainId: null),
          throwsA(
            isA<TeamChangedElsewhereException>().having(
              (e) => e.message,
              'message',
              'This team was changed on another device — it has been reloaded. Please make your change again.',
            ),
          ),
        );
        expect(teamDb.saveParams.last['p_expected_version'], 1);
        final reloaded = c.read(teamProvider(team.id))!;
        expect(
          (reloaded.name, reloaded.version),
          ('Lions First XI', 2),
          reason: 'the latest copy, nothing overwritten',
        );

        // Made again on the reloaded copy: saved.
        await c.read(teamsProvider.notifier).saveMembers(team.id, const []);
        expect(teamDb.saveParams.last['p_expected_version'], 2);
        expect(c.read(teamProvider(team.id))!.version, 3);
        expect(c.read(teamProvider(team.id))!.name, 'Lions First XI');
      });

      test(
        'the squad editor keeps the draft after a conflict, for the retry',
        () async {
          final team = await firstXi();
          final other = SupabaseTeamRepository(db: teamDb);
          await other.save(
            (await other.teams(club.id)).single
                .copyWith(name: 'Lions First XI'),
          );
          final editor = c.read(squadEditorProvider(team.id).notifier);
          await expectLater(
            editor.save(),
            throwsA(isA<TeamChangedElsewhereException>()),
          );
          expect(c.read(teamProvider(team.id))!.version, 2);
          await editor.save();
          expect(c.read(teamProvider(team.id))!.version, 3);
        },
      );
    });
  });
}

class _FixedRequests extends JoinRequestsController {
  _FixedRequests(this.requests);
  final List<JoinRequest> requests;

  @override
  Future<List<JoinRequest>> build() async => requests;
}
