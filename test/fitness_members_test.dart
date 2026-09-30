import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/fitness_meter.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/screens/members_screen.dart';
import 'package:criceco/features/club/teams/team_suggestion.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/club/widgets/squad_widgets.dart';
import 'package:criceco/features/fitness/fitness_providers.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 23, 10);

Future<ProviderContainer> _owner() async {
  final c = await makeContainer(clock: TestClock(_now));
  addTearDown(c.dispose);
  await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
  await c.read(sessionProvider.notifier).createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  c.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner);
  await c.read(clubMembersProvider.future);
  await c.read(clubPlayerPoolProvider.future);
  await c.read(memberActivityProvider.future);
  await c.read(performanceProvider.future);
  return c;
}

Future<ProviderContainer> _pump(WidgetTester tester, {bool owner = true, double width = 375}) async {
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
  if (owner) await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  final nav = c.read(roleControllerProvider.notifier).continueAs(owner ? UserRole.clubOwner : UserRole.player);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last);
  }
  await tester.ensureVisible(f.last);
  await tester.pumpAndSettle();
  await tester.tap(f.last);
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

/// A chip inside the Members filter panel.
Finder _inPanel(String label) =>
    find.descendant(of: find.byKey(const Key('members.filters')), matching: find.text(label));

/// A role chip in the row at the top of the Members screen.
Finder _roleChip(String label) =>
    find.descendant(of: find.byKey(const Key('members.roles')), matching: find.widgetWithText(CeChip, label));

Future<void> _scrollAll(WidgetTester tester) async {
  final count = find.byType(Scrollable).evaluate().length;
  for (var s = 0; s < count; s++) {
    for (var i = 0; i < 8; i++) {
      final scrollables = find.byType(Scrollable);
      if (s >= scrollables.evaluate().length) return;
      await tester.drag(scrollables.at(s), const Offset(0, -350), warnIfMissed: false);
      await tester.pump();
    }
  }
}

MatchLogEntry _m(int daysAgo, {int balls = 0, String overs = '0.0'}) => MatchLogEntry(
      opponentAbbr: 'KK',
      opponentName: 'Karachi Kings CC',
      date: DateTime(2026, 9, 23 - daysAgo, 14),
      result: MatchResult.won,
      runs: 0,
      balls: balls,
      wickets: 0,
      overs: overs,
    );

void main() {
  // =========================================================================
  // Fitness Meter rules
  // =========================================================================
  group('Fitness Meter rules', () {
    test('no matches in 7 days → 10/10 Fresh; older matches are ignored', () {
      final r = FitnessMeter.evaluate([_m(8, overs: '10.0'), _m(20)], now: _now);
      expect(r.score, 10);
      expect(r.level, FitnessLevel.fresh);
      expect(r.recommendation, 'Good to play');
      expect(r.matches, 0);
      expect(r.daysSinceLastMatch, isNull);
    });

    test('load, back-to-back days and rest days', () {
      // 2 matches (4) + 8 overs (2) + back-to-back (1) = 7; rested 2 days → 5.
      final r = FitnessMeter.evaluate([_m(2, overs: '4.0'), _m(3, overs: '4.0')], now: _now);
      expect(r.score, 5);
      expect(r.level, FitnessLevel.fatigued);
      expect(r.restDays, 2);
      expect(r.recommendation, 'Take 2 rest days before the next match');
      expect(r.alerts, contains('Played on consecutive days'));
      expect(r.backToBack, 1);
      expect(r.daysSinceLastMatch, 2);
    });

    test('Moderate says one more match; Overloaded says avoid playing', () {
      final moderate = FitnessMeter.evaluate([_m(1, balls: 30), _m(4, balls: 35)], now: _now);
      expect(moderate.score, 6);
      expect(moderate.recommendation, 'Can safely play one more match, then rest');
      final heavy = FitnessMeter.evaluate(
          [for (final d in [1, 2, 4, 6]) _m(d, overs: '6.0')], now: _now);
      expect(heavy.score, 0);
      expect(heavy.level, FitnessLevel.overloaded);
      expect(heavy.avoidPlaying, isTrue);
      expect(heavy.recommendation, 'Avoid playing — take 7 rest days');
      expect(heavy.alerts, containsAll(['4 matches in the last 7 days', '24 overs bowled this week']));
    });

    test('injured / unavailable on Availability always means avoid playing', () {
      final r = FitnessMeter.evaluate(const [], now: _now, availability: PlayerAvailability.injured);
      expect(r.score, 10);
      expect(r.avoidPlaying, isTrue);
      expect(r.recommendation, 'Avoid playing — marked injured');
      expect(r.alerts.first, 'Marked injured on Availability');
    });

    test('overs figures count balls ("3.4" = 22 balls)', () {
      expect(FitnessMeter.ballsIn('3.4'), 22);
      expect(FitnessMeter.ballsIn('4.0'), 24);
      expect(FitnessMeter.ballsIn('0'), 0);
    });
  });

  // =========================================================================
  // Members data, fitness visibility, filters
  // =========================================================================
  group('Members and fitness', () {
    test('members: owner with Player profile, 18 linked players, staff without fitness', () async {
      final c = await _owner();
      final members = c.read(clubMembersProvider).value!;
      expect(members, hasLength(21));
      final owner = members.singleWhere((m) => m.role == MemberRole.owner);
      expect(owner.name, 'Aman Ali');
      expect(owner.playingRole, PlayerRole.batsman, reason: 'one account, both roles');
      expect(c.read(memberFitnessProvider(owner.id))!.score, c.read(playerFitnessProvider)!.score);
      expect(c.read(memberFitnessProvider('mem_coach')), isNull, reason: 'staff: no cricket fitness');
      expect(members.where((m) => m.name == 'Usman Tariq'), isEmpty, reason: 'still a pending request');
      final levels = {
        for (final m in members)
          if (c.read(memberFitnessProvider(m.id)) case final f?) f.level,
      };
      expect(levels, FitnessLevel.values.toSet(), reason: 'demo shows every level');
      expect(c.read(memberFitnessProvider('mem_sp_10'))!.level, FitnessLevel.overloaded);
      expect(c.read(memberFitnessProvider('mem_sp_16'))!.level, FitnessLevel.fatigued);
      expect(c.read(memberFitnessProvider('mem_sp_2'))!.level, FitnessLevel.moderate);
      expect(c.read(memberFitnessProvider('mem_sp_7'))!.avoidPlaying, isTrue, reason: 'unavailable');
    });

    test('player demo: Moderate from the two matches in the last 7 days', () async {
      final c = await _owner();
      final f = c.read(playerFitnessProvider)!;
      expect(f.matches, 2);
      expect(f.level, FitnessLevel.moderate);
    });

    test('approving a join request as Player carries the cricket profile; staff roles do not', () async {
      final c = await _owner();
      final repo = c.read(clubRepositoryProvider);
      const club = 'club_sc';
      await repo.decideJoinRequest(club, 'jr_1', approve: true, at: _now);
      await repo.decideJoinRequest(club, 'jr_2', approve: true, role: MemberRole.coach, at: _now);
      final members = await repo.members(club);
      final bilal = members.singleWhere((m) => m.name == 'Bilal Ahmed');
      expect(bilal.playingRole, PlayerRole.batsman);
      expect(bilal.battingStyle, BattingStyle.rightHanded);
      final hamza = members.singleWhere((m) => m.name == 'Hamza Sheikh');
      expect(hamza.role, MemberRole.coach);
      expect(hamza.plays, isFalse);
    });

    test('filter: roles OR within the group, AND with fitness levels', () {
      const bowler = ClubMember(id: 'a', name: 'A', role: MemberRole.player, playingRole: PlayerRole.bowler);
      const keeper =
          ClubMember(id: 'b', name: 'B', role: MemberRole.player, playingRole: PlayerRole.batsman, isWicketkeeper: true);
      const f = MemberFilter(roles: {MemberRoleFilter.bowler, MemberRoleFilter.wicketKeeper});
      expect(f.accepts(bowler, FitnessLevel.fresh), isTrue);
      expect(f.accepts(keeper, FitnessLevel.fresh), isTrue);
      final g = f.copyWith(levels: {FitnessLevel.overloaded});
      expect(g.accepts(bowler, FitnessLevel.fresh), isFalse);
      expect(g.accepts(bowler, FitnessLevel.overloaded), isTrue);
      expect(g.activeCount, 1, reason: 'the filter-button badge counts the panel filters, not the role chips');
      expect(keeper.roleLine, 'Batsman · Wicket Keeper');
    });
  });

  // =========================================================================
  // Suggest Team
  // =========================================================================
  group('Suggest Team (logic)', () {
    test('11 + 2, a wicket keeper, 4+ bowling options; injured / unavailable / overloaded left out', () async {
      final c = await _owner();
      final pool = c.read(clubPlayerPoolProvider).value!;
      final s = TeamSuggestion.build(
        pool,
        stats: {for (final p in pool) p.id: c.read(squadPlayerStatsProvider((p.name, p.position, p.availability)))},
        fitness: c.read(poolFitnessProvider),
      );
      final xi = [for (final e in s.picks.entries) if (e.value == SelectionRole.playing) e.key];
      final subs = [for (final e in s.picks.entries) if (e.value == SelectionRole.sub) e.key];
      expect(xi, hasLength(11));
      expect(subs, hasLength(2));
      final byId = {for (final p in pool) p.id: p};
      expect(xi.any((id) => TeamSuggestion.isKeeper(byId[id]!)), isTrue);
      expect(xi.where((id) => byId[id]!.category != SquadCategory.batsman).length, greaterThanOrEqualTo(4));
      final out = {for (final (p, reason) in s.leftOut) p.name: reason};
      expect(out['Kamran Iqbal'], 'Overloaded (0/10)');
      expect(out['Moiz Yousuf'], 'Overloaded (3/10)');
      expect(out['Usman Tariq'], 'Injured');
      expect(out['Fahad Mir'], 'Unavailable');
      for (final name in out.keys) {
        expect(s.picks.keys.map((id) => byId[id]!.name), isNot(contains(name)));
      }
    });
  });

  // =========================================================================
  // Screens
  // =========================================================================
  group('Player Dashboard Fitness Meter', () {
    testWidgets('card after Next Match; details sheet; availability updates it', (tester) async {
      final c = await _pump(tester, owner: false);
      final card = find.byKey(const Key('fitness.card'));
      await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Can safely play one more match, then rest'), findsOneWidget);
      final nextMatch = tester.getTopLeft(find.text('Next Match')).dy;
      expect(tester.getTopLeft(card).dy, greaterThan(nextMatch));
      await _tap(tester, card);
      expect(find.text('Overs bowled'.toUpperCase()), findsOneWidget);
      expect(find.textContaining('not a medical assessment'), findsOneWidget);
      await _tap(tester, _button('Close'));

      c.read(playerAvailabilityProvider.notifier).update(status: PlayerAvailability.unavailable);
      await tester.pumpAndSettle();
      expect(find.text('Avoid playing — marked unavailable'), findsOneWidget);
    });
  });

  group('Members screen', () {
    testWidgets('players with role + fitness, staff section, role chips, right-side filter panel', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.members);
      expect(find.bySemanticsLabel('21 members'), findsOneWidget);
      expect(find.text('Players · 19'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Aman Ali, Batsman, Owner, Fitness 6 out of 10')), findsOneWidget);

      // Role chips near the top: All (default) + the four cricket roles.
      for (final label in ['All', 'Batsman', 'Bowler', 'All-Rounder', 'Wicket Keeper']) {
        expect(_roleChip(label), findsOneWidget, reason: label);
      }
      expect(tester.widget<CeChip>(_roleChip('All')).selected, isTrue, reason: 'All by default');
      expect(tester.getTopLeft(_roleChip('All')).dy, lessThan(tester.getTopLeft(find.text('Players · 19')).dy));

      await _tap(tester, _roleChip('Wicket Keeper'));
      expect(tester.widget<CeChip>(_roleChip('Wicket Keeper')).selected, isTrue);
      expect(tester.widget<CeChip>(_roleChip('All')).selected, isFalse);
      final keepers = (await c.read(clubMembersProvider.future)).where((m) => m.isWicketkeeper).length;
      expect(find.text('Players · $keepers of 19'), findsOneWidget);
      expect(find.textContaining('Club Staff'), findsNothing, reason: 'staff have no cricket role');

      await _tap(tester, _roleChip('Bowler'));
      expect(tester.widget<CeChip>(_roleChip('Wicket Keeper')).selected, isFalse, reason: 'one role at a time');
      expect(find.text('Players · 6 of 19'), findsOneWidget);
      for (final row in tester.widgetList<MemberRow>(find.byType(MemberRow))) {
        expect(row.member.playingRole, PlayerRole.bowler);
      }

      await tester.tap(find.byTooltip('Filter members'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('members.filters')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('members.filters'))).dx, greaterThan(0), reason: 'slides in from the right');
      expect(_inPanel('Bowler'), findsNothing, reason: 'roles are picked with the chips, not in the panel');
      await tester.tap(_inPanel('Fitness: low to high'));
      await tester.tap(_button('Apply'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Filter members, 1 active'), findsOneWidget);
      expect(find.text('Players · 6 of 19'), findsOneWidget);
      expect(find.textContaining('Club Staff'), findsNothing, reason: 'staff hidden while filtering');
      expect(tester.getTopLeft(find.text('Kamran Iqbal')).dy, lessThan(tester.getTopLeft(find.text('Moiz Yousuf')).dy),
          reason: 'lowest fitness first');

      await _tap(tester, _roleChip('All'));
      expect(find.text('Players · 19'), findsOneWidget);
      await tester.tap(find.byTooltip('Filter members, 1 active'));
      await tester.pumpAndSettle();
      await tester.tap(_button('Reset'));
      await tester.pump();
      await tester.tap(_inPanel('Overloaded'));
      await tester.tap(_button('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Players · 2 of 19'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Players · 19'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Club Staff · 2'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Tariq Mahmood'), findsOneWidget);
    });

    testWidgets('Member Profile: fitness, recent matches, stats; Back → Members; staff and not-found', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.members);
      await tester.enterText(find.byType(TextField), 'Kamran');
      await tester.pumpAndSettle();
      await _tap(tester, find.bySemanticsLabel(RegExp(r'^Kamran Iqbal')));
      expect(_loc(c), Routes.memberProfile('mem_sp_10'));
      expect(find.text('Avoid playing — take 7 rest days'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Last 7 days · 4 matches'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Last 7 days · 4 matches'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Player Stats'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Player Stats'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.members);

      await _go(tester, c, Routes.memberProfile('mem_coach'));
      expect(find.text('Club Coach'), findsOneWidget);
      expect(find.byKey(const Key('fitness.card')), findsNothing, reason: 'no cricket fitness for staff');

      await _go(tester, c, Routes.memberProfile('nope'));
      expect(find.text('Member not found'), findsOneWidget);
    });
  });

  group('Suggest Team (New Team sheet)', () {
    testWidgets('suggest → review (existing pick cycle) → Create Team saves the selection', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.teams);
      await _tap(tester, find.bySemanticsLabel(RegExp('^Create New Team')));
      await _tap(tester, find.byKey(const Key('teams.suggest')));
      expect(find.text('Suggested Team'), findsOneWidget);
      expect(find.text('11/11'), findsOneWidget);
      expect(find.text('2/4'), findsOneWidget);
      expect(find.textContaining('Kamran Iqbal — Overloaded (0/10)'), findsOneWidget);

      // Adjust: the first suggested player goes Playing XI → Substitute.
      await _tap(tester, find.byType(SquadPickRow).first);
      expect(find.text('10/11'), findsOneWidget);
      expect(find.text('3/4'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('teams.name')), 'Weekend XI');
      await _tap(tester, find.text('T20'));
      await _tap(tester, _button('Create Team'));
      expect(find.text('Team created!'), findsOneWidget);
      final team = c.read(teamsProvider).value!.singleWhere((t) => t.name == 'Weekend XI');
      expect(team.playingCount, 10);
      expect(team.subCount, 3);
    });

    testWidgets('Create Team without Suggest Team still creates an empty team', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.teams);
      await _tap(tester, find.bySemanticsLabel(RegExp('^Create New Team')));
      await tester.enterText(find.byKey(const Key('teams.name')), 'Plain XI');
      await _tap(tester, find.text('ODI'));
      await _tap(tester, _button('Create Team'));
      expect(c.read(teamsProvider).value!.singleWhere((t) => t.name == 'Plain XI').members, isEmpty);
    });
  });

  // =========================================================================
  // Responsive
  // =========================================================================
  group('Responsive (Fitness Meter, Members, Member Profile, Suggest Team)', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('player dashboard meter + sheet fit at ${width.toInt()} px', (tester) async {
        await _pump(tester, owner: false, width: width);
        await _scrollAll(tester);
        expect(tester.takeException(), isNull, reason: 'dashboard @ $width');
        await _tap(tester, find.byKey(const Key('fitness.card')));
        await _scrollAll(tester);
        expect(tester.takeException(), isNull, reason: 'fitness sheet @ $width');
      });

      testWidgets('club owner screens fit at ${width.toInt()} px', (tester) async {
        final c = await _pump(tester, width: width);
        await _go(tester, c, Routes.members);
        for (final label in ['All-Rounder', 'Wicket Keeper', 'All']) {
          await _tap(tester, _roleChip(label));
          expect(tester.takeException(), isNull, reason: '$label chip @ $width');
        }
        await _scrollAll(tester);
        expect(tester.takeException(), isNull, reason: 'members @ $width');
        await tester.tap(find.byTooltip('Filter members'));
        await tester.pumpAndSettle();
        for (final label in ['Overloaded', 'Fitness: high to low']) {
          await tester.tap(_inPanel(label));
        }
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'filter panel @ $width');
        await tester.tap(_button('Apply'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'filtered members @ $width');

        for (final id in ['mem_sp_10', 'mem_owner', 'mem_manager', 'mem_sp_6']) {
          await _go(tester, c, Routes.memberProfile(id));
          await _scrollAll(tester);
          expect(tester.takeException(), isNull, reason: 'profile $id @ $width');
        }

        await _go(tester, c, Routes.teams);
        await _tap(tester, find.bySemanticsLabel(RegExp('^Create New Team')));
        await _tap(tester, find.byKey(const Key('teams.suggest')));
        await _scrollAll(tester);
        expect(tester.takeException(), isNull, reason: 'suggest team @ $width');
      });
    }
  });
}
