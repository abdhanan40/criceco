import 'package:flutter/material.dart';

/// Shown instead of the app when the build's configuration is invalid
/// (BackendConfigException): no backend is started and no data — real or
/// sample — is shown. [message] names the define to fix; it never contains
/// a key.
class ConfigurationErrorApp extends StatelessWidget {
  const ConfigurationErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'CricEco',
    home: Scaffold(
      key: const Key('configError'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Color(0xFFB42318)),
                const SizedBox(height: 16),
                const Text(
                  'CricEco can’t start',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                const Text(
                  'This build of the app is not configured correctly, so nothing was loaded.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                SelectableText(
                  message,
                  key: const Key('configError.message'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF5B6472)),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
