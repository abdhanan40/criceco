import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/challenges/challenges_controller.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 24, 11);

Future<ProviderContainer> _owner({TestClock? clock}) async {
  final c = await makeContainer(clock: clock ?? TestClock(_now));
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  await c.read(challengesProvider.future);
  await c.read(clubMatchesProvider.future);
  return c;
}

Future<ProviderContainer> _pumpOwner(WidgetTester tester, {double width = 375, bool demo = true}) async {
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
  if (!demo) c.read(demoModeProvider.notifier).set(false);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  final nav = c.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner);
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
    await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Lets a toast clear so it can't cover the next tap target.
Future<void> _clearToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

/// Scrolls to the top, then down until [text] is visible (lazy lists).
Future<void> _expectVisible(WidgetTester tester, String text) async {
  await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text(text), 120, scrollable: find.byType(Scrollable).first);
  expect(find.text(text), findsOneWidget, reason: text);
}

void main() {
  group('Challenge rules', () {
    test('Demo ON: a sent challenge is accepted instantly and creates ONE pending match', () async {
      final c = await _owner();
      expect(c.read(demoModeProvider), isTrue);
      final before = c.read(clubMatchesProvider).value!.length;

      final ch = await c.read(challengesProvider.notifier).send('club_kk');
      expect(ch.status, ChallengeStatus.accepted);
      expect(ch.direction, ChallengeDirection.sent);
      expect(ch.matchId, isNotNull);
      final matches = c.read(clubMatchesProvider).value!;
      expect(matches.length, before + 1);
      final m = matches.singleWhere((x) => x.id == ch.matchId);
      expect(m.status, MatchStatus.pending);
      expect(m.opponentClubId, 'club_kk');
      expect(m.format, MatchFormat.t20, reason: 'KK prefers T20 / ODI');

      // Accepting again is a no-op: still exactly one match for this challenge.
      await c.read(challengesProvider.notifier).accept(ch.id);
      expect(c.read(clubMatchesProvider).value!.length, before + 1);
    });

    test('Demo OFF: a sent challenge stays pending (Sent), then expires after the window', () async {
      final clock = TestClock(_now);
      final c = await _owner(clock: clock);
      c.read(demoModeProvider.notifier).set(false);
      final before = c.read(clubMatchesProvider).value!.length;

      final ch = await c.read(challengesProvider.notifier).send('club_iu', format: MatchFormat.odi);
      expect(ch.status, ChallengeStatus.pending);
      expect(ch.expiresAt, _now.add(Challenge.responseWindow));
      expect(c.read(myChallengeSectionsProvider).sent.map((x) => x.id), [ch.id]);
      expect(c.read(pendingSentClubIdsProvider), contains('club_iu'));
      expect(c.read(clubMatchesProvider).value!.length, before, reason: 'no match until accepted');

      clock.advance(const Duration(days: 8));
      expect(ch.statusAt(clock.now), ChallengeStatus.expired);
      final result = await c.read(challengesProvider.notifier).accept(ch.id);
      expect(result!.status, ChallengeStatus.expired, reason: 'an expired challenge cannot be accepted');
      expect(c.read(clubMatchesProvider).value!.length, before);
    });

    test('Received: Accept creates one match; Decline creates none; overdue ones load as expired', () async {
      final clock = TestClock(_now);
      final c = await _owner(clock: clock);
      final ctrl = c.read(challengesProvider.notifier);
      final before = c.read(clubMatchesProvider).value!.length;

      final declined = await ctrl.decline('ch_gc');
      expect(declined!.status, ChallengeStatus.declined);
      expect(declined.respondedAt, _now);
      expect(c.read(clubMatchesProvider).value!.length, before);

      final accepted = await ctrl.accept('ch_db');
      expect(accepted!.status, ChallengeStatus.accepted);
      await ctrl.accept('ch_db');
      expect(c.read(clubMatchesProvider).value!.length, before + 1);
      final m = c.read(clubMatchesProvider).value!.last;
      expect((m.opponentClubId, m.format, m.status), ('club_db', MatchFormat.t20, MatchStatus.pending));

      final sections = c.read(myChallengeSectionsProvider);
      expect(sections.awaitingDecision, isEmpty);
      expect(sections.resolved.map((x) => x.id), containsAll(['ch_db', 'ch_gc', 'ch_gt']));

      // A received challenge whose proposed date has passed loads as expired.
      final c2 = await _owner(clock: clock);
      clock.advance(const Duration(days: 30));
      c2.invalidate(challengesProvider);
      final list = await c2.read(challengesProvider.future);
      expect(list.firstWhere((x) => x.id == 'ch_gc').status, ChallengeStatus.expired);
    });
  });

  group('Challenges screens (Demo ON)', () {
    testWidgets('hub Challenge → Challenge Accepted; Back hands off to Match Management → Waiting', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.challenges);
      expect(find.text('Karachi Kings CC'), findsOneWidget);
      expect(find.text('Islamabad United XI'), findsOneWidget);
      expect(find.textContaining('Create Availability Slot', findRichText: true), findsOneWidget);

      await _tap(tester, _button('Challenge').first);
      final ch = c.read(challengesProvider).value!.last;
      expect(_loc(c), Routes.challengeAccepted(ch.id));
      expect(find.text('Challenge Accepted!'), findsOneWidget);
      expect(find.text('Challenge sent to Karachi Kings CC!'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing, reason: 'terminal screen');

      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(_loc(c), Routes.matchManagement(MatchTab.waiting));
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
    });

    testWidgets('My Challenges: Decline → Resolved; Accept → Waiting with one new match', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.myChallenges);
      expect(find.text('Awaiting your Decision'), findsOneWidget);
      expect(find.text('DHA Bulls CC'), findsOneWidget);
      expect(find.text('NEW'), findsNWidgets(2));
      expect(find.text('ACCEPTED'), findsOneWidget); // Gulberg Tigers, resolved

      expect(find.text('2'), findsWidgets, reason: 'My Challenges tab counts decisions awaiting');
      await _tap(tester, _button('Decline').last); // GOR Challengers
      expect(find.text('Decline this challenge?'), findsOneWidget, reason: 'confirms first');
      await _tap(tester, _button('Decline Challenge'));
      expect(find.text('Challenge declined'), findsOneWidget);
      expect(find.text('DECLINED'), findsOneWidget);
      expect(find.text('NEW'), findsOneWidget);

      await _clearToast(tester);
      final before = c.read(clubMatchesProvider).value!.length;
      await _tap(tester, _button('Accept Challenge'));
      expect(find.text('Challenge accepted!'), findsOneWidget);
      expect(_loc(c), Routes.matchManagement(MatchTab.waiting));
      expect(c.read(clubMatchesProvider).value!.length, before + 1);
    });

    testWidgets('Find Match: derived count; Send Match Request uses the listing format', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.findMatch);
      expect(find.text('Teams Looking for Opponents · 2 Teams'), findsOneWidget);
      expect(find.text('Rawalpindi Rams'), findsOneWidget, reason: 'seed name fixed (was "Riders")');
      await _tap(tester, _button('Send Match Request').last);
      final ch = c.read(challengesProvider).value!.last;
      expect(ch.opponentClubId, 'club_rr');
      expect(ch.format, MatchFormat.t20);
      expect(find.text('Challenge Accepted!'), findsOneWidget);
    });

    testWidgets('tabs switch sections; Club Profile → Challenge This Club', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.challenges);
      await _tap(tester, find.text('My Challenges'));
      expect(_loc(c), Routes.myChallenges);
      await _tap(tester, find.text('Find Match'));
      expect(_loc(c), Routes.findMatch);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.challenges);

      await _tap(tester, find.text('Faisalabad Wolves'));
      expect(_loc(c), Routes.clubProfile('club_fw'));
      await tester.scrollUntilVisible(find.textContaining('Key Players'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Club Captain', skipOffstage: false), findsOneWidget);
      await _tap(tester, _button('Challenge This Club'));
      expect(find.text('Challenge Accepted!'), findsOneWidget);
      expect(find.text('Faisalabad Wolves'), findsWidgets);
    });

    testWidgets('Create Availability Slot: inline validation, post, list on Find Match, remove', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.findMatch);
      await _tap(tester, find.textContaining('Create Availability Slot', findRichText: true));
      expect(_loc(c), Routes.createAvailabilitySlot);

      await _tap(tester, _button('Post Availability Slot'));
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      for (final e in ['Please select a format', 'Please select a city', 'Please pick a date', 'Please pick a time slot']) {
        await tester.scrollUntilVisible(find.text(e), 120, scrollable: find.byType(Scrollable).first);
        expect(find.text(e), findsOneWidget, reason: e);
      }
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();

      await _tap(tester, find.text('Custom Overs'));
      await _tap(tester, _button('Post Availability Slot'));
      await _expectVisible(tester, 'Please enter the number of overs');
      await tester.enterText(find.byKey(const Key('slot.overs')), '15');
      await _tap(tester, find.byKey(const Key('slot.city')));
      await _tap(tester, find.text('Lahore').last);
      await _tap(tester, find.bySemanticsLabel('Date, not set'));
      await _tap(tester, find.bySemanticsLabel('Wed, 30 Sep 2026'));
      await _tap(tester, find.text('4pm – 6pm'));
      await _tap(tester, _button('Post Availability Slot'));

      expect(find.text('Availability slot posted!'), findsOneWidget);
      expect(_loc(c), Routes.findMatch);
      final slot = c.read(availabilitySlotsProvider).value!.single;
      expect((slot.format, slot.customOvers, slot.city, slot.date), (MatchFormat.custom, 15, 'Lahore', DateTime(2026, 9, 30)));
      expect(find.text('Your Open Slot'), findsOneWidget);
      expect(find.text('Custom · 15 overs'), findsOneWidget);

      await _clearToast(tester);
      await _tap(tester, find.text('Remove'));
      await _tap(tester, find.widgetWithText(CeButton, 'Remove Slot'));
      expect(find.text('Availability slot removed'), findsOneWidget);
      expect(find.text('Your Open Slot'), findsNothing);
    });
  });

  group('Challenges screens (Demo OFF)', () {
    testWidgets('Challenge stays pending: Sent section, "Challenge Sent" button, status screen', (tester) async {
      final c = await _pumpOwner(tester, demo: false);
      await _go(tester, c, Routes.challenges);
      await _tap(tester, _button('Challenge').first);
      expect(find.text('Challenge sent to Karachi Kings CC — awaiting their reply'), findsOneWidget);
      expect(_loc(c), Routes.myChallenges);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('AWAITING REPLY'), findsOneWidget);

      await _go(tester, c, Routes.challenges);
      expect(_button('Challenge Sent'), findsOneWidget, reason: 'no duplicate challenge while pending');

      final ch = c.read(challengesProvider).value!.last;
      await _go(tester, c, Routes.challengeAccepted(ch.id));
      expect(find.text('Challenge Sent'), findsWidgets);
      expect(find.text('Challenge Accepted!'), findsNothing);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 5 screens render without overflow at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        final ctrl = c.read(challengesProvider.notifier);
        final accepted = await ctrl.send('club_kk');
        c.read(demoModeProvider.notifier).set(false);
        final pending = await ctrl.send('club_iu');
        await ctrl.decline('ch_gc');
        await c.read(availabilitySlotsProvider.notifier).post(AvailabilitySlot(
              id: 'slot_x',
              format: MatchFormat.custom,
              customOvers: 25,
              city: 'Rahim Yar Khan',
              groundId: 'g_national',
              date: DateTime(2026, 10, 3),
              slot: TimeSlot.standard.last,
              notes: 'Looking for a competitive weekend friendly with a well-drilled side from the region.',
            ));
        for (final loc in [
          Routes.challenges,
          Routes.myChallenges,
          Routes.findMatch,
          Routes.createAvailabilitySlot,
          Routes.clubProfile('club_kk'),
          Routes.clubProfile('club_db'),
          Routes.challengeAccepted(accepted.id),
          Routes.challengeAccepted(pending.id),
          Routes.challengeAccepted('ch_gc'),
        ]) {
          await _go(tester, c, loc);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 10; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        // Validation errors + open calendar on the slot form.
        await _go(tester, c, Routes.createAvailabilitySlot);
        await _tap(tester, find.text('Custom Overs'));
        await _tap(tester, _button('Post Availability Slot'));
        await _tap(tester, find.bySemanticsLabel('Date, not set'));
        expect(tester.takeException(), isNull, reason: 'slot form errors @ $width');
      });
    }
  });
}
