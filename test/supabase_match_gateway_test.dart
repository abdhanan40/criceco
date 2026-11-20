// M1 P3: SupabaseMatchGateway on the real supabase_flutter client, with the
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
  late SupabaseMatchGateway gateway;

  setUp(() {
    requests.clear();
    respond = (_) =>
        http.Response('[]', 200, headers: {'content-type': 'application/json'});
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
    gateway = SupabaseMatchGateway(client);
  });
  tearDown(() => client.dispose());

  http.Response json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  /// The single request: a POST to /rest/v1/rpc/[fn] with [params] as body.
  void expectRpc(String fn, Map<String, Object?> params) {
    final r = requests.single;
    expect(r.method, 'POST');
    expect(r.url.path, '/rest/v1/rpc/$fn');
    expect(r.headers['apikey'], key);
    expect(jsonDecode(r.body), params);
    requests.clear();
  }

  group('MatchGateway requests', () {
    test(
      'every function by name, with its parameters (nulls sent as null)',
      () async {
        final row = {'id': 'x'};
        respond = (_) => json([]);
        await gateway.clubDirectory();
        expectRpc('match_club_directory', {'p_search': null, 'p_city': null});
        await gateway.clubDirectory(search: 'kings', city: 'Karachi');
        expectRpc('match_club_directory', {
          'p_search': 'kings',
          'p_city': 'Karachi',
        });
        await gateway.clubChallenges('c1');
        expectRpc('club_challenges', {'p_club_id': 'c1'});
        await gateway.clubMatches('c1');
        expectRpc('club_matches', {'p_club_id': 'c1'});
        await gateway.matchLineup('m1');
        expectRpc('match_lineup', {'p_match_id': 'm1'});
        await gateway.clubAvailability('c1');
        expectRpc('club_player_availability', {'p_club_id': 'c1'});

        respond = (_) => json(row);
        const send = {
          'p_from_club_id': 'a',
          'p_to_club_id': 'b',
          'p_format': 'custom',
          'p_custom_overs': 15,
          'p_proposed_date': '2026-11-23',
          'p_venue_name': 'V',
          'p_message': null,
        };
        expect(await gateway.sendChallenge(send), row);
        expectRpc('send_challenge', send);
        await gateway.respondToChallenge('ch1', accept: true);
        expectRpc('respond_to_challenge', {
          'p_challenge_id': 'ch1',
          'p_accept': true,
        });
        await gateway.respondToChallenge('ch1', accept: false);
        expectRpc('respond_to_challenge', {
          'p_challenge_id': 'ch1',
          'p_accept': false,
        });
        const propose = {
          'p_match_id': 'm1',
          'p_starts_at': '2026-11-24T09:30:00.000Z',
          'p_venue_name': 'V',
          'p_city': null,
        };
        await gateway.proposeSchedule(propose);
        expectRpc('propose_match_schedule', propose);
        await gateway.respondToSchedule('m1', proposalVersion: 3, accept: true);
        expectRpc('respond_to_match_schedule', {
          'p_match_id': 'm1',
          'p_proposal_version': 3,
          'p_accept': true,
        });
        await gateway.cancelMatch('m1', 'Rain');
        expectRpc('cancel_match', {'p_match_id': 'm1', 'p_reason': 'Rain'});
        final lineup = {
          'p_match_id': 'm1',
          'p_name': 'XI',
          'p_source_team_id': null,
          'p_players': [
            {'member_id': 'p1', 'selection': 'playing'},
          ],
          'p_captain_member_id': null,
          'p_vice_member_id': null,
        };
        await gateway.saveLineup(lineup);
        expectRpc('save_match_lineup', lineup);
        const avail = {
          'p_status': 'injured',
          'p_reason': 'injury',
          'p_until_date': null,
          'p_notes': null,
        };
        await gateway.setMyAvailability(avail);
        expectRpc('set_my_availability', avail);
      },
    );

    test('my_availability: a set-returning function — first row, or null when empty', () async {
      respond = (_) => json([
        {'user_id': 'u', 'status': 'limited'},
      ]);
      expect((await gateway.myAvailability())!['status'], 'limited');
      expect(requests.single.url.path, '/rest/v1/rpc/my_availability');
      respond = (_) => json([]);
      expect(await gateway.myAvailability(), isNull);
    });

    test('a list response tolerates null and non-object entries', () async {
      respond = (_) => json(null);
      expect(await gateway.clubMatches('c1'), isEmpty);
      respond = (_) => json([
        1,
        'x',
        {'match_id': 'm'},
      ]);
      expect(await gateway.clubMatches('c1'), [
        {'match_id': 'm'},
      ]);
    });

    test(
      'a write function without a row → unexpected (never an empty success)',
      () async {
        respond = (_) => json(null);
        await expectLater(
          gateway.cancelMatch('m1', 'Rain'),
          throwsA(
            isA<GatewayUnexpectedException>().having(
              (e) => e.detail,
              'detail',
              'cancel_match-no-row',
            ),
          ),
        );
      },
    );
  });

  group('MatchGateway errors', () {
    test(
      'a function refusal keeps its SQLSTATE and message (prefix intact)',
      () async {
        respond = (_) => json({
          'code': '23505',
          'message': 'challenge: already pending',
        }, 409);
        final e = await gateway
            .sendChallenge(const {})
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(e, isA<GatewayConstraintException>());
        expect((e as GatewayConstraintException).sqlState, '23505');
        expect(e.message, 'challenge: already pending');
      },
    );

    test('42501 stays a refusal (not a lost session); JWT problems are a lost session', () async {
      respond = (_) =>
          json({'code': '42501', 'message': 'match: not allowed'}, 403);
      final refusal = await gateway
          .clubMatches('c1')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        refusal,
        isA<GatewayConstraintException>().having(
          (e) => e.sqlState,
          'sqlState',
          '42501',
        ),
      );
      respond = (_) =>
          json({'code': 'PGRST301', 'message': 'JWT expired'}, 401);
      final lost = await gateway
          .clubMatches('c1')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(lost, isA<GatewayPermissionException>());
    });

    test('5xx and a dropped connection → network', () async {
      respond = (_) => http.Response('down', 503);
      final down = await gateway
          .clubChallenges('c1')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(down, isA<GatewayNetworkException>());
      respond = (_) => throw http.ClientException('connection reset');
      final reset = await gateway.myAvailability().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect(reset, isA<GatewayNetworkException>());
    });
  });
}
