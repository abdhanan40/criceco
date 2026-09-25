// Phase B — UX consolidation & interaction regressions: shared interaction
// widgets, in-place views (sheets, expandable cards, segmented metric),
// Back / route / role behaviour, and a 320–414 px sweep of the new surfaces.
import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/booking/booking_controller.dart';
import 'package:criceco/features/booking/payment_gateway.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/features/player/screens/performance_screens.dart';
import 'package:criceco/features/player/screens/performance_workspace.dart';
import 'package:criceco/features/tournaments/screens/hosted_screens.dart';
import 'package:criceco/features/tournaments/tournaments_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_expandable.dart';
import 'package:criceco/shared/widgets/ce_feedback.dart';
import 'package:criceco/shared/widgets/ce_segmented.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

/// Friday 25 Sep 2026, 09:00 (booking seed: the 27th is available).
final _now = DateTime(2026, 9, 25, 9);

Future<ProviderContainer> _pump(WidgetTester tester, {bool club = false, double width = 375}) async {
  tester.view.physicalSize = Size(width * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    clockProvider.overrideWithValue(Clock.fixed(_now)),
    nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    realPaymentGatewayProvider.overrideWithValue(InstantPaymentGateway()),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  if (club) await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  final nav = c.read(roleControllerProvider.notifier).continueAs(club ? UserRole.clubOwner : UserRole.player);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

/// Bounded settle: booking screens have endless animations (pulse, spinner).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await _settle(tester);
}

final _mainList = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 150, scrollable: _mainList);
  await tester.ensureVisible(f);
  await _settle(tester);
  await tester.tap(f);
  await _settle(tester);
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

/// Reserve m_3 (Islamabad United XI) at Pindi, Sun 27 Sep, 8–10 am.
Future<void> _reserveM3(ProviderContainer c) async {
  await c.read(clubMatchesProvider.future);
  final b = c.read(bookingsProvider.notifier);
  b.start(c.read(clubMatchProvider('m_3'))!);
  b.updateDraft(
    'm_3',
    (d) => d.copyWith(groundId: 'g_pindi', date: DateTime(2026, 9, 27), slot: const TimeSlot(startHour: 8, endHour: 10)),
  );
  await b.reserve('m_3');
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('Shared interaction widgets', () {
    testWidgets('CeErrorState: plain message and Retry (never a raw error)', (tester) async {
      var retries = 0;
      await tester.pumpWidget(_host(CeErrorState(onRetry: () => retries++)));
      expect(find.text("Couldn't load this"), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
    });

    testWidgets('showCeConfirmSheet: Cancel → false, confirm → true', (tester) async {
      bool? result;
      await tester.pumpWidget(_host(Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showCeConfirmSheet(context,
              title: 'Remove?', body: 'Gone for good.', confirmLabel: 'Remove', destructive: true),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Remove?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CeButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('CeExpandableCard: collapsed by default, expands and collapses, reports expanded', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const CeExpandableCard(title: 'Details', summary: 'Rs 100', child: Text('inside'))));
      expect(find.text('inside'), findsNothing);
      expect(find.text('Rs 100'), findsOneWidget, reason: 'summary visible while collapsed');
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsOneWidget);
      expect(tester.getSemantics(find.text('Details')), isSemantics(isExpanded: true, isButton: true));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsNothing);
      handle.dispose();
    });

    testWidgets('CeSegmented: selecting the current segment does nothing; another one reports it', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_host(CeSegmented<String>(
        values: const ['A', 'B'],
        selected: 'A',
        labelOf: (s) => s,
        onSelected: picked.add,
      )));
      await tester.tap(find.text('A'));
      await tester.tap(find.text('B'));
      expect(picked, ['B']);
    });
  });

  group('Player', () {
    testWidgets('History chart switches Runs ↔ Wickets in place; the choice survives tab switches', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, PerformanceView.history.location);
      await tester.pumpAndSettle();
      expect(find.text('Runs per match'), findsOneWidget);
      await tester.tap(find.text('Wickets').first);
      await tester.pumpAndSettle();
      expect(find.text('Wickets per match'), findsOneWidget);
      expect(c.read(trendMetricProvider), TrendMetric.wickets);
      expect(_loc(c), PerformanceView.history.location, reason: 'no navigation');
      final log = c.read(performanceProvider).value!.matchLog;
      final total = log.fold<int>(0, (s, m) => s + m.wickets);
      expect(find.textContaining('$total wickets'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Wickets per match for the last ${log.length} matches')), findsOneWidget);

      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Wickets per match'), findsOneWidget, reason: 'session choice kept');
      expect(find.byType(PerMatchChart), findsOneWidget);
    });

    testWidgets('Dashboard stat cards open their lists; Matches Played → History tab', (tester) async {
      final c = await _pump(tester);
      await tester.tap(find.text('UPCOMING MATCHES'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myMatches);
      await _go(tester, c, Routes.playerHome);
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      await tester.tap(find.text('MATCHES PLAYED'));
      await tester.pumpAndSettle();
      expect(_loc(c), PerformanceView.history.location);
      expect(c.read(activeRoleProvider), UserRole.player);
    });

    testWidgets('Notifications are grouped Today / Earlier, newest first', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.notifications);
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Earlier'), findsOneWidget);
      final today = tester.getTopLeft(find.text('Today')).dy;
      final earlier = tester.getTopLeft(find.text('Earlier')).dy;
      expect(today, lessThan(earlier));
      expect(tester.getTopLeft(find.bySemanticsLabel(RegExp('Match request from'))).dy, lessThan(earlier),
          reason: '2 h old → Today');
    });
  });

  group('Club Owner match flow', () {
    testWidgets('Waiting card: next action + card tap → Pay; booking details expand in place', (tester) async {
      final c = await _pump(tester, club: true);
      await _reserveM3(c);
      await _go(tester, c, Routes.matchManagement(MatchTab.waiting));
      expect(find.text('Pay Your Share'), findsOneWidget);
      expect(find.textContaining('left on this reservation'), findsOneWidget);
      expect(find.text('You · due'), findsOneWidget, reason: 'unpaid share says so in words');
      await _tap(tester, find.text('Pay Your Share'));
      expect(_loc(c), Routes.payment('m_3'));
      expect(find.textContaining('Step 6 of 7', findRichText: true), findsOneWidget, reason: 'visible step label');

      expect(find.text('Opponent'), findsNothing, reason: 'details collapsed by default');
      await _tap(tester, find.text('Booking details'));
      expect(find.text('Opponent'), findsOneWidget);
      expect(find.text('Time Slot'), findsOneWidget);
      expect(_loc(c), Routes.payment('m_3'), reason: 'no extra screen');
    });

    testWidgets('Scheduled card shows line-up status in words and opens the line-up', (tester) async {
      final c = await _pump(tester, club: true);
      await _go(tester, c, Routes.matchManagement(MatchTab.scheduled));
      expect(find.text('Line-up set'), findsOneWidget);
      await _tap(tester, find.text('Line-up set'));
      expect(_loc(c), Routes.matchLineup('m_2'));
    });

    testWidgets('Line-up builder: pinned bar with live counts and role balance', (tester) async {
      final c = await _pump(tester, club: true);
      await _go(tester, c, Routes.matchLineupBuild('m_2'));
      final bar = find.textContaining('XI ', findRichText: true);
      expect(bar, findsWidgets);
      expect(_button('Confirm Team'), findsOneWidget);
      expect(tester.getRect(_button('Confirm Team')).bottom, lessThanOrEqualTo(812), reason: 'pinned, in reach');
      await _tap(tester, find.bySemanticsLabel(RegExp('^Ali Raza, ')).first);
      expect(find.textContaining('XI 1/11 · Subs 0/4', findRichText: true), findsOneWidget);
      expect(find.textContaining('1 Batsman', findRichText: true), findsOneWidget);
    });

    testWidgets('Points table: rank column and standings', (tester) async {
      final c = await _pump(tester, club: true);
      await c.read(tournamentsProvider.future);
      await c.read(tournamentRegistrationsProvider.future);
      final t = await c.read(tournamentsProvider.notifier).create(TournamentInput(
            name: 'Shalimar Cup',
            city: 'Islamabad',
            ground: 'Pindi Cricket Ground',
            format: MatchFormat.t20,
            type: TournamentType.league,
            startDate: _now.add(const Duration(days: 20)),
            endDate: _now.add(const Duration(days: 25)),
            registrationDeadline: _now.add(const Duration(days: 15)),
            maxTeams: 8,
          ));
      for (final r in c.read(pendingRequestsProvider(t.id)).take(2)) {
        await c.read(tournamentRegistrationsProvider.notifier).decide(r.id, approve: true);
      }
      await _go(tester, c, TournamentTab.points.location(t.id));
      expect(find.text('#'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
      expect(find.text('2'), findsWidgets);
    });
  });

  group('Responsive (Phase B surfaces)', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('new sheets, cards, tabs and bars fit at ${width.toInt()} px', (tester) async {
        final c = await _pump(tester, club: true, width: width);
        await _reserveM3(c);
        Future<void> sweep(String loc) async {
          await _go(tester, c, loc);
          for (var i = 0; i < 10; i++) {
            await tester.drag(_mainList, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }

        for (final loc in [
          Routes.clubHome,
          Routes.teams,
          Routes.teamSquad('team_cs'),
          Routes.addTeamPlayers('team_cs'),
          Routes.members,
          Routes.myClub,
          Routes.matchManagement(MatchTab.waiting),
          Routes.matchManagement(MatchTab.scheduled),
          Routes.matchLineupBuild('m_2'),
          Routes.myChallenges,
          Routes.notifications,
        ]) {
          await sweep(loc);
        }

        // Payment with the booking details expanded.
        await _go(tester, c, Routes.payment('m_3'));
        await _tap(tester, find.text('Booking details'));
        expect(tester.takeException(), isNull, reason: 'payment details @ $width');

        // Create Team sheet with validation errors.
        await _go(tester, c, Routes.teams);
        await _tap(tester, find.bySemanticsLabel(RegExp('^New Team')));
        await tester.tap(find.text('Custom'));
        await _settle(tester);
        await _tap(tester, _button('Create Team'));
        expect(tester.takeException(), isNull, reason: 'create team sheet @ $width');
        await tester.tapAt(const Offset(10, 10));
        await _settle(tester);

        // A confirm sheet (Decline a join request).
        await _go(tester, c, Routes.joinRequests);
        await tester.tap(find.byTooltip(RegExp('^Decline')).first);
        await _settle(tester);
        expect(find.textContaining('Decline '), findsWidgets);
        expect(tester.takeException(), isNull, reason: 'confirm sheet @ $width');
        await tester.tap(find.text('Cancel'));
        await _settle(tester);

        // Player side: History chart on Wickets, Availability explainer sheet.
        c.read(roleControllerProvider.notifier).switchTo(UserRole.player);
        c.read(trendMetricProvider.notifier).select(TrendMetric.wickets);
        await sweep(PerformanceView.history.location);
        await sweep(Routes.playerHome);
        await _go(tester, c, Routes.availability);
        await tester.tap(find.byTooltip('About availability'));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: 'availability sheet @ $width');
      });
    }
  });
}
