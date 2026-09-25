import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/booking/booking_controller.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

class CricEcoApp extends ConsumerWidget {
  const CricEcoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // App-wide reservation expiry, independent of the open screen.
    ref.watch(reservationExpiryWatcherProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'CricEco',
      debugShowCheckedModeBanner: false,
      // Manrope is bundled in assets/fonts (see pubspec.yaml).
      theme: AppTheme.light(),
      routerConfig: router,
    );
  }
}
