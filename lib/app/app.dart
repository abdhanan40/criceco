import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/booking/booking_controller.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// App-wide messenger, so reservation-expiry notices appear on whatever
/// screen is open (the expiry itself is app state, not screen state).
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class CricEcoApp extends ConsumerWidget {
  const CricEcoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // App-wide reservation expiry, independent of the open screen.
    ref.watch(reservationExpiryWatcherProvider);
    ref.listen<Map<String, ExpiryOutcome>>(expiryEventsProvider, (prev, next) {
      for (final e in next.entries) {
        if (prev?.containsKey(e.key) ?? false) continue;
        rootScaffoldMessengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            duration: CeMotion.toast * 2,
            margin: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            content: Text(
              e.value == ExpiryOutcome.returnedToPending
                  // P13: nothing was paid — the match simply returns to setup.
                  ? 'Reservation expired — the ground slot was released. Pick a slot again.'
                  : 'Reservation expired — choose a refund option in Upcoming Matches.',
              textAlign: TextAlign.center,
            ),
          ));
        ref.read(expiryEventsProvider.notifier).consume(e.key);
      }
    });
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'CricEco',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      // Manrope is bundled in assets/fonts (see pubspec.yaml).
      theme: AppTheme.light(),
      routerConfig: router,
    );
  }
}
