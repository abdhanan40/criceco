import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthFlowType, FlutterAuthClientOptions, Supabase, SupabaseClient;

import '../../data/supabase/auth_url_params.dart';
import '../../data/supabase/supabase_gateways.dart';
import '../../data/supabase/supabase_sdk_gateways.dart';
import 'backend_config.dart';

/// Starts Supabase and returns its client.
typedef SupabaseStarter = Future<SupabaseClient> Function({
  required String url,
  required String publishableKey,
});

/// Auth options for `Supabase.initialize`. PKCE for every redirect flow
/// (Google, recovery links), and — security S1 — only PKCE `code` and
/// `error` callbacks are read from the page address / incoming links: a
/// link carrying ready-made tokens is ignored instead of becoming the
/// session ([isAcceptedAuthCallback]).
const kAuthClientOptions = FlutterAuthClientOptions(
  authFlowType: AuthFlowType.pkce,
  detectSessionInUriPredicate: isAcceptedAuthCallback,
);

/// The real starter: `Supabase.initialize` with the publishable key only
/// (it also persists and restores the Auth session) and [kAuthClientOptions].
Future<SupabaseClient> startSupabase({
  required String url,
  required String publishableKey,
}) async => (await Supabase.initialize(
  url: url,
  publishableKey: publishableKey,
  authOptions: kAuthClientOptions,
)).client;

/// Provider overrides for the build's backend, called once from `main()`.
///
/// Memory mode (the default): just the config — nothing is started, the
/// demo behaves exactly as before. Supabase mode: [start] runs once, and the
/// real [AuthGateway] / [ProfileGateway] / [ClubGateway] replace the gateway
/// providers.
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
    clubGatewayProvider.overrideWithValue(SupabaseClubGateway(client)),
    locationGatewayProvider.overrideWithValue(SupabaseLocationGateway(client)),
    // Used only with the memberships switch (migrations 11–12 live).
    membershipGatewayProvider.overrideWithValue(SupabaseMembershipGateway(client)),
    teamGatewayProvider.overrideWithValue(SupabaseTeamGateway(client)),
    // Used only with the account-privacy switch (migrations 13–14 and the
    // delete-account Edge Function live).
    accountPrivacyGatewayProvider.overrideWithValue(SupabaseAccountPrivacyGateway(client)),
    // Used only with the account-privacy switch (migration 16 live).
    ownershipGatewayProvider.overrideWithValue(SupabaseOwnershipGateway(client)),
    // Used only with the matches switch (migrations 17–19 live).
    matchGatewayProvider.overrideWithValue(SupabaseMatchGateway(client)),
  ];
}
