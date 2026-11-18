import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/config/backend_bootstrap.dart';
import 'app/config/backend_config.dart';
import 'app/config_error_app.dart';
import 'app/providers/core_providers.dart';
import 'app/session/session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // CRICECO_BACKEND: memory or supabase; a release build must name it. An
  // invalid configuration shows a clear error screen instead of the app —
  // never a silent fall-back to the demo data. Supabase starts only in
  // supabase mode.
  final BackendConfig config;
  try {
    config = BackendConfig.fromEnvironment();
  } on BackendConfigException catch (e) {
    runApp(ConfigurationErrorApp(message: e.message));
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  final backend = await backendOverrides(config);
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs), ...backend],
  );
  // Restore a remembered session so the persisted active role (P21) applies.
  await container.read(sessionProvider.notifier).restore();
  runApp(UncontrolledProviderScope(container: container, child: const CricEcoApp(showSplash: true)));
}
