import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/formatters.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/features/booking/booking_controller.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Prepares a draft booking for the seeded pending match m_3 (vs IU).
Future<(ProviderContainer, TestClock)> _setup({DateTime? date, TimeSlot? slot, String groundId = 'g_pindi'}) async {
  final clock = TestClock(DateTime(2026, 9, 23, 10));
  final c = await makeContainer(clock: clock);
  await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
  await c.read(clubMatchesProvider.future);
  final match = c.read(clubMatchProvider('m_3'))!;
  final bookings = c.read(bookingsProvider.notifier)..start(match);
  bookings.updateDraft('m_3', (d) => d.copyWith(
        groundId: groundId,
        date: date ?? DateTime(2026, 10, 15),
        slot: slot ?? TimeSlot.standard[1],
      ));
  return (c, clock);
}

void main() {
  test('reserve creates a 30-minute hold with reservedAt/expiresAt and marks the match reserved', () async {
    final (c, clock) = await _setup();
    final hold = await c.read(bookingsProvider.notifier).reserve('m_3');

    expect(hold.reservedAt, clock.now);
    expect(hold.expiresAt, clock.now.add(const Duration(minutes: 30)));
    expect(hold.slotStart, DateTime(2026, 10, 15, 8));
    expect(c.read(bookingProvider('m_3'))!.status, BookingStatus.held);
    expect(c.read(bookingProvider('m_3'))!.groundCost, 12400); // Rs 6,200/hr × 2
    expect(c.read(clubMatchProvider('m_3'))!.status, MatchStatus.reserved);
  });

  test('booking labels derive from the selected DateTime (no hard-coded "Aug 2026")', () async {
    final (c, _) = await _setup(date: DateTime(2026, 11, 3));
    final d = c.read(bookingProvider('m_3'))!.draft;
    expect(CeFormat.date(d.slotStart!), '3 Nov 2026');
    expect(CeFormat.time(d.slotStart!), '8:00 AM');
    expect(CeFormat.monthYear(d.date!), 'November 2026');
  });

  test('remaining time is expiresAt − now, correct after "leaving and returning"', () async {
    final (c, clock) = await _setup();
    final hold = await c.read(bookingsProvider.notifier).reserve('m_3');
    clock.advance(const Duration(minutes: 12, seconds: 30));
    expect(hold.remaining(clock.now), const Duration(minutes: 17, seconds: 30));
    expect(CeFormat.mmss(hold.remaining(clock.now)), '17:30');
  });

  test('expiry happens regardless of the open screen; a paid hold needs resolution', () async {
    final (c, clock) = await _setup();
    final bookings = c.read(bookingsProvider.notifier);
    await bookings.reserve('m_3');
    expect(await bookings.payMyShare('m_3', PaymentMethodType.easypaisa), isTrue);
    expect(c.read(bookingProvider('m_3'))!.status, BookingStatus.awaitingOpponent);

    clock.advance(const Duration(minutes: 29));
    expect(await bookings.expireDue(clock.now), isEmpty);

    clock.advance(const Duration(minutes: 1));
    expect(await bookings.expireDue(clock.now), {'m_3': ExpiryOutcome.needsResolution});
    expect(c.read(bookingProvider('m_3'))!.status, BookingStatus.expired);
    expect(c.read(bookingProvider('m_3'))!.hold!.status, HoldStatus.expired);

    await bookings.resolveExpired('m_3', ReservationResolution.wallet);
    expect(c.read(bookingProvider('m_3'))!.status, BookingStatus.resolved);
    expect(c.read(clubMatchProvider('m_3'))!.status, MatchStatus.pending);
  });

  test('unpaid hold that expires returns the match to pending (P13)', () async {
    final (c, clock) = await _setup();
    final bookings = c.read(bookingsProvider.notifier);
    await bookings.reserve('m_3');
    clock.advance(const Duration(minutes: 31));
    expect(await bookings.expireDue(clock.now), {'m_3': ExpiryOutcome.returnedToPending});
    expect(c.read(clubMatchProvider('m_3'))!.status, MatchStatus.pending);
  });

  test('conflict: a slot held by another club throws and clears the chosen slot', () async {
    final (c, clock) = await _setup(groundId: 'g_national');
    // Seed: National Stadium is held by another club 20 days out, 2pm.
    final day = DateTime(clock.now.year, clock.now.month, clock.now.day + 20);
    c.read(bookingsProvider.notifier).updateDraft('m_3', (d) => d.copyWith(date: day, slot: TimeSlot.standard[2]));
    await expectLater(c.read(bookingsProvider.notifier).reserve('m_3'), throwsA(isA<SlotTakenException>()));
    expect(c.read(bookingProvider('m_3'))!.draft.slot, isNull);
  });

  test('opponent payment confirms the booking with 5% commission settlement', () async {
    final (c, _) = await _setup();
    final bookings = c.read(bookingsProvider.notifier);
    await bookings.reserve('m_3');
    await bookings.payMyShare('m_3', PaymentMethodType.jazzcash);
    await bookings.recordOpponentPayment('m_3');
    final b = c.read(bookingProvider('m_3'))!;
    expect(b.status, BookingStatus.confirmed);
    expect(b.hold!.status, HoldStatus.confirmed);
    expect(b.settlement!.commission, 620);
    expect(b.settlement!.toGround, 11780);
    expect(c.read(clubMatchProvider('m_3'))!.status, MatchStatus.confirmed);
  });

  test('wallet payment is refused when the balance is insufficient', () async {
    final (c, _) = await _setup(groundId: 'g_national'); // share Rs 8,000 > wallet Rs 5,000
    final bookings = c.read(bookingsProvider.notifier);
    await bookings.reserve('m_3');
    expect(await bookings.payMyShare('m_3', PaymentMethodType.wallet), isFalse);
  });
}
