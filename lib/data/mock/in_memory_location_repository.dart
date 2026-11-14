import '../../core/constants/cities.dart';
import '../../core/models/models.dart';
import '../repositories/repositories.dart';

/// Memory mode: the app's 20 featured cities only ([kPakistanCities], local
/// ids 1–20 in that order). There is no province / district data here — none
/// is invented — so the hierarchy calls return nothing.
class InMemoryLocationRepository implements LocationRepository {
  InMemoryLocationRepository()
    : _cities = [
        for (var i = 0; i < kPakistanCities.length; i++)
          CityOption(id: i + 1, name: kPakistanCities[i], featuredRank: i + 1),
      ];

  final List<CityOption> _cities;

  @override
  Future<List<Province>> provinces() async => const [];

  @override
  Future<List<District>> districts(int provinceId) async => const [];

  @override
  Future<List<CityOption>> featuredCities() async => List.unmodifiable(_cities);

  @override
  Future<List<CityOption>> searchCities(
    String query, {
    int? provinceId,
    int? districtId,
    int limit = 20,
  }) async {
    // Without province / district data, a filtered search finds nothing.
    if (provinceId != null || districtId != null) return const [];
    final q = query.trim().toLowerCase();
    final n = limit.clamp(1, 50);
    final hits = q.length < 2
        ? _cities
        : _cities.where((c) => c.name.toLowerCase().startsWith(q));
    return hits.take(n).toList(growable: false);
  }

  @override
  Future<CityOption?> cityById(int id) async {
    for (final c in _cities) {
      if (c.id == id) return c;
    }
    return null;
  }
}
