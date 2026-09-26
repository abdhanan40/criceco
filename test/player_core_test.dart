import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/features/player/screens/availability_screen.dart';
import 'package:criceco/features/player/screens/performance_screens.dart';
import 'package:criceco/features/player/screens/performance_workspace.dart';
import 'package:criceco/features/player/screens/player_match_workspace.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:criceco/shared/widgets/ce_match_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wednesday 23 Sep 2026, 10:00 — seed "tomorrow" match is Thu 24 Sep 08:00.
final _now = DateTime(2026, 9, 23, 10);

Future<ProviderContainer> _pumpPlayer(WidgetTester tester, {double width = 375, String? fullName}) async {
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
  await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
  if (fullName != null) {
    await c.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(fullName: fullName));
  }
  final nav = c.read(roleControllerProvider.notifier).continueAs(UserRole.player);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await tester.pumpAndSettle();
}

/// The screen's main (vertical) list — workspace tab rows scroll sideways.
final _mainList = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

/// Scrolls the screen's main list until [f] is built and on screen, then taps it.
Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150, scrollable: _mainList);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

void main() {
  group('Player Dashboard', () {
    testWidgets('shows account, club, stats and next match from real state', (tester) async {
      await _pumpPlayer(tester);
      expect(find.text('Welcome back,'), findsOneWidget);
      expect(find.text('Aman Ali'), findsOneWidget);
      expect(find.text('Club KRC001 • Islamabad'), findsOneWidget);
      expect(find.text('Next: Tomorrow'), findsOneWidget);
      expect(find.text('8.2'), findsOneWidget);
      expect(find.text('Very Good'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('CONFIRMED'), 150, scrollable: find.byType(Scrollable).first);
      expect(find.text('Falcons CC'), findsOneWidget);
      expect(find.text('Playing: '), findsOneWidget);
      expect(find.text('BS CS XI'), findsOneWidget);
      // Countdown derived from startsAt − now: Thu 08:00 − Wed 10:00 = 22 h.
      expect(find.text('22h : 00m : 00s'), findsOneWidget);
    });

    testWidgets('availability pill toggles the shared availability record', (tester) async {
      final c = await _pumpPlayer(tester);
      expect(find.text('Available'), findsOneWidget);
      await tester.tap(find.text('Available'));
      await tester.pumpAndSettle();
      expect(c.read(playerAvailabilityProvider).status, PlayerAvailability.unavailable);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('quick actions, See All and bell navigate to real routes', (tester) async {
      final c = await _pumpPlayer(tester);
      for (final (label, route) in [
        ('My Matches', Routes.myMatches),
        ('Availability', Routes.availability),
        ('My Performance', Routes.myPerformance),
        ('Open Matches', Routes.openMatches),
      ]) {
        await _go(tester, c, Routes.playerHome);
        await _tap(tester, find.bySemanticsLabel(label).first);
        expect(_loc(c), route, reason: label);
      }
      await _go(tester, c, Routes.playerHome);
      await _tap(tester, find.text('See All'));
      expect(_loc(c), Routes.myPerformance);

      await _go(tester, c, Routes.playerHome);
      // The branch keeps its scroll offset; bring the hero back into view.
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      expect(find.byTooltip(RegExp(r'^Notifications, [1-9]')), findsOneWidget, reason: 'bell shows the unread badge');
      await tester.tap(find.byTooltip(RegExp('^Notifications')));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.notifications);
    });

    testWidgets('Quick Actions "View All" opens the drawer', (tester) async {
      await _pumpPlayer(tester);
      await tester.tap(find.text('View All'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
    });
  });

  group('My Matches, Match Details, Scorecard', () {
    testWidgets('tabs filter by status and live in the URL', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.myMatches);
      expect(find.text('Shalimar CC vs Falcons CC'), findsOneWidget);
      expect(find.text('Shalimar CC vs Titans CC'), findsNothing);

      await tester.tap(find.text('Past'));
      await tester.pumpAndSettle();
      expect(_loc(c), '${Routes.myMatches}?tab=past');
      expect(find.text('Shalimar CC vs Titans CC'), findsOneWidget);
      expect(find.text('Shalimar CC vs Warriors CC'), findsOneWidget);

      await tester.tap(find.text('Cancelled'));
      await tester.pumpAndSettle();
      expect(find.text('Reason: Rain'), findsOneWidget);
    });

    testWidgets('past card → details → scorecard → back to details', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, '${Routes.myMatches}?tab=past');
      await _tap(tester, find.text('Shalimar CC vs Titans CC'));
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      expect(find.text('Won by 24 runs'), findsOneWidget);
      expect(find.text('Your Availability'), findsNothing, reason: 'past matches have no availability action');

      await _tap(tester, _button('View Scorecard'));
      expect(_loc(c), PlayerMatchView.scorecard.location('pm_2'));
      expect(find.text('Shalimar CC won by 24 runs'), findsOneWidget);
      expect(find.text('Ali Raza\n64 runs'), findsOneWidget);
      expect(find.text('U. Tariq\n3 wkts'), findsOneWidget);
      expect(find.text('BATTER'), findsWidgets);

      // Tabs switch in place: back and forth never adds history entries.
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      expect(find.text('Won by 24 runs'), findsOneWidget);
      await tester.tap(find.text('Scorecard'));
      await tester.pumpAndSettle();
      expect(_loc(c), PlayerMatchView.scorecard.location('pm_2'));
      expect(find.text('Shalimar CC won by 24 runs'), findsOneWidget);

      // Android system Back from Scorecard → Details (same as the top-bar Back).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      await _tap(tester, _button('View Scorecard'));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), startsWith(Routes.myMatches));
    });

    testWidgets('upcoming details shows countdown and Update Availability', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.playerMatchDetails('pm_1'));
      expect(find.text('Match starts in'), findsOneWidget);
      expect(find.text('22h : 00m : 00s'), findsOneWidget);
      await _tap(tester, _button('Update Availability'));
      expect(_loc(c), Routes.availability);
    });

    testWidgets('cancelled details shows the reason; unknown ids show not found', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.playerMatchDetails('pm_4'));
      expect(find.textContaining('Reason: Rain'), findsOneWidget);
      await _go(tester, c, Routes.playerMatchDetails('nope'));
      expect(find.text('Match not found'), findsOneWidget);
      // No scorecard for an upcoming or cancelled match: Details only, no
      // tab row, even when the Scorecard is asked for.
      for (final id in ['pm_1', 'pm_4']) {
        await _go(tester, c, Routes.matchScorecard(id));
        expect(_loc(c), PlayerMatchView.scorecard.location(id), reason: 'legacy route → workspace');
        expect(find.text('Match Details'), findsOneWidget, reason: id);
        expect(find.text('Scorecard'), findsNothing, reason: id);
        expect(find.text('Details'), findsNothing, reason: id);
      }
      expect(find.textContaining('Reason: Rain'), findsOneWidget);
    });

    testWidgets('legacy scorecard route opens the Match workspace on the Scorecard tab', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.matchScorecard('pm_2'));
      expect(_loc(c), PlayerMatchView.scorecard.location('pm_2'));
      expect(find.text('Shalimar CC won by 24 runs'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget, reason: 'tab row shown');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'), reason: 'Back → Details, not a loop');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), startsWith(Routes.myMatches));
      expect(c.read(activeRoleProvider), UserRole.player);
    });
  });

  group('Performance and History', () {
    testWidgets('stat tabs switch tiles; View All opens History; filters work', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.myPerformance);
      expect(find.text('3W - 2L'), findsOneWidget);
      expect(find.text('Runs Scored'), findsOneWidget);
      await tester.tap(find.text('Bowling'));
      await tester.pumpAndSettle();
      expect(find.text('Wickets Taken'), findsOneWidget);
      expect(find.text('Runs Scored'), findsNothing);

      await _tap(tester, find.text('View All'));
      expect(_loc(c), PerformanceView.history.location);
      expect(find.byType(PerMatchChart), findsOneWidget);
      final log = c.read(performanceProvider).value!.matchLog;
      final losses = log.where((m) => m.result == MatchResult.lost).length;
      await tester.tap(find.text('Lost').last);
      await tester.pumpAndSettle();
      final pills = tester.widgetList<CeResultPill>(find.byType(CeResultPill)).toList();
      expect(pills, isNotEmpty);
      expect(pills.every((p) => !p.won), isTrue);
      expect(losses, greaterThan(0));
      expect(find.byType(MatchLogCard), findsWidgets);
      expect(c.read(historyFilterProvider), HistoryFilter.lost);

      // Switching tabs keeps the filter; the tab lives in the URL.
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myPerformance);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(_loc(c), PerformanceView.history.location);
      expect(c.read(historyFilterProvider), HistoryFilter.lost);
      expect(tester.widgetList<CeResultPill>(find.byType(CeResultPill)).every((p) => !p.won), isTrue);

      // Back from History → Overview; Back from Overview → Dashboard.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myPerformance);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome);
    });

    testWidgets('Overview and History agree: matches, runs and wickets come from the same season log',
        (tester) async {
      final c = await _pumpPlayer(tester);
      final p = c.read(performanceProvider).value!;
      final log = p.matchLog;
      expect(log.length, p.matches, reason: 'History total = Overview matches');
      expect(log.fold<int>(0, (s, m) => s + m.runs), p.runs);
      expect(log.fold<int>(0, (s, m) => s + m.wickets), p.wickets);
      expect([for (final m in log.take(p.recentForm.length)) (m.opponentAbbr, m.runs, m.result)],
          [for (final f in p.recentForm) (f.opponentAbbr, f.runs, f.result)],
          reason: 'Recent Form = the latest log entries');

      await _go(tester, c, Routes.myPerformance);
      expect(find.text('${p.matches}'), findsWidgets);
      await _go(tester, c, PerformanceView.history.location);
      expect(find.text('${log.length}'), findsWidgets);
      expect(find.text('TOTAL'), findsOneWidget);
    });

    testWidgets('legacy history route opens the Performance workspace on History', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.matchHistory);
      expect(_loc(c), PerformanceView.history.location);
      expect(find.byType(PerMatchChart), findsOneWidget);
      expect(find.byType(MatchLogCard), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myPerformance, reason: 'system Back → Overview');
      expect(find.text('Runs Scored'), findsOneWidget);
    });
  });

  group('Open Matches', () {
    testWidgets('role gate, ranked search, interest and listing', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.openMatches);
      expect(find.text('Select a role above to see open requests'), findsOneWidget);
      expect(find.text('Choose a role to get started'), findsOneWidget);

      await tester.tap(find.text('Bowler'));
      await tester.pumpAndSettle();
      expect(find.text('1 open request'), findsOneWidget);
      expect(find.text('Karachi Kings CC'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'isl');
      await tester.pumpAndSettle();
      expect(find.text('0 open requests'), findsOneWidget);
      expect(find.text('No results for "isl".'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'kar');
      await tester.pumpAndSettle();
      expect(find.text('1 open request'), findsOneWidget);

      await _tap(tester, _button("I'm Interested"));
      expect(c.read(huntInterestProvider), contains('hunt_1002'));
      expect(_button('Interest Sent'), findsOneWidget);
      expect(find.text("You're on the list — the club will be notified"), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(c.read(playerAvailabilityProvider).openToOffers, isTrue);
      final open = await c.read(huntRepositoryProvider).openPlayers();
      final me = open.where((p) => p.isMe).single;
      expect(me.city, 'Islamabad', reason: 'listed with the account city (fix)');
      expect(me.name, 'Aman Ali');
    });
  });

  group('Availability', () {
    test('resolveUntil: weekend is the coming Saturday; a week ahead on Saturday', () {
      final wed = DateTime(2026, 9, 23, 15);
      expect(resolveUntil(AvailabilityUntil.today, wed, null), DateTime(2026, 9, 23));
      expect(resolveUntil(AvailabilityUntil.tomorrow, wed, null), DateTime(2026, 9, 24));
      expect(resolveUntil(AvailabilityUntil.weekend, wed, null), DateTime(2026, 9, 26));
      expect(resolveUntil(AvailabilityUntil.weekend, DateTime(2026, 9, 26), null), DateTime(2026, 10, 3));
      expect(resolveUntil(AvailabilityUntil.custom, wed, null), isNull);
    });

    testWidgets('Reason/Until hidden for Available; Injured + Tomorrow commits', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.availability);
      expect(find.text('Unavailable Until'), findsNothing);

      await _tap(tester, find.bySemanticsLabel('Injured'));
      expect(find.text('Unavailable Until'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('Tomorrow'));
      await tester.enterText(find.byType(TextField).last, 'Hamstring');
      await _tap(tester, _button('Update Availability'));

      final r = c.read(playerAvailabilityProvider);
      expect(r.status, PlayerAvailability.injured);
      expect(r.untilDate, DateTime(2026, 9, 24));
      expect(r.notes, 'Hamstring');
      expect(r.since, _now);
      expect(find.text('Availability updated'), findsOneWidget);

      // Dashboard pill reflects the same record.
      await _go(tester, c, Routes.playerHome);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('Select Date requires a date; picking one from the calendar commits it', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.availability);
      await _tap(tester, find.bySemanticsLabel('Unavailable'));
      await _tap(tester, _button('Update Availability'));
      expect(find.text('Select a date'), findsWidgets);
      expect(c.read(playerAvailabilityProvider).status, PlayerAvailability.available, reason: 'nothing committed');

      // Past days are disabled; pick the 30th of the current month.
      final day = find.bySemanticsLabel('Wed, 30 Sep 2026');
      await _tap(tester, day);
      await _tap(tester, _button('Update Availability'));
      expect(c.read(playerAvailabilityProvider).untilDate, DateTime(2026, 9, 30));
    });

    testWidgets('Change Status scrolls to the status picker; info shows a tip', (tester) async {
      await _pumpPlayer(tester);
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
      await _go(tester, c, Routes.availability);
      await tester.tap(find.byTooltip('About availability'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Set your status so your coach can plan squads around you'), findsOneWidget);
      await _tap(tester, _button('Got it'));
      await tester.pumpAndSettle();
      await _tap(tester, _button('Change Status'));
      expect(tester.getTopLeft(find.text('Choose your Status')).dy, lessThan(300));
    });
  });

  group('Player Profile', () {
    testWidgets('shows account details and routes to performance, availability, edit', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.playerProfile);
      expect(find.text('0312 9020000'), findsOneWidget);
      expect(find.text('KRC001'), findsOneWidget);
      expect(find.text('AVAILABLE'), findsOneWidget);

      await _tap(tester, _button('View Full Performance'));
      expect(_loc(c), Routes.myPerformance);

      await _go(tester, c, Routes.playerProfile);
      await _tap(tester, _button('Update Availability'));
      expect(_loc(c), Routes.availability);

      // Edit is a mode of the same screen, not a new route.
      await _go(tester, c, Routes.playerProfile);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile);
      expect(find.byKey(const Key('edit.name')), findsOneWidget);
      // The top-bar Cancel (always on screen, whatever the body's scroll).
      await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit.name')), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('legacy edit route opens inline edit; Back leaves edit mode, not the screen', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.editProfile);
      expect(_loc(c), '${Routes.playerProfile}?edit=1');
      expect(tester.widget<EditableText>(find.descendant(
              of: find.byKey(const Key('edit.name')), matching: find.byType(EditableText))).controller.text,
          'Aman Ali', reason: 'prefilled from the account');
      await tester.enterText(find.byKey(const Key('edit.name')), 'Discarded Name');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile);
      expect(find.byKey(const Key('edit.name')), findsNothing);
      expect(c.read(currentAccountProvider)!.fullName, 'Aman Ali', reason: 'Back discards unsaved edits');
      expect(find.text('Aman Ali'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome);
    });

    testWidgets('Career stats come from the same source as Dashboard and My Performance', (tester) async {
      final c = await _pumpPlayer(tester);
      final perf = c.read(performanceProvider).value!;
      Future<void> expectCareer() async {
        await _go(tester, c, Routes.playerProfile);
        for (final v in ['${perf.matches}', '${perf.runs}', perf.battingAverage, perf.rating]) {
          expect(find.text(v, skipOffstage: false), findsWidgets, reason: 'Profile career $v');
        }
        await _go(tester, c, Routes.playerHome);
        expect(find.text(perf.rating), findsOneWidget, reason: 'Dashboard rating');
        expect(find.text('${perf.matches}'), findsWidgets, reason: 'Dashboard matches');
        await _go(tester, c, Routes.myPerformance);
        expect(find.text('${perf.runs}', skipOffstage: false), findsWidgets, reason: 'Performance runs');
      }

      await expectCareer();
      // Renaming the account never changes the stats.
      await c.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(fullName: 'Aman Ullah Khan'));
      await tester.pumpAndSettle();
      final after = c.read(performanceProvider).value!;
      expect((after.matches, after.runs, after.battingAverage, after.rating),
          (perf.matches, perf.runs, perf.battingAverage, perf.rating));
      await expectCareer();
    });
  });

  testWidgets('regression: CeStatusChip ellipsizes a long label in a narrow parent', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: SizedBox(width: 90, child: Row(children: [Expanded(child: CeStatusChip('Limited Availability'))]))),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('LIMITED AVAILABILITY'), findsOneWidget);
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 2 screens render without overflow at ${width.toInt()} px (long content)', (tester) async {
        final c = await _pumpPlayer(tester,
            width: width, fullName: 'Muhammad Abdul Rehman Chaudhry Al-Pakistani the Third');
        c.read(playerAvailabilityProvider.notifier).update(
              status: PlayerAvailability.limited,
              reason: AvailabilityReason.familyEmergency,
              untilDate: DateTime(2026, 12, 31),
            );
        c.read(openMatchesRoleProvider.notifier).select(HuntRole.batsman);
        for (final loc in [
          Routes.playerHome,
          Routes.availability,
          Routes.openMatches,
          Routes.myMatches,
          '${Routes.myMatches}?tab=past',
          '${Routes.myMatches}?tab=cancelled',
          Routes.playerMatchDetails('pm_1'),
          Routes.playerMatchDetails('pm_2'),
          Routes.playerMatchDetails('pm_4'),
          PlayerMatchView.scorecard.location('pm_2'),
          PlayerMatchView.scorecard.location('pm_3'),
          Routes.myPerformance,
          PerformanceView.history.location,
          Routes.playerProfile,
          '${Routes.playerProfile}?edit=1',
        ]) {
          await _go(tester, c, loc);
          // Scroll through the whole screen so every section lays out.
          final scrollable = _mainList;
          for (var i = 0; i < 12; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        // Availability with Reason / Until / calendar open.
        await _go(tester, c, Routes.availability);
        await _tap(tester, find.bySemanticsLabel('Select Date'));
        expect(tester.takeException(), isNull, reason: 'availability calendar @ $width');
      });
    }
  });
}
