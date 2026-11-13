import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/core/constants/cities.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_location_repository.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/location_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_location_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stage 4.2: the read-only location lookup (not yet used by any screen).

Map<String, dynamic> cityRow(
  int id,
  String name, {
  int? rank,
  String? qualifier,
  String? district,
  String province = 'Punjab',
}) => {
  'id': id,
  'name': name,
  'qualifier': qualifier,
  'kind': 'city',
  'featured_rank': rank,
  'search_key': name.toLowerCase(),
  'province_id': 1,
  'province_name': province,
  'primary_district_id': district == null ? null : 10,
  'primary_district_name': district,
  'district_count': district == null ? 0 : 1,
  'latitude': 31.5,
  'longitude': 74.3,
};

class FakeLocationDb implements LocationGateway {
  final calls = <String>[];
  final params = <Map<String, Object?>>[];
  GatewayException? failNext;
  List<Map<String, dynamic>> provinces = [
    {
      'id': 1,
      'name': 'Punjab',
      'display_name': null,
      'kind': 'province',
      'sort_order': 1,
    },
    {
      'id': 7,
      'name': 'Azad Jammu and Kashmir',
      'display_name': 'Azad Jammu and Kashmir',
      'kind': 'administrative_territory',
      'sort_order': 7,
    },
  ];
  List<Map<String, dynamic>> featured = [
    cityRow(1, 'Karachi', rank: 1, province: 'Sindh'),
    cityRow(2, 'Lahore', rank: 2, district: 'Lahore'),
  ];
  List<Map<String, dynamic>> hits = [
    cityRow(3, 'Kamra', qualifier: 'Attock', district: 'Attock'),
  ];

  void _maybeFail(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProvinces() async {
    _maybeFail('fetchProvinces');
    return provinces;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchDistricts(int provinceId) async {
    _maybeFail('fetchDistricts');
    return [
      {'id': 10, 'province_id': provinceId, 'name': 'Lahore'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> searchCities(
    Map<String, Object?> p,
  ) async {
    _maybeFail('searchCities');
    params.add(p);
    return p['p_query'] == null ? featured : hits;
  }

  @override
  Future<Map<String, dynamic>?> fetchCity(int id) async {
    _maybeFail('fetchCity');
    return id == 2 ? featured[1] : null;
  }
}

void main() {
  group('LocationRowMapper', () {
    test('province: display name first, kind decoded; unknown kind fails', () {
      final p = LocationRowMapper.provinceFromRow({
        'id': 7,
        'name': 'AJK',
        'display_name': 'Azad Jammu and Kashmir',
        'kind': 'administrative_territory',
      });
      expect(
        (p.id, p.name, p.kind),
        (7, 'Azad Jammu and Kashmir', ProvinceKind.administrativeTerritory),
      );
      expect(
        LocationRowMapper.provinceFromRow({
          'id': 1,
          'name': 'Punjab',
          'kind': 'province',
        }).name,
        'Punjab',
      );
      expect(
        () => LocationRowMapper.provinceFromRow({
          'id': 1,
          'name': 'X',
          'kind': 'state',
        }),
        throwsFormatException,
      );
      for (final k in ProvinceKind.values) {
        expect(
          LocationRowMapper.provinceKindFromCode(
            LocationRowMapper.provinceKindCode(k),
          ),
          k,
        );
      }
    });

    test('city: v_city_options row; label and subtitle', () {
      final kamra = LocationRowMapper.cityFromRow(
        cityRow(3, 'Kamra', qualifier: 'Attock', district: 'Attock'),
      );
      expect(kamra.label, 'Kamra (Attock)');
      expect(kamra.subtitle, 'Punjab'); // the district is already the qualifier
      final lahore = LocationRowMapper.cityFromRow(
        cityRow(2, 'Lahore', rank: 2, district: 'Lahore'),
      );
      expect((lahore.label, lahore.subtitle), ('Lahore', 'Lahore, Punjab'));
      expect(lahore.featuredRank, 2);
      expect(lahore.isFeatured, isTrue);
      final karachi = LocationRowMapper.cityFromRow(
        cityRow(1, 'Karachi', rank: 1, province: 'Sindh'),
      );
      expect((karachi.primaryDistrictId, karachi.districtCount), (null, 0));
      expect(karachi.subtitle, 'Sindh');
    });

    test('ids arrive as numbers or strings', () {
      final d = LocationRowMapper.districtFromRow({
        'id': '10',
        'province_id': 1.0,
        'name': 'Lahore',
      });
      expect((d.id, d.provinceId), (10, 1));
    });

    test('search parameters', () {
      expect(
        LocationRowMapper.searchParams(
          query: 'lah',
          provinceId: 1,
          districtId: null,
          limit: 20,
        ),
        {'p_query': 'lah', 'p_province': 1, 'p_district': null, 'p_limit': 20},
      );
    });
  });

  group('InMemoryLocationRepository (memory mode)', () {
    final repo = InMemoryLocationRepository();

    test('the 20 featured cities, in kPakistanCities order', () async {
      final f = await repo.featuredCities();
      expect(f.map((c) => c.name).toList(), kPakistanCities);
      expect(f.map((c) => c.featuredRank).toList(), [
        for (var i = 1; i <= 20; i++) i,
      ]);
      expect(f.every((c) => c.provinceId == null), isTrue); // nothing invented
    });

    test('search: prefix, short query → all, limit, filters → none', () async {
      expect((await repo.searchCities('ra')).map((c) => c.name), [
        'Rawalpindi',
        'Rahim Yar Khan',
      ]);
      expect(await repo.searchCities(' S '), hasLength(20));
      expect(await repo.searchCities('', limit: 3), hasLength(3));
      expect(await repo.searchCities('', limit: 0), hasLength(1));
      expect(await repo.searchCities('lah', provinceId: 1), isEmpty);
      expect(await repo.provinces(), isEmpty);
      expect(await repo.districts(1), isEmpty);
      expect((await repo.cityById(2))!.name, 'Lahore');
      expect(await repo.cityById(99), isNull);
    });
  });

  group('SupabaseLocationRepository', () {
    late FakeLocationDb db;
    late SupabaseLocationRepository repo;
    setUp(() {
      db = FakeLocationDb();
      repo = SupabaseLocationRepository(db: db);
    });

    test('featured cities and provinces are read once', () async {
      expect((await repo.featuredCities()).map((c) => c.name), [
        'Karachi',
        'Lahore',
      ]);
      await repo.featuredCities();
      expect(db.params.single, {
        'p_query': null,
        'p_province': null,
        'p_district': null,
        'p_limit': 50,
      });
      expect((await repo.provinces()).map((p) => p.name), [
        'Punjab',
        'Azad Jammu and Kashmir',
      ]);
      await repo.provinces();
      expect(db.calls.where((c) => c == 'fetchProvinces'), hasLength(1));
    });

    test('a failed read is not cached', () async {
      db.failNext = const GatewayNetworkException();
      await expectLater(
        repo.featuredCities(),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(await repo.featuredCities(), hasLength(2));
    });

    test('short queries never search; longer ones do, trimmed', () async {
      await repo.searchCities('k');
      await repo.searchCities('  ');
      expect(
        db.calls.where((c) => c == 'searchCities'),
        hasLength(1),
      ); // featured
      final hits = await repo.searchCities('  kamra ', limit: 500);
      expect(hits.single.label, 'Kamra (Attock)');
      expect(db.params.last, {
        'p_query': 'kamra',
        'p_province': null,
        'p_district': null,
        'p_limit': 50,
      });
    });

    test('a short query with a filter lists the filtered cities', () async {
      await repo.searchCities('', districtId: 10, limit: 0);
      expect(db.params.last, {
        'p_query': null,
        'p_province': null,
        'p_district': 10,
        'p_limit': 1,
      });
    });

    test('districts, cityById and error mapping', () async {
      expect((await repo.districts(1)).single.name, 'Lahore');
      expect((await repo.cityById(2))!.name, 'Lahore');
      expect(await repo.cityById(404), isNull);
      db.failNext = const GatewayPermissionException();
      await expectLater(repo.cityById(2), throwsA(isA<AccountException>()));
    });
  });

  group('locationRepositoryProvider', () {
    test('memory mode by default; Supabase mode uses the gateway', () {
      final memory = ProviderContainer();
      addTearDown(memory.dispose);
      expect(
        memory.read(locationRepositoryProvider),
        isA<InMemoryLocationRepository>(),
      );

      final remote = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(
            BackendConfig.parse(
              backend: 'supabase',
              supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
              supabasePublishableKey: 'sb_publishable_test_0000000000000000',
            ),
          ),
          locationGatewayProvider.overrideWithValue(FakeLocationDb()),
        ],
      );
      addTearDown(remote.dispose);
      expect(
        remote.read(locationRepositoryProvider),
        isA<SupabaseLocationRepository>(),
      );
    });
  });
}
