// CricEco Stage 4.2 — GeoNames → location seed (pure rules, no I/O).
//
// Input: the GeoNames Pakistan gazetteer (PK.txt) and alternate names
// (alternatenames/PK.txt), plus three curated CSVs (province_display.csv,
// featured_cities.csv, overrides.csv). Output: the seed CSVs, the
// apply_locations.sql data script and import_report.md — deterministic
// (same input → byte-identical output; no clock, no randomness).
//
// Source licence: GeoNames, CC BY 4.0 (see ATTRIBUTION.md). HDX and PBS are
// never read here.
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// Rules (see supabase/seed/locations/README.md).
// ---------------------------------------------------------------------------

/// GeoNames populated-place codes always taken (capital and admin seats).
const seatCodes = {'PPLC', 'PPLA', 'PPLA2', 'PPLA3'};

/// Never imported: section of a place, abandoned, destroyed, historical.
const excludedPlaceCodes = {'PPLX', 'PPLQ', 'PPLW', 'PPLH'};

/// Other populated places are taken from this GeoNames population up.
const minPopulation = 10000;

/// Alternate-name languages kept ('' = untagged). Urdu is stored, not shown yet (P8).
const aliasLanguages = {'', 'en', 'ur'};

/// The 2018-style suffixes GeoNames still uses on some district names.
final _districtSuffix = RegExp(r'\s+district$', caseSensitive: false);

// ---------------------------------------------------------------------------
// The search key — an exact mirror of public.location_search_key() in
// migration 20261110090000_create_locations.sql.
// ---------------------------------------------------------------------------
final Map<int, int> _fold = {
  ..._pairs('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'),
  ..._pairs('āáàâäãå', 'aaaaaaa'),
  ..._pairs('īíìîï', 'iiiii'),
  ..._pairs('ūúùûü', 'uuuuu'),
  ..._pairs('ēéèêë', 'eeeee'),
  ..._pairs('ōóòôöõ', 'oooooo'),
  ..._pairs('ñçṣṭḍẓḥṛś', 'ncstdzhrs'),
  ..._pairs('ĀÁÀÂÄÃÅ', 'aaaaaaa'),
  ..._pairs('ĪÍÌÎÏ', 'iiiii'),
  ..._pairs('ŪÚÙÛÜ', 'uuuuu'),
  ..._pairs('ĒÉÈÊË', 'eeeee'),
  ..._pairs('ŌÓÒÔÖÕ', 'oooooo'),
  ..._pairs('ÑÇṢṬḌẒḤṚŚ', 'ncstdzhrs'),
};

Map<int, int> _pairs(String from, String to) {
  final f = from.runes.toList(), t = to.runes.toList();
  if (f.length != t.length) {
    throw StateError('fold table length mismatch: $from');
  }
  return {for (var i = 0; i < f.length; i++) f[i]: t[i]};
}

// \s in the SQL pattern = ASCII whitespace; the explicit ranges follow it.
final _separators = RegExp('[\t\n\u000b\f\r !-/:-@\\[-`{-~ -¿ -⁯،؛؟۔]+');

/// Lower case (A–Z and the listed letters only), Latin diacritics folded,
/// punctuation/whitespace runs → one space, trimmed; null when empty.
String? searchKey(String? text) {
  if (text == null) return null;
  final folded = String.fromCharCodes(text.runes.map((r) => _fold[r] ?? r));
  var s = folded.replaceAll(_separators, ' ');
  while (s.startsWith(' ')) {
    s = s.substring(1);
  }
  while (s.endsWith(' ')) {
    s = s.substring(0, s.length - 1);
  }
  return s.isEmpty ? null : s;
}

// ---------------------------------------------------------------------------
// GeoNames records.
// ---------------------------------------------------------------------------
class GeoRecord {
  GeoRecord({
    required this.id,
    required this.name,
    required this.asciiName,
    required this.latitude,
    required this.longitude,
    required this.featureClass,
    required this.featureCode,
    required this.admin1,
    required this.admin2,
    required this.population,
  });

  final int id;
  final String name;
  final String asciiName;
  final String latitude;
  final String longitude;
  final String featureClass;
  final String featureCode;
  final String admin1;
  final String admin2;
  final int population;

  /// The display spelling: GeoNames' ASCII name (falls back to the name).
  String get plainName => (asciiName.trim().isEmpty ? name : asciiName).trim();
}

class AltName {
  AltName({
    required this.id,
    required this.geonameId,
    required this.language,
    required this.name,
    required this.isPreferred,
    required this.isShort,
    required this.isColloquial,
    required this.isHistoric,
  });

  final int id;
  final int geonameId;
  final String language;
  final String name;
  final bool isPreferred;
  final bool isShort;
  final bool isColloquial;
  final bool isHistoric;
}

/// GeoNames `PK.txt` (19 tab-separated columns, see the dump readme).
List<GeoRecord> parseGeoNames(String content) {
  final out = <GeoRecord>[];
  for (final line in const LineSplitter().convert(content)) {
    if (line.isEmpty) continue;
    final c = line.split('\t');
    if (c.length != 19) {
      throw FormatException(
        'PK.txt: expected 19 columns, got ${c.length}',
        line,
      );
    }
    out.add(
      GeoRecord(
        id: int.parse(c[0]),
        name: c[1],
        asciiName: c[2],
        latitude: c[4],
        longitude: c[5],
        featureClass: c[6],
        featureCode: c[7],
        admin1: c[10],
        admin2: c[11],
        population: int.tryParse(c[14]) ?? 0,
      ),
    );
  }
  return out;
}

/// GeoNames `alternatenames/PK.txt` (alternateNamesV2: 10 columns).
List<AltName> parseAlternateNames(String content) {
  final out = <AltName>[];
  for (final line in const LineSplitter().convert(content)) {
    if (line.isEmpty) continue;
    final c = line.split('\t');
    if (c.length < 8) {
      throw FormatException(
        'alternatenames: expected ≥ 8 columns, got ${c.length}',
        line,
      );
    }
    out.add(
      AltName(
        id: int.parse(c[0]),
        geonameId: int.parse(c[1]),
        language: c[2],
        name: c[3],
        isPreferred: c[4] == '1',
        isShort: c[5] == '1',
        isColloquial: c[6] == '1',
        isHistoric: c[7] == '1',
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// CSV (RFC 4180 subset: comma, double-quote quoting, \n line ends).
// ---------------------------------------------------------------------------
String csvField(Object? v) {
  final s = v == null ? '' : '$v';
  return RegExp(r'[",\n\r]').hasMatch(s) || s != s.trim()
      ? '"${s.replaceAll('"', '""')}"'
      : s;
}

String toCsv(List<String> header, List<List<Object?>> rows) {
  final b = StringBuffer()..writeln(header.map(csvField).join(','));
  for (final r in rows) {
    b.writeln(r.map(csvField).join(','));
  }
  return b.toString();
}

/// Parses CSV text into maps keyed by the header. Lines starting with '#'
/// (outside quotes) are comments.
List<Map<String, String>> parseCsv(String text) {
  final records = <List<String>>[];
  var field = StringBuffer();
  var row = <String>[];
  var quoted = false, atStart = true, comment = false;
  void endField() {
    row.add(field.toString());
    field = StringBuffer();
  }

  void endRow() {
    endField();
    if (!(row.length == 1 && row.first.isEmpty)) records.add(row);
    row = <String>[];
    atStart = true;
  }

  final s = text.replaceAll('\r\n', '\n');
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (comment) {
      if (ch == '\n') {
        comment = false;
        atStart = true;
      }
      continue;
    }
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    if (atStart && ch == '#') {
      comment = true;
      continue;
    }
    atStart = false;
    if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      endField();
    } else if (ch == '\n') {
      endRow();
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  if (records.isEmpty) return [];
  final header = records.first;
  return [
    for (final r in records.skip(1))
      {
        for (var i = 0; i < header.length; i++)
          header[i]: i < r.length ? r[i] : '',
      },
  ];
}

// ---------------------------------------------------------------------------
// Curated inputs.
// ---------------------------------------------------------------------------
class ProvinceDisplay {
  ProvinceDisplay(
    this.admin1,
    this.name,
    this.displayName,
    this.kind,
    this.sortOrder,
  );
  final String admin1;
  final String name;
  final String? displayName;
  final String kind;
  final int sortOrder;
}

class FeaturedCity {
  FeaturedCity(this.rank, this.name, this.geonamesId);
  final int rank;
  final String name;
  final int geonamesId;
}

class Override {
  Override(this.entity, this.geonamesId, this.action, this.value, this.reason);
  final String entity; // province | district | city | alias
  final int geonamesId; // GeoNames id (alias: alternateNameId)
  final String action;
  final String value;
  final String reason;
}

const _overrideActions = {
  'district': {'exclude', 'inactive', 'rename'},
  'city': {
    'exclude',
    'inactive',
    'rename',
    'qualifier',
    'district',
    'no_district',
  },
  'alias': {'exclude', 'not_searchable'},
};
const _needsValue = {'rename', 'qualifier', 'district'};
const provinceKinds = {
  'province',
  'federal_territory',
  'administrative_territory',
};

List<ProvinceDisplay> parseProvinceDisplay(String csv) => [
  for (final r in parseCsv(csv))
    ProvinceDisplay(
      _req(r, 'geonames_admin1', 'province_display.csv'),
      _req(r, 'name', 'province_display.csv'),
      (r['display_name'] ?? '').trim().isEmpty
          ? null
          : r['display_name']!.trim(),
      _req(r, 'kind', 'province_display.csv'),
      int.parse(_req(r, 'sort_order', 'province_display.csv')),
    ),
];

List<FeaturedCity> parseFeatured(String csv) => [
  for (final r in parseCsv(csv))
    FeaturedCity(
      int.parse(_req(r, 'featured_rank', 'featured_cities.csv')),
      _req(r, 'name', 'featured_cities.csv'),
      int.parse(_req(r, 'geonames_id', 'featured_cities.csv')),
    ),
];

List<Override> parseOverrides(String csv) => [
  for (final r in parseCsv(csv))
    Override(
      _req(r, 'entity', 'overrides.csv'),
      int.parse(_req(r, 'geonames_id', 'overrides.csv')),
      _req(r, 'action', 'overrides.csv'),
      (r['value'] ?? '').trim(),
      _req(r, 'reason', 'overrides.csv'),
    ),
];

String _req(Map<String, String> r, String k, String file) {
  final v = (r[k] ?? '').trim();
  if (v.isEmpty) throw FormatException('$file: "$k" is required', r.toString());
  return v;
}

// ---------------------------------------------------------------------------
// Output rows.
// ---------------------------------------------------------------------------
class ProvinceRow {
  ProvinceRow({
    required this.admin1,
    required this.geonamesId,
    required this.name,
    required this.displayName,
    required this.kind,
    required this.sortOrder,
    required this.altNames,
  });
  final String admin1;
  final int geonamesId;
  final String name;
  final String? displayName;
  final String kind;
  final int sortOrder;
  final List<String> altNames;
}

class DistrictRow {
  DistrictRow({
    required this.geonamesId,
    required this.admin1,
    required this.name,
    required this.isActive,
    required this.altNames,
  });
  final int geonamesId;
  final String admin1;
  final String name;
  final bool isActive;
  final List<String> altNames;
}

class CityRow {
  CityRow({
    required this.geonamesId,
    required this.admin1,
    required this.name,
    required this.qualifier,
    required this.kind,
    required this.featureCode,
    required this.featuredRank,
    required this.latitude,
    required this.longitude,
    required this.isActive,
    required this.population,
  });
  final int geonamesId;
  final String admin1;
  final String name;
  final String? qualifier;
  final String kind;
  final String featureCode;
  final int? featuredRank;
  final String latitude;
  final String longitude;
  final bool isActive;
  final int population;
}

class CityDistrictRow {
  CityDistrictRow(
    this.cityGeonamesId,
    this.districtGeonamesId, {
    required this.isPrimary,
  });
  final int cityGeonamesId;
  final int districtGeonamesId;
  final bool isPrimary;
}

class AliasRow {
  AliasRow({
    required this.alternateNameId,
    required this.cityGeonamesId,
    required this.alias,
    required this.language,
    required this.kind,
    required this.isSearchable,
  });
  final int alternateNameId;
  final int cityGeonamesId;
  final String alias;
  final String? language;
  final String kind;
  final bool isSearchable;
}

class LocationBuild {
  LocationBuild({
    required this.provinces,
    required this.districts,
    required this.cities,
    required this.cityDistricts,
    required this.aliases,
    required this.report,
  });
  final List<ProvinceRow> provinces;
  final List<DistrictRow> districts;
  final List<CityRow> cities;
  final List<CityDistrictRow> cityDistricts;
  final List<AliasRow> aliases;
  final BuildReport report;
}

class BuildReport {
  final placeCodeCounts = <String, int>{};
  final excludedByOverride = <String>[];
  final unlinkedCities = <String>[];
  final skippedNoProvince = <String>[];
  final nationwideDuplicateNames = <String>[];
  final ambiguousAliases = <String>[];
  final overridesApplied = <String>[];
  int populatedPlaces = 0;
  int selectedBySeat = 0;
  int selectedByPopulation = 0;
  int aliasCandidates = 0;
  final aliasDropped = <String, int>{};
  final droppedLanguages = <String>{};
}

/// Raised when the data breaks a rule; the build stops (nothing is written).
class LocationBuildException implements Exception {
  LocationBuildException(this.problems);
  final List<String> problems;
  @override
  String toString() => 'LocationBuildException:\n  ${problems.join('\n  ')}';
}

bool _validName(String s) =>
    s == s.trim() && s.runes.length >= 2 && s.runes.length <= 80;

String _fmtCoord(String v) {
  final d = double.parse(v);
  return d.toStringAsFixed(5);
}

/// Builds the seed from parsed inputs. Throws [LocationBuildException] with
/// every problem found (unknown ids, clashes, missing featured cities, …).
LocationBuild buildLocations({
  required List<GeoRecord> records,
  required List<AltName> alternateNames,
  required List<ProvinceDisplay> provinceDisplay,
  required List<FeaturedCity> featured,
  required List<Override> overrides,
}) {
  final problems = <String>[];
  final report = BuildReport();
  final byId = {for (final r in records) r.id: r};

  // -- Overrides: validate first.
  final ov = <String, Map<int, List<Override>>>{};
  final seen = <String>{};
  for (final o in overrides) {
    final allowed = _overrideActions[o.entity];
    if (allowed == null || !allowed.contains(o.action)) {
      problems.add(
        'overrides.csv: unknown entity/action "${o.entity}/${o.action}" (id ${o.geonamesId})',
      );
      continue;
    }
    if (_needsValue.contains(o.action) && o.value.isEmpty) {
      problems.add(
        'overrides.csv: ${o.entity} ${o.geonamesId} "${o.action}" needs a value',
      );
    }
    if (!seen.add('${o.entity}|${o.geonamesId}|${o.action}')) {
      problems.add(
        'overrides.csv: duplicate ${o.entity} ${o.geonamesId} ${o.action}',
      );
    }
    if (o.entity != 'alias' && !byId.containsKey(o.geonamesId)) {
      problems.add(
        'overrides.csv: ${o.entity} ${o.geonamesId} is not in the GeoNames dump',
      );
    }
    ((ov[o.entity] ??= {})[o.geonamesId] ??= []).add(o);
  }
  Override? find(String entity, int id, String action) {
    for (final o in ov[entity]?[id] ?? const <Override>[]) {
      if (o.action == action) return o;
    }
    return null;
  }

  void applied(Override o) => report.overridesApplied.add(
    '${o.entity} ${o.geonamesId} ${o.action}'
    '${o.value.isEmpty ? '' : ' → ${o.value}'} — ${o.reason}',
  );

  // -- Provinces: the GeoNames ADM1 records + the curated display rows.
  final adm1 = records.where((r) => r.featureCode == 'ADM1').toList();
  final display = {for (final p in provinceDisplay) p.admin1: p};
  final provinces = <ProvinceRow>[];
  for (final r in adm1) {
    final d = display[r.admin1];
    if (d == null) {
      problems.add(
        'province_display.csv: no row for GeoNames admin1 ${r.admin1} (${r.name})',
      );
      continue;
    }
    if (!provinceKinds.contains(d.kind)) {
      problems.add('province_display.csv: unknown kind "${d.kind}"');
    }
    if (!_validName(d.name)) {
      problems.add('province_display.csv: invalid name "${d.name}"');
    }
    provinces.add(
      ProvinceRow(
        admin1: r.admin1,
        geonamesId: r.id,
        name: d.name,
        displayName: d.displayName,
        kind: d.kind,
        sortOrder: d.sortOrder,
        altNames: _altNames(d.name, [r.name, r.asciiName]),
      ),
    );
  }
  for (final a in display.keys) {
    if (!adm1.any((r) => r.admin1 == a)) {
      problems.add(
        'province_display.csv: admin1 $a has no GeoNames ADM1 record',
      );
    }
  }
  _unique(provinces.map((p) => searchKey(p.name)), 'province name', problems);
  provinces.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final provinceAdmin1 = {for (final p in provinces) p.admin1};

  // -- Districts: GeoNames ADM2 (ADM2H historical records are never taken).
  final districts = <DistrictRow>[];
  final districtByAdmin2 = <String, DistrictRow>{}; // "admin1.admin2" → row
  for (final r in records.where((r) => r.featureCode == 'ADM2')) {
    if (!provinceAdmin1.contains(r.admin1)) {
      problems.add(
        'district ${r.id} ${r.name}: admin1 ${r.admin1} is not a province',
      );
      continue;
    }
    final excl = find('district', r.id, 'exclude');
    if (excl != null) {
      applied(excl);
      report.excludedByOverride.add(
        'district ${r.id} ${r.plainName} — ${excl.reason}',
      );
      continue;
    }
    final rename = find('district', r.id, 'rename');
    if (rename != null) applied(rename);
    final inactive = find('district', r.id, 'inactive');
    if (inactive != null) applied(inactive);
    final name =
        rename?.value ?? r.plainName.replaceFirst(_districtSuffix, '').trim();
    if (!_validName(name)) {
      problems.add('district ${r.id}: invalid name "$name"');
    }
    final row = DistrictRow(
      geonamesId: r.id,
      admin1: r.admin1,
      name: name,
      isActive: inactive == null,
      altNames: _altNames(name, [
        r.name,
        r.asciiName,
        r.name.replaceFirst(_districtSuffix, ''),
      ]),
    );
    districts.add(row);
    districtByAdmin2['${r.admin1}.${r.admin2}'] = row;
  }
  _unique(
    districts.map((d) => '${d.admin1}|${searchKey(d.name)}'),
    'district name in a province',
    problems,
  );
  districts.sort(
    (a, b) => _cmp(
      [a.admin1, a.name, a.geonamesId],
      [b.admin1, b.name, b.geonamesId],
    ),
  );
  final districtById = {for (final d in districts) d.geonamesId: d};

  // -- Cities.
  final featuredById = <int, FeaturedCity>{};
  for (final f in featured) {
    if (featuredById.containsKey(f.geonamesId)) {
      problems.add('featured_cities.csv: id ${f.geonamesId} listed twice');
    }
    featuredById[f.geonamesId] = f;
    final r = byId[f.geonamesId];
    if (r == null) {
      problems.add(
        'featured_cities.csv: ${f.name} (${f.geonamesId}) is not in the GeoNames dump',
      );
    } else if (r.featureClass != 'P' ||
        excludedPlaceCodes.contains(r.featureCode)) {
      problems.add(
        'featured_cities.csv: ${f.name} (${f.geonamesId}) is ${r.featureClass}/${r.featureCode}, '
        'not an importable populated place',
      );
    } else if (searchKey(r.plainName) != searchKey(f.name)) {
      problems.add(
        'featured_cities.csv: ${f.geonamesId} is "${r.plainName}" in GeoNames, not "${f.name}"',
      );
    }
  }
  final ranks = featured.map((f) => f.rank).toList()..sort();
  for (var i = 0; i < ranks.length; i++) {
    if (ranks[i] != i + 1) {
      problems.add(
        'featured_cities.csv: ranks must be 1..${featured.length} without gaps',
      );
      break;
    }
  }

  final cities = <CityRow>[];
  final links = <CityDistrictRow>[];
  for (final r in records.where((r) => r.featureClass == 'P')) {
    report.populatedPlaces++;
    report.placeCodeCounts[r.featureCode] =
        (report.placeCodeCounts[r.featureCode] ?? 0) + 1;
    final isFeatured = featuredById.containsKey(r.id);
    final bySeat = seatCodes.contains(r.featureCode);
    final byPopulation =
        !excludedPlaceCodes.contains(r.featureCode) &&
        r.population >= minPopulation;
    if (!isFeatured && !bySeat && !byPopulation) continue;
    if (excludedPlaceCodes.contains(r.featureCode)) continue;
    final excl = find('city', r.id, 'exclude');
    if (excl != null) {
      if (isFeatured) {
        problems.add('overrides.csv: featured city ${r.id} cannot be excluded');
      }
      applied(excl);
      report.excludedByOverride.add(
        'city ${r.id} ${r.plainName} (${r.featureCode}, pop ${r.population}) — ${excl.reason}',
      );
      continue;
    }
    if (!provinceAdmin1.contains(r.admin1)) {
      report.skippedNoProvince.add(
        '${r.id} ${r.plainName} (admin1 "${r.admin1}")',
      );
      if (isFeatured) problems.add('featured city ${r.id} has no province');
      continue;
    }
    if (bySeat) {
      report.selectedBySeat++;
    } else if (byPopulation) {
      report.selectedByPopulation++;
    }
    final rename = find('city', r.id, 'rename');
    final qualifier = find('city', r.id, 'qualifier');
    final inactive = find('city', r.id, 'inactive');
    for (final o in [rename, qualifier, inactive]) {
      if (o != null) applied(o);
    }
    final name = rename?.value ?? r.plainName;
    if (!_validName(name)) problems.add('city ${r.id}: invalid name "$name"');
    if (qualifier != null && !_validName(qualifier.value)) {
      problems.add('city ${r.id}: invalid qualifier');
    }
    cities.add(
      CityRow(
        geonamesId: r.id,
        admin1: r.admin1,
        name: name,
        qualifier: qualifier?.value,
        kind: _cityKind(r, name),
        featureCode: r.featureCode,
        featuredRank: featuredById[r.id]?.rank,
        latitude: _fmtCoord(r.latitude),
        longitude: _fmtCoord(r.longitude),
        isActive: inactive == null,
        population: r.population,
      ),
    );

    // District link.
    final noDistrict = find('city', r.id, 'no_district');
    final forced = find('city', r.id, 'district');
    if (noDistrict != null) {
      applied(noDistrict);
      report.unlinkedCities.add(
        '${r.id} ${r.plainName}: no district (override — ${noDistrict.reason})',
      );
    } else if (forced != null) {
      applied(forced);
      final d = districtById[int.tryParse(forced.value)];
      if (d == null || d.admin1 != r.admin1) {
        problems.add(
          'overrides.csv: city ${r.id} district ${forced.value} is not an imported district of its province',
        );
      } else {
        links.add(CityDistrictRow(r.id, d.geonamesId, isPrimary: true));
      }
    } else {
      final d = r.admin2.isEmpty
          ? null
          : districtByAdmin2['${r.admin1}.${r.admin2}'];
      if (d == null) {
        report.unlinkedCities.add(
          '${r.id} ${r.plainName}: '
          '${r.admin2.isEmpty ? 'no admin2 code in GeoNames' : 'admin2 ${r.admin2} is not an imported district'}',
        );
      } else if (!d.isActive) {
        report.unlinkedCities.add(
          '${r.id} ${r.plainName}: its district ${d.name} is inactive',
        );
      } else {
        links.add(CityDistrictRow(r.id, d.geonamesId, isPrimary: true));
      }
    }
  }
  for (final f in featured) {
    if (!cities.any((c) => c.geonamesId == f.geonamesId)) {
      problems.add(
        'featured city ${f.name} (${f.geonamesId}) is not in the output',
      );
    }
  }
  // Same name twice in one province needs a qualifier (database rule).
  final clash = <String, List<CityRow>>{};
  for (final c in cities) {
    (clash['${c.admin1}|${searchKey(c.name)}|${searchKey(c.qualifier) ?? ''}'] ??=
            [])
        .add(c);
  }
  for (final e in clash.values.where((v) => v.length > 1)) {
    problems.add(
      'city name clash in one province — add a qualifier or exclude in overrides.csv: '
      '${e.map((c) => '${c.geonamesId} "${c.name}" (${c.featureCode}, pop ${c.population}, admin1 ${c.admin1})').join(' / ')}',
    );
  }
  final nationwide = <String, List<CityRow>>{};
  for (final c in cities) {
    (nationwide[searchKey(c.name) ?? c.name] ??= []).add(c);
  }
  for (final e in nationwide.entries.where((e) => e.value.length > 1)) {
    report.nationwideDuplicateNames.add(
      '${e.value.first.name} ×${e.value.length} '
      '(${e.value.map((c) => '${c.geonamesId}/${c.qualifier ?? 'admin1 ${c.admin1}'}').join(', ')})',
    );
  }
  cities.sort(
    (a, b) => _cmp(
      [a.admin1, a.name, a.geonamesId],
      [b.admin1, b.name, b.geonamesId],
    ),
  );
  links.sort(
    (a, b) => _cmp(
      [a.cityGeonamesId, a.districtGeonamesId],
      [b.cityGeonamesId, b.districtGeonamesId],
    ),
  );

  // -- Aliases (imported cities only).
  final cityById = {for (final c in cities) c.geonamesId: c};
  final nameKeysByProvince = <String, Set<int>>{}; // "admin1|key" → city ids
  for (final c in cities) {
    (nameKeysByProvince['${c.admin1}|${searchKey(c.name)}'] ??= {}).add(
      c.geonamesId,
    );
  }
  void drop(String why) =>
      report.aliasDropped[why] = (report.aliasDropped[why] ?? 0) + 1;
  final best = <String, AltName>{}; // "city|key" → chosen alternate name
  for (final a in alternateNames) {
    final city = cityById[a.geonameId];
    if (city == null) continue;
    report.aliasCandidates++;
    if (!aliasLanguages.contains(a.language)) {
      drop('other language or code (not en / ur / untagged)');
      report.droppedLanguages.add(a.language);
      continue;
    }
    final text = a.name.trim().replaceAll(RegExp(r'\s+'), ' ');
    final key = searchKey(text);
    if (!_validName(text) || key == null) {
      drop('empty or outside 2–80 characters');
      continue;
    }
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(text)) {
      drop('no letter');
      continue;
    }
    if (key == searchKey(city.name)) {
      drop('same as the city name');
      continue;
    }
    final ex = find('alias', a.id, 'exclude');
    if (ex != null) {
      applied(ex);
      drop('excluded by overrides.csv');
      continue;
    }
    final slot = '${city.geonamesId}|$key';
    final prev = best[slot];
    if (prev == null || _aliasBetter(a, prev)) {
      if (prev != null) drop('duplicate spelling for the same city');
      best[slot] = a;
    } else {
      drop('duplicate spelling for the same city');
    }
  }
  final aliases = <AliasRow>[];
  for (final e in best.entries) {
    final a = e.value;
    final city = cityById[a.geonameId]!;
    final key = e.key.substring(e.key.indexOf('|') + 1);
    final clashes = (nameKeysByProvince['${city.admin1}|$key'] ?? const <int>{})
        .difference({city.geonamesId});
    final notSearchable = find('alias', a.id, 'not_searchable');
    if (notSearchable != null) applied(notSearchable);
    final searchable = clashes.isEmpty && notSearchable == null;
    if (clashes.isNotEmpty) {
      report.ambiguousAliases.add(
        '"${a.name.trim()}" (alias ${a.id}) of ${city.name} ${city.geonamesId} '
        'equals the name of ${clashes.join(', ')} in the same province → not searchable',
      );
    }
    aliases.add(
      AliasRow(
        alternateNameId: a.id,
        cityGeonamesId: city.geonamesId,
        alias: a.name.trim().replaceAll(RegExp(r'\s+'), ' '),
        language: a.language.isEmpty ? null : a.language,
        kind: a.isHistoric
            ? 'historic'
            : a.isColloquial
            ? 'colloquial'
            : 'alternate',
        isSearchable: searchable,
      ),
    );
  }
  aliases.sort(
    (a, b) => _cmp(
      [a.cityGeonamesId, a.alternateNameId],
      [b.cityGeonamesId, b.alternateNameId],
    ),
  );

  // Every alias override must have matched something.
  for (final o in overrides.where((o) => o.entity == 'alias')) {
    if (!alternateNames.any((a) => a.id == o.geonamesId)) {
      problems.add(
        'overrides.csv: alias ${o.geonamesId} is not in the alternate names file',
      );
    }
  }
  if (problems.isNotEmpty) throw LocationBuildException(problems);
  report.excludedByOverride.sort();
  report.unlinkedCities.sort();
  report.skippedNoProvince.sort();
  report.nationwideDuplicateNames.sort();
  report.ambiguousAliases.sort();
  report.overridesApplied.sort();
  return LocationBuild(
    provinces: provinces,
    districts: districts,
    cities: cities,
    cityDistricts: links,
    aliases: aliases,
    report: report,
  );
}

bool _aliasBetter(AltName a, AltName b) {
  int score(AltName x) =>
      (x.isPreferred ? 4 : 0) +
      (x.language == 'en' ? 2 : 0) +
      (x.isHistoric ? 0 : 1);
  final sa = score(a), sb = score(b);
  return sa != sb ? sa > sb : a.id < b.id;
}

String _cityKind(GeoRecord r, String name) {
  if (RegExp(
    r'\bcantonment\b|\bcantt\b',
    caseSensitive: false,
  ).hasMatch(name)) {
    return 'cantonment';
  }
  if (r.featureCode == 'PPLC' ||
      r.featureCode == 'PPLA' ||
      r.featureCode == 'PPLA2' ||
      r.population >= 100000) {
    return 'city';
  }
  return 'town';
}

List<String> _altNames(String name, List<String> candidates) {
  final own = searchKey(name);
  final out = <String, String>{};
  for (final c in candidates) {
    final t = c.trim();
    final k = searchKey(t);
    if (k == null || k == own || !_validName(t)) continue;
    out.putIfAbsent(t, () => t);
  }
  return out.keys.toList()..sort();
}

void _unique(Iterable<String?> keys, String what, List<String> problems) {
  final seen = <String>{};
  for (final k in keys) {
    if (k != null && !seen.add(k)) problems.add('duplicate $what: $k');
  }
}

int _cmp(List<Object> a, List<Object> b) {
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    final c = x is num && y is num ? x.compareTo(y) : '$x'.compareTo('$y');
    if (c != 0) return c;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Rendering.
// ---------------------------------------------------------------------------
Map<String, String> renderOutputs(
  LocationBuild b, {
  required String sourceVersion,
}) {
  return {
    'provinces.csv': toCsv(
      [
        'geonames_admin1',
        'geonames_id',
        'name',
        'display_name',
        'kind',
        'sort_order',
        'alt_names',
      ],
      [
        for (final p in b.provinces)
          [
            p.admin1,
            p.geonamesId,
            p.name,
            p.displayName,
            p.kind,
            p.sortOrder,
            p.altNames.join('|'),
          ],
      ],
    ),
    'districts.csv': toCsv(
      ['geonames_id', 'geonames_admin1', 'name', 'is_active', 'alt_names'],
      [
        for (final d in b.districts)
          [d.geonamesId, d.admin1, d.name, d.isActive, d.altNames.join('|')],
      ],
    ),
    'cities.csv': toCsv(
      [
        'geonames_id',
        'geonames_admin1',
        'name',
        'qualifier',
        'kind',
        'geonames_fcode',
        'featured_rank',
        'latitude',
        'longitude',
        'is_active',
      ],
      [
        for (final c in b.cities)
          [
            c.geonamesId,
            c.admin1,
            c.name,
            c.qualifier,
            c.kind,
            c.featureCode,
            c.featuredRank,
            c.latitude,
            c.longitude,
            c.isActive,
          ],
      ],
    ),
    'city_districts.csv': toCsv(
      ['city_geonames_id', 'district_geonames_id', 'is_primary'],
      [
        for (final l in b.cityDistricts)
          [l.cityGeonamesId, l.districtGeonamesId, l.isPrimary],
      ],
    ),
    'city_aliases.csv': toCsv(
      [
        'geonames_alternatename_id',
        'city_geonames_id',
        'alias',
        'language',
        'kind',
        'is_searchable',
      ],
      [
        for (final a in b.aliases)
          [
            a.alternateNameId,
            a.cityGeonamesId,
            a.alias,
            a.language,
            a.kind,
            a.isSearchable,
          ],
      ],
    ),
    'apply_locations.sql': renderApplySql(b, sourceVersion: sourceVersion),
    'import_report.md': renderReport(b, sourceVersion: sourceVersion),
  };
}

String sqlText(String? s) =>
    s == null ? 'null' : "'${s.replaceAll("'", "''")}'";
String _sqlArray(List<String> xs) => xs.isEmpty
    ? "'{}'::text[]"
    : 'array[${xs.map(sqlText).join(', ')}]::text[]';

String _values(List<List<String>> rows) =>
    rows.map((r) => '  (${r.join(', ')})').join(',\n');

String renderApplySql(LocationBuild b, {required String sourceVersion}) {
  final v = sqlText(sourceVersion);
  final featuredCount = b.cities.where((c) => c.featuredRank != null).length;
  final s = StringBuffer()
    ..writeln(
      '-- CricEco · D1 location data (GENERATED by tool/locations/build_locations.dart — do not edit).',
    )
    ..writeln(
      '-- Source: GeoNames (CC BY 4.0, see ATTRIBUTION.md) · $sourceVersion',
    )
    ..writeln(
      '-- Rows: ${b.provinces.length} provinces, ${b.districts.length} districts, ${b.cities.length} cities, '
      '${b.cityDistricts.length} city↔district links, ${b.aliases.length} aliases.',
    )
    ..writeln(
      '-- Requires migration 6. Re-runnable: rows are matched on GeoNames ids (never on database ids);',
    )
    ..writeln(
      '-- changed rows are updated, nothing is deleted or deactivated by this script. Rows in the',
    )
    ..writeln(
      '-- database that this version no longer contains are only reported (NOTICE).',
    )
    ..writeln(
      '-- Run the WHOLE file at once. Any failed check aborts it and changes nothing.',
    )
    ..writeln()
    ..writeln('begin;')
    ..writeln("set local lock_timeout = '5s';")
    ..writeln()
    ..writeln('do \$\$ begin')
    ..writeln("  if to_regclass('public.cities') is null then")
    ..writeln(
      "    raise exception 'D1: migration 6 (location tables) is not applied';",
    )
    ..writeln('  end if;')
    ..writeln('end \$\$;')
    ..writeln()
    ..writeln(
      'create temporary table stage_provinces (geonames_admin1 text, geonames_id integer, name text, '
      'display_name text, kind text, sort_order smallint, alt_names text[]) on commit drop;',
    )
    ..writeln('insert into stage_provinces values')
    ..writeln(
      _values([
        for (final p in b.provinces)
          [
            sqlText(p.admin1),
            '${p.geonamesId}',
            sqlText(p.name),
            sqlText(p.displayName),
            sqlText(p.kind),
            '${p.sortOrder}',
            _sqlArray(p.altNames),
          ],
      ]),
    )
    ..writeln(';')
    ..writeln()
    ..writeln(
      'create temporary table stage_districts (geonames_id integer, geonames_admin1 text, name text, '
      'is_active boolean, alt_names text[]) on commit drop;',
    )
    ..writeln('insert into stage_districts values')
    ..writeln(
      _values([
        for (final d in b.districts)
          [
            '${d.geonamesId}',
            sqlText(d.admin1),
            sqlText(d.name),
            '${d.isActive}',
            _sqlArray(d.altNames),
          ],
      ]),
    )
    ..writeln(';')
    ..writeln()
    ..writeln(
      'create temporary table stage_cities (geonames_id integer, geonames_admin1 text, name text, '
      'qualifier text, kind text, geonames_fcode text, featured_rank smallint, latitude numeric(8,5), '
      'longitude numeric(8,5), is_active boolean) on commit drop;',
    )
    ..writeln('insert into stage_cities values')
    ..writeln(
      _values([
        for (final c in b.cities)
          [
            '${c.geonamesId}',
            sqlText(c.admin1),
            sqlText(c.name),
            sqlText(c.qualifier),
            sqlText(c.kind),
            sqlText(c.featureCode),
            c.featuredRank == null ? 'null' : '${c.featuredRank}',
            c.latitude,
            c.longitude,
            '${c.isActive}',
          ],
      ]),
    )
    ..writeln(';')
    ..writeln()
    ..writeln(
      'create temporary table stage_city_districts (city_geonames_id integer, district_geonames_id integer, '
      'is_primary boolean) on commit drop;',
    );
  if (b.cityDistricts.isNotEmpty) {
    s
      ..writeln('insert into stage_city_districts values')
      ..writeln(
        _values([
          for (final l in b.cityDistricts)
            [
              '${l.cityGeonamesId}',
              '${l.districtGeonamesId}',
              '${l.isPrimary}',
            ],
        ]),
      )
      ..writeln(';');
  }
  s
    ..writeln()
    ..writeln(
      'create temporary table stage_city_aliases (geonames_alternatename_id integer, city_geonames_id integer, '
      'alias text, language text, kind text, is_searchable boolean) on commit drop;',
    );
  if (b.aliases.isNotEmpty) {
    s
      ..writeln('insert into stage_city_aliases values')
      ..writeln(
        _values([
          for (final a in b.aliases)
            [
              '${a.alternateNameId}',
              '${a.cityGeonamesId}',
              sqlText(a.alias),
              sqlText(a.language),
              sqlText(a.kind),
              '${a.isSearchable}',
            ],
        ]),
      )
      ..writeln(';');
  }
  s.writeln(_applyBody(v, featuredCount: featuredCount));
  return s.toString();
}

String _applyBody(String v, {required int featuredCount}) =>
    '''

-- Provinces (matched on the GeoNames admin1 code).
do \$\$
declare n_ins int; n_upd int;
begin
  with x as (
    insert into public.provinces (name, display_name, kind, alt_names, geonames_id, geonames_admin1, sort_order,
                                  is_active, source, source_version)
    select s.name, s.display_name, s.kind, s.alt_names, s.geonames_id, s.geonames_admin1, s.sort_order,
           true, 'geonames', $v
      from stage_provinces s
    on conflict (geonames_admin1) do update
       set name = excluded.name, display_name = excluded.display_name, kind = excluded.kind,
           alt_names = excluded.alt_names, geonames_id = excluded.geonames_id, sort_order = excluded.sort_order,
           source_version = excluded.source_version
     where (provinces.name, provinces.display_name, provinces.kind, provinces.alt_names, provinces.geonames_id,
            provinces.sort_order)
           is distinct from
           (excluded.name, excluded.display_name, excluded.kind, excluded.alt_names, excluded.geonames_id,
            excluded.sort_order)
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into n_ins, n_upd from x;
  raise notice 'provinces: % inserted, % updated, % unchanged', n_ins, n_upd,
    (select count(*) from stage_provinces) - n_ins - n_upd;
end \$\$;

-- Districts (matched on the GeoNames id).
do \$\$
declare n_ins int; n_upd int;
begin
  if exists (select 1 from stage_districts s left join public.provinces p on p.geonames_admin1 = s.geonames_admin1
              where p.id is null) then
    raise exception 'D1: a district refers to an unknown province';
  end if;
  with x as (
    insert into public.districts (province_id, name, alt_names, geonames_id, is_active, source, source_version)
    select p.id, s.name, s.alt_names, s.geonames_id, s.is_active, 'geonames', $v
      from stage_districts s join public.provinces p on p.geonames_admin1 = s.geonames_admin1
    on conflict (geonames_id) do update
       set province_id = excluded.province_id, name = excluded.name, alt_names = excluded.alt_names,
           is_active = excluded.is_active, source_version = excluded.source_version
     where (districts.province_id, districts.name, districts.alt_names, districts.is_active)
           is distinct from (excluded.province_id, excluded.name, excluded.alt_names, excluded.is_active)
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into n_ins, n_upd from x;
  raise notice 'districts: % inserted, % updated, % unchanged', n_ins, n_upd,
    (select count(*) from stage_districts) - n_ins - n_upd;
end \$\$;

-- Cities (matched on the GeoNames id). A featured rank that moves to another
-- city is cleared first, so the unique rank index never blocks the update.
update public.cities c set featured_rank = null
 where c.featured_rank is not null
   and not exists (select 1 from stage_cities s where s.geonames_id = c.geonames_id
                      and s.featured_rank = c.featured_rank);
do \$\$
declare n_ins int; n_upd int;
begin
  with x as (
    insert into public.cities (province_id, name, qualifier, kind, geonames_id, geonames_fcode, featured_rank,
                               latitude, longitude, is_active, source, source_version)
    select p.id, s.name, s.qualifier, s.kind, s.geonames_id, s.geonames_fcode, s.featured_rank,
           s.latitude, s.longitude, s.is_active, 'geonames', $v
      from stage_cities s join public.provinces p on p.geonames_admin1 = s.geonames_admin1
    on conflict (geonames_id) do update
       set province_id = excluded.province_id, name = excluded.name, qualifier = excluded.qualifier,
           kind = excluded.kind, geonames_fcode = excluded.geonames_fcode, featured_rank = excluded.featured_rank,
           latitude = excluded.latitude, longitude = excluded.longitude, is_active = excluded.is_active,
           source_version = excluded.source_version
     where (cities.province_id, cities.name, cities.qualifier, cities.kind, cities.geonames_fcode,
            cities.featured_rank, cities.latitude, cities.longitude, cities.is_active)
           is distinct from
           (excluded.province_id, excluded.name, excluded.qualifier, excluded.kind, excluded.geonames_fcode,
            excluded.featured_rank, excluded.latitude, excluded.longitude, excluded.is_active)
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into n_ins, n_upd from x;
  raise notice 'cities: % inserted, % updated, % unchanged', n_ins, n_upd,
    (select count(*) from stage_cities) - n_ins - n_upd;
end \$\$;

-- City ↔ district links. A primary link that moves is demoted first.
update public.city_districts cd set is_primary = false
  from public.cities c, public.districts d
 where c.id = cd.city_id and d.id = cd.district_id and cd.is_primary
   and not exists (select 1 from stage_city_districts s
                    where s.city_geonames_id = c.geonames_id and s.district_geonames_id = d.geonames_id
                      and s.is_primary);
do \$\$
declare n int;
begin
  with x as (
    insert into public.city_districts (city_id, district_id, province_id, is_primary, source)
    select c.id, d.id, c.province_id, s.is_primary, 'geonames'
      from stage_city_districts s
      join public.cities c on c.geonames_id = s.city_geonames_id
      join public.districts d on d.geonames_id = s.district_geonames_id
    on conflict (city_id, district_id) do update set is_primary = excluded.is_primary
     where city_districts.is_primary is distinct from excluded.is_primary
    returning 1)
  select count(*) into n from x;
  raise notice 'city_districts: % inserted or updated, % in this version', n,
    (select count(*) from stage_city_districts);
end \$\$;

-- Aliases (matched on the GeoNames alternate-name id).
do \$\$
declare n_ins int; n_upd int;
begin
  with x as (
    insert into public.city_aliases (city_id, alias, language, kind, is_searchable, source, geonames_alternatename_id)
    select c.id, s.alias, s.language, s.kind, s.is_searchable, 'geonames', s.geonames_alternatename_id
      from stage_city_aliases s join public.cities c on c.geonames_id = s.city_geonames_id
    on conflict (geonames_alternatename_id) do update
       set city_id = excluded.city_id, alias = excluded.alias, language = excluded.language,
           kind = excluded.kind, is_searchable = excluded.is_searchable
     where (city_aliases.city_id, city_aliases.alias, city_aliases.language, city_aliases.kind,
            city_aliases.is_searchable)
           is distinct from
           (excluded.city_id, excluded.alias, excluded.language, excluded.kind, excluded.is_searchable)
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into n_ins, n_upd from x;
  raise notice 'city_aliases: % inserted, % updated, % unchanged', n_ins, n_upd,
    (select count(*) from stage_city_aliases) - n_ins - n_upd;
end \$\$;

-- Checks (abort on failure) and the report of rows this version no longer has.
do \$\$
begin
  if (select count(*) from public.cities where featured_rank is not null) <> $featuredCount then
    raise exception 'D1: expected $featuredCount featured cities';
  end if;
  if exists (select 1 from stage_cities s left join public.cities c on c.geonames_id = s.geonames_id where c.id is null)
     or exists (select 1 from stage_districts s left join public.districts d on d.geonames_id = s.geonames_id where d.id is null)
     or exists (select 1 from stage_city_aliases s left join public.city_aliases a
                   on a.geonames_alternatename_id = s.geonames_alternatename_id where a.id is null)
     or (select count(*) from stage_city_districts s
           join public.cities c on c.geonames_id = s.city_geonames_id
           join public.districts d on d.geonames_id = s.district_geonames_id
           join public.city_districts cd on cd.city_id = c.id and cd.district_id = d.id and cd.is_primary = s.is_primary)
        <> (select count(*) from stage_city_districts) then
    raise exception 'D1: not every staged row is present after the load';
  end if;
  raise notice 'not in this source version (left unchanged, review): % provinces, % districts, % cities, % aliases',
    (select count(*) from public.provinces p where p.source = 'geonames'
        and not exists (select 1 from stage_provinces s where s.geonames_admin1 = p.geonames_admin1)),
    (select count(*) from public.districts d where d.source = 'geonames'
        and not exists (select 1 from stage_districts s where s.geonames_id = d.geonames_id)),
    (select count(*) from public.cities c where c.source = 'geonames'
        and not exists (select 1 from stage_cities s where s.geonames_id = c.geonames_id)),
    (select count(*) from public.city_aliases a where a.source = 'geonames'
        and not exists (select 1 from stage_city_aliases s where s.geonames_alternatename_id = a.geonames_alternatename_id));
end \$\$;

commit;''';

String renderReport(LocationBuild b, {required String sourceVersion}) {
  final r = b.report;
  final s = StringBuffer();
  void line([String x = '']) => s.writeln(x);
  void list(String title, List<String> xs, {int max = 1000}) {
    line('### $title (${xs.length})');
    line();
    if (xs.isEmpty) line('_None._');
    for (final x in xs.take(max)) {
      line('- $x');
    }
    if (xs.length > max) line('- … ${xs.length - max} more');
    line();
  }

  line('# CricEco location seed — import report');
  line();
  line(
    'Generated by `tool/locations/build_locations.dart` (deterministic). Source: GeoNames, CC BY 4.0 '
    '— $sourceVersion. HDX and PBS were not used.',
  );
  line();
  line('## Totals');
  line();
  line('| Table | Rows | Active |');
  line('|---|---|---|');
  line('| provinces | ${b.provinces.length} | ${b.provinces.length} |');
  line(
    '| districts | ${b.districts.length} | ${b.districts.where((d) => d.isActive).length} |',
  );
  line(
    '| cities | ${b.cities.length} | ${b.cities.where((c) => c.isActive).length} |',
  );
  line('| city_districts | ${b.cityDistricts.length} | — |');
  line(
    '| city_aliases | ${b.aliases.length} | ${b.aliases.where((a) => a.isSearchable).length} searchable |',
  );
  line();
  line('## Selection');
  line();
  line('- GeoNames populated places read: ${r.populatedPlaces}.');
  line(
    '- Selected as capital / admin seat (${seatCodes.join(', ')}): ${r.selectedBySeat}; '
    'by GeoNames population ≥ $minPopulation: ${r.selectedByPopulation}; '
    'featured (forced): ${b.cities.where((c) => c.featuredRank != null).length}.',
  );
  line('- Never taken: ${excludedPlaceCodes.join(', ')}.');
  final codes = r.placeCodeCounts.keys.toList()..sort();
  line(
    '- Populated-place codes in the dump: ${codes.map((c) => '$c ${r.placeCodeCounts[c]}').join(', ')}.',
  );
  final kinds = <String, int>{};
  for (final c in b.cities) {
    kinds[c.kind] = (kinds[c.kind] ?? 0) + 1;
  }
  line(
    '- City kinds: ${(kinds.keys.toList()..sort()).map((k) => '$k ${kinds[k]}').join(', ')}.',
  );
  line(
    '- Cities with a district link: ${b.cityDistricts.map((l) => l.cityGeonamesId).toSet().length} '
    'of ${b.cities.length}.',
  );
  line();
  line('## Provinces');
  line();
  line(
    '| Order | GeoNames admin1 | Name | Display name | Kind | Districts | Cities |',
  );
  line('|---|---|---|---|---|---|---|');
  for (final p in b.provinces) {
    line(
      '| ${p.sortOrder} | ${p.admin1} (${p.geonamesId}) | ${p.name} | ${p.displayName ?? '—'} | ${p.kind} | '
      '${b.districts.where((d) => d.admin1 == p.admin1 && d.isActive).length} active / '
      '${b.districts.where((d) => d.admin1 == p.admin1).length} | '
      '${b.cities.where((c) => c.admin1 == p.admin1).length} |',
    );
  }
  line();
  line('## Featured cities');
  line();
  line('| Rank | Name | GeoNames id | Code | Province | Primary district |');
  line('|---|---|---|---|---|---|');
  final provName = {
    for (final p in b.provinces) p.admin1: p.displayName ?? p.name,
  };
  final distName = {for (final d in b.districts) d.geonamesId: d.name};
  final primary = {
    for (final l in b.cityDistricts.where((l) => l.isPrimary))
      l.cityGeonamesId: l.districtGeonamesId,
  };
  for (final c in [
    ...b.cities.where((c) => c.featuredRank != null),
  ]..sort((a, b) => a.featuredRank!.compareTo(b.featuredRank!))) {
    line(
      '| ${c.featuredRank} | ${c.name} | ${c.geonamesId} | ${c.featureCode} | ${provName[c.admin1]} | '
      '${primary[c.geonamesId] == null ? '— (none)' : distName[primary[c.geonamesId]]} |',
    );
  }
  line();
  line('## Review items');
  line();
  list('Overrides applied (overrides.csv)', r.overridesApplied);
  list('Excluded by override', r.excludedByOverride);
  list('Inactive districts', [
    for (final d in b.districts.where((d) => !d.isActive))
      '${d.geonamesId} ${d.name} (${provName[d.admin1]})',
  ]);
  list('Cities without a district link', r.unlinkedCities, max: 300);
  list('Skipped: no province (GeoNames admin1 missing)', r.skippedNoProvince);
  list(
    'Same city name in more than one province (allowed; shown with province)',
    r.nationwideDuplicateNames,
  );
  list(
    'Aliases made non-searchable (equal another city name in the province)',
    r.ambiguousAliases,
  );
  line('### Alias candidates');
  line();
  line(
    '${r.aliasCandidates} alternate names for the selected cities; kept ${b.aliases.length}. Dropped:',
  );
  line();
  for (final k in r.aliasDropped.keys.toList()..sort()) {
    line('- $k: ${r.aliasDropped[k]}');
  }
  line();
  line(
    'Language / code values dropped: ${(r.droppedLanguages.toList()..sort()).join(', ')}.',
  );
  line();
  final langs = <String, int>{};
  for (final a in b.aliases) {
    langs[a.language ?? '(untagged)'] =
        (langs[a.language ?? '(untagged)'] ?? 0) + 1;
  }
  line(
    'Kept by language: ${(langs.keys.toList()..sort()).map((k) => '$k ${langs[k]}').join(', ')}.',
  );
  return s.toString();
}
