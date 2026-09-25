/// Ranked search (approved revised architecture §8).
///
/// Tiers, best wins across fields:
///   0 exact · 1 starts with · 2 a word starts with · 3 contains.
/// Non-matches are excluded. Sort key:
///   (tier, field weight, value length, value A–Z, original index).
/// An empty query returns the input unchanged.
library;

class SearchField<T> {
  const SearchField(this.getter, {this.weight = 0});
  final String? Function(T item) getter;

  /// 0 = primary field (e.g. name); higher = secondary (e.g. city).
  final int weight;
}

enum SearchTier { exact, startsWith, wordStartsWith, contains }

String normalizeQuery(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

SearchTier? matchTier(String value, String normalizedQuery) {
  if (normalizedQuery.isEmpty) return null;
  final v = normalizeQuery(value);
  if (v == normalizedQuery) return SearchTier.exact;
  if (v.startsWith(normalizedQuery)) return SearchTier.startsWith;
  if (v.split(' ').skip(1).any((w) => w.startsWith(normalizedQuery))) {
    return SearchTier.wordStartsWith;
  }
  if (v.contains(normalizedQuery)) return SearchTier.contains;
  return null;
}

List<T> rankedSearch<T>(
  Iterable<T> items,
  String query, {
  required List<SearchField<T>> fields,
}) {
  final q = normalizeQuery(query);
  final list = items.toList();
  if (q.isEmpty) return list;

  final scored = <_Scored<T>>[];
  for (var i = 0; i < list.length; i++) {
    final item = list[i];
    _Scored<T>? best;
    for (final f in fields) {
      final value = f.getter(item);
      if (value == null || value.isEmpty) continue;
      final tier = matchTier(value, q);
      if (tier == null) continue;
      final candidate = _Scored(item, tier.index, f.weight, normalizeQuery(value), i);
      if (best == null || candidate.compareTo(best) < 0) best = candidate;
    }
    if (best != null) scored.add(best);
  }
  scored.sort((a, b) => a.compareTo(b));
  return [for (final s in scored) s.item];
}

class _Scored<T> implements Comparable<_Scored<T>> {
  _Scored(this.item, this.tier, this.weight, this.value, this.index);
  final T item;
  final int tier;
  final int weight;
  final String value;
  final int index;

  @override
  int compareTo(_Scored<T> o) {
    if (tier != o.tier) return tier - o.tier;
    if (weight != o.weight) return weight - o.weight;
    if (value.length != o.value.length) return value.length - o.value.length;
    final c = value.compareTo(o.value);
    if (c != 0) return c;
    return index - o.index;
  }
}
