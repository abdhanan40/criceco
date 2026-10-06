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
import 'package:criceco/features/fitness/fitness_widgets.dart';
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

    WorkoutEntry wk(int daysAgo, int minutes, WorkoutIntensity intensity) => WorkoutEntry(
          id: 'w$daysAgo$minutes',
          date: _now.subtract(Duration(days: daysAgo)),
          type: WorkoutType.training,
          minutes: minutes,
          intensity: intensity,
        );

    test('workout load = hours × intensity points (Light 0.5 · Moderate 1 · High 1.5)', () {
      expect(FitnessMeter.workoutLoad(wk(0, 60, WorkoutIntensity.light)), 0.5);
      expect(FitnessMeter.workoutLoad(wk(0, 60, WorkoutIntensity.moderate)), 1.0);
      expect(FitnessMeter.workoutLoad(wk(0, 90, WorkoutIntensity.high)), 2.25);
      expect(FitnessMeter.workoutLoad(wk(0, 30, WorkoutIntensity.moderate)), 0.5);
    });

    test('match-only results are unchanged; workouts only add training load', () {
      final matches = [_m(2, overs: '4.0'), _m(3, overs: '4.0')];
      final base = FitnessMeter.evaluate(matches, now: _now);
      final same = FitnessMeter.evaluate(matches, now: _now, workouts: const []);
      expect((same.score, same.level, same.recommendation, same.restDays),
          (base.score, base.level, base.recommendation, base.restDays));
      expect(same.alerts, base.alerts);
      expect((base.score, base.restDays), (5, 2), reason: "same numbers as the existing rule test");
      expect((base.trainingSessions, base.trainingLoad), (0, 0.0));

      // 2 h high (3) on top of the match load (7) with 2 rest days → 10 − 10 + 2 = 2.
      final trained = FitnessMeter.evaluate(matches, now: _now, workouts: [wk(1, 120, WorkoutIntensity.high)]);
      expect((trained.trainingSessions, trained.trainingLoad), (1, 3.0));
      expect(trained.score, 2);
      expect(trained.level, FitnessLevel.overloaded);
      expect((trained.matches, trained.daysSinceLastMatch, trained.backToBack), (2, 2, 1),
          reason: 'workouts are not matches and do not change recovery');
    });

    test('no matches: training alone lowers the score; old workouts are ignored', () {
      final r = FitnessMeter.evaluate(const [], now: _now, workouts: [
        wk(0, 60, WorkoutIntensity.high),
        wk(2, 60, WorkoutIntensity.high),
        wk(9, 600, WorkoutIntensity.high), // outside the 7 days
      ]);
      expect((r.trainingSessions, r.trainingLoad), (2, 3.0));
      expect(r.score, 7);
      expect(r.level, FitnessLevel.moderate);
      expect(r.matches, 0);
      // Thresholds are untouched.
      expect([for (final s in [10, 8, 7, 6, 5, 4, 3, 0]) FitnessLevel.ofScore(s)], [
        FitnessLevel.fresh, FitnessLevel.fresh, FitnessLevel.moderate, FitnessLevel.moderate,
        FitnessLevel.fatigued, FitnessLevel.fatigued, FitnessLevel.overloaded, FitnessLevel.overloaded,
      ]);
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
    testWidgets('inline after Next Match: gauge, metrics, tap-a-day, recommendation, next match; availability updates it',
        (tester) async {
      final c = await _pump(tester, owner: false);
      final report = c.read(playerFitnessProvider)!;
      final card = find.byKey(const Key('fitness.card'));
      await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
      final nextMatch = tester.getTopLeft(find.text('Next Match')).dy;
      expect(tester.getTopLeft(card).dy, greaterThan(nextMatch));
      expect(find.text('Fitness Meter'), findsOneWidget);
      expect(find.text('Last 7 days'), findsOneWidget);
      expect(find.byKey(const Key('fitness.gauge')), findsOneWidget);
      expect(find.text('${report.score}'), findsWidgets);
      for (final (value, label) in [
        ('${report.matches}', 'Matches'),
        ('${report.ballsFaced}', 'Balls faced'),
        (report.oversBowled, 'Overs bowled'),
      ]) {
        expect(find.descendant(of: card, matching: find.text(label)), findsOneWidget, reason: label);
        expect(find.descendant(of: card, matching: find.text(value)), findsWidgets, reason: label);
      }

      // Tap a day: highlighted, with its detail below — no navigation.
      final loc = _loc(c);
      // Bring the bars well clear of the bottom navigation first.
      await tester.ensureVisible(find.byKey(const Key('fitness.gauge'))); // card top at the top
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fitness.day.0')));
      await tester.pumpAndSettle();
      final day0 = DateTime(2026, 9, 17); // _now − 6 days
      expect(find.descendant(of: find.byKey(const Key('fitness.dayDetail')), matching: find.textContaining('Thu 17 Sep')),
          findsOneWidget);
      expect(_loc(c), loc, reason: 'in place');
      expect(day0.weekday, DateTime.thursday);

      // Recommendation from the report; moderate → OK to play.
      await tester.scrollUntilVisible(find.byKey(const Key('fitness.nextMatch')), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(report.recommendation), findsOneWidget);
      expect(find.text('OK TO PLAY'), findsOneWidget);
      expect(find.byKey(const Key('fitness.recoveryPlan')), findsNothing, reason: 'no rest advised');
      expect(find.textContaining('not a medical assessment'), findsOneWidget);

      // Tapping a day bar stays in place; tapping the card opens the details sheet.
      expect(find.byKey(const Key('fitness.sheet')), findsNothing, reason: 'day taps never open the sheet');
      await tester.ensureVisible(find.byKey(const Key('fitness.gauge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fitness.gauge')));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const Key('fitness.sheet'));
      expect(sheet, findsOneWidget);
      expect(_loc(c), loc, reason: 'a sheet, no navigation');
      for (final label in ['Matches', 'Overs bowled', 'Balls faced']) {
        expect(find.descendant(of: sheet, matching: find.text(label)), findsOneWidget, reason: label);
      }
      expect(find.descendant(of: sheet, matching: find.textContaining(RegExp(r'Days? since last'))), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text(report.recommendation)), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.textContaining('not a medical assessment')), findsOneWidget);
      await _tap(tester, _button('Close'));
      expect(find.byKey(const Key('fitness.sheet')), findsNothing);

      c.read(playerAvailabilityProvider.notifier).update(status: PlayerAvailability.unavailable);
      await tester.pumpAndSettle();
      expect(find.text('Avoid playing — marked unavailable'), findsOneWidget);
      expect(find.text('SIT OUT'), findsOneWidget);
      expect(find.text('Marked unavailable on Availability'), findsOneWidget);
    });
  });

  group('Fitness Meter view (each state)', () {
    final now = DateTime(2026, 9, 26, 10); // Saturday
    MatchLogEntry entry(int daysAgo, {int balls = 30, String overs = '0'}) => MatchLogEntry(
          opponentAbbr: 'HH',
          opponentName: 'Harbour Hawks',
          date: now.subtract(Duration(days: daysAgo)),
          result: MatchResult.won,
          runs: 40,
          balls: balls,
          wickets: 1,
          overs: overs,
        );
    final samples = <String, (List<MatchLogEntry>, PlayerAvailability, FitnessLevel)>{
      'fresh': ([entry(5, balls: 31, overs: '4')], PlayerAvailability.available, FitnessLevel.fresh),
      'moderate': ([entry(4), entry(3)], PlayerAvailability.available, FitnessLevel.moderate),
      'fatigued': ([entry(3, balls: 40, overs: '4'), entry(1, balls: 20)], PlayerAvailability.available, FitnessLevel.fatigued),
      'overloaded': (
        [entry(4, balls: 45, overs: '4'), entry(2, balls: 30, overs: '4'), entry(1, balls: 31, overs: '4')],
        PlayerAvailability.available,
        FitnessLevel.overloaded
      ),
      'injured': ([entry(5, balls: 31, overs: '4')], PlayerAvailability.injured, FitnessLevel.fresh),
    };

    Future<FitnessReport> pumpView(WidgetTester tester, String state, {double width = 375, bool next = true}) async {
      tester.view.physicalSize = Size(width * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final (log, availability, level) = samples[state]!;
      final report = FitnessMeter.evaluate(log, now: now, availability: availability);
      expect(report.level, level, reason: 'sample data for $state');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FitnessMeterView(
              report: report,
              log: log,
              now: now,
              nextMatch: next ? (startsAt: now.add(const Duration(days: 1)), opponent: 'Falcons CC') : null,
              sharedWithClub: 'Karachi Ravians CC',
            ),
          ),
        ),
      ));
      return report;
    }

    for (final (state, headline, chip, sitOut) in [
      ('fresh', 'Fresh · ready to play', 'FRESH', false),
      ('moderate', 'Moderate load', 'MODERATE', false),
      ('fatigued', 'High fatigue', 'FATIGUED', true),
      ('overloaded', 'Overloaded', 'OVERLOADED', true),
      ('injured', 'Not available to play', 'UNAVAILABLE', true),
    ]) {
      testWidgets('$state: status, recommendation, recovery plan and next-match status', (tester) async {
        final r = await pumpView(tester, state);
        expect(find.text(headline), findsOneWidget);
        expect(find.text(chip), findsOneWidget);
        expect(find.text('${r.score}'), findsOneWidget, reason: 'the report score, unchanged');
        expect(find.text(r.recommendation), findsOneWidget, reason: 'the report recommendation, unchanged');
        for (final a in r.alerts) {
          expect(find.text(a), findsOneWidget, reason: 'every existing alert is a reason');
        }
        // Recovery plan only when the report advises rest, sized by its rest days.
        expect(find.byKey(const Key('fitness.recoveryPlan')), r.restDays > 0 ? findsOneWidget : findsNothing);
        if (r.restDays > 0) {
          expect(find.text('Rest'), findsNWidgets(r.restDays + 1), reason: 'plan days + the legend');
          expect(find.text('Ready'), findsOneWidget);
        }
        expect(find.text(sitOut ? 'SIT OUT' : 'OK TO PLAY'), findsOneWidget);
        expect(find.text('Next: Sun 27 · vs Falcons CC'), findsOneWidget);
        expect(find.text('Shared with your club owner at Karachi Ravians CC'), findsOneWidget);
      });
    }

    testWidgets('a match and a workout on the same day: one stacked bar, both in the day detail', (tester) async {
      tester.view.physicalSize = const Size(375 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final log = [entry(2, balls: 30)];
      final workouts = [
        WorkoutEntry(
            id: 'w1', date: now.subtract(const Duration(days: 2)), type: WorkoutType.nets, minutes: 60,
            intensity: WorkoutIntensity.moderate),
        WorkoutEntry(
            id: 'w2', date: now.subtract(const Duration(days: 4)), type: WorkoutType.running, minutes: 30,
            intensity: WorkoutIntensity.light),
      ];
      final report = FitnessMeter.evaluate(log, now: now, workouts: workouts);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FitnessMeterView(report: report, log: log, now: now, workouts: workouts),
          ),
        ),
      ));
      expect(find.text('1 match, 2 training sessions and 5 rest days this week.'), findsOneWidget);
      expect(find.byKey(const Key('fitness.bar.training')), findsNWidgets(2), reason: 'two days with training');
      for (final l in ['Match', 'Training', 'Rest']) {
        expect(find.text(l), findsOneWidget, reason: 'legend $l');
      }
      // Default selection: the latest active day (match + nets on Thu 24).
      Finder detail(String t) => find.descendant(of: find.byKey(const Key('fitness.dayDetail')), matching: find.text(t));
      expect(detail('Match vs HH · 30 balls faced'), findsOneWidget);
      expect(detail('Nets / Practice · 60 min · Moderate'), findsOneWidget);
      expect(detail('Load 3.5'), findsOneWidget, reason: 'match 2.5 + training 1');
      await tester.tap(find.byKey(const Key('fitness.day.2'))); // Tue 22: a light run only
      await tester.pumpAndSettle();
      expect(detail('Running / Cardio · 30 min · Light'), findsOneWidget);
      expect(detail('Load 0.3'), findsOneWidget, reason: '0.25 rounded to one decimal');
    });

    testWidgets('tap a day: highlight + detail; rest days say so; no next match → no row', (tester) async {
      await pumpView(tester, 'moderate', next: false);
      expect(find.byKey(const Key('fitness.nextMatch')), findsNothing);
      // Default: the latest match day (3 days ago = Wed 23).
      Finder detail(String t) => find.descendant(of: find.byKey(const Key('fitness.dayDetail')), matching: find.textContaining(t));
      expect(detail('Wed 23 Sep'), findsOneWidget);
      expect(detail('Match vs HH · 30 balls faced'), findsOneWidget);
      expect(detail('Load 2.5'), findsOneWidget, reason: '2 per match + 0.5 per 30 balls faced');
      await tester.tap(find.byKey(const Key('fitness.day.6'))); // today, no match
      await tester.pumpAndSettle();
      expect(detail('Sat 26 Sep'), findsOneWidget);
      expect(detail('Rest day · recovery'), findsOneWidget);
      expect(detail('Load 0'), findsOneWidget);
      expect(tester.getSemantics(find.byKey(const Key('fitness.day.6'))), matchesSemantics(
              isSelected: true, hasSelectedState: true, isButton: true, hasTapAction: true, label: 'Saturday 26, rest day'));
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('every state fits at ${width.toInt()} px', (tester) async {
        for (final state in samples.keys) {
          await pumpView(tester, state, width: width);
          await tester.tap(find.byKey(const Key('fitness.day.3')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$state @ $width');
        }
      });
    }
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
      await tester.scrollUntilVisible(find.text('Tariq Mahmood'), 200, scrollable: find.byType(Scrollable).first);
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
      expect(find.byKey(const Key('fitness.recoveryPlan')), findsOneWidget, reason: 'rest advised');
      expect(find.byKey(const Key('fitness.nextMatch')), findsNothing, reason: 'owner view: no next match');
      expect(find.byKey(const Key('fitness.shared')), findsNothing);
      expect(find.descendant(of: find.byKey(const Key('fitness.card')), matching: find.text('Details')), findsNothing,
          reason: 'the details sheet is a Player Dashboard affordance');
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
      testWidgets('player dashboard meter fits at ${width.toInt()} px', (tester) async {
        await _pump(tester, owner: false, width: width);
        await _scrollAll(tester);
        expect(tester.takeException(), isNull, reason: 'dashboard @ $width');
        await _tap(tester, find.byKey(const Key('fitness.day.2')));
        expect(tester.takeException(), isNull, reason: 'selected day @ $width');
        await tester.ensureVisible(find.byKey(const Key('fitness.gauge')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('fitness.gauge')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('fitness.sheet')), findsOneWidget);
        await _scrollAll(tester);
        expect(tester.takeException(), isNull, reason: 'details sheet @ $width');
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
