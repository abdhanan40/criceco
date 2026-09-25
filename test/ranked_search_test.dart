import 'package:criceco/core/utils/ranked_search.dart';
import 'package:flutter_test/flutter_test.dart';

class _P {
  const _P(this.name, [this.city = '']);
  final String name;
  final String city;
  @override
  String toString() => name;
}

List<String> _names(Iterable<_P> ps) => [for (final p in ps) p.name];

void main() {
  final fields = [SearchField<_P>((p) => p.name), SearchField<_P>((p) => p.city, weight: 1)];

  test('starts-with ranks above contains (brief example "H")', () {
    final people = [const _P('Shahid'), const _P('Ahmed'), const _P('Hassan'), const _P('Haris'), const _P('Hamza')];
    final result = _names(rankedSearch(people, 'H', fields: fields));
    expect(result.take(3).toSet(), {'Hassan', 'Haris', 'Hamza'});
    expect(result.sublist(3).toSet(), {'Shahid', 'Ahmed'});
    expect(result, ['Hamza', 'Haris', 'Hassan', 'Ahmed', 'Shahid']); // ties: length, then A–Z
  });

  test('exact beats starts-with; word-prefix beats contains', () {
    final people = [const _P('Ali Raza'), const _P('Ali'), const _P('Alina'), const _P('Khalil')];
    expect(_names(rankedSearch(people, 'ali', fields: fields)), ['Ali', 'Alina', 'Ali Raza', 'Khalil']);
    expect(_names(rankedSearch(people, 'raza', fields: fields)), ['Ali Raza']);
  });

  test('primary field outranks secondary field in the same tier', () {
    final clubs = [const _P('Karachi Kings', 'Lahore'), const _P('Lahore Lions', 'Lahore')];
    expect(_names(rankedSearch(clubs, 'lah', fields: fields)), ['Lahore Lions', 'Karachi Kings']);
  });

  test('non-matches are excluded; empty query keeps order; case and spaces are normalised', () {
    final people = [const _P('Bilal'), const _P('Usman')];
    expect(_names(rankedSearch(people, 'zz', fields: fields)), isEmpty);
    expect(_names(rankedSearch(people, '   ', fields: fields)), ['Bilal', 'Usman']);
    expect(_names(rankedSearch(people, '  BIL ', fields: fields)), ['Bilal']);
  });
}
