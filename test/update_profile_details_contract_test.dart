import 'dart:io';

import 'package:criceco/data/supabase/profile_row_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stage 4.3.6b: the app's `update_profile_details` arguments against the
/// function migration 9 creates — read from the migration file in this
/// repository, so a renamed, added or reordered parameter fails here before
/// it fails at run time (PostgREST matches a function by its argument
/// names; an unknown name is PGRST202).
void main() {
  const migration =
      'supabase/migrations/20261111090000_create_update_profile_details.sql';

  /// `(name, type)` of each parameter, in order.
  List<(String, String)> parameters() {
    final sql = File(migration).readAsStringSync();
    final head = RegExp(
      r'create function public\.update_profile_details\(([\s\S]*?)\)\s*returns void',
    ).firstMatch(sql);
    expect(head, isNotNull, reason: 'the create function statement');
    return [
      for (final m in RegExp(
        r'^\s*(p_[a-z_]+)\s+([a-z]+)',
        multiLine: true,
      ).allMatches(head!.group(1)!))
        (m.group(1)!, m.group(2)!),
    ];
  }

  test('the eleven parameter names, in order, are the ones the app sends', () {
    final names = [for (final (n, _) in parameters()) n];
    expect(names, hasLength(11));
    expect(names, ProfileRowMapper.updateProfileDetailsArgs);
  });

  test('the parameter types match the values the app sends', () {
    for (final (name, type) in parameters()) {
      final want = name.endsWith('_city_id')
          ? 'integer'
          : name == 'p_date_of_birth'
          ? 'date'
          : 'text';
      expect(type, want, reason: name);
    }
  });

  test('the builder always sends every argument, also when nothing is '
      'given (explicit NULLs)', () {
    final empty = ProfileRowMapper.updateProfileDetailsParams(
      fullName: null,
      phone: null,
      dateOfBirth: null,
    );
    expect(empty.keys, ProfileRowMapper.updateProfileDetailsArgs);
    expect(empty.values.every((v) => v == null), isTrue);

    final full = ProfileRowMapper.updateProfileDetailsParams(
      fullName: 'Hamza Sheikh',
      phone: '+923001234567',
      dateOfBirth: DateTime(2000, 5, 1, 13, 45),
      current: (city: 'Kamra', cityId: 101, area: 'Cantt', address: 'St 1'),
      permanent: (
        city: 'Multan',
        cityId: null,
        area: 'Saddar',
        address: 'St 9',
      ),
    );
    expect(full.keys, ProfileRowMapper.updateProfileDetailsArgs);
    expect(full, {
      'p_full_name': 'Hamza Sheikh',
      'p_phone': '+923001234567',
      'p_date_of_birth': '2000-05-01', // a date, no time
      'p_current_city': 'Kamra',
      'p_current_city_id': 101,
      'p_current_area': 'Cantt',
      'p_current_address': 'St 1',
      'p_permanent_city': 'Multan',
      'p_permanent_city_id': null,
      'p_permanent_area': 'Saddar',
      'p_permanent_address': 'St 9',
    });
  });

  test('signed-in users may call it (EXECUTE for authenticated only)', () {
    final sql = File(migration).readAsStringSync();
    expect(
      sql,
      matches(
        RegExp(
          r'grant execute on function public\.update_profile_details\([^)]*\)\s+to authenticated;',
        ),
      ),
    );
    expect(
      sql,
      matches(
        RegExp(
          r'revoke execute on function public\.update_profile_details\([^)]*\)\s+from public, anon;',
        ),
      ),
    );
  });
}
