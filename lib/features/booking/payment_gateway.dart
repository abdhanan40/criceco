import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';

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

final paymentGatewayProvider = Provider<PaymentGateway>((ref) => const SimulatedPaymentGateway());
