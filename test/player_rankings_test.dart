import 'dart:async';

import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/domain/player_ranking.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/hunt/player_hunt_controller.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/club/widgets/squad_widgets.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/features/player/screens/performance_workspace.dart';
import 'package:criceco/features/rankings/rankings_providers.dart';
import 'package:criceco/features/rankings/rankings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 23, 10);
final _list = find.descendant(of: find.byKey(const Key('rankings.list')), matching: find.byType(Scrollable)).first;

RankingInput _in(
  String id, {
  SquadCategory role = SquadCategory.batsman,
  int matches = 10,
  int runs = 300,
  double? avg = 30,
  double? sr = 120,
  int wickets = 0,
  double? econ,
  double? bowlAvg,
  double? rating = 7,
  int wins = 3,
  int played = 5,
  String? name,
  bool me = false,
}) =>
    RankingInput(
      playerId: id,
      name: name ?? id,
      club: 'Club',
      role: role,
      completedMatches: matches,
      runs: runs,
      battingAverage: avg,
      strikeRate: sr,
      wickets: wickets,
      economy: econ,
      bowlingAverage: bowlAvg,
      rating: rating,
      recentWins: wins,
      recentPlayed: played,
      isMe: me,
    );

Future<ProviderContainer> _pump(WidgetTester tester, {required UserRole role, double width = 390}) async {
  tester.view.physicalSize = Size(width * 3, 900 * 3);
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
  if (role == UserRole.clubOwner) {
    await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  }
  final nav = c.read(roleControllerProvider.notifier).continueAs(role);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

void main() {
  group('Eligibility', () {
    test('6 completed matches → not ranked; 7 → ranked', () {
      final board = PlayerRankingMath.rank([_in('six', matches: 6), _in('seven', matches: 7)]);
      final six = board.byId('six')!;
      final seven = board.byId('seven')!;
      expect((six.eligible, six.overallRank, six.roleRank, six.progress), (false, null, null, '6/7'));
      expect((seven.eligible, seven.overallRank, seven.roleRank), (true, 1, 1));
      for (final c in RankingCategory.values) {
        expect(board.leaderboard(c).map((r) => r.playerId), isNot(contains('six')), reason: c.label);
      }
    });

    test('progress never shows more than 7/7', () {
      expect(PlayerRankingMath.rank([_in('a', matches: 0)]).byId('a')!.progress, '0/7');
      expect(PlayerRankingMath.rank([_in('a', matches: 30)]).byId('a')!.progress, '7/7');
    });

    test('only completed matches count — scheduled and cancelled matches are ignored', () async {
      final c = await makeContainer(clock: TestClock(_now));
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      final matches = await c.read(playerMatchesProvider.future);
      expect(matches.where((m) => m.status != PlayerMatchStatus.past), isNotEmpty, reason: 'upcoming / cancelled exist');
      final perf = await c.read(performanceProvider.future);
      final me = (await c.read(rankingBoardProvider.future)).me!;
      expect(me.completedMatches, perf.matchLog.length, reason: 'the season log = completed matches with a result');
      expect(perf.matchLog.every((e) => !e.date.isAfter(_now)), isTrue);
    });
  });

  group('Ranking score', () {
    test('deterministic and within 0–100', () {
      final input = _in('a');
      expect(PlayerRankingMath.score(input), PlayerRankingMath.score(input));
      final one = PlayerRankingMath.rank([_in('a'), _in('b', runs: 500), _in('c', role: SquadCategory.bowler, wickets: 20, econ: 6)]);
      final two = PlayerRankingMath.rank([_in('c', role: SquadCategory.bowler, wickets: 20, econ: 6), _in('b', runs: 500), _in('a')]);
      expect([for (final r in one.leaderboard(RankingCategory.overall)) r.playerId],
          [for (final r in two.leaderboard(RankingCategory.overall)) r.playerId], reason: 'input order never matters');
      for (final r in one.all) {
        expect(r.score, inInclusiveRange(0, 100));
      }
    });

    test('better numbers rank higher (batting, bowling)', () {
      expect(PlayerRankingMath.score(_in('good', runs: 450, avg: 40, sr: 140, rating: 8.5)),
          greaterThan(PlayerRankingMath.score(_in('weak', runs: 120, avg: 15, sr: 90, rating: 6))));
      int bowl(int wickets, double econ) =>
          PlayerRankingMath.score(_in('b', role: SquadCategory.bowler, wickets: wickets, econ: econ, bowlAvg: 22));
      expect(bowl(20, 5.5), greaterThan(bowl(8, 8.5)));
    });

    test('all-rounders get half batting, half bowling', () {
      final p = _in('ar', role: SquadCategory.allRounder, wickets: 12, econ: 7, bowlAvg: 25);
      final expected = ((PlayerRankingMath.battingScore(p) + PlayerRankingMath.bowlingScore(p)) / 2 * 100).round();
      expect(PlayerRankingMath.score(p), expected);
    });

    test('missing optional stats are left out, never counted as zero', () {
      final bare = _in('bare', avg: null, sr: null, rating: null, played: 0, wins: 0);
      expect(PlayerRankingMath.score(bare), inInclusiveRange(0, 100));
      // Runs per match alone (300 / 10 = 30 of the 50 benchmark) → 60.
      expect(PlayerRankingMath.score(bare), 60);
      final noEconomy = _in('bowler', role: SquadCategory.bowler, wickets: 10, econ: null, bowlAvg: null, rating: null, played: 0);
      expect(PlayerRankingMath.score(noEconomy), 40, reason: '1 wicket per match of 2.5 → 0.4');
      expect(PlayerRankingMath.score(_in('zero', matches: 0, runs: 0, avg: null, sr: null, rating: null, played: 0)), 0);
    });
  });

  group('Tie-breaking', () {
    List<String> order(List<RankingInput> inputs) =>
        [for (final r in PlayerRankingMath.rank(inputs).leaderboard(RankingCategory.overall)) r.playerId];

    test('equal score → more completed matches first', () {
      final a = _in('a', matches: 10, runs: 300);
      final b = _in('b', matches: 20, runs: 600);
      expect(PlayerRankingMath.score(a), PlayerRankingMath.score(b));
      expect(order([a, b]), ['b', 'a']);
    });

    test('then the better existing rating', () {
      final a = _in('a', rating: 8.0);
      final b = _in('b', rating: 8.04);
      expect(PlayerRankingMath.score(a), PlayerRankingMath.score(b));
      expect(order([a, b]), ['b', 'a']);
    });

    test('then better recent form, then name A–Z', () {
      final a = _in('a', wins: 1, played: 2);
      final b = _in('b', wins: 2, played: 4);
      expect(PlayerRankingMath.score(a), PlayerRankingMath.score(b));
      expect(order([a, b]), ['b', 'a']);
      expect(order([_in('z1', name: 'Zubair'), _in('a1', name: 'Ali')]), ['a1', 'z1']);
    });
  });

  group('Role tables', () {
    final board = PlayerRankingMath.rank([
      _in('bat1', runs: 450, avg: 45),
      _in('bat2', runs: 200),
      _in('bowl1', role: SquadCategory.bowler, wickets: 18, econ: 6),
      _in('ar1', role: SquadCategory.allRounder, wickets: 10, econ: 7),
      _in('rookie', matches: 3),
    ]);
    List<String> ids(RankingCategory c) => [for (final r in board.leaderboard(c)) r.playerId];

    test('Batsmen, Bowlers and All-Rounders hold only their role; Overall holds every eligible player', () {
      expect(ids(RankingCategory.batsmen), ['bat1', 'bat2']);
      expect(ids(RankingCategory.bowlers), ['bowl1']);
      expect(ids(RankingCategory.allRounders), ['ar1']);
      expect(ids(RankingCategory.overall).toSet(), {'bat1', 'bat2', 'bowl1', 'ar1'});
      expect(board.byId('bat2')!.roleRank, 2);
      expect(board.byId('bowl1')!.roleRank, 1);
    });
  });

  group('Real data', () {
    test('the board covers the roster, Available Players (once each) and you', () async {
      final c = await makeContainer(clock: TestClock(_now));
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      final board = await c.read(rankingBoardProvider.future);
      final names = [for (final r in board.all) r.input.name];
      expect(names.toSet().length, names.length, reason: 'nobody is counted twice');
      expect(names, containsAll(['Aman Ali', 'Ali Raza', 'Ali Hassan']));
      expect(board.me!.input.name, 'Aman Ali');
      final open = await c.read(openPlayersProvider.future);
      final dupe = open.firstWhere((p) => p.name == 'Ahmed Raza'); // also on the roster
      expect(rankingForOpenPlayer(board, dupe)!.playerId, isNot(dupe.id), reason: 'the roster entry');
    });
  });

  group('UI', () {
    testWidgets('My Performance → Rankings: your ranking, your highlighted row, role tabs, search', (tester) async {
      final c = await _pump(tester, role: UserRole.player);
      c.read(routerProvider).go(PerformanceView.rankings.location);
      await tester.pumpAndSettle();
      expect(c.read(routerProvider).state.uri.toString(), '${Routes.myPerformance}?tab=rankings',
          reason: 'a tab of the existing Performance screen — no new route');
      expect(find.byKey(const Key('rankings.mine')), findsOneWidget);
      final me = c.read(rankingBoardProvider).value!.me!;
      final myRow = find.byKey(Key('rankings.row.${me.playerId}'));
      await tester.scrollUntilVisible(myRow, 200, scrollable: _list);
      expect(find.descendant(of: myRow, matching: find.text('You')), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Bowlers'), -200, scrollable: _list);
      await tester.tap(find.text('Bowlers'));
      await tester.pumpAndSettle();
      final board = c.read(rankingBoardProvider).value!;
      final topBowler = board.leaderboard(RankingCategory.bowlers).first;
      expect(find.byKey(Key('rankings.row.${topBowler.playerId}')), findsOneWidget);
      expect(myRow, findsNothing, reason: 'Aman is a Batsman');

      await tester.enterText(find.byType(TextField).first, 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('No players found'), findsOneWidget);
    });

    testWidgets('not yet ranked shows progress', (tester) async {
      final r = PlayerRankingMath.rank([_in('me', matches: 5, me: true)]).me;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: YourRankingCard(ranking: r))));
      expect(find.text('Not yet ranked'), findsOneWidget);
      expect(find.text('5/7 matches completed'), findsOneWidget);
    });

    testWidgets('no eligible players → empty state, never fake ranks', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [rankingInputsProvider.overrideWith((ref) async => [_in('rookie', matches: 2)])],
        child: const MaterialApp(home: Scaffold(body: RankingsView())),
      ));
      await tester.pumpAndSettle();
      expect(find.text('No ranked players yet'), findsOneWidget);
    });

    testWidgets('Player Hunt → Available Players shows a compact ranking badge', (tester) async {
      final c = await _pump(tester, role: UserRole.clubOwner);
      c.read(openPlayersCityProvider.notifier).select('Islamabad');
      c.read(openPlayersRoleProvider.notifier).select(HuntRole.batsman);
      c.read(routerProvider).go('${Routes.playerHunt}?tab=available');
      await tester.pumpAndSettle();
      final board = c.read(rankingBoardProvider).value!;
      final ali = board.all.firstWhere((r) => r.input.name == 'Ali Hassan');
      expect(find.text('${roleRankLabel(ali)} · Score ${ali.score}'), findsOneWidget);
    });

    testWidgets('the Player Stats sheet has a Ranking section', (tester) async {
      final c = await _pump(tester, role: UserRole.clubOwner);
      await c.read(rankingBoardProvider.future);
      final player = (await c.read(clubPlayerPoolProvider.future)).first;
      final ctx = tester.element(find.byType(Scaffold).last);
      unawaited(showPlayerStatsSheet(ctx, player: player, stats: c.read(squadPlayerStatsProvider((player.name, player.position, player.availability)))));
      await tester.pumpAndSettle();
      final section = find.byKey(const Key('rankings.section'));
      expect(section, findsOneWidget);
      final r = c.read(rankingBoardProvider).value!.byId(player.id)!;
      expect(find.descendant(of: section, matching: find.text('Overall Rank')), findsOneWidget);
      expect(find.descendant(of: section, matching: find.text('#${r.overallRank}')), findsWidgets);
      expect(find.descendant(of: section, matching: find.text('${r.completedMatches}')), findsOneWidget);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Rankings fit at ${width.toInt()} px', (tester) async {
        final c = await _pump(tester, role: UserRole.player, width: width);
        c.read(routerProvider).go(PerformanceView.rankings.location);
        await tester.pumpAndSettle();
        await tester.drag(_list, const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'rankings @ $width');
        c.read(openPlayersCityProvider.notifier).select('Islamabad');
        c.read(openPlayersRoleProvider.notifier).select(HuntRole.allRounder);
        await c.read(sessionProvider.notifier).createClub(name: 'Royal Rawalpindi Gymkhana Cricket Club', city: 'Islamabad', type: ClubType.professional);
        c.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner);
        c.read(routerProvider).go('${Routes.playerHunt}?tab=available');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'hunt badge @ $width');
        final player = (await c.read(clubPlayerPoolProvider.future)).first;
        unawaited(showPlayerStatsSheet(tester.element(find.byType(Scaffold).last),
            player: player, stats: c.read(squadPlayerStatsProvider((player.name, player.position, player.availability)))));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.byKey(const Key('rankings.section')), 200,
            scrollable: find.byType(Scrollable).last);
        expect(tester.takeException(), isNull, reason: 'ranking section @ $width');
      });
    }
  });
}
