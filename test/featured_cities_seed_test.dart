import 'dart:io';

import 'package:criceco/core/constants/cities.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/locations/locations_import.dart';

/// Stage 4.2: the curated featured-city seed keeps the app's 20 cities in
/// kPakistanCities order, and the generated seed carries exactly them.
void main() {
  const dir = 'supabase/seed/locations';

  test(
    'featured_cities.csv = kPakistanCities, ranks 1–20, one GeoNames id each',
    () {
      final featured = parseFeatured(
        File('$dir/featured_cities.csv').readAsStringSync(),
      );
      expect(featured.map((f) => f.name).toList(), kPakistanCities);
      expect(
        featured.map((f) => f.rank).toList(),
        List.generate(20, (i) => i + 1),
      );
      expect(featured.map((f) => f.geonamesId).toSet(), hasLength(20));
    },
  );

  test(
    'the generated cities.csv carries the same 20 featured cities, active',
    () {
      final featured = {
        for (final f in parseFeatured(
          File('$dir/featured_cities.csv').readAsStringSync(),
        ))
          '${f.geonamesId}': f,
      };
      final rows = parseCsv(File('$dir/cities.csv').readAsStringSync())
          .where((r) => r['featured_rank']!.isNotEmpty)
          .toList();
      expect(rows, hasLength(20));
      for (final r in rows) {
        final f = featured[r['geonames_id']];
        expect(
          f,
          isNotNull,
          reason: 'unexpected featured city ${r['geonames_id']}',
        );
        expect(r['featured_rank'], '${f!.rank}');
        expect(r['name'], f.name);
        expect(r['is_active'], 'true');
      }
    },
  );

  test('province display names approved in Stage 4.2 (P2)', () {
    final p = {
      for (final r in parseCsv(File('$dir/provinces.csv').readAsStringSync()))
        r['geonames_admin1']: r,
    };
    expect(p['06']!['display_name'], 'Azad Jammu and Kashmir');
    expect(p['07']!['display_name'], 'Gilgit-Baltistan');
    expect(p, hasLength(7));
  });
}
