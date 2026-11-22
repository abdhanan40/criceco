// M3 P2: SupabaseNotificationsGateway on the real supabase_flutter client,
// with the HTTP layer faked — RPC names, parameters, integer results and
// error translation. No live project, no credentials.
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
  late SupabaseNotificationsGateway gateway;

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
    gateway = SupabaseNotificationsGateway(client);
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

  group('NotificationsGateway requests', () {
    test(
      'every function by name, with its parameters (nulls sent as null)',
      () async {
        respond = (_) => json([]);
        await gateway.myNotifications({
          'p_inbox': 'player',
          'p_before': null,
          'p_before_id': null,
          'p_limit': 30,
        });
        expectRpc('my_notifications', {
          'p_inbox': 'player',
          'p_before': null,
          'p_before_id': null,
          'p_limit': 30,
        });
        await gateway.announcement('ann-1');
        expectRpc('club_announcement', {'p_announcement_id': 'ann-1'});
        await gateway.clubAnnouncements('club-a');
        expectRpc('club_announcement_list', {
          'p_club_id': 'club-a',
          'p_limit': 50,
        });

        // Preferences (migration 26): set-returning, the first row.
        respond = (_) => json([
          {'matches': false},
        ]);
        expect((await gateway.myPreferences())['matches'], isFalse);
        expectRpc('my_notification_preferences', {});
        await gateway.setPreferences({
          'p_join_requests': true,
          'p_challenges': true,
          'p_matches': false,
          'p_results': true,
          'p_announcements': true,
        });
        expectRpc('set_notification_preferences', {
          'p_join_requests': true,
          'p_challenges': true,
          'p_matches': false,
          'p_results': true,
          'p_announcements': true,
        });
        respond = (_) => json([]);
        expect(
          await errorOf(gateway.myPreferences()),
          isA<GatewayUnexpectedException>(),
        );
        requests.clear();

        respond = (_) => json(3);
        expect(await gateway.unreadCount('club_owner'), 3);
        expectRpc('notification_unread_count', {'p_inbox': 'club_owner'});
        expect(await gateway.markRead(['a', 'b']), 3);
        expectRpc('mark_notifications_read', {
          'p_ids': ['a', 'b'],
        });
        expect(
          await gateway.markAllRead(
            'player',
            upTo: '2026-11-22T10:00:00.123456+00:00',
          ),
          3,
        );
        expectRpc('mark_all_notifications_read', {
          'p_inbox': 'player',
          'p_up_to': '2026-11-22T10:00:00.123456+00:00',
        });
        await gateway.markAllRead('player');
        expectRpc('mark_all_notifications_read', {
          'p_inbox': 'player',
          'p_up_to': null,
        });

        respond = (_) => json([
          {'announcement_id': 'ann-2', 'recipient_count': 15},
        ]);
        final p = await gateway.publishAnnouncement({
          'p_club_id': 'c',
          'p_title': 't',
          'p_message': 'm',
          'p_audience': 'all',
        });
        expect(p['announcement_id'], 'ann-2');
        expectRpc('publish_club_announcement', {
          'p_club_id': 'c',
          'p_title': 't',
          'p_message': 'm',
          'p_audience': 'all',
        });
      },
    );

    test(
      'an integer result that is not an integer is an unexpected response',
      () async {
        for (final body in [
          null,
          'three',
          2.5,
          [1],
        ]) {
          respond = (_) => json(body);
          expect(
            await errorOf(gateway.unreadCount('player')),
            isA<GatewayUnexpectedException>(),
            reason: '$body',
          );
        }
      },
    );

    test('publishing without a row is an unexpected response', () async {
      respond = (_) => json([]);
      expect(
        await errorOf(
          gateway.publishAnnouncement({
            'p_club_id': 'c',
            'p_title': 't',
            'p_message': 'm',
            'p_audience': 'all',
          }),
        ),
        isA<GatewayUnexpectedException>(),
      );
    });

    test('list responses keep only object rows', () async {
      respond = (_) => json([
        {'notification_id': 'a'},
        null,
        7,
        {'notification_id': 'b'},
      ]);
      expect(
        (await gateway.myNotifications(const {}))
            .map((r) => r['notification_id']),
        ['a', 'b'],
      );
    });
  });

  group('NotificationsGateway errors', () {
    test('a function refusal keeps its SQLSTATE and message', () async {
      respond = (_) =>
          json({'code': 'P0001', 'message': 'announcement: too many'}, 400);
      final e = await errorOf(gateway.publishAnnouncement(const {}));
      expect(e, isA<GatewayConstraintException>());
      expect((e as GatewayConstraintException).sqlState, 'P0001');
      expect(e.message, 'announcement: too many');
    });

    test(
      'JWT problems are a lost session; 5xx and a dropped connection → network',
      () async {
        respond = (_) =>
            json({'code': 'PGRST301', 'message': 'JWT expired'}, 401);
        expect(
          await errorOf(gateway.unreadCount('player')),
          isA<GatewayPermissionException>(),
        );
        respond = (_) => http.Response('down', 503);
        expect(
          await errorOf(gateway.markRead(['a'])),
          isA<GatewayNetworkException>(),
        );
        respond = (_) => throw http.ClientException('connection reset');
        expect(
          await errorOf(gateway.myNotifications(const {})),
          isA<GatewayNetworkException>(),
        );
      },
    );
  });
}
