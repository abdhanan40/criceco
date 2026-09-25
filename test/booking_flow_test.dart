import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/demo/demo_payment_tools.dart';
import 'package:criceco/features/booking/booking_controller.dart';
import 'package:criceco/features/booking/payment_gateway.dart';
import 'package:criceco/features/challenges/challenges_controller.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

/// Friday 25 Sep 2026, 09:00. Seed availability is day % 5: the 25th is
/// full, the 26th partial, the 27th available.
final _now = DateTime(2026, 9, 25, 9);
final _sunday = DateTime(2026, 9, 27);
const _eightToTen = TimeSlot(startHour: 8, endHour: 10);

class _FailingGateway implements PaymentGateway {
  @override
  Future<bool> charge({required PaymentMethodType method, required int amount}) async => false;
}

Future<ProviderContainer> _owner({List<dynamic> overrides = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final sp = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(sp),
    clockProvider.overrideWithValue(Clock.fixed(_now)),
    realPaymentGatewayProvider.overrideWithValue(InstantPaymentGateway()),
    ...overrides.cast(),
  ]);
  addTearDown(c.dispose);
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  await c.read(clubMatchesProvider.future);
  return c;
}

/// Draft + reserve m_3 (Islamabad United XI) at Pindi, Sun 27 Sep, 8–10am.
Future<void> _reserveM3(ProviderContainer c) async {
  final b = c.read(bookingsProvider.notifier);
  b.start(c.read(clubMatchProvider('m_3'))!);
  b.updateDraft('m_3', (d) => d.copyWith(groundId: 'g_pindi', date: _sunday, slot: _eightToTen));
  await b.reserve('m_3');
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
    realPaymentGatewayProvider.overrideWithValue(InstantPaymentGateway()),
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

/// Bounded settle: Waiting for Opponent has endless animations (pulse ring,
/// progress spinner), so pumpAndSettle would never return.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(f);
  await _settle(tester);
  await tester.tap(f);
  await _settle(tester);
}

/// Waits out the prototype's 900 ms "success → continue" pauses and toasts.
Future<void> _wait(WidgetTester tester, [int ms = 1000]) async {
  await tester.pump(Duration(milliseconds: ms));
  await _settle(tester);
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

/// Taps and pumps only briefly, to catch short-lived states (the 900 ms
/// "Payment Successful!" before the redirect).
Future<void> _tapThen(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(f);
  await _settle(tester);
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Simulates one tick of the app-wide expiry watcher.
Future<void> _tick(ProviderContainer c) async {
  final outcomes = await c.read(bookingsProvider.notifier).expireDue(_now);
  if (outcomes.isNotEmpty) c.read(expiryEventsProvider.notifier).add(outcomes);
}

void main() {
  group('Booking rules', () {
    test('pay(): failure keeps the hold and records a failed payment; retry succeeds', () async {
      final c = await _owner(overrides: [paymentGatewayProvider.overrideWithValue(_FailingGateway())]);
      await _reserveM3(c);
      expect(await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.easypaisa), PaymentOutcome.failed);
      final b = c.read(bookingProvider('m_3'))!;
      expect(b.myPayment!.status, PaymentStatus.failed);
      expect(b.status, BookingStatus.held);
      expect(b.hold!.status, HoldStatus.active);
      expect(c.read(walletRepositoryProvider).ledger, isEmpty, reason: 'nothing charged');
    });

    test('pay(): insufficient wallet funds and an expired hold are reported distinctly', () async {
      final c = await _owner();
      await _reserveM3(c);
      final ctrl = c.read(bookingsProvider.notifier);
      expect(await ctrl.pay('m_3', PaymentMethodType.wallet), PaymentOutcome.insufficientFunds);
      ctrl.forceExpire('m_3');
      await ctrl.expireDue(_now);
      expect(await ctrl.pay('m_3', PaymentMethodType.card), PaymentOutcome.holdExpired);
      expect(c.read(clubMatchProvider('m_3'))!.status, MatchStatus.pending, reason: 'unpaid expiry → pending (P13)');
    });

    test('Demo: an armed failure fails exactly one charge, then clears', () async {
      final c = await _owner();
      await _reserveM3(c);
      c.read(demoFailNextPaymentProvider.notifier).select(true);
      expect(await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.jazzcash), PaymentOutcome.failed);
      expect(c.read(demoFailNextPaymentProvider), isFalse);
      expect(await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.jazzcash), PaymentOutcome.success);
    });

    test('Demo OFF: the failure toggle and opponent payer do nothing', () async {
      final c = await _owner();
      c.read(demoModeProvider.notifier).set(false);
      await _reserveM3(c);
      c.read(demoFailNextPaymentProvider.notifier).select(true);
      expect(await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.card), PaymentOutcome.success);
      expect(await c.read(demoOpponentPayerProvider).pay('m_3'), isFalse);
      expect(c.read(bookingProvider('m_3'))!.status, BookingStatus.awaitingOpponent);
    });

    test('opponent payment confirms once — repeats never create another confirmed match', () async {
      final c = await _owner();
      await _reserveM3(c);
      await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.card);
      expect(await c.read(demoOpponentPayerProvider).pay('m_3'), isTrue);
      await c.read(bookingsProvider.notifier).recordOpponentPayment('m_3');
      final confirmed = c.read(clubMatchesProvider).value!.where((m) => m.status == MatchStatus.confirmed).toList();
      expect(confirmed.map((m) => m.id), unorderedEquals(['m_2', 'm_3']));
      expect(c.read(bookingProvider('m_3'))!.settlement!.commission, 620); // 5 % of Rs 12,400
    });

    test('an accepted challenge hands off ONE pending match to Waiting', () async {
      final c = await _owner();
      await c.read(challengesProvider.future);
      final before = c.read(clubMatchesProvider).value!.length;
      await c.read(challengesProvider.notifier).accept('ch_db');
      await c.read(challengesProvider.notifier).accept('ch_db');
      final waiting = c.read(clubMatchesProvider).value!.where((m) => MatchTab.waiting.includes(m.status));
      expect(c.read(clubMatchesProvider).value!.length, before + 1);
      expect(waiting.map((m) => m.opponentClubId), contains('club_db'));
    });
  });

  group('Match Management', () {
    testWidgets('tabs with counts: Waiting / Scheduled / History from real match state', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.matchManagement());
      expect(find.text('Waiting (1)'), findsOneWidget);
      expect(find.text('Scheduled (1)'), findsOneWidget);
      expect(find.text('History (1)'), findsOneWidget);
      expect(find.text('vs Islamabad United XI'), findsOneWidget);
      expect(find.text('SETUP NEEDED'), findsOneWidget);

      await _tap(tester, find.text('Scheduled (1)'));
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled));
      expect(find.text('Shalimar Cricket Club vs Karachi Kings CC'), findsOneWidget);
      expect(find.text('CONFIRMED'), findsOneWidget);

      await _tap(tester, find.text('History (1)'));
      expect(find.text('vs Gulberg Tigers'), findsOneWidget);
      expect(find.text('Won by 18 runs'), findsOneWidget);
    });

    testWidgets('full booking (Demo ON): setup → ground → date → summary → pay → opponent → confirmed', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.matchManagement());
      await _tap(tester, find.text('vs Islamabad United XI'));
      expect(_loc(c), Routes.matchSetup('m_3'));
      expect(find.text('Islamabad'), findsOneWidget, reason: 'city prefilled from the challenge');
      await _tap(tester, _button('Continue'));

      expect(_loc(c), Routes.bookGround('m_3'));
      await _tap(tester, _button('Continue'));
      expect(find.text('Please select a ground'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('Pindi Cricket Ground, Islamabad'));
      await _tap(tester, _button('Continue'));

      expect(_loc(c), Routes.groundDetails('m_3', 'g_pindi'));
      expect(find.text('Ground Specifications'), findsOneWidget);
      await _tap(tester, _button('Continue · Pick a Date'));

      expect(_loc(c), Routes.selectDate('m_3', 'g_pindi'));
      expect(find.text('September 2026'), findsOneWidget, reason: 'month derived from the clock');
      await _tap(tester, find.bySemanticsLabel('Fri, 25 Sep 2026'));
      expect(find.text('This ground is fully booked that day'), findsOneWidget);
      await _wait(tester, 2000);
      await _tap(tester, find.bySemanticsLabel('Sun, 27 Sep 2026'));
      expect(find.bySemanticsLabel('6am – 8am, Booked'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('8am – 10am, Open'));
      await _tap(tester, _button('Continue · Booking Summary'));

      expect(_loc(c), Routes.bookingSummary('m_3', 'g_pindi'));
      expect(find.text('Sun, 27 Sep 2026'), findsOneWidget);
      expect(find.text('8am – 10am'), findsOneWidget);
      expect(find.text('Rs 12,400'), findsOneWidget);
      await _tap(tester, _button('Reserve Ground for 30 Minutes'));

      expect(_loc(c), Routes.payment('m_3'));
      expect(find.text('30:00'), findsOneWidget, reason: 'expiresAt − now');
      expect(find.textContaining('Insufficient'), findsOneWidget, reason: 'wallet Rs 5,000 < share Rs 6,200');
      await _tapThen(tester, _button('Pay Rs 6,200 via EasyPaisa'));
      expect(find.text('Payment Successful!'), findsOneWidget);
      await _wait(tester);

      expect(_loc(c), Routes.waitingForOpponent('m_3'));
      expect(find.text('Waiting for Islamabad United XI to pay'), findsOneWidget);
      await _tap(tester, find.text('Opponent Pays Now'));
      await _wait(tester);

      expect(_loc(c), Routes.bookingConfirmed('m_3'));
      expect(find.text('Booking Confirmed!'), findsOneWidget);
      expect(find.text('Rs 11,780'), findsOneWidget, reason: '12,400 − 5 % commission');

      // Terminal: system Back → Scheduled, and never back into payment.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _settle(tester);
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled));
      expect(find.text('Scheduled (2)'), findsOneWidget);
    });

    testWidgets('conflict: a slot held by another club shows Reserved; a race at Reserve sends you back', (tester) async {
      final c = await _pumpOwner(tester);
      // Another club holds Pindi, Sun 27 Sep, 2–4pm.
      c.read(reservationRepositoryProvider).reserve(
            matchId: 'other_club_match',
            groundId: 'g_pindi',
            slotStart: DateTime(2026, 9, 27, 14),
            slotEnd: DateTime(2026, 9, 27, 16),
            now: _now,
          );
      final b = c.read(bookingsProvider.notifier);
      b.start(c.read(clubMatchProvider('m_3'))!);
      b.updateDraft('m_3', (d) => d.copyWith(groundId: 'g_pindi', date: _sunday));
      await _go(tester, c, Routes.selectDate('m_3', 'g_pindi'));
      expect(find.bySemanticsLabel('2pm – 4pm, Reserved'), findsOneWidget);

      // Race: the slot was picked before the other club's hold landed.
      c.read(reservationRepositoryProvider).reserve(
            matchId: 'other_club_match_2',
            groundId: 'g_pindi',
            slotStart: DateTime(2026, 9, 27, 18),
            slotEnd: DateTime(2026, 9, 27, 20),
            now: _now,
          );
      b.updateDraft('m_3', (d) => d.copyWith(slot: const TimeSlot(startHour: 18, endHour: 20)));
      await _go(tester, c, Routes.bookingSummary('m_3', 'g_pindi'));
      await _tap(tester, _button('Reserve Ground for 30 Minutes'));
      expect(find.text('That slot was just taken by another club — pick another time'), findsOneWidget);
      expect(_loc(c), Routes.selectDate('m_3', 'g_pindi'));
      expect(c.read(bookingProvider('m_3'))!.draft.slot, isNull, reason: 'slot cleared');
      expect(c.read(clubMatchProvider('m_3'))!.status, MatchStatus.pending);
    });

    testWidgets('payment failure state (Demo) → Try Again succeeds', (tester) async {
      final c = await _pumpOwner(tester);
      await _reserveM3(c);
      await _go(tester, c, Routes.payment('m_3'));
      await _tap(tester, find.text('Simulate a failed payment'));
      expect(find.text('The next payment will fail.'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel(RegExp('^Debit / Credit Card')));
      await _tap(tester, _button('Pay Rs 6,200 via Debit / Credit Card'));
      expect(find.text('Payment Failed'), findsOneWidget);
      expect(c.read(bookingProvider('m_3'))!.status, BookingStatus.held);
      await _tapThen(tester, _button('Try Again'));
      expect(find.text('Payment Successful!'), findsOneWidget);
      await _wait(tester);
      expect(_loc(c), Routes.waitingForOpponent('m_3'));
    });

    testWidgets('unpaid hold expires on the Payment screen → Waiting tab, slot released (P13)', (tester) async {
      final c = await _pumpOwner(tester);
      await _reserveM3(c);
      await _go(tester, c, Routes.payment('m_3'));
      c.read(bookingsProvider.notifier).forceExpire('m_3');
      await _tick(c);
      await _settle(tester);
      expect(_loc(c), Routes.matchManagement(MatchTab.waiting));
      expect(find.textContaining('Reservation expired — the ground slot was released'), findsOneWidget);
      expect(find.text('SETUP NEEDED'), findsOneWidget);
    });

    testWidgets('paid hold expires on Waiting (Demo force) → Expired → Move to Wallet', (tester) async {
      final c = await _pumpOwner(tester);
      await _reserveM3(c);
      await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.card);
      await _go(tester, c, Routes.waitingForOpponent('m_3'));
      expect(find.text('30:00'), findsOneWidget);
      await _tap(tester, find.text('Force reservation to expire now'));
      await _tick(c);
      await _settle(tester);

      expect(_loc(c), Routes.reservationExpired('m_3'));
      expect(find.text('Reservation Expired'), findsWidgets);
      expect(find.textContaining('Sun, 27 Sep 2026'), findsOneWidget, reason: 'dates from DateTime state');
      // Terminal: system Back → Waiting (the card offers the refund choice).
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _settle(tester);
      expect(_loc(c), Routes.matchManagement(MatchTab.waiting));
      expect(find.text('EXPIRED'), findsOneWidget);
      await _tap(tester, find.text('Choose Refund Option'));
      expect(_loc(c), Routes.reservationExpired('m_3'));

      final before = c.read(walletRepositoryProvider).clubWalletBalance;
      await _tap(tester, find.text('Move to CricEco Wallet'));
      expect(find.text('Rs 6,200 added to your CricEco Wallet'), findsOneWidget);
      expect(c.read(walletRepositoryProvider).clubWalletBalance, before + 6200);
      expect(_loc(c), Routes.matchManagement(MatchTab.waiting));
      expect(c.read(clubMatchProvider('m_3'))!.status, MatchStatus.pending);
    });

    testWidgets('Demo OFF: no simulation controls; Opponent Payment cannot be forced', (tester) async {
      final c = await _pumpOwner(tester, demo: false);
      await _reserveM3(c);
      await _go(tester, c, Routes.payment('m_3'));
      expect(find.text('Simulate a failed payment'), findsNothing);
      expect(find.textContaining('Final Year Project'), findsNothing);
      await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.card);
      await _go(tester, c, Routes.waitingForOpponent('m_3'));
      expect(find.text('Opponent Pays Now'), findsNothing);
      expect(find.text('Force reservation to expire now'), findsNothing);
      await _go(tester, c, Routes.opponentPayment('m_3'));
      expect(find.text("Waiting for the opponent's payment"), findsOneWidget);
      expect(c.read(bookingProvider('m_3'))!.status, BookingStatus.awaitingOpponent);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 6 screens render without overflow at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        await c.read(challengesProvider.future);
        await c.read(challengesProvider.notifier).accept('ch_db'); // second waiting match
        await _reserveM3(c);
        final locs = [
          Routes.matchManagement(),
          Routes.matchManagement(MatchTab.scheduled),
          Routes.matchManagement(MatchTab.history),
          Routes.matchSetup('m_3'),
          Routes.bookGround('m_3'),
          Routes.groundDetails('m_3', 'g_national'),
          Routes.selectDate('m_3', 'g_pindi'),
          Routes.bookingSummary('m_3', 'g_pindi'),
          Routes.payment('m_3'),
        ];
        for (final loc in locs) {
          await _go(tester, c, loc);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 10; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        // Custom format + errors on Match Setup.
        await _go(tester, c, Routes.matchSetup('m_3'));
        await _tap(tester, find.bySemanticsLabel('Custom Overs'));
        await _tap(tester, _button('Continue'));
        expect(tester.takeException(), isNull, reason: 'setup errors @ $width');
        // Waiting → Confirmed, and a paid-then-expired booking.
        await c.read(bookingsProvider.notifier).pay('m_3', PaymentMethodType.card);
        await _go(tester, c, Routes.waitingForOpponent('m_3'));
        expect(tester.takeException(), isNull, reason: 'waiting @ $width');
        await c.read(demoOpponentPayerProvider).pay('m_3');
        await _go(tester, c, Routes.bookingConfirmed('m_3'));
        expect(tester.takeException(), isNull, reason: 'confirmed @ $width');
      });
    }
  });
}
