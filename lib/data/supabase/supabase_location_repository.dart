import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'location_row_mapper.dart';
import 'supabase_error_mapper.dart';
import 'supabase_gateways.dart';

/// [LocationRepository] on the location tables of migration 6 (read-only).
///
/// The featured cities and the province list rarely change, so each is read
/// once per repository (a failed read is not cached: the next call retries).
/// A query shorter than two characters never searches the database: it is
/// the featured list (no filter) or the filtered list by name.
class SupabaseLocationRepository implements LocationRepository {
  SupabaseLocationRepository({required this.db});

  final LocationGateway db;

  Future<List<CityOption>>? _featured;
  Future<List<Province>>? _provinces;

  @override
  Future<List<Province>> provinces() => _provinces ??= _cached(
    () async => [
      for (final r in await _call(db.fetchProvinces))
        LocationRowMapper.provinceFromRow(r),
    ],
    () => _provinces = null,
  );

  @override
  Future<List<District>> districts(int provinceId) async => [
    for (final r in await _call(() => db.fetchDistricts(provinceId)))
      LocationRowMapper.districtFromRow(r),
  ];

  @override
  Future<List<CityOption>> featuredCities() => _featured ??= _cached(
    () => _search(null, null, null, 50),
    () => _featured = null,
  );

  @override
  Future<List<CityOption>> searchCities(
    String query, {
    int? provinceId,
    int? districtId,
    int limit = 20,
  }) async {
    final q = query.trim();
    final n = limit.clamp(1, 50);
    if (q.length < 2) {
      if (provinceId == null && districtId == null) {
        return (await featuredCities()).take(n).toList(growable: false);
      }
      return _search(null, provinceId, districtId, n);
    }
    return _search(q, provinceId, districtId, n);
  }

  @override
  Future<CityOption?> cityById(int id) async {
    final row = await _call(() => db.fetchCity(id));
    return row == null ? null : LocationRowMapper.cityFromRow(row);
  }

  Future<List<CityOption>> _search(
    String? query,
    int? provinceId,
    int? districtId,
    int limit,
  ) async => [
    for (final r in await _call(
      () => db.searchCities(
        LocationRowMapper.searchParams(
          query: query,
          provinceId: provinceId,
          districtId: districtId,
          limit: limit,
        ),
      ),
    ))
      LocationRowMapper.cityFromRow(r),
  ];

  /// Keeps a successful result; forgets a failed one so the next call retries.
  static Future<T> _cached<T>(
    Future<T> Function() load,
    void Function() forget,
  ) async {
    try {
      return await load();
    } catch (_) {
      forget();
      rethrow;
    }
  }

  static Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on GatewayException catch (e) {
      throw SupabaseErrorMapper.map(e);
    }
  }
}
