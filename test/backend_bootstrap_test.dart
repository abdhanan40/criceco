import 'package:criceco/app/config/backend_bootstrap.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/supabase/supabase_account_repository.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthClientOptions, AuthFlowType, SupabaseClient;

/// Phase 2 Step 4: startup wiring. The real `Supabase.initialize` is never
/// called here — a recording starter stands in for it.
void main() {
  const url = 'https://abcdefghijklmnop.supabase.co';
  const key = 'sb_publishable_test_0000000000000000';

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// Records each start and returns a local client (no network until used).
  ({
    SupabaseStarter start,
    List<(String, String)> calls,
    List<SupabaseClient> clients,
  })
  recorder() {
    final calls = <(String, String)>[];
    final clients = <SupabaseClient>[];
    Future<SupabaseClient> start({
      required String url,
      required String publishableKey,
    }) async {
      calls.add((url, publishableKey));
      final c = SupabaseClient(
        url,
        publishableKey,
        authOptions: const AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: AuthFlowType.implicit,
        ),
      );
      clients.add(c);
      return c;
    }

    return (start: start, calls: calls, clients: clients);
  }

  ProviderContainer containerWith(List<Override> overrides) {
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        ...overrides,
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('memory mode (default): Supabase is never started; the demo repository is used', () async {
    final r = recorder();
    final overrides = await backendOverrides(
      BackendConfig.fromEnvironment(),
      start: r.start,
    );
    expect(r.calls, isEmpty);
    expect(overrides, hasLength(1)); // just the config
    final c = containerWith(overrides);
    expect(c.read(backendConfigProvider).mode, BackendMode.memory);
    expect(c.read(accountRepositoryProvider), isA<InMemoryAccountRepository>());
    expect(c.read(clubRepositoryProvider), isA<InMemoryClubRepository>());
    // No club gateway is wired in memory mode (it is never needed there).
    expect(
      () => c.read(clubGatewayProvider),
      throwsA(
        predicate((e) => e.toString().contains('Supabase is not initialized')),
      ),
    );
  });

  test(
    'explicit memory mode ignores Supabase values and starts nothing',
    () async {
      final r = recorder();
      await backendOverrides(
        BackendConfig.parse(
          backend: 'memory',
          supabaseUrl: url,
          supabasePublishableKey: key,
        ),
        start: r.start,
      );
      expect(r.calls, isEmpty);
    },
  );

  test(
    'supabase mode: started exactly once, with the URL and the publishable key',
    () async {
      final r = recorder();
      final overrides = await backendOverrides(
        BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: url,
          supabasePublishableKey: key,
        ),
        start: r.start,
      );
      addTearDown(() async {
        for (final client in r.clients) {
          await client.dispose();
        }
      });
      expect(r.calls, hasLength(1));
      expect(r.calls.single.$1, url);
      expect(r.calls.single.$2 == key, isTrue); // compared, never printed

      final c = containerWith(overrides);
      expect(c.read(authGatewayProvider), isA<SupabaseAuthGateway>());
      expect(c.read(profileGatewayProvider), isA<SupabaseProfileGateway>());
      expect(c.read(clubGatewayProvider), isA<SupabaseClubGateway>());
      expect(
        c.read(accountRepositoryProvider),
        isA<SupabaseAccountRepository>(),
      );
      expect(c.read(clubRepositoryProvider), isA<SupabaseClubRepository>());
      expect(
        c.read(authGatewayProvider).currentUser,
        isNull,
      ); // nobody signed in
    },
  );

  test(
    'invalid supabase configuration fails before anything is started',
    () async {
      final r = recorder();
      for (final bad in [
        () => BackendConfig.parse(
          backend: 'supabase',
          supabasePublishableKey: key,
        ), // no URL
        () => BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: url,
        ), // no key
        () => BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: url,
          supabasePublishableKey: 'sb_secret_x0000000',
        ),
      ]) {
        await expectLater(
          () async => backendOverrides(bad(), start: r.start),
          throwsA(isA<BackendConfigException>()),
        );
      }
      expect(r.calls, isEmpty);
    },
  );

  test('a failing start stops startup (no half-wired app)', () async {
    Future<SupabaseClient> failing({
      required String url,
      required String publishableKey,
    }) => Future.error(StateError('init failed'));
    await expectLater(
      backendOverrides(
        BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: url,
          supabasePublishableKey: key,
        ),
        start: failing,
      ),
      throwsStateError,
    );
  });

  test('supabase mode without startup wiring: a clear error, not a silent fallback', () {
    final c = containerWith([
      backendConfigProvider.overrideWithValue(
        BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: url,
          supabasePublishableKey: key,
        ),
      ),
    ]);
    expect(
      () => c.read(accountRepositoryProvider),
      throwsA(
        predicate((e) => e.toString().contains('Supabase is not initialized')),
      ),
    );
  });
}
