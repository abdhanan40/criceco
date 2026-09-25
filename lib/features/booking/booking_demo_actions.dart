import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../demo/demo_payment_tools.dart';

/// Booking-flow seam to the Demo Mode simulators in `lib/demo/` (revised
/// architecture §11: screens never import `lib/demo/` directly). Only used
/// from inside `DemoOnly` / `DemoPanel` and the demo-only Opponent Payment
/// route.
class BookingDemoActions {
  const BookingDemoActions(this._ref);
  final Ref _ref;

  bool get paymentFailureArmed => _ref.read(demoFailNextPaymentProvider);

  /// "Simulate a failed payment": the next charge fails once.
  void armPaymentFailure(bool armed) => _ref.read(demoFailNextPaymentProvider.notifier).select(armed);

  /// "Opponent Pays Now": their 50 % arrives and the booking confirms.
  Future<bool> opponentPays(String matchId) => _ref.read(demoOpponentPayerProvider).pay(matchId);
}

final bookingDemoActionsProvider = Provider<BookingDemoActions>(BookingDemoActions.new);

/// Rebuilds when the failure simulation is armed / disarmed.
final paymentFailureArmedProvider = Provider<bool>((ref) => ref.watch(demoFailNextPaymentProvider));
