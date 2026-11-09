import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:supabase_flutter/supabase_flutter.dart'
    show Supabase, SupabaseClient;

import '../../data/supabase/supabase_gateways.dart';
import '../../data/supabase/supabase_sdk_gateways.dart';
import 'backend_config.dart';

/// Starts Supabase and returns its client.
typedef SupabaseStarter = Future<SupabaseClient> Function({
  required String url,
  required String publishableKey,
});

/// The real starter: `Supabase.initialize` with the publishable key only
/// (it also persists and restores the Auth session).
Future<SupabaseClient> startSupabase({
  required String url,
  required String publishableKey,
}) async => (await Supabase.initialize(
  url: url,
  publishableKey: publishableKey,
)).client;

/// Provider overrides for the build's backend, called once from `main()`.
///
/// Memory mode (the default): just the config — nothing is started, the
/// demo behaves exactly as before. Supabase mode: [start] runs once, and the
/// real [AuthGateway] / [ProfileGateway] replace the gateway providers.
/// An invalid configuration has already thrown in [BackendConfig.parse].
Future<List<Override>> backendOverrides(
  BackendConfig config, {
  SupabaseStarter start = startSupabase,
}) async {
  if (!config.isSupabase) {
    return [backendConfigProvider.overrideWithValue(config)];
  }
  final client = await start(
    url: config.supabaseUrl.toString(),
    publishableKey: config.supabasePublishableKey!,
  );
  return [
    backendConfigProvider.overrideWithValue(config),
    authGatewayProvider.overrideWithValue(SupabaseAuthGateway(client.auth)),
    profileGatewayProvider.overrideWithValue(SupabaseProfileGateway(client)),
  ];
}
