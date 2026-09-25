import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/providers/core_providers.dart';
import 'app/session/session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  // Restore a remembered session so the persisted active role (P21) applies.
  await container.read(sessionProvider.notifier).restore();
  runApp(UncontrolledProviderScope(container: container, child: const CricEcoApp()));
}
