import 'dart:convert';

import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build-time backend switch (Phase 2, Step 1). No Supabase dependency and
/// no network: only parsing, validation and provider wiring.
void main() {
  const url = 'https://abcdefghijklmnop.supabase.co';
  const publishable = 'sb_publishable_test_0000000000000000';

  /// A JWT-shaped legacy key with the given role (not a real key).
  String jwtWithRole(String role) {
    String part(Map<String, Object> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${part({'iss': 'supabase', 'role': role})}.signature';
  }

  Matcher configError(String fragment) => throwsA(
    isA<BackendConfigException>().having(
      (e) => e.message,
      'message',
      contains(fragment),
    ),
  );

  group('memory mode', () {
    test('is the default when nothing is passed', () {
      final c = BackendConfig.parse();
      expect(c.mode, BackendMode.memory);
      expect(c.isSupabase, isFalse);
      expect(c.supabaseUrl, isNull);
      expect(c.supabasePublishableKey, isNull);
    });

    test('is the default for an empty CRICECO_BACKEND (no --dart-define)', () {
      expect(BackendConfig.parse(backend: '').mode, BackendMode.memory);
    });

    test('this test run (no --dart-define) resolves to memory', () {
      expect(BackendConfig.fromEnvironment().mode, BackendMode.memory);
    });

    test('explicit "memory" (trimmed, any case)', () {
      expect(BackendConfig.parse(backend: 'memory').mode, BackendMode.memory);
      expect(BackendConfig.parse(backend: ' Memory ').mode, BackendMode.memory);
    });

    test('ignores Supabase values (a publishable key and URL)', () {
      final c = BackendConfig.parse(
        backend: 'memory',
        supabaseUrl: url,
        supabasePublishableKey: publishable,
      );
      expect(c.mode, BackendMode.memory);
      expect(c.supabaseUrl, isNull);
      expect(c.supabasePublishableKey, isNull);
    });
  });

  group('supabase mode', () {
    test('accepts an https project URL and a publishable key (trimmed)', () {
      final c = BackendConfig.parse(
        backend: 'supabase',
        supabaseUrl: ' $url ',
        supabasePublishableKey: ' $publishable ',
      );
      expect(c.mode, BackendMode.supabase);
      expect(c.isSupabase, isTrue);
      expect(c.supabaseUrl, Uri.parse(url));
      expect(c.supabasePublishableKey, publishable);
    });

    test('accepts a legacy anon JWT key', () {
      final anon = jwtWithRole('anon');
      final c = BackendConfig.parse(
        backend: 'SUPABASE',
        supabaseUrl: url,
        supabasePublishableKey: anon,
      );
      expect(c.supabasePublishableKey, anon);
    });

    test('allows plain http for a local Supabase only', () {
      for (final local in [
        'http://localhost:54321',
        'http://127.0.0.1:54321',
        'http://10.0.2.2:54321',
      ]) {
        expect(
          BackendConfig.parse(
            backend: 'supabase',
            supabaseUrl: local,
            supabasePublishableKey: publishable,
          ).supabaseUrl,
          Uri.parse(local),
        );
      }
    });
  });

  group('invalid configuration', () {
    test('an unknown backend name', () {
      expect(
        () => BackendConfig.parse(backend: 'firebase'),
        configError('must be "memory" or "supabase"'),
      );
    });

    test('supabase without a URL, or with a malformed one', () {
      for (final bad in [null, '', '   ', 'not a url', 'abcdefghijklmnop']) {
        expect(
          () => BackendConfig.parse(
            backend: 'supabase',
            supabaseUrl: bad,
            supabasePublishableKey: publishable,
          ),
          configError('SUPABASE_URL is required'),
          reason: 'url "$bad"',
        );
      }
    });

    test('supabase over plain http to a remote host', () {
      expect(
        () => BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: 'http://abcdefghijklmnop.supabase.co',
          supabasePublishableKey: publishable,
        ),
        configError('must use https'),
      );
    });

    test('supabase without a key', () {
      for (final bad in [null, '', '   ']) {
        expect(
          () => BackendConfig.parse(
            backend: 'supabase',
            supabaseUrl: url,
            supabasePublishableKey: bad,
          ),
          configError('SUPABASE_PUBLISHABLE_KEY is required'),
        );
      }
    });

    test(
      'a secret or service-role key is refused in every mode — never echoed',
      () {
        // Default (no backend), explicit memory, supabase, and even a wrong
        // backend name: the secret is refused before anything else.
        for (final backend in [null, '', 'memory', 'supabase', 'firebase']) {
          for (final secret in [
            'sb_secret_test_0000000000000000',
            ' sb_secret_test_0000000000000000 ',
            jwtWithRole('service_role'),
          ]) {
            expect(
              () => BackendConfig.parse(
                backend: backend,
                supabaseUrl: url,
                supabasePublishableKey: secret,
              ),
              throwsA(
                isA<BackendConfigException>()
                    .having(
                      (e) => e.message,
                      'message',
                      contains('never a secret'),
                    )
                    .having(
                      (e) => e.toString(),
                      'toString',
                      isNot(contains(secret.trim())),
                    ),
              ),
              reason: 'backend "$backend"',
            );
          }
        }
      },
    );

    test('a secret key is refused even without a URL (memory mode)', () {
      expect(
        () => BackendConfig.parse(
          supabasePublishableKey: 'sb_secret_test_0000000000000000',
        ),
        configError('never a secret'),
      );
    });
  });

  group('provider wiring', () {
    test('default: the in-memory account repository (demo unchanged)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(backendConfigProvider).mode, BackendMode.memory);
      expect(
        container.read(accountRepositoryProvider),
        isA<InMemoryAccountRepository>(),
      );
    });

    test('supabase mode fails clearly until its gateways exist (Step 4)', () {
      final container = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(
            BackendConfig.parse(
              backend: 'supabase',
              supabaseUrl: url,
              supabasePublishableKey: publishable,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        () => container.read(accountRepositoryProvider),
        throwsA(predicate((e) => e.toString().contains('not available yet'))),
      );
    });
  });
}
