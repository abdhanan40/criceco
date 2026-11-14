import '../../core/models/models.dart';

/// Pure conversions between the location rows of migration 6
/// (`provinces`, `districts`, `v_city_options`) and the app's models.
abstract final class LocationRowMapper {
  /// `provinces.kind` — identical to its CHECK constraint.
  static String provinceKindCode(ProvinceKind k) => switch (k) {
    ProvinceKind.province => 'province',
    ProvinceKind.federalTerritory => 'federal_territory',
    ProvinceKind.administrativeTerritory => 'administrative_territory',
  };

  static ProvinceKind provinceKindFromCode(String code) {
    for (final k in ProvinceKind.values) {
      if (provinceKindCode(k) == code) return k;
    }
    // The app and the schema disagree — fail loudly (as ProfileRowMapper).
    throw FormatException('Unknown provinces.kind value', code);
  }

  /// The display name when set (e.g. "Azad Jammu and Kashmir"), else the name.
  static Province provinceFromRow(Map<String, dynamic> r) => Province(
    id: _int(r['id']),
    name: (r['display_name'] as String?) ?? r['name'] as String,
    kind: provinceKindFromCode(r['kind'] as String),
  );

  static District districtFromRow(Map<String, dynamic> r) => District(
    id: _int(r['id']),
    provinceId: _int(r['province_id']),
    name: r['name'] as String,
  );

  /// A `v_city_options` row.
  static CityOption cityFromRow(Map<String, dynamic> r) => CityOption(
    id: _int(r['id']),
    name: r['name'] as String,
    qualifier: r['qualifier'] as String?,
    provinceId: _intOrNull(r['province_id']),
    provinceName: r['province_name'] as String?,
    primaryDistrictId: _intOrNull(r['primary_district_id']),
    primaryDistrictName: r['primary_district_name'] as String?,
    districtCount: _intOrNull(r['district_count']) ?? 0,
    featuredRank: _intOrNull(r['featured_rank']),
  );

  /// `search_cities()` arguments.
  static Map<String, Object?> searchParams({
    required String? query,
    int? provinceId,
    int? districtId,
    required int limit,
  }) => {
    'p_query': query,
    'p_province': provinceId,
    'p_district': districtId,
    'p_limit': limit,
  };

  static int _int(Object? v) => _intOrNull(v)!;

  static int? _intOrNull(Object? v) => switch (v) {
    final int i => i,
    final num n => n.toInt(),
    final String s => int.tryParse(s),
    _ => null,
  };
}
