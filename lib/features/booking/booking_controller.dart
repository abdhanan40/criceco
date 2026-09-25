import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';
import '../matches/club_matches_controller.dart';
import 'payment_gateway.dart';

/// Result of an expiry, so the UI can pick the right follow-up (P13).
enum ExpiryOutcome { needsResolution, returnedToPending }

/// All bookings, keyed by match id. Application state — independent of which
/// screen is open (approved decision 8). `bookingProvider(matchId)` selects one.
class BookingsController extends Notifier<Map<String, Booking>> {
  @override
  Map<String, Booking> build() {
    ref.watch(currentAccountProvider.select((a) => a?.id)); // reset on logout
    return {};
  }

  DateTime get _now => ref.read(clockProvider).now();
  ReservationRepository get _holds => ref.read(reservationRepositoryProvider);
  WalletRepository get _wallet => ref.read(walletRepositoryProvider);

  Booking? operator [](String matchId) => state[matchId];

  void _put(Booking b) => state = {...state, b.matchId: b};

  /// Match Setup entry. Starts a fresh draft unless a live booking exists.
  Booking start(ClubMatch match) {
    final existing = state[match.id];
    if (existing != null &&
        existing.status != BookingStatus.expired &&
        existing.status != BookingStatus.resolved) {
      return existing;
    }
    final b = Booking(
      matchId: match.id,
      opponentClubId: match.opponentClubId,
      draft: BookingDraft(format: match.format, customOvers: match.customOvers, city: match.city),
    );
    _put(b);
    return b;
  }

  void updateDraft(String matchId, BookingDraft Function(BookingDraft d) change) {
    final b = state[matchId];
    if (b == null) return;
    _put(b.copyWith(draft: change(b.draft)));
  }

  /// Booking Summary → "Reserve Ground for 30 Minutes". Throws
  /// [SlotTakenException] on conflict (the slot is cleared so the user picks again).
  Future<ReservationHold> reserve(String matchId) async {
    final b = state[matchId]!;
    final d = b.draft;
    final start = d.slotStart!;
    final grounds = await ref.read(groundRepositoryProvider).grounds();
    final ground = grounds.firstWhere((g) => g.id == d.groundId);
    try {
      final hold = _holds.reserve(
        matchId: matchId,
        groundId: ground.id,
        slotStart: start,
        slotEnd: d.slot!.endOn(d.date!),
        now: _now,
      );
      _put(b.copyWith(hold: hold, groundCost: ground.matchCost, status: BookingStatus.held, clearPayments: true));
      final matches = ref.read(clubMatchesProvider.notifier);
      final m = matches.byId(matchId);
      if (m != null) {
        await matches.save(m.copyWith(
          status: MatchStatus.reserved,
          groundId: ground.id,
          startsAt: start,
          format: d.format,
          customOvers: d.customOvers,
          city: d.city,
        ));
      }
      return hold;
    } on SlotTakenException {
      updateDraft(matchId, (d) => d.copyWith(clearSlot: true));
      rethrow;
    }
  }

  /// Pay your 50 % share. Returns false if the wallet balance is insufficient.
  Future<bool> payMyShare(String matchId, PaymentMethodType method) async {
    final b = state[matchId]!;
    if (method == PaymentMethodType.wallet && _wallet.clubWalletBalance < b.shareAmount) return false;
    _put(b.copyWith(myPayment: PaymentRecord(method: method, amount: b.shareAmount, status: PaymentStatus.processing)));
    final ok = await ref.read(paymentGatewayProvider).charge(method: method, amount: b.shareAmount);
    final current = state[matchId]!;
    if (!ok || current.hold?.status != HoldStatus.active) return false;
    if (method == PaymentMethodType.wallet) _wallet.adjustClubWallet(-b.shareAmount);
    _wallet.log(
      LedgerEntry(type: LedgerType.clubPayment, matchId: matchId, amount: b.shareAmount, at: _now, method: method),
      escrowDelta: b.shareAmount,
    );
    _put(current.copyWith(
      myPayment: PaymentRecord(method: method, amount: b.shareAmount, status: PaymentStatus.paid, at: _now),
      status: BookingStatus.awaitingOpponent,
    ));
    return true;
  }

  /// Opponent's share arrives (Demo action or, later, a backend event).
  Future<void> recordOpponentPayment(String matchId) async {
    final b = state[matchId];
    if (b == null || b.hold?.status != HoldStatus.active) return;
    _wallet.log(
      LedgerEntry(type: LedgerType.clubPayment, matchId: matchId, amount: b.shareAmount, at: _now),
      escrowDelta: b.shareAmount,
    );
    final settlement = Settlement.forCost(b.groundCost);
    _wallet.log(
      LedgerEntry(type: LedgerType.groundSettlement, matchId: matchId, amount: settlement.toGround, at: _now),
      escrowDelta: -b.groundCost,
    );
    final hold = _holds.update(b.hold!.copyWith(status: HoldStatus.confirmed));
    _put(b.copyWith(
      hold: hold,
      opponentPayment: PaymentRecord(method: null, amount: b.shareAmount, status: PaymentStatus.paid, at: _now),
      settlement: settlement,
      status: BookingStatus.confirmed,
    ));
    final matches = ref.read(clubMatchesProvider.notifier);
    final m = matches.byId(matchId);
    if (m != null) await matches.save(m.copyWith(status: MatchStatus.confirmed));
  }

  /// Expires every active hold whose `expiresAt` has passed. Called by the
  /// app-wide [reservationExpiryWatcherProvider] on each tick.
  Future<Map<String, ExpiryOutcome>> expireDue(DateTime now) async {
    final outcomes = <String, ExpiryOutcome>{};
    for (final b in state.values.toList()) {
      final hold = b.hold;
      if (hold == null || hold.status != HoldStatus.active || now.isBefore(hold.expiresAt)) continue;
      _holds.update(hold.copyWith(status: HoldStatus.expired));
      final paid = b.myShareSettled;
      _put(b.copyWith(hold: hold.copyWith(status: HoldStatus.expired), status: BookingStatus.expired));
      final matches = ref.read(clubMatchesProvider.notifier);
      final m = matches.byId(b.matchId);
      if (m != null && !paid) {
        await matches.save(m.copyWith(status: MatchStatus.pending, clearSchedule: true));
      }
      outcomes[b.matchId] = paid ? ExpiryOutcome.needsResolution : ExpiryOutcome.returnedToPending;
    }
    return outcomes;
  }

  /// Reservation Expired → Refund to original method / Move to CricEco Wallet.
  Future<void> resolveExpired(String matchId, ReservationResolution resolution) async {
    final b = state[matchId];
    if (b == null || b.status != BookingStatus.expired) return;
    final paid = b.myPayment;
    if (paid != null && paid.status == PaymentStatus.paid) {
      if (resolution == ReservationResolution.wallet) _wallet.adjustClubWallet(paid.amount);
      _wallet.log(LedgerEntry(type: LedgerType.refund, matchId: matchId, amount: paid.amount, at: _now),
          escrowDelta: -paid.amount);
    }
    _put(b.copyWith(
      status: BookingStatus.resolved,
      myPayment: paid?.copyWith(
          status: resolution == ReservationResolution.wallet ? PaymentStatus.movedToWallet : PaymentStatus.refunded),
    ));
    final matches = ref.read(clubMatchesProvider.notifier);
    final m = matches.byId(matchId);
    if (m != null) await matches.save(m.copyWith(status: MatchStatus.pending, clearSchedule: true));
  }

  /// Demo tool: "force reservation to expire now".
  void forceExpire(String matchId) {
    final b = state[matchId];
    final hold = b?.hold;
    if (b == null || hold == null || hold.status != HoldStatus.active) return;
    final expired = _holds.update(hold.copyWith(expiresAt: _now));
    _put(b.copyWith(hold: expired));
  }
}

final bookingsProvider = NotifierProvider<BookingsController, Map<String, Booking>>(BookingsController.new);

/// activeBooking — typed selected-context lookup by route id.
final bookingProvider = Provider.family<Booking?, String>((ref, matchId) => ref.watch(bookingsProvider)[matchId]);

/// Remaining hold time, always `expiresAt - now` (correct after leaving and
/// returning to any screen).
final holdRemainingProvider = Provider.family<Duration?, String>((ref, matchId) {
  final hold = ref.watch(bookingProvider(matchId))?.hold;
  if (hold == null || hold.status != HoldStatus.active) return null;
  final now = ref.watch(nowProvider).value ?? ref.read(clockProvider).now();
  return hold.remaining(now);
});

/// Latest expiry outcomes, so the UI can react (e.g. navigate to Reservation
/// Expired or show "Reservation expired — pick a slot again").
class ExpiryEvents extends Notifier<Map<String, ExpiryOutcome>> {
  @override
  Map<String, ExpiryOutcome> build() => const {};
  void add(Map<String, ExpiryOutcome> events) => state = {...state, ...events};
  void consume(String matchId) => state = {...state}..remove(matchId);
}

final expiryEventsProvider = NotifierProvider<ExpiryEvents, Map<String, ExpiryOutcome>>(ExpiryEvents.new);

/// App-wide watcher, listened once at the app root. Expiry happens regardless
/// of which screen is open.
final reservationExpiryWatcherProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<DateTime>>(nowProvider, (_, next) async {
    final now = next.value;
    if (now == null) return;
    final outcomes = await ref.read(bookingsProvider.notifier).expireDue(now);
    if (outcomes.isNotEmpty) ref.read(expiryEventsProvider.notifier).add(outcomes);
  });
});
