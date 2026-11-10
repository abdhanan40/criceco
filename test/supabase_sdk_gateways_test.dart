import 'dart:async';
import 'dart:convert';

import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Phase 2 Step 4: the real gateways on the real `supabase_flutter` client,
/// with the HTTP layer faked — no live project, no credentials.
void main() {
  const url = 'https://abcdefghijklmnop.supabase.co';
  const key = 'sb_publishable_test_0000000000000000';
  const uid = '00000000-0000-4000-8000-000000000001';

  final requests = <http.Request>[];
  late http.Response Function(http.Request) respond;
  late sb.SupabaseClient client;

  setUp(() {
    requests.clear();
    respond = (_) => http.Response('[]', 200);
    client = sb.SupabaseClient(
      url,
      key,
      httpClient: MockClient((r) async {
        requests.add(r);
        final res = respond(r);
        // Real responses carry their request (postgrest reads it).
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

  group('ProfileGateway requests', () {
    test(
      'fetchAccountRows: one embedded select on the own profile id',
      () async {
        respond = (_) => json([
          {
            'id': uid,
            'full_name': 'Hamza Sheikh',
            'phone': '+923001234567',
            'current_addresses': {
              'user_id': uid,
              'city': 'Lahore',
              'area': 'Gulberg',
              'address': 'House 1',
            },
            'permanent_addresses': [
              {
                'user_id': uid,
                'city': 'Multan',
                'area': 'Cantt',
                'address': 'Street 9',
              },
            ],
            'player_profiles': null,
          },
        ]);
        final rows = await SupabaseProfileGateway(client).fetchAccountRows(uid);
        final r = requests.single;
        expect(r.method, 'GET');
        expect(r.url.path, '/rest/v1/profiles');
        expect(r.url.queryParameters['id'], 'eq.$uid');
        expect(
          r.url.queryParameters['select']!.replaceAll(' ', ''),
          '*,current_addresses(*),permanent_addresses(*),player_profiles(*)',
        );
        expect(r.headers['apikey'], key); // the publishable key, nothing else
        expect(rows!.profile['full_name'], 'Hamza Sheikh');
        expect(rows.profile.containsKey('current_addresses'), isFalse);
        expect(rows.currentAddress!['city'], 'Lahore'); // object form
        expect(rows.permanentAddress!['city'], 'Multan'); // list form tolerated
        expect(rows.playerProfile, isNull);
      },
    );

    test('fetchAccountRows: no row → null', () async {
      respond = (_) => json([]);
      expect(
        await SupabaseProfileGateway(client).fetchAccountRows(uid),
        isNull,
      );
    });

    test('saveProfileSetup calls the save_profile_setup function with the parameters', () async {
      respond = (_) => http.Response('', 204);
      final params = {
        'p_full_name': 'Hamza Sheikh',
        'p_phone': '+923001234567',
      };
      await SupabaseProfileGateway(client).saveProfileSetup(params);
      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rest/v1/rpc/save_profile_setup');
      expect(jsonDecode(r.body), params);
    });

    test('upsertPlayerProfile upserts on user_id', () async {
      respond = (_) => http.Response('', 201);
      await SupabaseProfileGateway(client)
          .upsertPlayerProfile({'user_id': uid, 'player_role': 'batsman'});
      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rest/v1/player_profiles');
      expect(r.url.queryParameters['on_conflict'], 'user_id');
      expect(r.headers['Prefer'], contains('resolution=merge-duplicates'));
    });

    test('setRoleIfUnset only updates where role is null', () async {
      respond = (_) => http.Response('', 204);
      await SupabaseProfileGateway(client).setRoleIfUnset(uid, 'player');
      final r = requests.single;
      expect(r.method, 'PATCH');
      expect(r.url.path, '/rest/v1/profiles');
      expect(r.url.queryParameters['id'], 'eq.$uid');
      expect(r.url.queryParameters['role'], 'is.null');
      expect(jsonDecode(r.body), {'role': 'player'});
    });

    test(
      'setRoleUnlessClubOwner: own row, only where role is NULL or player',
      () async {
        respond = (_) => http.Response('', 204);
        await SupabaseProfileGateway(client)
            .setRoleUnlessClubOwner(uid, 'club_owner');
        final r = requests.single;
        expect(r.method, 'PATCH');
        expect(r.url.path, '/rest/v1/profiles');
        expect(r.url.queryParameters['id'], 'eq.$uid');
        expect(r.url.queryParameters['or'], '(role.is.null,role.eq.player)');
        expect(r.url.queryParameters.keys.toSet(), {
          'id',
          'or',
        }, reason: 'no other filter, no other row');
        expect(jsonDecode(r.body), {'role': 'club_owner'});
      },
    );

    test(
      'updateProfileColumns / updateAddress target the own rows only',
      () async {
        respond = (_) => http.Response('', 204);
        final g = SupabaseProfileGateway(client);
        await g.updateProfileColumns(uid, {'phone': '+923331112223'});
        await g.updateAddress('current_addresses', uid, {'city': 'Karachi'});
        expect(
          requests.map((r) => '${r.method} ${r.url.path} ${r.url.query}'),
          [
            'PATCH /rest/v1/profiles id=eq.$uid',
            'PATCH /rest/v1/current_addresses user_id=eq.$uid',
          ],
        );
      },
    );

    test('updateAddress refuses any other table, before a request', () {
      expect(
        () =>
            SupabaseProfileGateway(client)
                .updateAddress('profiles', uid, {'role': 'club_owner'}),
        throwsArgumentError,
      );
      expect(requests, isEmpty);
    });
  });

  group('ProfileGateway errors', () {
    Future<Object?> failure(http.Response Function(http.Request) r) async {
      respond = r;
      try {
        await SupabaseProfileGateway(client).saveProfileSetup({});
      } catch (e) {
        return e;
      }
      return null;
    }

    test(
      'a CHECK refusal keeps the SQLSTATE and the database message',
      () async {
        final e = await failure(
          (_) => json({
            'code': '23514',
            'message': 'phone must be a Pakistani mobile number',
            'details': null,
            'hint': null,
          }, 400),
        );
        expect(e, isA<GatewayConstraintException>());
        final c = e as GatewayConstraintException;
        expect(c.sqlState, '23514');
        expect(c.message, 'phone must be a Pakistani mobile number');
      },
    );

    test('JWT problems → permission (a lost session)', () async {
      for (final code in ['PGRST301', 'PGRST302', 'PGRST303']) {
        expect(
          await failure((_) => json({'code': code, 'message': 'JWT'}, 401)),
          isA<GatewayPermissionException>(),
          reason: code,
        );
      }
    });

    test('42501 keeps its SQLSTATE and message (not a lost session)', () async {
      final e = await failure(
        (_) => json({
          'code': '42501',
          'message': 'new row violates row-level security policy',
        }, 403),
      );
      expect(e, isA<GatewayConstraintException>());
      final c = e as GatewayConstraintException;
      expect(c.sqlState, '42501');
      expect(c.message, 'new row violates row-level security policy');
    });

    test('5xx → network; a dropped connection → network', () async {
      expect(
        await failure((_) => http.Response('Service Unavailable', 503)),
        isA<GatewayNetworkException>(),
      );
      expect(
        await failure((_) => throw http.ClientException('Connection closed')),
        isA<GatewayNetworkException>(),
      );
    });

    test('anything else → unexpected, with a short code only', () async {
      final e = await failure(
        (_) => json({
          'code': 'PGRST202',
          'message': 'function not found: secret detail',
        }, 404),
      );
      expect(e, isA<GatewayUnexpectedException>());
      expect(
        (e as GatewayUnexpectedException).detail,
        isNot(contains('secret')),
      );
    });
  });

  group('ClubGateway requests (Stage 3A)', () {
    const clubId = 'c1a1b2c3-0000-4000-8000-000000000001';
    Map<String, Object?> clubRow() => {
      'id': clubId,
      'owner_id': uid,
      'name': 'Lahore Lions CC',
      'short_name': null,
      'city': 'Lahore',
      'club_type': 'corporate',
      'code': 'K7MQ2X',
      'owner_name': 'Hamza Sheikh',
      'address': null,
      'email': null,
      'home_ground_id': null,
      'established_year': 2026,
    };

    test('fetchOwnClub: one select on the own owner_id', () async {
      respond = (_) => json([clubRow()]);
      final row = await SupabaseClubGateway(client).fetchOwnClub(uid);
      final r = requests.single;
      expect(r.method, 'GET');
      expect(r.url.path, '/rest/v1/clubs');
      expect(r.url.queryParameters['owner_id'], 'eq.$uid');
      expect(r.url.queryParameters['select'], '*');
      expect(r.url.queryParameters.keys.toSet(), {'owner_id', 'select'});
      expect(r.headers['apikey'], key);
      expect(row!['code'], 'K7MQ2X');
    });

    test('fetchOwnClub: no club → null', () async {
      respond = (_) => json([]);
      expect(await SupabaseClubGateway(client).fetchOwnClub(uid), isNull);
    });

    test('createClub calls create_club with the parameters', () async {
      respond = (_) => json(clubRow());
      final params = {
        'p_name': 'Lahore Lions CC',
        'p_city': 'Lahore',
        'p_club_type': 'corporate',
        'p_owner_name': 'Hamza Sheikh',
        'p_address': null,
        'p_email': null,
        'p_home_ground_id': null,
      };
      final row = await SupabaseClubGateway(client).createClub(params);
      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rest/v1/rpc/create_club');
      expect(jsonDecode(r.body), params);
      expect((row['id'], row['code']), (clubId, 'K7MQ2X'));
    });

    test(
      'createClub: a one-element list is accepted; no row is an error',
      () async {
        respond = (_) => json([clubRow()]);
        expect(
          (await SupabaseClubGateway(client).createClub(const {}))['id'],
          clubId,
        );
        respond = (_) => json([]);
        await expectLater(
          SupabaseClubGateway(client).createClub(const {}),
          throwsA(isA<GatewayUnexpectedException>()),
        );
      },
    );

    test('updateClub: own row only (id and owner_id), only the columns, returns the row', () async {
      respond = (_) => json([
        {...clubRow(), 'city': 'Karachi'},
      ]);
      final row = await SupabaseClubGateway(client)
          .updateClub(clubId, uid, {'city': 'Karachi', 'email': null});
      final r = requests.single;
      expect(r.method, 'PATCH');
      expect(r.url.path, '/rest/v1/clubs');
      expect(r.url.queryParameters['id'], 'eq.$clubId');
      expect(r.url.queryParameters['owner_id'], 'eq.$uid');
      expect(r.url.queryParameters.keys.toSet(), {'id', 'owner_id', 'select'});
      expect(jsonDecode(r.body), {'city': 'Karachi', 'email': null});
      expect(r.headers['Prefer'], contains('return=representation'));
      expect(row!['city'], 'Karachi');
    });

    test(
      'updateClub: no row updated (not the caller\'s club) → null',
      () async {
        respond = (_) => json([]);
        expect(
          await SupabaseClubGateway(client)
              .updateClub(clubId, uid, const {'city': 'Karachi'}),
          isNull,
        );
      },
    );
  });

  group('ClubGateway errors', () {
    Future<Object?> failure(http.Response Function(http.Request) r) async {
      respond = r;
      try {
        await SupabaseClubGateway(client).createClub(const {});
      } catch (e) {
        return e;
      }
      return null;
    }

    test('a CHECK refusal keeps its SQLSTATE and constraint text', () async {
      final e = await failure(
        (_) => json({
          'code': '23514',
          'message': 'new row for relation "clubs" violates check constraint "clubs_email_check"',
        }, 400),
      );
      expect(e, isA<GatewayConstraintException>());
      expect((e as GatewayConstraintException).sqlState, '23514');
      expect(e.message, contains('clubs_email_check'));
    });

    test('create_club\'s own refusals keep their message', () async {
      final e = await failure(
        (_) => json({
          'code': '23514',
          'message': 'profile_completed requires a completed User Profile Setup before creating a club',
        }, 400),
      );
      expect(
        (e as GatewayConstraintException).message,
        startsWith('profile_completed requires'),
      );
    });

    test('42501 stays a refusal; JWT problems are a lost session', () async {
      expect(
        await failure(
          (_) => json({'code': '42501', 'message': 'not authenticated'}, 403),
        ),
        isA<GatewayConstraintException>().having(
          (e) => e.sqlState,
          'sqlState',
          '42501',
        ),
      );
      expect(
        await failure(
          (_) => json({'code': 'PGRST303', 'message': 'JWT expired'}, 401),
        ),
        isA<GatewayPermissionException>(),
      );
    });

    test('5xx and a dropped connection → network', () async {
      expect(
        await failure((_) => http.Response('Bad Gateway', 502)),
        isA<GatewayNetworkException>(),
      );
      expect(
        await failure((_) => throw http.ClientException('Connection reset')),
        isA<GatewayNetworkException>(),
      );
    });
  });

  group('AuthGateway requests', () {
    Map<String, Object?> userJson([Map<String, Object?> meta = const {}]) => {
      'id': uid,
      'aud': 'authenticated',
      'email': 'a@example.com',
      'app_metadata': <String, Object?>{},
      'user_metadata': meta,
      'created_at': '2026-10-29T10:00:00Z',
    };
    // Not a real token: an opaque string the SDK just stores.
    Map<String, Object?> sessionJson([Map<String, Object?> meta = const {}]) =>
        {
          'access_token': 'test-access-token',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'test-refresh-token',
          'user': userJson(meta),
        };

    test('signUp with a session: signed in, metadata sent and kept', () async {
      respond = (_) => json(sessionJson({'full_name': 'Hamza Sheikh'}));
      final g = SupabaseAuthGateway(client.auth);
      final r = await g.signUp(
        email: 'a@example.com',
        password: 'Cricket@123',
        metadata: {'full_name': 'Hamza Sheikh'},
      );
      expect(r.hasSession, isTrue);
      expect(r.user.id, uid);
      expect(r.user.metadata['full_name'], 'Hamza Sheikh');
      expect(g.currentUser!.id, uid);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/auth/v1/signup');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['email'], 'a@example.com');
      expect(body['data'], {'full_name': 'Hamza Sheikh'});
    });

    test('signUp needing email confirmation: a user, no session', () async {
      respond = (_) => json(userJson());
      final g = SupabaseAuthGateway(client.auth);
      final r = await g.signUp(
        email: 'a@example.com',
        password: 'Cricket@123',
        metadata: {'full_name': ''},
      );
      expect(r.hasSession, isFalse);
      expect(r.user.id, uid);
      expect(g.currentUser, isNull, reason: 'not signed in until confirmed');
    });

    test('signInWithPassword: the user, now the current user', () async {
      respond = (_) => json(sessionJson({'full_name': 'Ali Raza'}));
      final g = SupabaseAuthGateway(client.auth);
      final user = await g.signInWithPassword(
        email: 'a@example.com',
        password: 'Cricket@123',
      );
      expect(user!.id, uid);
      expect(user.metadata['full_name'], 'Ali Raza');
      expect(g.currentUser!.id, uid);
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(
        (body['email'], body['password']),
        ('a@example.com', 'Cricket@123'),
      );
    });

    test('signOut offline: the local session ends anyway', () async {
      respond = (_) => json(sessionJson());
      final g = SupabaseAuthGateway(client.auth);
      await g.signInWithPassword(email: 'a@example.com', password: 'x');
      expect(g.currentUser, isNotNull);
      respond = (_) => throw http.ClientException('Failed host lookup');
      // GoTrue drops the local session first, then reports the failed
      // server call (translated: never a raw SDK error).
      await expectLater(g.signOut(), throwsA(isA<GatewayNetworkException>()));
      expect(g.currentUser, isNull);
      expect(requests.last.url.path, '/auth/v1/logout');
    });
  });

  group('timeouts (M2)', () {
    late sb.SupabaseClient stalled;

    setUp(() {
      // Every request hangs: a connection that never answers.
      stalled = sb.SupabaseClient(
        url,
        key,
        httpClient: MockClient((_) => Completer<http.Response>().future),
        authOptions: const sb.AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: sb.AuthFlowType.implicit,
        ),
      );
    });
    tearDown(() => stalled.dispose());

    const short = Duration(milliseconds: 50);

    test('the default is 20 seconds for both gateways', () {
      expect(kGatewayTimeout, const Duration(seconds: 20));
      expect(SupabaseAuthGateway(client.auth).timeout, kGatewayTimeout);
      expect(SupabaseProfileGateway(client).timeout, kGatewayTimeout);
    });

    test('a stalled sign-in → GatewayNetworkException', () async {
      await expectLater(
        SupabaseAuthGateway(
          stalled.auth,
          timeout: short,
        ).signInWithPassword(email: 'a@example.com', password: 'x'),
        throwsA(isA<GatewayNetworkException>()),
      );
    });

    test('a stalled sign-up → GatewayNetworkException', () async {
      await expectLater(
        SupabaseAuthGateway(stalled.auth, timeout: short).signUp(
          email: 'a@example.com',
          password: 'Cricket@123',
          metadata: const {},
        ),
        throwsA(isA<GatewayNetworkException>()),
      );
    });

    test('stalled database calls → GatewayNetworkException', () async {
      final g = SupabaseProfileGateway(stalled, timeout: short);
      await expectLater(
        g.fetchAccountRows(uid),
        throwsA(isA<GatewayNetworkException>()),
      );
      await expectLater(
        g.saveProfileSetup(const {}),
        throwsA(isA<GatewayNetworkException>()),
      );
      await expectLater(
        g.upsertPlayerProfile({'user_id': uid}),
        throwsA(isA<GatewayNetworkException>()),
      );
    });

    test('stalled club calls → GatewayNetworkException', () async {
      final g = SupabaseClubGateway(stalled, timeout: short);
      expect(SupabaseClubGateway(client).timeout, kGatewayTimeout);
      await expectLater(
        g.fetchOwnClub(uid),
        throwsA(isA<GatewayNetworkException>()),
      );
      await expectLater(
        g.createClub(const {}),
        throwsA(isA<GatewayNetworkException>()),
      );
      await expectLater(
        g.updateClub('club-1', uid, const {'city': 'Karachi'}),
        throwsA(isA<GatewayNetworkException>()),
      );
    });

    test('a timeout reaches the screens as "couldn\'t reach the server"', () {
      expect(
        SupabaseErrorMapper.map(const GatewayNetworkException()),
        isA<BackendUnavailableException>(),
      );
    });
  });

  group('AuthGateway', () {
    test('signed out: no current user', () {
      expect(SupabaseAuthGateway(client.auth).currentUser, isNull);
    });

    test('wrong email or password → null (not an error)', () async {
      respond = (_) => json({
        'error_code': 'invalid_credentials',
        'msg': 'Invalid login credentials',
      }, 400);
      final user = await SupabaseAuthGateway(client.auth)
          .signInWithPassword(email: 'a@example.com', password: 'x');
      expect(user, isNull);
      final r = requests.single;
      expect(r.url.path, '/auth/v1/token');
      expect(r.url.queryParameters['grant_type'], 'password');
    });

    test('unconfirmed email → GatewayEmailNotConfirmedException', () async {
      respond = (_) => json({
        'error_code': 'email_not_confirmed',
        'msg': 'Email not confirmed',
      }, 400);
      await expectLater(
        SupabaseAuthGateway(client.auth)
            .signInWithPassword(email: 'a@example.com', password: 'x'),
        throwsA(isA<GatewayEmailNotConfirmedException>()),
      );
    });

    test('no connection → GatewayNetworkException', () async {
      respond = (_) => throw http.ClientException('Failed host lookup');
      await expectLater(
        SupabaseAuthGateway(client.auth)
            .signInWithPassword(email: 'a@example.com', password: 'x'),
        throwsA(isA<GatewayNetworkException>()),
      );
    });

    test('translate: Auth error codes → gateway errors', () {
      GatewayException t(sb.AuthException e) =>
          SupabaseAuthGateway.translate(e);
      expect(
        t(
          const sb.AuthApiException(
            'exists',
            statusCode: '422',
            code: 'user_already_exists',
          ),
        ),
        isA<GatewayConstraintException>().having(
          (e) => e.message,
          'message',
          'user already exists',
        ),
      );
      expect(
        t(
          sb.AuthWeakPasswordException(
            message: 'weak',
            statusCode: '422',
            reasons: const ['length'],
          ),
        ),
        isA<GatewayConstraintException>().having(
          (e) => e.message,
          'message',
          'weak password',
        ),
      );
      expect(
        t(const sb.AuthApiException('expired', statusCode: '401')),
        isA<GatewayPermissionException>(),
      );
      expect(
        t(sb.AuthSessionMissingException()),
        isA<GatewayPermissionException>(),
      );
      expect(
        t(const sb.AuthApiException('down', statusCode: '502')),
        isA<GatewayNetworkException>(),
      );
      expect(
        t(const sb.AuthApiException('?', statusCode: '418', code: 'teapot')),
        isA<GatewayUnexpectedException>(),
      );
    });
  });
}
