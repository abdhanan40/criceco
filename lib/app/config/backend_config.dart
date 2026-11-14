import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which backend the app talks to. Chosen at build time:
/// `--dart-define=CRICECO_BACKEND=memory|supabase` (default `memory`, the
/// in-memory demo data).
enum BackendMode { memory, supabase }

/// Build-time backend configuration. Supabase mode also needs
/// `--dart-define=SUPABASE_URL=…` and `--dart-define=SUPABASE_PUBLISHABLE_KEY=…`
/// (the publishable / anon key — a service-role or secret key is refused).
class BackendConfig {
  const BackendConfig.memory()
    : mode = BackendMode.memory,
      supabaseUrl = null,
      supabasePublishableKey = null;

  const BackendConfig._supabase(this.supabaseUrl, this.supabasePublishableKey)
    : mode = BackendMode.supabase;

  final BackendMode mode;
  final Uri? supabaseUrl;
  final String? supabasePublishableKey;

  bool get isSupabase => mode == BackendMode.supabase;

  /// The values passed with `--dart-define` when the app was built.
  factory BackendConfig.fromEnvironment() => BackendConfig.parse(
    backend: const String.fromEnvironment('CRICECO_BACKEND'),
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: const String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
    ),
  );

  /// Validates raw values. Throws [BackendConfigException] — whose message
  /// never contains the key — when they don't form a usable configuration.
  /// A secret or service-role key is refused in every mode: anything passed
  /// with `--dart-define` is compiled into the app, even when unused. Other
  /// Supabase values are ignored in memory mode.
  factory BackendConfig.parse({
    String? backend,
    String? supabaseUrl,
    String? supabasePublishableKey,
  }) {
    final key = (supabasePublishableKey ?? '').trim();
    if (_isSecretKey(key)) {
      throw const BackendConfigException(
        'SUPABASE_PUBLISHABLE_KEY must be the publishable (anon) key — '
        'never a secret or service-role key',
      );
    }

    final name = (backend ?? '').trim().toLowerCase();
    if (name.isEmpty || name == 'memory') return const BackendConfig.memory();
    if (name != 'supabase') {
      throw BackendConfigException(
        'CRICECO_BACKEND must be "memory" or "supabase", not "$backend"',
      );
    }

    final url = Uri.tryParse((supabaseUrl ?? '').trim());
    if (url == null || !url.hasAuthority || url.host.isEmpty) {
      throw const BackendConfigException(
        'SUPABASE_URL is required in supabase mode (https://<project>.supabase.co)',
      );
    }
    final local = _localHosts.contains(url.host);
    if (url.scheme != 'https' && !(local && url.scheme == 'http')) {
      throw const BackendConfigException(
        'SUPABASE_URL must use https (http is allowed for a local host only)',
      );
    }

    if (key.isEmpty) {
      throw const BackendConfigException(
        'SUPABASE_PUBLISHABLE_KEY is required in supabase mode',
      );
    }
    return BackendConfig._supabase(url, key);
  }

  /// Hosts a local Supabase or an Android emulator reaches over plain http.
  static const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

  /// A new-style secret key (`sb_secret_…`), or a legacy JWT key whose
  /// payload says `"role": "service_role"`.
  static bool _isSecretKey(String key) {
    if (key.startsWith('sb_secret_')) return true;
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map && payload['role'] == 'service_role';
    } on FormatException {
      return false;
    }
  }
}

class BackendConfigException implements Exception {
  const BackendConfigException(this.message);
  final String message;

  @override
  String toString() => 'BackendConfigException: $message';
}

/// The build's backend configuration. Tests override it.
final backendConfigProvider = Provider<BackendConfig>(
  (ref) => BackendConfig.fromEnvironment(),
);
