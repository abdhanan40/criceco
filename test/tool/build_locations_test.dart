import 'package:flutter_test/flutter_test.dart';

import '../../tool/locations/locations_import.dart';

/// Stage 4.2: the GeoNames → location seed rules (tool/locations).
/// All records here are made-up test strings ("Zz…" names), not real data.

// A GeoNames PK.txt line (19 tab-separated columns).
String geo(
  int id,
  String name,
  String fclass,
  String fcode, {
  String admin1 = '01',
  String admin2 = '',
  int pop = 0,
  String ascii = '',
  String lat = '30.1',
  String lon = '70.2',
}) => [
  id,
  name,
  ascii.isEmpty ? name : ascii,
  '',
  lat,
  lon,
  fclass,
  fcode,
  'PK',
  '',
  admin1,
  admin2,
  '',
  '',
  pop,
  '',
  '0',
  'Asia/Karachi',
  '2026-01-01',
].join('\t');

// An alternateNamesV2 line.
String alt(
  int id,
  int geonameId,
  String lang,
  String name, {
  bool preferred = false,
  bool historic = false,
  bool colloquial = false,
}) => [
  id,
  geonameId,
  lang,
  name,
  preferred ? 1 : '',
  '',
  colloquial ? 1 : '',
  historic ? 1 : '',
  '',
  '',
].join('\t');

const provinceCsv =
    'geonames_admin1,name,display_name,kind,sort_order\n'
    '01,Zz North,,province,1\n'
    '02,Zz Territory,Zz Territory Display,administrative_territory,2\n';

final baseRecords = [
  geo(1, 'Zz North Province', 'A', 'ADM1', admin1: '01'),
  geo(2, 'Zz Territory', 'A', 'ADM1', admin1: '02'),
  geo(10, 'Zz Alpha District', 'A', 'ADM2', admin1: '01', admin2: '10'),
  geo(11, 'Zz Beta Agency', 'A', 'ADM2', admin1: '01', admin2: '11'),
  geo(12, 'Zz Gamma', 'A', 'ADM2', admin1: '02', admin2: '12'),
  geo(13, 'Zz Old Tribal Area', 'A', 'ADM2', admin1: '01', admin2: '13'),
  geo(100, 'Zzmetro', 'P', 'PPLA', admin1: '01', admin2: '10', pop: 500000),
  geo(101, 'Zzseat', 'P', 'PPLA2', admin1: '01', admin2: '11', pop: 0),
  geo(102, 'Zzbig', 'P', 'PPL', admin1: '02', admin2: '12', pop: 10000),
  geo(103, 'Zzsmall', 'P', 'PPL', admin1: '01', admin2: '10', pop: 9999),
  geo(104, 'Zzsection', 'P', 'PPLX', admin1: '01', admin2: '10', pop: 900000),
  geo(
    105,
    'Zzfeatured Village',
    'P',
    'PPL',
    admin1: '01',
    admin2: '10',
    pop: 0,
  ),
  geo(
    106,
    'Zzfrontier Town',
    'P',
    'PPL',
    admin1: '01',
    admin2: '13',
    pop: 20000,
  ),
  geo(107, 'Zzloose', 'P', 'PPL', admin1: '01', pop: 30000),
  geo(108, 'Zz Cantt', 'P', 'PPL', admin1: '01', admin2: '10', pop: 15000),
];

const featuredCsv =
    'featured_rank,name,geonames_id\n1,Zzmetro,100\n2,Zzfeatured Village,105\n';

LocationBuild build({
  List<String>? records,
  List<String> alts = const [],
  String provinces = provinceCsv,
  String featured = featuredCsv,
  String overrides = 'entity,geonames_id,action,value,reason\n',
}) => buildLocations(
  records: parseGeoNames((records ?? baseRecords).join('\n')),
  alternateNames: parseAlternateNames(alts.join('\n')),
  provinceDisplay: parseProvinceDisplay(provinces),
  featured: parseFeatured(featured),
  overrides: parseOverrides(overrides),
);

Matcher problemContaining(String text) => isA<LocationBuildException>().having(
  (e) => e.problems.join('\n'),
  'problems',
  contains(text),
);

void main() {
  group('searchKey (mirror of public.location_search_key)', () {
    test('the cases checked in SQL test 06', () {
      expect(searchKey('Jāfarābād'), 'jafarabad');
      expect(searchKey('  Rahim-Yar  Khan '), 'rahim yar khan');
      expect(searchKey('D.I. Khan'), 'd i khan');
      expect(searchKey('ÑÇṢṬḌẒḤṚŚ'), 'ncstdzhrs');
      expect(searchKey('ĀĪŪĒŌ'), 'aiueo');
      expect(searchKey('کراچی'), 'کراچی');
      expect(searchKey('---'), isNull);
      expect(searchKey(null), isNull);
    });

    test('folds only A–Z and the listed letters (locale independent)', () {
      expect(searchKey('LAHORE'), 'lahore');
      expect(
        searchKey('Ş'),
        'Ş',
      ); // not in the table: kept as is, exactly like the SQL function
      expect(searchKey("Khairpur Mir's"), 'khairpur mir s');
      expect(searchKey('Tando Adam'), 'tando adam');
    });
  });

  group('CSV', () {
    test('quotes, doubled quotes, commas, CRLF and comment lines', () {
      final rows = parseCsv(
        '# a comment, with a comma\r\na,b,c\r\n1,"x, ""y""",\r\n# another\r\n2,plain,z\r\n',
      );
      expect(rows, [
        {'a': '1', 'b': 'x, "y"', 'c': ''},
        {'a': '2', 'b': 'plain', 'c': 'z'},
      ]);
    });

    test('round trip', () {
      final text = toCsv(
        ['k', 'v'],
        [
          ['a', 'with, comma'],
          ['b', 'say "hi"'],
          ['c', null],
        ],
      );
      expect(parseCsv(text), [
        {'k': 'a', 'v': 'with, comma'},
        {'k': 'b', 'v': 'say "hi"'},
        {'k': 'c', 'v': ''},
      ]);
    });
  });

  group('selection', () {
    test('seats always, others from population 10,000; never PPLX', () {
      final ids = build().cities.map((c) => c.geonamesId).toSet();
      expect(ids, containsAll([100, 101, 102, 106, 107, 108]));
      expect(ids, isNot(contains(103))); // population 9,999
      expect(
        ids,
        isNot(contains(104)),
      ); // section of a place, despite its population
    });

    test('featured cities are forced in, ranked, and checked', () {
      final b = build();
      final f = b.cities.where((c) => c.featuredRank != null).toList()
        ..sort((a, c) => a.featuredRank!.compareTo(c.featuredRank!));
      expect(f.map((c) => c.geonamesId), [100, 105]);
      expect(
        () => build(
          featured: 'featured_rank,name,geonames_id\n1,Zzsection,104\n',
        ),
        throwsA(problemContaining('not an importable populated place')),
      );
      expect(
        () => build(
          featured: 'featured_rank,name,geonames_id\n1,Wrong Name,100\n',
        ),
        throwsA(problemContaining('not "Wrong Name"')),
      );
      expect(
        () => build(
          featured: 'featured_rank,name,geonames_id\n1,Zzmetro,100\n3,Zzfeatured Village,105\n',
        ),
        throwsA(problemContaining('without gaps')),
      );
    });

    test(
      'kinds: city for seats / 100,000+, cantonment by name, otherwise town',
      () {
        final kind = {for (final c in build().cities) c.geonamesId: c.kind};
        expect(kind[100], 'city');
        expect(kind[101], 'city');
        expect(kind[102], 'town');
        expect(kind[108], 'cantonment');
      },
    );

    test('coordinates are written with 5 decimals', () {
      final c = build().cities.firstWhere((c) => c.geonamesId == 100);
      expect(c.latitude, '30.10000');
      expect(c.longitude, '70.20000');
    });
  });

  group('provinces and districts', () {
    test('display rows are required for every ADM1, and kinds are checked', () {
      expect(
        () => build(
          provinces: 'geonames_admin1,name,display_name,kind,sort_order\n01,Zz North,,province,1\n',
        ),
        throwsA(problemContaining('no row for GeoNames admin1 02')),
      );
      expect(
        () =>
            build(provinces: provinceCsv.replaceFirst('province,1', 'state,1')),
        throwsA(problemContaining('unknown kind')),
      );
      final p = build().provinces;
      expect(p.map((x) => x.name), ['Zz North', 'Zz Territory']);
      expect(p.first.altNames, ['Zz North Province']);
      expect(p.last.displayName, 'Zz Territory Display');
    });

    test('" District" is stripped; the original spelling becomes an alternate name', () {
      final d = build().districts.firstWhere((d) => d.geonamesId == 10);
      expect(d.name, 'Zz Alpha');
      expect(d.altNames, ['Zz Alpha District']);
    });

    test(
      'overrides: rename, inactive (its cities stay but unlinked), exclude',
      () {
        final b = build(
          overrides:
              'entity,geonames_id,action,value,reason\n'
              'district,11,rename,Zz Beta,old suffix\n'
              'district,13,inactive,,merged\n'
              'district,12,exclude,,duplicate\n',
        );
        final names = {for (final d in b.districts) d.geonamesId: d};
        expect(names[11]!.name, 'Zz Beta');
        expect(names[11]!.altNames, contains('Zz Beta Agency'));
        expect(names[13]!.isActive, isFalse);
        expect(names.containsKey(12), isFalse);
        final linked = b.cityDistricts.map((l) => l.cityGeonamesId).toSet();
        expect(linked, isNot(contains(106))); // in the inactive district
        expect(linked, isNot(contains(102))); // its district was excluded
        expect(linked, isNot(contains(107))); // no admin2 in GeoNames
        expect(
          b.cityDistricts
              .where((l) => l.cityGeonamesId == 100)
              .single
              .districtGeonamesId,
          10,
        );
        expect(b.cities.map((c) => c.geonamesId), containsAll([102, 106, 107]));
        expect(b.report.unlinkedCities.join('\n'), contains('is inactive'));
      },
    );

    test('two districts with one name in a province stop the build', () {
      expect(
        () => build(
          records: [
            ...baseRecords,
            geo(14, 'Zz Alpha', 'A', 'ADM2', admin1: '01', admin2: '14'),
          ],
        ),
        throwsA(problemContaining('duplicate district name')),
      );
    });
  });

  group('cities: name clashes', () {
    final twin = geo(
      109,
      'Zzmetro',
      'P',
      'PPL',
      admin1: '01',
      admin2: '11',
      pop: 20000,
    );

    test('same name in one province stops the build', () {
      expect(
        () => build(records: [...baseRecords, twin]),
        throwsA(problemContaining('city name clash')),
      );
    });

    test('a qualifier or an exclusion resolves it', () {
      final q = build(
        records: [...baseRecords, twin],
        overrides: 'entity,geonames_id,action,value,reason\ncity,109,qualifier,Zz Beta,two towns\n',
      );
      expect(
        q.cities.firstWhere((c) => c.geonamesId == 109).qualifier,
        'Zz Beta',
      );
      final e = build(
        records: [...baseRecords, twin],
        overrides: 'entity,geonames_id,action,value,reason\ncity,109,exclude,,copied population\n',
      );
      expect(e.cities.any((c) => c.geonamesId == 109), isFalse);
      expect(e.report.excludedByOverride.single, contains('copied population'));
    });

    test('a featured city cannot be excluded', () {
      expect(
        () => build(
          overrides:
              'entity,geonames_id,action,value,reason\ncity,100,exclude,,x\n',
        ),
        throwsA(problemContaining('featured city 100 cannot be excluded')),
      );
    });

    test('same name in another province is allowed and reported', () {
      final b = build(
        records: [
          ...baseRecords,
          geo(110, 'Zzmetro', 'P', 'PPLA2', admin1: '02', admin2: '12'),
        ],
      );
      expect(
        b.report.nationwideDuplicateNames.single,
        startsWith('Zzmetro ×2'),
      );
    });
  });

  group('aliases', () {
    final alts = [
      alt(1, 100, 'link', 'https://example.org/Zzmetro'),
      alt(2, 100, 'iata', 'ZZM'),
      alt(3, 100, 'en', 'ZZMETRO'), // same as the name
      alt(4, 100, '', 'Zz Old Metro', historic: true),
      alt(5, 100, 'ur', 'زز میٹرو'),
      alt(6, 100, 'fr', 'Zzmétro Ville'),
      alt(7, 100, 'en', 'Zz Metro City'),
      alt(
        8,
        100,
        '',
        'Zz Metro City',
        preferred: true,
      ), // same spelling: the preferred one wins
      alt(9, 101, '', 'Zzmetro'), // equals another city's name in the province
      alt(10, 999, 'en', 'Not imported'),
    ];

    test('kept: untagged / en / ur names; dropped: codes, other languages, the city name itself', () {
      final b = build(alts: alts);
      final ids = b.aliases.map((a) => a.alternateNameId).toList();
      expect(ids, unorderedEquals([4, 5, 8, 9]));
      final byId = {for (final a in b.aliases) a.alternateNameId: a};
      expect(byId[4]!.kind, 'historic');
      expect(byId[4]!.language, isNull);
      expect(byId[5]!.language, 'ur');
      expect(byId[9]!.isSearchable, isFalse);
      expect(b.report.ambiguousAliases.single, contains('Zzmetro'));
      expect(b.report.droppedLanguages, containsAll(['link', 'iata', 'fr']));
    });

    test('alias overrides: exclude and not_searchable', () {
      final b = build(
        alts: alts,
        overrides: 'entity,geonames_id,action,value,reason\nalias,4,exclude,,wrong\nalias,5,not_searchable,,review\n',
      );
      expect(b.aliases.any((a) => a.alternateNameId == 4), isFalse);
      expect(
        b.aliases.firstWhere((a) => a.alternateNameId == 5).isSearchable,
        isFalse,
      );
    });
  });

  group('override validation', () {
    test('unknown action, missing value, unknown id and duplicates are reported together', () {
      expect(
        () => build(
          overrides:
              'entity,geonames_id,action,value,reason\n'
              'city,100,teleport,,x\n'
              'city,101,qualifier,,x\n'
              'district,424242,inactive,,x\n'
              'district,13,inactive,,x\n'
              'district,13,inactive,,again\n'
              'alias,777,exclude,,x\n',
        ),
        throwsA(
          isA<LocationBuildException>().having(
            (e) => e.problems.join('\n'),
            'problems',
            allOf(
              contains('unknown entity/action'),
              contains('needs a value'),
              contains('424242 is not in'),
              contains('duplicate district 13'),
              contains('alias 777 is not in'),
            ),
          ),
        ),
      );
    });
  });

  group('rendering', () {
    test('deterministic: same input, and shuffled input order, give identical files', () {
      String render(List<String> records) => renderOutputs(
        build(records: records),
        sourceVersion: 'test',
      ).entries.map((e) => '${e.key}\n${e.value}').join();
      final a = render(baseRecords);
      expect(render(baseRecords), a);
      expect(render(baseRecords.reversed.toList()), a);
    });

    test('SQL text is quoted safely and the script is one transaction', () {
      final b = build(
        records: [
          ...baseRecords,
          geo(111, "Zz Mir's Town", 'P', 'PPLA2', admin1: '02', admin2: '12'),
        ],
      );
      final sql = renderOutputs(
        b,
        sourceVersion: "v'1",
      )['apply_locations.sql']!;
      expect(sql, contains("'Zz Mir''s Town'"));
      expect(sql, contains("'v''1'"));
      expect(sql.trimLeft(), startsWith('-- CricEco'));
      expect(RegExp(r'^begin;$', multiLine: true).allMatches(sql).length, 1);
      expect(sql.trimRight(), endsWith('commit;'));
      expect(sql, isNot(contains('delete from')));
      expect(sqlText(null), 'null');
    });

    test('every generated file is listed', () {
      expect(renderOutputs(build(), sourceVersion: 't').keys, [
        'provinces.csv',
        'districts.csv',
        'cities.csv',
        'city_districts.csv',
        'city_aliases.csv',
        'apply_locations.sql',
        'import_report.md',
      ]);
    });
  });
}
