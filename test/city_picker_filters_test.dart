import 'dart:async';

import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/features/location/city_picker.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stage 4.3.2: province / district filtering in the city picker, on a fake
/// [LocationRepository] (made-up hierarchy for the test only).

const punjab = Province(id: 1, name: 'Punjab', kind: ProvinceKind.province);
const sindh = Province(id: 2, name: 'Sindh', kind: ProvinceKind.province);
const lahoreD = District(id: 10, provinceId: 1, name: 'Lahore');
const attockD = District(id: 11, provinceId: 1, name: 'Attock');
const emptyD = District(id: 12, provinceId: 1, name: 'Quiet');
const karachiCentral = District(id: 20, provinceId: 2, name: 'Karachi Central');

CityOption city(
  int id,
  String name, {
  required Province p,
  District? d,
  int? rank,
  String? qualifier,
}) => CityOption(
  id: id,
  name: name,
  qualifier: qualifier,
  provinceId: p.id,
  provinceName: p.name,
  primaryDistrictId: d?.id,
  primaryDistrictName: d?.name,
  districtCount: d == null ? 0 : 1,
  featuredRank: rank,
);

final karachi = city(1, 'Karachi', p: sindh, rank: 1);
final lahore = city(2, 'Lahore', p: punjab, d: lahoreD, rank: 2);
final kamra = city(101, 'Kamra', p: punjab, d: attockD, qualifier: 'Attock');
final hyderabad = city(103, 'Hyderabad', p: sindh, d: karachiCentral);
final catalogue = [karachi, lahore, kamra, hyderabad];

typedef Search = (String, int?, int?);

class FakeHierarchyRepository implements LocationRepository {
  final searches = <Search>[];
  final districtCalls = <int>[];
  Object? searchFailNext;
  Object? provincesFailNext;
  Object? districtsFailNext;
  Completer<List<Province>>? provincesHold;

  @override
  Future<List<Province>> provinces() async {
    final f = provincesFailNext;
    if (f != null) {
      provincesFailNext = null;
      throw f;
    }
    if (provincesHold != null) return provincesHold!.future;
    return const [punjab, sindh];
  }

  @override
  Future<List<District>> districts(int provinceId) async {
    districtCalls.add(provinceId);
    final f = districtsFailNext;
    if (f != null) {
      districtsFailNext = null;
      throw f;
    }
    return [
      for (final d in const [lahoreD, attockD, emptyD, karachiCentral])
        if (d.provinceId == provinceId) d,
    ];
  }

  @override
  Future<List<CityOption>> searchCities(
    String query, {
    int? provinceId,
    int? districtId,
    int limit = 20,
  }) async {
    searches.add((query, provinceId, districtId));
    final f = searchFailNext;
    if (f != null) {
      searchFailNext = null;
      throw f;
    }
    final q = query.trim().toLowerCase();
    if (q.length < 2 && provinceId == null && districtId == null) {
      return [karachi, lahore]; // the featured list
    }
    return [
      for (final c in catalogue)
        if ((provinceId == null || c.provinceId == provinceId) &&
            (districtId == null || c.primaryDistrictId == districtId) &&
            (q.length < 2 || c.name.toLowerCase().startsWith(q)))
          c,
    ];
  }

  @override
  Future<List<CityOption>> featuredCities() async => [karachi, lahore];
  @override
  Future<CityOption?> cityById(int id) async => null;
}

/// A screen with the city field and the Area that depends on it.
class _Host extends StatefulWidget {
  const _Host({this.initial, this.initialArea});
  final CityOption? initial;
  final String? initialArea;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late CityOption? value = widget.initial;
  late String? area = widget.initialArea;
  int changes = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          CityPickerField(
            fieldKey: const Key('city-field'),
            value: value,
            onChanged: (c) => setState(() {
              changes++;
              value = c;
              area = null; // the Area belongs to the old city
            }),
          ),
          Text('area: ${area ?? '-'}', key: const Key('area')),
          Text('changes: $changes', key: const Key('changes')),
        ],
      ),
    ),
  );
}

Future<void> pumpField(
  WidgetTester tester, {
  LocationRepository? repo,
  CityOption? initial,
  String? initialArea,
}) async {
  tester.view.physicalSize = const Size(1170, 2532); // 390 × 844 @3x
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (repo != null) locationRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: _Host(initial: initial, initialArea: initialArea),
      ),
    ),
  );
}

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('city-field')));
  await tester.pumpAndSettle();
}

Finder option(int id) => find.byKey(Key('city-option-$id'));
Finder chip(String label) => find.widgetWithText(CeChip, label);
Finder get districtChip => find.byKey(const Key('district-filter'));

Future<void> tapAndSettle(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> pickDistrict(WidgetTester tester, District? d) async {
  await tapAndSettle(tester, districtChip);
  await tapAndSettle(
    tester,
    find.byKey(Key('district-option-${d?.id ?? 'all'}')),
  );
}

String sectionTitle(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('city-picker-section')),
        matching: find.byType(Text),
      ),
    )
    .data!;

void main() {
  testWidgets('province chips: "All" first and selected; picking one filters '
      'the cities at once', (tester) async {
    final repo = FakeHierarchyRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);

    expect(find.bySemanticsLabel('Filter by province'), findsOneWidget);
    expect(chip('All'), findsOneWidget);
    expect(chip('Punjab'), findsOneWidget);
    expect(chip('Sindh'), findsOneWidget);
    expect(tester.widget<CeChip>(chip('All')).selected, isTrue);
    expect(sectionTitle(tester), 'Popular cities');
    expect(districtChip, findsNothing); // no district without a province

    await tester.tap(chip('Punjab'));
    await tester.pump(); // a filter change searches without the debounce
    await tester.pump();
    expect(repo.searches.last, ('', 1, null));
    expect(tester.widget<CeChip>(chip('Punjab')).selected, isTrue);
    expect(sectionTitle(tester), 'Cities in Punjab');
    expect(option(2), findsOneWidget); // Lahore
    expect(option(101), findsOneWidget); // Kamra
    expect(option(1), findsNothing); // Karachi is in Sindh
  });

  testWidgets('districts: only the selected province\'s; picking one filters', (
    tester,
  ) async {
    final repo = FakeHierarchyRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await tapAndSettle(tester, chip('Punjab'));

    expect(repo.districtCalls, [1]);
    expect(find.text('All districts'), findsOneWidget);
    await tapAndSettle(tester, districtChip);
    expect(find.text('District in Punjab'), findsOneWidget);
    expect(find.byKey(const Key('district-option-10')), findsOneWidget);
    expect(find.byKey(const Key('district-option-11')), findsOneWidget);
    expect(find.text('Karachi Central'), findsNothing); // Sindh's
    await tapAndSettle(tester, find.byKey(const Key('district-option-11')));

    expect(repo.searches.last, ('', 1, 11));
    expect(sectionTitle(tester), 'Cities in Attock');
    expect(option(101), findsOneWidget);
    expect(option(2), findsNothing);
    expect(tester.widget<CeChip>(districtChip).label, 'Attock');
    expect(tester.widget<CeChip>(districtChip).selected, isTrue);
  });

  testWidgets('changing the province resets the district; "All" clears both', (
    tester,
  ) async {
    final repo = FakeHierarchyRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await tapAndSettle(tester, chip('Punjab'));
    await pickDistrict(tester, attockD);
    expect(repo.searches.last, ('', 1, 11));

    await tapAndSettle(tester, chip('Sindh'));
    expect(repo.searches.last, ('', 2, null)); // district cleared
    expect(repo.districtCalls, [1, 2]);
    expect(tester.widget<CeChip>(districtChip).label, 'All districts');
    expect(option(1), findsOneWidget); // Karachi
    expect(option(101), findsNothing);

    await tapAndSettle(tester, chip('All'));
    expect(repo.searches.last, ('', null, null));
    expect(districtChip, findsNothing);
    expect(sectionTitle(tester), 'Popular cities');
  });

  testWidgets('"All districts" clears only the district', (tester) async {
    final repo = FakeHierarchyRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await tapAndSettle(tester, chip('Punjab'));
    await pickDistrict(tester, attockD);
    await pickDistrict(tester, null);

    expect(repo.searches.last, ('', 1, null));
    expect(tester.widget<CeChip>(districtChip).label, 'All districts');
    expect(tester.widget<CeChip>(chip('Punjab')).selected, isTrue);
  });

  testWidgets('typed text is still debounced, and searched with the filters', (
    tester,
  ) async {
    final repo = FakeHierarchyRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await tapAndSettle(tester, chip('Punjab'));
    final before = repo.searches.length;

    await tester.enterText(find.byKey(const Key('city-picker-search')), 'kam');
    await tester.pump(const Duration(milliseconds: 249));
    expect(repo.searches.length, before);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(repo.searches.last, ('kam', 1, null));
    expect(sectionTitle(tester), 'Results');
    expect(option(101), findsOneWidget);
    expect(option(2), findsNothing);

    // A filter change with text typed searches that text at once.
    await tapAndSettle(tester, chip('Sindh'));
    expect(repo.searches.last, ('kam', 2, null));
    expect(find.byKey(const Key('city-picker-empty')), findsOneWidget);
    expect(
      find.text('Check the spelling, or choose the nearest city.'),
      findsOneWidget,
    );
  });

  testWidgets('an empty filtered list offers "Clear filters"', (tester) async {
    final repo = FakeHierarchyRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await tapAndSettle(tester, chip('Punjab'));
    await pickDistrict(tester, emptyD);

    expect(find.byKey(const Key('city-picker-empty')), findsOneWidget);
    expect(find.text('No cities are listed here yet.'), findsOneWidget);
    await tapAndSettle(tester, find.text('Clear filters'));

    expect(repo.searches.last, ('', null, null));
    expect(tester.widget<CeChip>(chip('All')).selected, isTrue);
    expect(districtChip, findsNothing);
    expect(sectionTitle(tester), 'Popular cities');
  });

  testWidgets(
    'picking a different city resets the Area; the same city changes nothing',
    (tester) async {
      final repo = FakeHierarchyRepository();
      await pumpField(
        tester,
        repo: repo,
        initial: lahore,
        initialArea: 'Gulberg',
      );

      await openSheet(tester);
      await tapAndSettle(tester, option(2)); // Lahore again
      expect(find.text('area: Gulberg'), findsOneWidget);
      expect(find.text('changes: 0'), findsOneWidget);

      await openSheet(tester);
      await tester.enterText(
        find.byKey(const Key('city-picker-search')),
        'kam',
      );
      await tester.pump(kCitySearchDebounce);
      await tester.pumpAndSettle();
      await tapAndSettle(tester, option(101));
      expect(find.text('area: -'), findsOneWidget);
      expect(find.text('changes: 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('city-field')),
          matching: find.text('Kamra (Attock)'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('memory mode: no filters; the 20 featured cities and prefix '
      'search stay', (tester) async {
    await pumpField(tester); // no override: InMemoryLocationRepository
    await openSheet(tester);
    expect(find.byKey(const Key('province-filter')), findsNothing);
    expect(find.bySemanticsLabel('Filter by province'), findsNothing);
    expect(districtChip, findsNothing);
    expect(sectionTitle(tester), 'Popular cities');
    expect(find.text('Karachi'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('city-picker-search')), 'ra');
    await tester.pump(kCitySearchDebounce);
    await tester.pumpAndSettle();
    expect(find.text('Rawalpindi'), findsOneWidget);
    expect(find.text('Rahim Yar Khan'), findsOneWidget);
    expect(find.text('Karachi'), findsNothing);
  });

  testWidgets('the filters appear once the provinces load', (tester) async {
    final repo = FakeHierarchyRepository()
      ..provincesHold = Completer<List<Province>>();
    await pumpField(tester, repo: repo);
    await openSheet(tester);

    expect(option(1), findsOneWidget); // the cities don't wait for them
    expect(find.byKey(const Key('province-filter')), findsNothing);
    repo.provincesHold!.complete(const [punjab, sindh]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('province-filter')), findsOneWidget);
  });

  testWidgets('provinces that fail to load can be retried', (tester) async {
    final repo = FakeHierarchyRepository()
      ..provincesFailNext = const BackendUnavailableException();
    await pumpField(tester, repo: repo);
    await openSheet(tester);

    expect(find.text('Couldn\'t load provinces'), findsOneWidget);
    expect(option(1), findsOneWidget); // the city list still works
    await tapAndSettle(tester, find.byKey(const Key('province-retry')));
    expect(find.text('Couldn\'t load provinces'), findsNothing);
    expect(chip('Punjab'), findsOneWidget);
  });

  testWidgets('districts that fail to load can be retried', (tester) async {
    final repo = FakeHierarchyRepository()
      ..districtsFailNext = const BackendUnavailableException();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await tapAndSettle(tester, chip('Punjab'));

    expect(
      tester.widget<CeChip>(districtChip).label,
      'Couldn\'t load districts · Retry',
    );
    await tapAndSettle(tester, districtChip);
    expect(repo.districtCalls, [1, 1]);
    expect(tester.widget<CeChip>(districtChip).label, 'All districts');
  });

  testWidgets('a failed filtered search: Retry keeps the filters', (
    tester,
  ) async {
    final repo = FakeHierarchyRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    repo.searchFailNext = const BackendUnavailableException();
    await tapAndSettle(tester, chip('Punjab'));

    expect(find.byKey(const Key('city-picker-error')), findsOneWidget);
    expect(chip('Punjab'), findsOneWidget); // the filters stay usable
    await tapAndSettle(tester, find.text('Retry'));
    expect(repo.searches.last, ('', 1, null));
    expect(find.byKey(const Key('city-picker-error')), findsNothing);
    expect(sectionTitle(tester), 'Cities in Punjab');
  });
}
