import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/matches/lineup_controller.dart';
import 'package:criceco/features/tournaments/registration_draft.dart';
import 'package:criceco/features/tournaments/screens/hosted_screens.dart';
import 'package:criceco/features/tournaments/screens/registration_screens.dart';
import 'package:criceco/features/tournaments/tournament_demo_actions.dart';
import 'package:criceco/features/tournaments/tournaments_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_workspace_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 25, 9);
DateTime _day(int d) => DateTime(2026, 9, 25).add(Duration(days: d));

TournamentInput _input({
  String name = 'Shalimar Champions Trophy',
  TournamentType type = TournamentType.knockout,
  int maxTeams = 8,
  int startIn = 20,
}) =>
    TournamentInput(
      name: name,
      city: 'Islamabad',
      ground: 'Pindi Cricket Ground',
      format: MatchFormat.t20,
      type: type,
      startDate: _day(startIn),
      endDate: _day(startIn + 5),
      registrationDeadline: _day(startIn - 5),
      entryFee: 5000,
      prize: 100000,
      maxTeams: maxTeams,
      description: 'Weekend T20 knockout.',
    );

Future<ProviderContainer> _owner({bool demo = true}) async {
  final c = await makeContainer(clock: TestClock(_now));
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  c.read(demoModeProvider.notifier).set(demo);
  await c.read(tournamentsProvider.future);
  await c.read(tournamentRegistrationsProvider.future);
  await c.read(teamsProvider.future);
  return c;
}

String _ownClub(ProviderContainer c) => c.read(currentClubProvider)!.id;

/// Confirms a full 11 + 4 squad for [tournamentId] through the shared
/// line-up flow, then agrees to the rules.
Future<void> _readyRegistration(ProviderContainer c, String tournamentId, {bool agree = true}) async {
  final target = TournamentEntryTarget(tournamentId);
  final pool = await c.read(clubPlayerPoolProvider.future);
  final ctrl = c.read(lineupDraftProvider(target).notifier)..startNew();
  for (final p in pool.where((p) => !p.locked).take(15)) {
    ctrl.cycle(p);
  }
  expect(await ctrl.confirmBuilt(), isNull);
  if (agree) c.read(registrationDraftProvider(tournamentId).notifier).setAgreed(true);
}

Future<TournamentRegistration> _register(ProviderContainer c, String tournamentId) async {
  await _readyRegistration(c, tournamentId);
  final result = await c.read(tournamentRegistrationsProvider.notifier).submit(tournamentId);
  expect(result.error, isNull);
  return result.registration!;
}

// ---- Widget harness -------------------------------------------------------

Future<ProviderContainer> _pumpOwner(WidgetTester tester, {double width = 375}) async {
  tester.view.physicalSize = Size(width * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    clockProvider.overrideWithValue(Clock.fixed(_now)),
    nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  final nav = c.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  await c.read(tournamentsProvider.future);
  await c.read(tournamentRegistrationsProvider.future);
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _clearToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

/// Text inside the tournament host workspace (not the shell page beneath).
Finder _inHost(String text) => find.descendant(of: find.byType(TournamentDetailsScreen), matching: find.text(text));

void main() {
  group('Create Tournament', () {
    test('validation keeps the prototype order plus the approved date checks', () {
      expect(validateTournamentInput(const TournamentInput(), _now).values.first, 'Please enter a tournament name');
      final ok = _input();
      expect(validateTournamentInput(ok, _now), isEmpty);
      Map<String, String> v(TournamentInput i) => validateTournamentInput(i, _now);
      expect(
          v(TournamentInput(
            name: 'X', city: 'Lahore', ground: 'G', format: MatchFormat.custom, type: TournamentType.league,
            startDate: _day(10), endDate: _day(9), registrationDeadline: _day(11), maxTeams: 1,
          )),
          {
            'overs': 'Please enter the number of overs',
            'end': 'End date must be on or after the start date',
            'deadline': 'Registration must close on or before the start date',
            'maxTeams': 'Enter between 2 and 32 teams',
          });
      expect(v(TournamentInput(
        name: 'X', city: 'Lahore', ground: 'G', format: MatchFormat.custom, customOvers: 60,
        type: TournamentType.league, startDate: _day(-1), endDate: _day(3), registrationDeadline: _day(-2), maxTeams: 4,
      )).keys, ['overs', 'start', 'deadline']);
    });

    test('the organizer is always my own club; Demo seeds three requests from other clubs', () async {
      final c = await _owner();
      final t = await c.read(tournamentsProvider.notifier).create(_input());
      expect(t.organizerClubId, _ownClub(c));
      expect(t.status, TournamentStatus.registrationOpen);
      expect(c.read(hostedTournamentsProvider).map((x) => x.id), [t.id]);
      expect(c.read(browseTournamentsProvider).map((x) => x.id), isNot(contains(t.id)),
          reason: 'my own tournament is never listed in Browse');
      final requests = c.read(pendingRequestsProvider(t.id));
      expect(requests, hasLength(3));
      expect(requests.map((r) => r.clubId), everyElement(isNot(_ownClub(c))));
      expect(c.read(tournamentProvider(t.id))!.pending.map((e) => e.id), requests.map((r) => r.id),
          reason: 'pending entrants are registration ids');
    });

    test('Demo Mode OFF: no simulated requests', () async {
      final c = await _owner(demo: false);
      final t = await c.read(tournamentsProvider.notifier).create(_input());
      expect(c.read(pendingRequestsProvider(t.id)), isEmpty);
    });
  });

  group('Hosting', () {
    test('accept moves pending → joined; reject drops it; a full tournament refuses more', () async {
      final c = await _owner();
      final t = await c.read(tournamentsProvider.notifier).create(_input(maxTeams: 2));
      final regs = c.read(pendingRequestsProvider(t.id));
      final ctrl = c.read(tournamentRegistrationsProvider.notifier);

      expect(await ctrl.decide(regs[0].id, approve: false), RegistrationDecision.rejected);
      expect(await ctrl.decide(regs[1].id, approve: true), RegistrationDecision.approved);
      expect(await ctrl.decide(regs[1].id, approve: true), RegistrationDecision.notPending);
      expect(await ctrl.decide(regs[2].id, approve: true), RegistrationDecision.approved);
      var now = c.read(tournamentProvider(t.id))!;
      expect(now.joined.map((e) => e.id), [regs[1].id, regs[2].id]);
      expect(now.pending, isEmpty);
      expect(now.status, TournamentStatus.registrationFull);
      expect(c.read(registrationProvider(regs[0].id))!.status, RegistrationStatus.rejected);

      // Full: a new request can't even be received, and removal reopens it.
      expect(await ctrl.receive(t.id, clubId: 'club_fw', teamName: 'Wolves'), isNull);
      expect(await c.read(tournamentsProvider.notifier).removeTeam(t.id, regs[2].id), isTrue);
      now = c.read(tournamentProvider(t.id))!;
      expect(now.status, TournamentStatus.registrationOpen);
      expect(c.read(registrationProvider(regs[2].id))!.status, RegistrationStatus.rejected);
    });

    test('fixtures need two teams, close registration and lock the teams', () async {
      final c = await _owner();
      final tournaments = c.read(tournamentsProvider.notifier);
      final t = await tournaments.create(_input());
      final regs = c.read(pendingRequestsProvider(t.id));
      final ctrl = c.read(tournamentRegistrationsProvider.notifier);
      expect(await tournaments.generateFixtures(t.id), FixturesOutcome.notEnoughTeams);
      await ctrl.decide(regs[0].id, approve: true);
      await ctrl.decide(regs[1].id, approve: true);
      expect(await tournaments.generateFixtures(t.id), FixturesOutcome.generated);
      final g = c.read(tournamentProvider(t.id))!;
      expect(g.fixtures!.single.name, 'Final');
      expect(g.status, TournamentStatus.registrationClosed);
      expect(await tournaments.generateFixtures(t.id), FixturesOutcome.alreadyGenerated);
      expect(await ctrl.decide(regs[2].id, approve: true), RegistrationDecision.closed);
      expect(await tournaments.removeTeam(t.id, regs[0].id), isFalse);

      // Final → champion, tournament completed.
      final done = await tournaments.recordResult(t.id, 0, 0, regs[0].id);
      expect(done!.winnerId, regs[0].id);
      expect(done.status, TournamentStatus.completed);
      expect(done.standings[regs[0].id]!.points, 2);
    });
  });

  group('Registration', () {
    test('the squad comes from the shared line-up flow into the registration draft', () async {
      final c = await _owner();
      await _readyRegistration(c, 't_1', agree: false);
      final draft = c.read(registrationDraftProvider('t_1'));
      expect(draft.lineup!.members, hasLength(15));
      expect(draft.agreed, isFalse);

      // Select Existing Team snapshots a club team instead.
      final pool = await c.read(clubPlayerPoolProvider.future);
      await c.read(teamsProvider.notifier).saveMembers('team_it', [
        for (final (i, p) in pool.where((p) => !p.locked).take(12).indexed)
          TeamMember(playerId: p.id, selection: i < 11 ? SelectionRole.playing : SelectionRole.sub),
      ]);
      final team = c.read(teamsProvider).value!.firstWhere((t) => t.id == 'team_it');
      await c.read(lineupDraftProvider(const TournamentEntryTarget('t_1')).notifier).useTeam(team);
      expect(c.read(registrationDraftProvider('t_1')).lineup!.name, 'BS IT XI');
      expect(c.read(registrationDraftProvider('t_1')).lineup!.sourceTeamId, 'team_it');
    });

    test('submit needs a squad and agreement, then files one pending registration', () async {
      final c = await _owner();
      final ctrl = c.read(tournamentRegistrationsProvider.notifier);
      expect((await ctrl.submit('t_1')).error, 'Please pick your team first');
      await _readyRegistration(c, 't_1', agree: false);
      expect((await ctrl.submit('t_1')).error, 'Please agree to the tournament rules');
      c.read(registrationDraftProvider('t_1').notifier).setAgreed(true);
      final reg = (await ctrl.submit('t_1')).registration!;

      expect(reg.status, RegistrationStatus.pending);
      expect(reg.clubId, _ownClub(c));
      expect(reg.teamName, Lineup.newMatchDaySquadName);
      expect(reg.lineup!.members, hasLength(15));
      final t = c.read(tournamentProvider('t_1'))!;
      expect(t.pending.map((e) => e.id), [reg.id]);
      expect(t.pending.single.displayName, 'Shalimar Cricket Club');
      expect(c.read(activeRegistrationProvider('t_1'))!.id, reg.id);
      expect(c.read(myRegistrationsByStatusProvider(RegistrationStatus.pending)).map((r) => r.id), [reg.id]);
      expect(c.read(registrationDraftProvider('t_1')).lineup, isNull, reason: 'draft cleared');
      expect(c.read(lineupDraftProvider(const TournamentEntryTarget('t_1'))).picks, isEmpty);

      await _readyRegistration(c, 't_1');
      expect((await ctrl.submit('t_1')).error, 'Your club has already registered for this tournament');
    });

    test('full, closed and own tournaments refuse registrations', () async {
      final c = await _owner();
      final ctrl = c.read(tournamentRegistrationsProvider.notifier);
      await _readyRegistration(c, 't_4');
      expect((await ctrl.submit('t_4')).error, 'Registration is full');

      final own = await c.read(tournamentsProvider.notifier).create(_input());
      await _readyRegistration(c, own.id);
      expect((await ctrl.submit(own.id)).error, 'Your club is hosting this tournament');

      final t2 = c.read(tournamentProvider('t_2'))!;
      expect(t2.statusAt(_day(14)), TournamentStatus.registrationClosed, reason: 'deadline day passed');
      expect(t2.statusAt(_day(13)), TournamentStatus.registrationOpen);
    });

    test('Demo organizer decision: approval publishes fixtures; results update standings', () async {
      final c = await _owner();
      final reg = await _register(c, 't_1');
      final demo = c.read(tournamentDemoActionsProvider);
      expect(await demo.organizerDecides(reg.id, approve: true), RegistrationDecision.approved);
      expect(c.read(registrationProvider(reg.id))!.status, RegistrationStatus.approved);
      final t = c.read(tournamentProvider('t_1'))!;
      expect(t.joined.map((e) => e.id), ['club_iu', 'club_rr', reg.id]);
      expect(t.fixtures, isNotNull, reason: 'the simulated organizer generated the draw');
      final ready = flattenFixtures(t).firstWhere((f) => f.match.ready);
      final winner = await demo.simulateResult('t_1', ready);
      expect(winner, isNotNull);
      final after = c.read(tournamentProvider('t_1'))!;
      expect(after.standings[winner]!.points, 2);
      expect(c.read(tournamentHubStatsProvider).approved, 1);
    });

    test('Demo OFF: no simulated organizer or results; a rejected club may register again', () async {
      final c = await _owner(demo: false);
      final reg = await _register(c, 't_1');
      final demo = c.read(tournamentDemoActionsProvider);
      expect(await demo.organizerDecides(reg.id, approve: true), isNull);
      expect(c.read(registrationProvider(reg.id))!.status, RegistrationStatus.pending);

      // The real organizer (a backend event) rejects: the club can try again.
      await c.read(tournamentRegistrationsProvider.notifier).decide(reg.id, approve: false);
      expect(c.read(activeRegistrationProvider('t_1')), isNull);
      expect(c.read(tournamentProvider('t_1'))!.pending, isEmpty);
      final again = await _register(c, 't_1');
      expect(again.id, isNot(reg.id));
    });
  });

  group('Tournament screens', () {
    testWidgets('hub: Tournament Center, approved names, Back → dashboard', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.clubHome);
      await _go(tester, c, Routes.tournamentHub);
      expect(find.text('Organize, discover and manage tournaments with ease.'), findsOneWidget);
      for (final name in ['Create Tournament', 'Browse Tournaments', 'My Tournaments', 'My Registrations']) {
        expect(find.bySemanticsLabel(RegExp('^$name')), findsOneWidget, reason: name);
      }
      await _tap(tester, find.bySemanticsLabel(RegExp('^My Registrations')));
      expect(_loc(c), Routes.myRegistrations);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.tournamentHub);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.clubHome);
    });

    testWidgets('registration: Browse → Details → Select Team → Summary → Success → Registration Details',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.browseTournaments);
      expect(find.text('Choose a city'), findsOneWidget);
      await _go(tester, c, Routes.browseTournamentsIn('Karachi'));
      expect(find.text('Karachi Premier Cup'), findsOneWidget);
      await _tap(tester, _button('Register Team'));
      expect(_loc(c), Routes.tournamentRegister('t_1'));
      // Back keeps the chosen city (prototype `browseTournamentsCityFilter`).
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.browseTournaments);
      expect(find.text('Karachi Premier Cup'), findsOneWidget);
      await _tap(tester, _button('Register Team'));
      expect(find.text('Tournament Details'), findsOneWidget);
      await _tap(tester, _button('Continue Registration'));
      expect(_loc(c), Routes.tournamentTeam('t_1'));
      expect(find.text('Almost there!'), findsOneWidget);

      await _tap(tester, find.bySemanticsLabel('Create New Team'));
      expect(_loc(c), Routes.tournamentTeamBuild('t_1'));
      final pool = await c.read(clubPlayerPoolProvider.future);
      for (final p in pool.where((p) => !p.locked).take(15)) {
        c.read(lineupDraftProvider(const TournamentEntryTarget('t_1')).notifier).cycle(p);
      }
      await tester.pumpAndSettle();
      await _tap(tester, _button('Confirm Team'));
      expect(_loc(c), Routes.registrationSummary('t_1'));
      await _clearToast(tester);

      await _tap(tester, _button('Submit Registration'));
      expect(find.text('Please agree to the tournament rules'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('I agree to the tournament rules.'));
      await _tap(tester, _button('Submit Registration'));
      final reg = c.read(myRegistrationsProvider).single;
      expect(_loc(c), Routes.registrationSuccess(reg.id));
      expect(find.text('Registration Submitted Successfully!'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing, reason: 'terminal screen');

      // System Back never returns into the finished flow.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(_loc(c), MyRegistrationsScreen.location(RegistrationStatus.pending));

      await _go(tester, c, Routes.registrationSuccess(reg.id));
      await _tap(tester, _button('View Registration'));
      expect(_loc(c), Routes.registrationDetails(reg.id));
      expect(find.text('Pending Approval'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myRegistrations);
      expect(find.text('Karachi Premier Cup'), findsOneWidget, reason: 'the last tab (Pending) is remembered');

      // Browse now offers View Registration, never a second registration.
      await _go(tester, c, Routes.browseTournamentsIn('Karachi'));
      await _tap(tester, _button('View Registration'));
      expect(_loc(c), Routes.registrationDetails(reg.id));
    });

    testWidgets('Registration Details: Demo decision panel and fixture simulation; hidden with Demo OFF',
        (tester) async {
      final c = await _pumpOwner(tester);
      final reg = await _register(c, 't_1');
      await _go(tester, c, Routes.registrationDetails(reg.id));
      await tester.scrollUntilVisible(find.text('PROTOTYPE CONTROLS'), 200, scrollable: find.byType(Scrollable).first);
      await _tap(tester, find.widgetWithText(OutlinedButton, 'Approve'));
      expect(find.text('Registration approved by organizer!'), findsOneWidget);
      await _clearToast(tester);
      expect(find.text('Fixtures / Schedule', skipOffstage: false), findsOneWidget);
      // Each fixture is listed once (by round) — no separate Upcoming / Results copies.
      Finder inDetails(String s) => find.descendant(
          of: find.byType(RegistrationDetailsScreen), matching: find.text(s, skipOffstage: false), skipOffstage: false);
      expect(inDetails('Upcoming Matches'), findsNothing);
      expect(inDetails('Results'), findsNothing);
      expect(find.textContaining(RegExp(r'^\d+ played · \d+ to play$'), skipOffstage: false), findsOneWidget);
      final simulate = find.text('Tap to simulate result');
      for (var i = 0; i < 20 && simulate.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      await _tap(tester, simulate.first);
      expect(find.textContaining('won the match!'), findsOneWidget);
      await _clearToast(tester);

      c.read(demoModeProvider.notifier).set(false);
      await tester.pumpAndSettle();
      expect(find.text('Tap to simulate result', skipOffstage: false), findsNothing, reason: 'P10: read-only');
    });

    testWidgets('hosting: Published is terminal; View Tournament → Details; accept a request; generate fixtures',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.createTournament);
      await _tap(tester, _button('Publish Tournament'));
      expect(find.text('Please enter a tournament name'), findsWidgets);
      await _clearToast(tester);

      final t = await c.read(tournamentsProvider.notifier).create(_input());
      await _go(tester, c, Routes.tournamentPublished(t.id));
      expect(find.text('Tournament Created Successfully'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.tournamentHub);

      await _go(tester, c, Routes.tournamentPublished(t.id));
      await _tap(tester, _button('View Tournament'));
      expect(_loc(c), Routes.tournamentDetails(t.id));
      // Overview carries the former Dashboard sections.
      await tester.scrollUntilVisible(_inHost('Upcoming Matches'), 200, scrollable: find.byType(Scrollable).first);
      await tester.scrollUntilVisible(_inHost('Tournament Awards'), 200, scrollable: find.byType(Scrollable).first);
      await _tap(tester, _button('Manage Teams (3 pending)'));
      expect(_loc(c), TournamentTab.teams.location(t.id), reason: 'Teams tab of the same tournament');
      expect(find.text('Clubs Requesting Registration · 3'), findsOneWidget);
      await _tap(tester, find.text('Karachi Kings CC'));
      final first = c.read(pendingRequestsProvider(t.id)).first;
      expect(_loc(c), Routes.teamRequestDetail(t.id, first.id));
      await _tap(tester, _button('Accept'));
      expect(find.text('Karachi Kings CC accepted'), findsOneWidget);
      expect(_loc(c), TournamentTab.teams.location(t.id));
      expect(find.text('Clubs Requesting Registration · 2'), findsOneWidget);
      await _clearToast(tester);
      await c.read(tournamentRegistrationsProvider.notifier)
          .decide(c.read(pendingRequestsProvider(t.id)).first.id, approve: true);

      await _go(tester, c, Routes.tournamentDetails(t.id));
      await _tap(tester, _button('Generate Fixtures'));
      expect(find.text('Bracket generated!'), findsOneWidget);
      expect(_loc(c), '${Routes.tournamentDetails(t.id)}?tab=fixtures');
      expect(find.text('Final'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(c.read(routerProvider).state.uri.path, Routes.myTournaments);
    });

    testWidgets('legacy Dashboard / Manage Teams routes open the host workspace tabs', (tester) async {
      final c = await _pumpOwner(tester);
      final t = await c.read(tournamentsProvider.notifier).create(_input());

      await _go(tester, c, Routes.tournamentDashboard(t.id));
      expect(_loc(c), Routes.tournamentDetails(t.id), reason: 'Dashboard → Overview');
      expect(_inHost(t.name), findsWidgets, reason: 'same tournament');
      expect(_inHost('Organizer Club'), findsOneWidget, reason: 'summary on Overview');
      await tester.scrollUntilVisible(_inHost('Tournament Awards'), 200, scrollable: find.byType(Scrollable).first);

      await _go(tester, c, Routes.tournamentTeamsManage(t.id));
      expect(_loc(c), TournamentTab.teams.location(t.id), reason: 'Manage Teams → Teams tab');
      expect(find.text('Organizer Club'), findsNothing, reason: 'Teams starts under the tabs, no repeated summary');
      expect(find.text('Clubs Requesting Registration · 3'), findsOneWidget);
      expect(find.text('Confirmed Teams · 0'), findsOneWidget);

      // Tab switches replace the location: one Back leaves the workspace.
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      Future<void> tapTab(TournamentTab tab) async {
        final chip = find.descendant(of: find.byType(CeWorkspaceTabs<TournamentTab>), matching: find.text(tab.label));
        await tester.ensureVisible(chip); // the tab row scrolls sideways on narrow phones
        await tester.pumpAndSettle();
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(_loc(c), tab.location(t.id));
      }

      for (final tab in TournamentTab.values.reversed) {
        await tapTab(tab);
      }
      await tapTab(TournamentTab.teams);
      expect(_loc(c), TournamentTab.teams.location(t.id));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(c.read(routerProvider).state.uri.path, Routes.myTournaments);

      // A request deep link (notification) keeps the Teams tab underneath.
      final req = c.read(pendingRequestsProvider(t.id)).first;
      await _go(tester, c, Routes.teamRequestDetail(t.id, req.id));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), TournamentTab.teams.location(t.id));
      expect(find.text('Clubs Requesting Registration · 3', skipOffstage: false), findsOneWidget, reason: 'Back → Teams tab');
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
    });

    testWidgets('a participant never lands in the host tools, and a host never registers', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.tournamentDetails('t_1'));
      expect(find.text('Hosted by another club'), findsOneWidget);
      await _go(tester, c, Routes.tournamentTeamsManage('t_1'));
      expect(_loc(c), TournamentTab.teams.location('t_1'));
      expect(find.text('Hosted by another club'), findsOneWidget);
      await _go(tester, c, Routes.tournamentDashboard('t_1'));
      expect(find.text('Hosted by another club'), findsOneWidget);
      final own = await c.read(tournamentsProvider.notifier).create(_input());
      await _go(tester, c, Routes.tournamentRegister(own.id));
      expect(find.text('Your club is hosting this'), findsOneWidget);
      await _go(tester, c, Routes.tournamentTeam(own.id));
      expect(find.text('Your club is hosting this'), findsOneWidget);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 8 screens render without overflow at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        final hosted = await c.read(tournamentsProvider.notifier).create(_input(
              name: 'Shalimar Cricket Club Grand Invitational Championship',
              type: TournamentType.league,
            ));
        final requests = c.read(pendingRequestsProvider(hosted.id));
        await c.read(tournamentRegistrationsProvider.notifier).decide(requests[0].id, approve: true);
        await c.read(tournamentRegistrationsProvider.notifier).decide(requests[1].id, approve: true);
        await c.read(tournamentsProvider.notifier).generateFixtures(hosted.id);
        final reg = await _register(c, 't_3');
        await c.read(tournamentDemoActionsProvider).organizerDecides(reg.id, approve: true);
        await _readyRegistration(c, 't_1');
        for (final loc in [
          Routes.tournamentHub,
          Routes.browseTournamentsIn('Rawalpindi'),
          Routes.tournamentRegister('t_1'),
          Routes.tournamentTeam('t_1'),
          Routes.tournamentTeamBuild('t_1'),
          Routes.tournamentTeamPick('t_1'),
          Routes.registrationSummary('t_1'),
          Routes.createTournament,
          Routes.tournamentPublished(hosted.id),
          Routes.myTournaments,
          Routes.tournamentDetails(hosted.id),
          '${Routes.tournamentDetails(hosted.id)}?tab=teams',
          '${Routes.tournamentDetails(hosted.id)}?tab=fixtures',
          '${Routes.tournamentDetails(hosted.id)}?tab=points',
          Routes.tournamentDashboard(hosted.id), // legacy → Overview
          Routes.tournamentTeamsManage(hosted.id), // legacy → Teams tab
          Routes.teamRequestDetail(hosted.id, requests[2].id),
          '${Routes.myRegistrations}?tab=approved',
          Routes.registrationDetails(reg.id),
          Routes.registrationSuccess(reg.id),
        ]) {
          await _go(tester, c, loc);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 14; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
      });
    }
  });
}
