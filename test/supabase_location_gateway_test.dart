import 'dart:convert';

import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Stage 4.2: [SupabaseLocationGateway] on the real `supabase_flutter`
/// client, with the HTTP layer faked — no live project, no credentials.
void main() {
  const url = 'https://abcdefghijklmnop.supabase.co';
  const key = 'sb_publishable_test_0000000000000000';

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

  test(
    'provinces: active only, in display order, the needed columns',
    () async {
      respond = (_) => json([
        {
          'id': 1,
          'name': 'Punjab',
          'display_name': null,
          'kind': 'province',
          'sort_order': 1,
        },
      ]);
      final rows = await SupabaseLocationGateway(client).fetchProvinces();
      final r = requests.single;
      expect((r.method, r.url.path), ('GET', '/rest/v1/provinces'));
      expect(
        r.url.queryParameters['select']!.replaceAll(' ', ''),
        'id,name,display_name,kind,sort_order',
      );
      expect(r.url.queryParameters['is_active'], 'eq.true');
      expect(r.url.queryParameters['order'], 'sort_order.asc.nullslast');
      expect(r.headers['apikey'], key);
      expect(rows.single['name'], 'Punjab');
    },
  );

  test('districts: one province, active, by name', () async {
    await SupabaseLocationGateway(client).fetchDistricts(4);
    final r = requests.single;
    expect(r.url.path, '/rest/v1/districts');
    expect(r.url.queryParameters['province_id'], 'eq.4');
    expect(r.url.queryParameters['is_active'], 'eq.true');
    expect(r.url.queryParameters['order'], 'name.asc.nullslast');
  });

  test('searchCities: POST rpc/search_cities with the parameters', () async {
    respond = (_) => json([
      {'id': 2, 'name': 'Lahore'},
    ]);
    final rows = await SupabaseLocationGateway(client).searchCities({
      'p_query': 'lah',
      'p_province': null,
      'p_district': null,
      'p_limit': 20,
    });
    final r = requests.single;
    expect((r.method, r.url.path), ('POST', '/rest/v1/rpc/search_cities'));
    expect(jsonDecode(r.body), {
      'p_query': 'lah',
      'p_province': null,
      'p_district': null,
      'p_limit': 20,
    });
    expect(rows.single['name'], 'Lahore');
  });

  test('fetchCity: v_city_options by id; none → null', () async {
    respond = (_) => json([
      {'id': 2, 'name': 'Lahore'},
    ]);
    expect(
      (await SupabaseLocationGateway(client).fetchCity(2))!['name'],
      'Lahore',
    );
    expect(requests.single.url.path, '/rest/v1/v_city_options');
    expect(requests.single.url.queryParameters['id'], 'eq.2');
    respond = (_) => json(<Object>[]);
    expect(await SupabaseLocationGateway(client).fetchCity(3), isNull);
  });

  test('errors become gateway exceptions', () async {
    respond = (_) => json({
      'code': '42501',
      'message': 'permission denied for table cities',
    }, 403);
    await expectLater(
      SupabaseLocationGateway(client).fetchProvinces(),
      throwsA(isA<GatewayException>()),
    );
    respond = (_) => throw http.ClientException('offline');
    await expectLater(
      SupabaseLocationGateway(client).searchCities(const {}),
      throwsA(isA<GatewayNetworkException>()),
    );
  });
}
