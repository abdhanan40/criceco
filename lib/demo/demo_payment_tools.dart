import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/config/demo_mode.dart';
import '../core/models/models.dart';
import '../features/booking/booking_controller.dart';
import '../features/booking/payment_gateway.dart';
import '../shared/state/selection_controller.dart';

/// Demo Mode only (revised architecture §11). Everything here simulates the
/// other side of a booking and calls the same controller APIs a backend
/// event would. Production screens only reach it from inside a DemoPanel.

/// "Simulate a failed payment": the NEXT charge fails once, so the Payment
/// screen's failure state can be shown without a real gateway.
final demoFailNextPaymentProvider =
    NotifierProvider<SelectionController<bool>, bool>(() => SelectionController(false));

/// Gateway wrapper: in Demo Mode, fails the next charge when armed; otherwise
/// delegates to the real (simulated) gateway.
class DemoAwarePaymentGateway implements PaymentGateway {
  DemoAwarePaymentGateway(this._ref, this._inner);
  final Ref _ref;
  final PaymentGateway _inner;

  @override
  Future<bool> charge({required PaymentMethodType method, required int amount}) async {
    final armed = _ref.read(demoModeProvider) && _ref.read(demoFailNextPaymentProvider);
    final ok = await _inner.charge(method: method, amount: amount);
    if (armed) {
      _ref.read(demoFailNextPaymentProvider.notifier).select(false);
      return false;
    }
    return ok;
  }
}

/// "Opponent Pays Now": the opponent club's 50 % arrives through the same
/// gateway seam, then the booking confirms (prototype `runSimulatedPayment`
/// for the opponent). Demo OFF: this never runs; confirmation waits for the
/// opponent's real payment event.
class DemoOpponentPayer {
  const DemoOpponentPayer(this.ref);
  final Ref ref;

  Future<bool> pay(String matchId) async {
    if (!ref.read(demoModeProvider)) return false;
    final booking = ref.read(bookingProvider(matchId));
    if (booking == null || booking.status != BookingStatus.awaitingOpponent) return false;
    await ref.read(realPaymentGatewayProvider).charge(method: PaymentMethodType.jazzcash, amount: booking.shareAmount);
    await ref.read(bookingsProvider.notifier).recordOpponentPayment(matchId);
    return ref.read(bookingProvider(matchId))?.status == BookingStatus.confirmed;
  }
}

final demoOpponentPayerProvider = Provider<DemoOpponentPayer>(DemoOpponentPayer.new);
