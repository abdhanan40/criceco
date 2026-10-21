import 'dart:convert';

/// The areas of each city, for the Profile Setup Area picker. Loaded from
/// `assets/data/city_areas.json` (city → list of area names, in the order to
/// show them). A city with no listed areas keeps the typed Area field.
///
/// TEMPORARY DEMO DATA: the lists in that file are sample areas (5–9 per
/// city) for UI testing only — not a verified or complete list of real
/// localities. Replace them with verified data (or a backend areas source)
/// before release; "Other (type it)" covers anything not listed meanwhile.
class CityAreas {
  const CityAreas(this._byCity);

  /// No area data (still loading, or none supplied yet).
  static const empty = CityAreas({});

  /// Parses the asset. Names are trimmed; blanks and repeats (ignoring case)
  /// are dropped; anything that isn't a list of strings is ignored.
  factory CityAreas.parse(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return empty;
    final out = <String, List<String>>{};
    decoded.forEach((city, areas) {
      if (city is! String || areas is! List) return;
      final seen = <String>{};
      final list = [
        for (final a in areas)
          if (a is String && a.trim().isNotEmpty && seen.add(a.trim().toLowerCase())) a.trim(),
      ];
      if (list.isNotEmpty) out[city.trim()] = List.unmodifiable(list);
    });
    return CityAreas(Map.unmodifiable(out));
  }

  final Map<String, List<String>> _byCity;

  /// Listed areas of [city] (empty when none, or no city yet).
  List<String> areasFor(String? city) => city == null ? const [] : _byCity[city] ?? const [];

  /// Any city has areas — the Area field becomes a picker.
  bool get isNotEmpty => _byCity.isNotEmpty;

  /// [area] is one of [city]'s listed areas (exact match).
  bool isListed(String? city, String? area) => area != null && areasFor(city).contains(area);
}

/// The Area picker's last option: type an area that isn't listed.
const kOtherArea = 'Other (type it)';
