import 'dart:async';
import 'dart:convert';

import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/auth_url_params.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// AUTH-04 / AUTH-05 on the real `supabase_flutter` client with the HTTP
/// layer faked (no live project, no credentials): the recovery requests, the
/// session kind read from the token, and how SDK auth events and link
/// errors become the app's events.
void main() {
  const url = 'https://abcdefghijklmnop.supabase.co';
  const key = 'sb_publishable_test_0000000000000000';
  const uid = '00000000-0000-4000-8000-000000000001';

  final requests = <http.Request>[];
  late http.Response Function(http.Request) respond;
  late sb.SupabaseClient client;

  setUp(() {
    requests.clear();
    respond = (_) => http.Response('{}', 200);
    client = sb.SupabaseClient(
      url,
      key,
      httpClient: MockClient((r) async {
        requests.add(r);
        final res = respond(r);
        return http.Response.bytes(
          res.bodyBytes,
          res.statusCode,
          headers: res.headers,
          request: r,
        );
      }),
      authOptions: const sb.AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: sb.AuthFlowType.implicit,
      ),
    );
  });
  tearDown(() => client.dispose());

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  /// A token whose payload has [amr] (the signature is not checked here).
  String jwt(List<String> amr) {
    String part(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${part({
          'sub': uid,
          'exp': 4102444800, // 2100
          'amr': [
            for (final m in amr) {'method': m, 'timestamp': 1763200000},
          ],
        })}.sig';
  }

  Map<String, Object?> session(List<String> amr) => {
    'access_token': jwt(amr),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'test-refresh-token',
    'user': {
      'id': uid,
      'aud': 'authenticated',
      'email': 'a@example.com',
      'app_metadata': <String, Object?>{},
      'user_metadata': {'full_name': 'Hamza Sheikh'},
      'created_at': '2026-10-29T10:00:00Z',
    },
  };

  group('recovery requests', () {
    test(
      'sendPasswordReset: POST /recover with the email and the app\'s redirect',
      () async {
        await SupabaseAuthGateway(client.auth).sendPasswordReset(
          email: 'a@example.com',
          redirectTo: 'com.criceco.criceco://login-callback',
        );
        final r = requests.single;
        expect((r.method, r.url.path), ('POST', '/auth/v1/recover'));
        expect(
          r.url.queryParameters['redirect_to'],
          'com.criceco.criceco://login-callback',
        );
        expect((jsonDecode(r.body) as Map)['email'], 'a@example.com');
      },
    );

    test('sendPasswordReset: too soon → GatewayRateLimitedException', () async {
      respond = (_) => json({
        'code': 429,
        'error_code': 'over_email_send_rate_limit',
        'msg': 'wait',
      }, 429);
      await expectLater(
        SupabaseAuthGateway(client.auth)
            .sendPasswordReset(email: 'a@example.com'),
        throwsA(isA<GatewayRateLimitedException>()),
      );
    });

    test(
      'verifyRecoveryCode: POST /verify (type recovery) → a recovery session',
      () async {
        // Supabase labels a code-started recovery "otp" (seen on the local
        // stack, AUTH-04 live test) — the gateway must not rely on the label.
        respond = (_) => json(session(['otp']));
        final g = SupabaseAuthGateway(client.auth);
        expect(g.sessionKind, AuthSessionKind.none);
        final user = await g.verifyRecoveryCode(
          email: 'a@example.com',
          code: '123456',
        );
        expect(user.id, uid);
        expect(g.sessionKind, AuthSessionKind.recovery);
        final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
        expect(
          (body['type'], body['email'], body['token']),
          ('recovery', 'a@example.com', '123456'),
        );
      },
    );

    test('the recovery mark ends with any other sign-in or sign-out', () async {
      final g = SupabaseAuthGateway(client.auth);
      respond = (_) => json(session(['otp']));
      await g.verifyRecoveryCode(email: 'a@example.com', code: '123456');
      respond = (_) => json(session(['password']));
      await g.signInWithPassword(email: 'a@example.com', password: 'x');
      expect(
        g.sessionKind,
        AuthSessionKind.other,
        reason: 'a password sign-in is not a recovery',
      );

      respond = (_) => json(session(['otp']));
      await g.verifyRecoveryCode(email: 'a@example.com', code: '123456');
      respond = (_) => http.Response('', 204);
      await g.signOut();
      expect(g.sessionKind, AuthSessionKind.none);
      respond = (_) => json(session(['otp']));
      await g.verifySignUpCode(email: 'a@example.com', code: '123456');
      expect(
        g.sessionKind,
        AuthSessionKind.other,
        reason: 'a sign-up code is "otp" too, but not a recovery',
      );
    });

    test('a recovery link (the SDK\'s passwordRecovery event) marks the session too', () async {
      final g = SupabaseAuthGateway(client.auth);
      await g.takeStartEvent(); // listening, as at app start
      respond = (_) => json(session(['otp']));
      // As the deep-link handler's code exchange would: a session, then the event.
      await client.auth.verifyOTP(
        type: sb.OtpType.recovery,
        email: 'a@example.com',
        token: '123456',
      );
      await pumpEventQueue();
      expect(g.sessionKind, AuthSessionKind.recovery);
    });

    test('verifyRecoveryCode: wrong / expired / used (403 otp_expired) → GatewayInvalidCodeException', () async {
      respond = (_) => json({
        'code': 403,
        'error_code': 'otp_expired',
        'msg': 'Token has expired or is invalid',
      }, 403);
      final g = SupabaseAuthGateway(client.auth);
      await expectLater(
        g.verifyRecoveryCode(email: 'a@example.com', code: '000000'),
        throwsA(isA<GatewayInvalidCodeException>()),
      );
      expect(g.sessionKind, AuthSessionKind.none);
    });

    test('updatePassword: PUT /user with the new password; the old one → GatewaySamePasswordException', () async {
      respond = (_) => json(session(['recovery']));
      final g = SupabaseAuthGateway(client.auth);
      await g.verifyRecoveryCode(email: 'a@example.com', code: '123456');
      respond = (_) => json((session(['recovery'])['user'])!);
      await g.updatePassword('Wicket#2027');
      final put = requests.last;
      expect((put.method, put.url.path), ('PUT', '/auth/v1/user'));
      expect((jsonDecode(put.body) as Map)['password'], 'Wicket#2027');
      respond = (_) => json({
        'code': 422,
        'error_code': 'same_password',
        'msg': 'New password should be different from the old password.',
      }, 422);
      await expectLater(
        g.updatePassword('Cricket@2026'),
        throwsA(isA<GatewaySamePasswordException>()),
      );
      expect(
        SupabaseErrorMapper.map(const GatewaySamePasswordException()),
        isA<SamePasswordException>(),
      );
    });

    test('signOutEverywhere: POST /logout?scope=global, and the session is gone here', () async {
      respond = (_) => json(session(['recovery']));
      final g = SupabaseAuthGateway(client.auth);
      await g.verifyRecoveryCode(email: 'a@example.com', code: '123456');
      respond = (_) => http.Response('', 204);
      await g.signOutEverywhere();
      final r = requests.last;
      expect(
        (r.method, r.url.path, r.url.queryParameters['scope']),
        ('POST', '/auth/v1/logout', 'global'),
      );
      expect(g.currentUser, isNull);
      expect(g.sessionKind, AuthSessionKind.none);
    });
  });

  group('events', () {
    test(
      'a recovery during start is the start event; later ones go to the stream',
      () async {
        respond = (_) => json(session(['recovery']));
        final g = SupabaseAuthGateway(client.auth);
        await client.auth.verifyOTP(
          type: sb.OtpType.recovery,
          email: 'a@example.com',
          token: '123456',
        );
        expect(await g.takeStartEvent(), isA<GatewayRecoveryStarted>());

        final seen = <AuthGatewayEvent>[];
        final sub = g.events.listen(seen.add);
        addTearDown(sub.cancel);
        await g.verifyRecoveryCode(email: 'a@example.com', code: '123456');
        await pumpEventQueue();
        expect(seen.single, isA<GatewayRecoveryStarted>());
      },
    );

    test('nothing at start: null', () async {
      expect(await SupabaseAuthGateway(client.auth).takeStartEvent(), isNull);
    });

    test('a password sign-in is the app\'s own call: no event', () async {
      final g = SupabaseAuthGateway(client.auth);
      await g.takeStartEvent();
      final seen = <AuthGatewayEvent>[];
      final sub = g.events.listen(seen.add);
      addTearDown(sub.cancel);
      respond = (_) => json(session(['password']));
      await g.signInWithPassword(email: 'a@example.com', password: 'x');
      await pumpEventQueue();
      expect(seen, isEmpty);
      expect(g.sessionKind, AuthSessionKind.other);
    });

    final oauth = sb.Session.fromJson(session(['oauth']))!;
    final password = sb.Session.fromJson(session(['password']))!;
    AuthGatewayEvent? ev(
      sb.AuthChangeEvent e,
      sb.Session? s, {
      sb.SignOutReason? reason,
    }) => SupabaseAuthGateway.eventOf(
      sb.AuthState(e, s, signOutReason: reason),
      SupabaseAuthGateway.kindOf(s),
    );

    test('eventOf: recovery, a Google return, an ended session; the app\'s own calls are not events', () {
      expect(
        ev(sb.AuthChangeEvent.passwordRecovery, null),
        isA<GatewayRecoveryStarted>(),
      );
      final google = ev(sb.AuthChangeEvent.signedIn, oauth);
      expect(google, isA<GatewayOAuthSignedIn>());
      expect((google! as GatewayOAuthSignedIn).user.fullName, 'Hamza Sheikh');
      expect(
        ev(sb.AuthChangeEvent.signedIn, password),
        isNull,
        reason: 'password / code sign-ins',
      );
      expect(
        ev(
          sb.AuthChangeEvent.signedOut,
          null,
          reason: sb.SignOutReason.sessionExpired,
        ),
        isA<GatewaySessionExpired>(),
      );
      expect(
        ev(
          sb.AuthChangeEvent.signedOut,
          null,
          reason: sb.SignOutReason.userInitiated,
        ),
        isNull,
      );
      expect(ev(sb.AuthChangeEvent.signedOut, null), isNull);
      expect(ev(sb.AuthChangeEvent.tokenRefreshed, oauth), isNull);
      expect(ev(sb.AuthChangeEvent.initialSession, oauth), isNull);
    });

    test('linkError: the callback\'s error codes; other errors are not about a link', () {
      GatewayLinkError? l(Object e) => SupabaseAuthGateway.linkError(e);
      // ?error=access_denied&error_code=otp_expired (an expired / used email link)
      expect(
        l(
          const sb.AuthException(
            'Email link is invalid or has expired',
            statusCode: 'otp_expired',
            code: 'access_denied',
          ),
        ),
        GatewayLinkError.expired,
      );
      // ?error=access_denied (Google: cancelled or permission refused)
      expect(
        l(const sb.AuthException('User denied access', code: 'access_denied')),
        GatewayLinkError.cancelled,
      );
      // Opened in another browser: no PKCE verifier here.
      expect(
        l(
          const sb.AuthException(
            'Code verifier could not be found in local storage.',
          ),
        ),
        GatewayLinkError.invalid,
      );
      expect(
        l(
          const sb.AuthPKCEGrantCodeExchangeError(
            'No code detected in query parameters.',
          ),
        ),
        GatewayLinkError.invalid,
      );
      expect(
        l(
          const sb.AuthApiException(
            'flow state not found',
            statusCode: '404',
            code: 'flow_state_not_found',
          ),
        ),
        GatewayLinkError.invalid,
      );
      expect(
        l(
          const sb.AuthApiException(
            'flow state expired',
            statusCode: '400',
            code: 'flow_state_expired',
          ),
        ),
        GatewayLinkError.expired,
      );
      // ?error=server_error&error_code=unexpected_failure (the provider)
      expect(
        l(
          const sb.AuthException(
            'Unable to exchange external code',
            statusCode: 'unexpected_failure',
            code: 'server_error',
          ),
        ),
        GatewayLinkError.failed,
      );
      // Not about a link: offline refresh, an expired refresh token, anything else.
      expect(l(sb.AuthRetryableFetchException(message: 'offline')), isNull);
      expect(
        l(
          const sb.AuthApiException(
            'Invalid Refresh Token',
            statusCode: '400',
            code: 'refresh_token_not_found',
          ),
        ),
        isNull,
      );
      expect(l(StateError('x')), isNull);
    });

    test('kindOf / amrMethods: from the token; unreadable tokens are "other", never recovery', () {
      expect(SupabaseAuthGateway.kindOf(null), AuthSessionKind.none);
      expect(SupabaseAuthGateway.kindOf(oauth), AuthSessionKind.oauth);
      expect(SupabaseAuthGateway.kindOf(password), AuthSessionKind.other);
      expect(
        SupabaseAuthGateway.kindOf(sb.Session.fromJson(session(['recovery']))),
        AuthSessionKind.recovery,
      );
      expect(SupabaseAuthGateway.amrMethods(jwt(['password', 'otp'])), {
        'password',
        'otp',
      });
      for (final bad in [
        '',
        'a.b',
        'a.!!!.c',
        'x.${base64Url.encode(utf8.encode('[1]'))}.y',
      ]) {
        expect(SupabaseAuthGateway.amrMethods(bad), isEmpty, reason: bad);
      }
    });
  });

  test('withoutAuthResult: a failed callback\'s parameters go, the route and other parameters stay', () {
    expect(
      withoutAuthResult(
        'http://localhost:60550/?error=access_denied&error_code=otp_expired'
        '&error_description=Email+link+is+invalid#/login',
      ),
      'http://localhost:60550/#/login',
    );
    expect(
      withoutAuthResult('http://localhost:60550/?code=abc'),
      'http://localhost:60550/',
    );
    expect(
      withoutAuthResult('https://app.example.com/?utm=x&code=abc#/login'),
      'https://app.example.com/?utm=x#/login',
    );
    expect(
      withoutAuthResult('http://localhost:60550/#/login'),
      isNull,
      reason: 'nothing to change',
    );
    expect(withoutAuthResult('http://localhost:60550/?utm=x'), isNull);
  });

  // AUTH-05 fix: provider errors that come back without `error_code`.
  group('callback errors without error_code (live: server_error showed nothing)', () {
    GatewayLinkError? l(Object e) => SupabaseAuthGateway.linkError(e);

    /// What the SDK raises for a callback address, as getSessionFromUrl does.
    Future<Object> fromUrl(String query) async {
      try {
        await client.auth.getSessionFromUrl(
          Uri.parse('http://localhost:60550/?$query#/login'),
        );
      } catch (e) {
        return e;
      }
      fail('no error raised for ?$query');
    }

    test(
      'mapping, from the SDK\'s own errors for each callback address',
      () async {
        expect(
          l(
            await fromUrl(
              'error=server_error&error_description=Unable+to+exchange+external+code',
            ),
          ),
          GatewayLinkError.failed,
        );
        expect(
          l(
            await fromUrl(
              'error=temporarily_unavailable&error_description=Try+later',
            ),
          ),
          GatewayLinkError.failed,
        );
        expect(
          l(
            await fromUrl(
              'error=access_denied&error_description=The+user+denied+access',
            ),
          ),
          GatewayLinkError.cancelled,
        );
        expect(
          l(
            await fromUrl(
              'error=invalid_request&error_code=bad_oauth_state&error_description=OAuth+state+invalid',
            ),
          ),
          GatewayLinkError.invalid,
        );
        expect(
          l(
            await fromUrl(
              'error=invalid_request&error_description=Missing+parameter',
            ),
          ),
          GatewayLinkError.invalid,
        );
        expect(
          l(await fromUrl('error_description=Something+went+wrong')),
          GatewayLinkError.invalid,
          reason: 'no `error` at all: malformed',
        );
        expect(
          l(
            await fromUrl(
              'error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid',
            ),
          ),
          GatewayLinkError.expired,
          reason: 'unchanged: an expired email link',
        );
      },
    );

    test('session problems on the same stream are still not link errors', () {
      expect(
        l(const sb.AuthException('Session expired.', code: 'session_expired')),
        isNull,
      );
      expect(
        l(
          const sb.AuthException(
            'Current session is missing data.',
            code: 'session_missing',
          ),
        ),
        isNull,
      );
      expect(
        l(
          const sb.AuthApiException(
            'Invalid Refresh Token',
            statusCode: '400',
            code: 'refresh_token_not_found',
          ),
        ),
        isNull,
      );
      expect(l(sb.AuthRetryableFetchException(message: 'offline')), isNull);
    });

    test('end to end: a server_error callback reaches the app as GatewayLinkFailed(failed)', () async {
      final g = SupabaseAuthGateway(client.auth);
      await g.takeStartEvent();
      final seen = <AuthGatewayEvent>[];
      final sub = g.events.listen(seen.add);
      addTearDown(sub.cancel);
      final e = await fromUrl(
        'error=server_error&error_description=Unable+to+exchange+external+code',
      );
      // As supabase_flutter's deep-link handler does with it.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(e);
      await pumpEventQueue();
      expect(seen.single, isA<GatewayLinkFailed>());
      expect(
        (seen.single as GatewayLinkFailed).reason,
        GatewayLinkError.failed,
      );
    });

    test('its parameters are cleaned from the address (web)', () {
      expect(
        withoutAuthResult(
          'http://localhost:60550/?error=server_error&error_description=Unable+to+exchange+external+code#/login',
        ),
        'http://localhost:60550/#/login',
      );
      expect(
        withoutAuthResult(
          'http://localhost:60550/?error=invalid_request&error_code=bad_oauth_state#/login',
        ),
        'http://localhost:60550/#/login',
      );
    });
  });

  test('a stalled recovery request → GatewayNetworkException', () async {
    final stalled = sb.SupabaseClient(
      url,
      key,
      httpClient: MockClient((_) => Completer<http.Response>().future),
      authOptions: const sb.AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: sb.AuthFlowType.implicit,
      ),
    );
    addTearDown(stalled.dispose);
    final g = SupabaseAuthGateway(
      stalled.auth,
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(
      g.sendPasswordReset(email: 'a@example.com'),
      throwsA(isA<GatewayNetworkException>()),
    );
    await expectLater(
      g.verifyRecoveryCode(email: 'a@example.com', code: '123456'),
      throwsA(isA<GatewayNetworkException>()),
    );
  });
}
