import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../demo/demo_payment_tools.dart';

/// Payment gateway seam (prototype: "replace runSimulatedPayment() with
/// JazzCash / EasyPaisa / Stripe / PayFast"). Screens never know which one
/// is in use.
abstract interface class PaymentGateway {
  Future<bool> charge({required PaymentMethodType method, required int amount});
}

/// Prototype timing: 1.6 s processing, then success.
class SimulatedPaymentGateway implements PaymentGateway {
  const SimulatedPaymentGateway({this.processing = const Duration(milliseconds: 1600)});
  final Duration processing;

  @override
  Future<bool> charge({required PaymentMethodType method, required int amount}) async {
    await Future<void>.delayed(processing);
    return true;
  }
}

/// The actual gateway (simulated until a real one is plugged in).
final realPaymentGatewayProvider = Provider<PaymentGateway>((ref) => const SimulatedPaymentGateway());

/// What the booking flow charges through. In Demo Mode it can be armed to
/// fail once ("Simulate a failed payment"); otherwise it is the real gateway.
final paymentGatewayProvider = Provider<PaymentGateway>(
  (ref) => DemoAwarePaymentGateway(ref, ref.watch(realPaymentGatewayProvider)),
);
