import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('app start with a restored session and a stale Club Owner role lands on Continue As', (tester) async {
    SharedPreferences.setMockInitialValues({
      'criceco.session.accountId': 'acc_aman',
      'criceco.activeRole': 'clubOwner',
      'criceco.lastRoute.clubOwner': '/club',
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ]);
    addTearDown(c.dispose);
    await c.read(sessionProvider.notifier).restore();
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.read(routerProvider).state.uri.toString(), '/continue-as');
    expect(find.text('Continue as'), findsOneWidget);
  });
}
