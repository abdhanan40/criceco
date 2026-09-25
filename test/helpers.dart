import 'package:clock/clock.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/features/booking/payment_gateway.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mutable clock for tests.
class TestClock {
  TestClock(this.now);
  DateTime now;
  Clock get clock => Clock(() => now);
  void advance(Duration d) => now = now.add(d);
}

class InstantPaymentGateway implements PaymentGateway {
  @override
  Future<bool> charge({required method, required int amount}) async => true;
}

Future<ProviderContainer> makeContainer({TestClock? clock, Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(sp),
    if (clock != null) clockProvider.overrideWith((ref) => clock.clock),
    paymentGatewayProvider.overrideWithValue(InstantPaymentGateway()),
  ]);
  return container;
}
