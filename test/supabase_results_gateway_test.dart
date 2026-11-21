// M2 P3: SupabaseResultsGateway on the real supabase_flutter client, with the
// HTTP layer faked — RPC names, parameters and error translation. No live
// project, no credentials.
import 'dart:convert';

import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

void main() {
  const url = 'https://abcdefghijklmnop.supabase.co';
  const key = 'sb_publishable_test_0000000000000000';

  final requests = <http.Request>[];
  late http.Response Function(http.Request) respond;
  late sb.SupabaseClient client;
  late SupabaseResultsGateway gateway;

  http.Response json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  setUp(() {
    requests.clear();
    respond = (_) => json([]);
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
    gateway = SupabaseResultsGateway(client);
  });
  tearDown(() => client.dispose());

  /// The single request: a POST to /rest/v1/rpc/[fn] with [params] as body.
  void expectRpc(String fn, Map<String, Object?> params) {
    final r = requests.single;
    expect(r.method, 'POST');
    expect(r.url.path, '/rest/v1/rpc/$fn');
    expect(r.headers['apikey'], key);
    expect(jsonDecode(r.body), params);
    requests.clear();
  }

  Future<Object?> errorOf(Future<Object?> call) =>
      call.then<Object?>((_) => null, onError: (Object e) => e);

  group('ResultsGateway requests', () {
    test(
      'every READ function by name, with its parameters (nulls sent as null)',
      () async {
        final row = {'played': 1};
        respond = (_) => json([row]);
        await gateway.clubRecord('c1');
        expectRpc('club_record', {'p_club_id': 'c1'});
        await gateway.playerStats();
        expectRpc('player_stats', {'p_user_id': null});
        await gateway.playerStats(userId: 'u2');
        expectRpc('player_stats', {'p_user_id': 'u2'});

        respond = (_) => json([]);
        await gateway.matchResult('m1');
        expectRpc('match_result', {'p_match_id': 'm1'});
        await gateway.clubResults('c1');
        expectRpc('club_results', {'p_club_id': 'c1'});
        await gateway.scorecard('m1');
        expectRpc('match_scorecard', {'p_match_id': 'm1', 'p_version': null});
        await gateway.scorecard('m1', version: 3);
        expectRpc('match_scorecard', {'p_match_id': 'm1', 'p_version': 3});
        await gateway.clubMemberStats('c1');
        expectRpc('club_member_stats', {'p_club_id': 'c1'});
        await gateway.playerMatchLog();
        expectRpc('player_match_log', {'p_user_id': null, 'p_limit': 50});
        await gateway.playerMatchLog(userId: 'u2', limit: 10);
        expectRpc('player_match_log', {'p_user_id': 'u2', 'p_limit': 10});
        await gateway.myMatches();
        expectRpc('my_matches', {});
      },
    );

    test(
      'club_record / player_stats are set-returning: the first row',
      () async {
        respond = (_) => json([
          {'played': 3},
          {'played': 9},
        ]);
        expect((await gateway.clubRecord('c1'))['played'], 3);
        expect((await gateway.playerStats())['played'], 3);
      },
    );

    test('a one-row read without a row is an unexpected response', () async {
      respond = (_) => json([]);
      expect(
        await errorOf(gateway.clubRecord('c1')),
        isA<GatewayUnexpectedException>(),
      );
    });

    test('list responses keep only object rows', () async {
      respond = (_) => json([
        {'version': 1},
        null,
        7,
        {'version': 2},
      ]);
      expect((await gateway.matchResult('m1')).map((r) => r['version']), [
        1,
        2,
      ]);
    });
  });

  group('ResultsGateway errors', () {
    test('a function refusal keeps its SQLSTATE and message', () async {
      respond = (_) =>
          json({'code': 'P0001', 'message': 'result: version changed'}, 400);
      final e = await errorOf(gateway.clubRecord('c1'));
      expect(e, isA<GatewayConstraintException>());
      expect((e as GatewayConstraintException).sqlState, 'P0001');
      expect(e.message, 'result: version changed');
    });

    test('42501 stays a refusal; JWT problems are a lost session', () async {
      respond = (_) =>
          json({'code': '42501', 'message': 'stats: not allowed'}, 403);
      expect(
        await errorOf(gateway.playerStats(userId: 'u2')),
        isA<GatewayConstraintException>().having(
          (e) => e.sqlState,
          'sqlState',
          '42501',
        ),
      );
      respond = (_) =>
          json({'code': 'PGRST301', 'message': 'JWT expired'}, 401);
      expect(
        await errorOf(gateway.myMatches()),
        isA<GatewayPermissionException>(),
      );
    });

    test('5xx and a dropped connection → network', () async {
      respond = (_) => http.Response('down', 503);
      expect(
        await errorOf(gateway.scorecard('m1')),
        isA<GatewayNetworkException>(),
      );
      respond = (_) => throw http.ClientException('connection reset');
      expect(
        await errorOf(gateway.clubResults('c1')),
        isA<GatewayNetworkException>(),
      );
    });
  });
}
