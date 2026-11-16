import 'dart:convert';

import 'package:criceco/app/config/backend_bootstrap.dart';
import 'package:criceco/data/supabase/auth_url_params.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Security S1 (final auth audit): the page address (web) and incoming
/// `com.criceco.criceco://login-callback` links (Android) may only start a
/// PKCE code exchange or report a failed callback — never hand the app a
/// ready-made session.
void main() {
  const web = 'http://localhost:60550/';
  const android = 'com.criceco.criceco://login-callback';
  bool ok(String link) => isAcceptedAuthCallback(Uri.parse(link));

  group('accepted: PKCE codes and failed callbacks', () {
    test('a Google return or recovery link (PKCE code in the query)', () {
      expect(ok('$web?code=0b5f2c'), isTrue);
      expect(
        ok('$web?code=0b5f2c#/login'),
        isTrue,
        reason: 'with the app route',
      );
      expect(ok('$android?code=0b5f2c'), isTrue);
    });

    test('a failed callback (message only)', () {
      expect(
        ok('$web?error=access_denied&error_description=The+user+denied+access'),
        isTrue,
      );
      expect(
        ok(
          '$web?error=server_error&error_description=Unable+to+exchange+external+code#/login',
        ),
        isTrue,
      );
      expect(
        ok(
          '$web?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid',
        ),
        isTrue,
      );
      expect(
        ok('$android?error=invalid_request&error_code=bad_oauth_state'),
        isTrue,
      );
      expect(
        ok('$android#error=access_denied&error_description=Denied'),
        isTrue,
        reason: 'errors may come in the fragment',
      );
    });
  });

  group('refused: ready-made tokens (session injection)', () {
    const tokens =
        'access_token=eyJhbGciOiJIUzI1NiJ9.e30.x&refresh_token=r1&expires_in=3600&token_type=bearer';

    test('tokens in the fragment (the implicit-flow shape)', () {
      expect(ok('$android#$tokens'), isFalse);
      expect(ok('$web#$tokens'), isFalse);
      expect(
        ok('$web?s=1#$tokens&type=recovery'),
        isFalse,
        reason: 'a "recovery" link with tokens',
      );
    });

    test('tokens in the query', () {
      expect(ok('$android?$tokens'), isFalse);
      expect(ok('$web?$tokens#/login'), isFalse);
    });

    test('any one token parameter is enough to refuse', () {
      for (final p in kSessionTokenParameters) {
        expect(ok('$android#$p=x'), isFalse, reason: p);
        expect(ok('$web?$p=x'), isFalse, reason: p);
      }
    });

    test('tokens mixed with a code or an error are still refused', () {
      expect(ok('$android?code=0b5f2c#access_token=x'), isFalse);
      expect(ok('$web?code=0b5f2c&refresh_token=x'), isFalse);
      expect(
        ok('$android?error=access_denied#access_token=x&refresh_token=y'),
        isFalse,
      );
    });
  });

  group('refused: everything else', () {
    test('ordinary app addresses are not callbacks', () {
      expect(ok(web), isFalse);
      expect(ok('$web#/login'), isFalse);
      expect(ok('$web#/onboarding/role?expand=player'), isFalse);
      expect(ok('$web?utm_source=x#/login'), isFalse);
      expect(ok(android), isFalse);
    });

    test('a code in the fragment (not where PKCE puts it)', () {
      expect(ok('$android#code=0b5f2c'), isFalse);
    });

    test('malformed addresses', () {
      // A garbled code is still a code callback: the exchange then fails
      // safely ("That link can't be used here"), as an unknown code does.
      expect(isAcceptedAuthCallback(Uri.parse('$web?code=%zz')), isTrue);
      // A garbled token is still a token: refused.
      expect(
        isAcceptedAuthCallback(Uri.parse('$android#access_token=%zz')),
        isFalse,
      );
      expect(
        isAcceptedAuthCallback(
          Uri(
            scheme: 'http',
            host: 'localhost',
            fragment: 'access_token=%E0%A4%A',
          ),
        ),
        isFalse,
      );
    });
  });

  test(
    'start-up options: PKCE, and this rule decides which links Supabase reads',
    () {
      expect(kAuthClientOptions.authFlowType, sb.AuthFlowType.pkce);
      expect(
        kAuthClientOptions.detectSessionInUri,
        isTrue,
        reason: 'Google and recovery links still work',
      );
      expect(
        identical(
          kAuthClientOptions.detectSessionInUriPredicate,
          isAcceptedAuthCallback,
        ),
        isTrue,
      );
      expect(
        kAuthClientOptions.detectSessionInUriPredicate!(
          Uri.parse('$android#access_token=x&refresh_token=y'),
        ),
        isFalse,
      );
      expect(
        kAuthClientOptions.detectSessionInUriPredicate!(
          Uri.parse('$android?code=0b5f2c'),
        ),
        isTrue,
      );
    },
  );

  test(
    'why it matters: the SDK itself would turn a token link into a session',
    () async {
      // The SDK only checks the token with the server (GET /user) and then
      // saves it — even in PKCE mode. Here the "server" knows the token.
      final requests = <String>[];
      final client = sb.SupabaseClient(
        'https://abcdefghijklmnop.supabase.co',
        'sb_publishable_test_0000000000000000',
        httpClient: MockClient((r) async {
          requests.add('${r.method} ${r.url.path}');
          return http.Response(
            jsonEncode({
              'id': '00000000-0000-4000-8000-0000000000aa',
              'aud': 'authenticated',
              'email': 'someone-else@example.com',
              'app_metadata': <String, Object?>{},
              'user_metadata': <String, Object?>{},
              'created_at': '2026-11-15T10:00:00Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
        authOptions: const sb.AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: sb.AuthFlowType.pkce,
        ),
      );
      addTearDown(client.dispose);
      final link = Uri.parse(
        '$android#access_token=attacker-token&refresh_token=attacker-refresh'
        '&expires_in=3600&token_type=bearer',
      );

      await client.auth.getSessionFromUrl(link);
      expect(
        client.auth.currentUser?.email,
        'someone-else@example.com',
        reason:
            'without the rule, the link would sign the app in as someone else',
      );
      expect(requests, ['GET /auth/v1/user']);

      expect(
        isAcceptedAuthCallback(link),
        isFalse,
        reason: 'with the rule, Supabase never reads this link',
      );
    },
  );
}
