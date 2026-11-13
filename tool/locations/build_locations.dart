// CricEco Stage 4.2 — builds the location seed from the GeoNames files.
//
//   dart run tool/locations/build_locations.dart \
//     --dump <extracted geonames PK.txt> \
//     --alternatenames <extracted alternatenames PK.txt> \
//     --source-version "<what was downloaded, when, sha256>" \
//     [--seed-dir supabase/seed/locations] [--check]
//
// Reads the curated province_display.csv, featured_cities.csv and
// overrides.csv from the seed directory and (re)writes the generated files
// there. --check writes nothing: it exits 1 if any generated file would
// change (a determinism / staleness check). The GeoNames files are read
// only; nothing is downloaded.
import 'dart:io';

import 'locations_import.dart';

const generated = [
  'provinces.csv',
  'districts.csv',
  'cities.csv',
  'city_districts.csv',
  'city_aliases.csv',
  'apply_locations.sql',
  'import_report.md',
];

Future<void> main(List<String> args) async {
  final opts = <String, String>{};
  var check = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--check') {
      check = true;
    } else if (a.startsWith('--') && i + 1 < args.length) {
      opts[a.substring(2)] = args[++i];
    } else {
      _fail('unexpected argument: $a');
    }
  }
  final dump = opts['dump'],
      alt = opts['alternatenames'],
      version = opts['source-version'];
  if (dump == null || alt == null || version == null) {
    _fail(
      'usage: --dump <PK.txt> --alternatenames <PK.txt> --source-version <text> [--seed-dir <dir>] [--check]',
    );
  }
  final dir = opts['seed-dir'] ?? 'supabase/seed/locations';

  String readFile(String path) {
    final f = File(path);
    if (!f.existsSync()) _fail('missing file: $path');
    return f.readAsStringSync();
  }

  final LocationBuild build;
  try {
    build = buildLocations(
      records: parseGeoNames(readFile(dump)),
      alternateNames: parseAlternateNames(readFile(alt)),
      provinceDisplay: parseProvinceDisplay(
        readFile('$dir/province_display.csv'),
      ),
      featured: parseFeatured(readFile('$dir/featured_cities.csv')),
      overrides: parseOverrides(readFile('$dir/overrides.csv')),
    );
  } on LocationBuildException catch (e) {
    stderr.writeln(
      'BUILD STOPPED — fix these and run again (nothing was written):',
    );
    for (final p in e.problems) {
      stderr.writeln('  - $p');
    }
    exit(2);
  }

  final outputs = renderOutputs(build, sourceVersion: version);
  var changed = 0;
  for (final name in generated) {
    final file = File('$dir/$name');
    final next = outputs[name]!;
    final same = file.existsSync() && file.readAsStringSync() == next;
    if (!same) changed++;
    if (check) {
      stdout.writeln('${same ? 'same   ' : 'CHANGED'} $name');
    } else if (!same) {
      file.writeAsStringSync(next);
      stdout.writeln('wrote  $name (${next.length} chars)');
    } else {
      stdout.writeln('same   $name');
    }
  }
  stdout.writeln(
    'provinces ${build.provinces.length}, districts ${build.districts.length}, '
    'cities ${build.cities.length}, links ${build.cityDistricts.length}, aliases ${build.aliases.length}',
  );
  if (check && changed > 0) exit(1);
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(64);
}
