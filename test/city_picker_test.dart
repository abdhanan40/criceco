import 'dart:async';

import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/constants/cities.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/features/location/city_picker.dart';
import 'package:criceco/shared/widgets/ce_list_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stage 4.3.1: the searchable city picker, on a fake [LocationRepository].

final featured = [
  for (var i = 0; i < kPakistanCities.length; i++)
    CityOption(
      id: i + 1,
      name: kPakistanCities[i],
      featuredRank: i + 1,
      provinceName: 'Punjab',
      primaryDistrictName: i == 1 ? 'Lahore' : null,
    ),
];
const kamra = CityOption(
  id: 101,
  name: 'Kamra',
  qualifier: 'Attock',
  provinceName: 'Punjab',
  primaryDistrictName: 'Attock',
);
const kamraRwp = CityOption(
  id: 102,
  name: 'Kamra',
  qualifier: 'Rawalpindi',
  provinceName: 'Punjab',
  primaryDistrictName: 'Rawalpindi',
);

class FakeCityRepository implements LocationRepository {
  final queries = <String>[];
  Object? failNext;

  /// Searches whose answer the test releases by hand (query → completer).
  final held = <String, Completer<List<CityOption>>>{};
  final holdQueries = <String>{};

  Map<String, List<CityOption>> results = {
    'kam': [kamra, kamraRwp],
    'kamra': [kamra, kamraRwp],
  };

  @override
  Future<List<CityOption>> searchCities(
    String query, {
    int? provinceId,
    int? districtId,
    int limit = 20,
  }) async {
    queries.add(query);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    final q = query.trim().toLowerCase();
    if (holdQueries.contains(q)) {
      return (held[q] = Completer<List<CityOption>>()).future;
    }
    return q.length < 2 ? featured : (results[q] ?? const []);
  }

  @override
  Future<List<CityOption>> featuredCities() async => featured;
  @override
  Future<List<Province>> provinces() async => const [];
  @override
  Future<List<District>> districts(int provinceId) async => const [];
  @override
  Future<CityOption?> cityById(int id) async => null;
}

/// The field on a screen; [picked] collects every onChanged.
class _Host extends StatefulWidget {
  const _Host({required this.picked, this.initial, this.validator});
  final List<CityOption> picked;
  final CityOption? initial;
  final String? Function(CityOption?)? validator;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final formKey = GlobalKey<FormState>();
  late CityOption? value = widget.initial;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: formKey,
        child: Column(
          children: [
            CityPickerField(
              fieldKey: const Key('city-field'),
              value: value,
              validator: widget.validator,
              onChanged: (c) {
                widget.picked.add(c);
                setState(() => value = c);
              },
            ),
            TextButton(
              onPressed: () => formKey.currentState!.validate(),
              child: const Text('Validate'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> pumpField(
  WidgetTester tester, {
  LocationRepository? repo,
  List<CityOption>? picked,
  CityOption? initial,
  String? Function(CityOption?)? validator,
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
        home: _Host(
          picked: picked ?? [],
          initial: initial,
          validator: validator,
        ),
      ),
    ),
  );
}

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('city-field')));
  await tester.pumpAndSettle();
}

Finder option(int id) => find.byKey(Key('city-option-$id'));

Future<void> typeQuery(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('city-picker-search')), text);
  await tester.pump();
}

void main() {
  testWidgets('opens on the 20 featured cities, in order', (tester) async {
    final repo = FakeCityRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);

    expect(find.text('Select city'), findsWidgets);
    expect(find.text('Popular cities'), findsOneWidget);
    expect(repo.queries, ['']); // one request: the featured list
    expect(option(1), findsOneWidget);
    expect(find.text('Karachi'), findsOneWidget);
    expect(find.text('Lahore, Punjab'), findsOneWidget); // district, province
    final list = find
        .descendant(
          of: find.byType(CeListSheetFrame),
          matching: find.byType(Scrollable),
        )
        .last;
    await tester.scrollUntilVisible(option(20), 300, scrollable: list);
    expect(find.text('Rahim Yar Khan'), findsOneWidget);
    expect(repo.queries, ['']); // scrolling asks nothing
  });

  testWidgets('searches once, 250 ms after typing stops', (tester) async {
    final repo = FakeCityRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);

    await typeQuery(tester, 'k');
    await tester.pump(const Duration(milliseconds: 100));
    await typeQuery(tester, 'ka');
    await tester.pump(const Duration(milliseconds: 100));
    await typeQuery(tester, 'kam');
    await tester.pump(const Duration(milliseconds: 249));
    expect(repo.queries, ['']); // still waiting
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(repo.queries, ['', 'kam']); // only the last text
    expect(find.text('Results'), findsOneWidget);
  });

  testWidgets(
    'results show name (qualifier) and district / province; tapping picks',
    (tester) async {
      final repo = FakeCityRepository();
      final picked = <CityOption>[];
      await pumpField(tester, repo: repo, picked: picked);
      await openSheet(tester);
      await typeQuery(tester, 'kamra');
      await tester.pump(kCitySearchDebounce);
      await tester.pump();

      expect(find.text('Kamra (Attock)'), findsOneWidget);
      expect(find.text('Kamra (Rawalpindi)'), findsOneWidget);
      // The district is already the qualifier, so only the province is added.
      expect(find.text('Punjab'), findsNWidgets(2));

      await tester.tap(option(102));
      await tester.pumpAndSettle();
      expect(picked.single.id, 102);
      expect(find.byType(CeListSheetFrame), findsNothing); // sheet closed
      expect(
        find.descendant(
          of: find.byKey(const Key('city-field')),
          matching: find.text('Kamra (Rawalpindi)'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('loading first, then the list', (tester) async {
    final repo = FakeCityRepository()..holdQueries.add('');
    await pumpField(tester, repo: repo);
    await tester.tap(find.byKey(const Key('city-field')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('city-picker-loading')), findsOneWidget);
    expect(find.bySemanticsLabel('Loading cities'), findsOneWidget);
    expect(option(1), findsNothing);

    repo.held['']!.complete(featured);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('city-picker-loading')), findsNothing);
    expect(option(1), findsOneWidget);
  });

  testWidgets('a newer search keeps the old list and shows a thin bar', (
    tester,
  ) async {
    final repo = FakeCityRepository()..holdQueries.add('kam');
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await typeQuery(tester, 'kam');
    await tester.pump(kCitySearchDebounce);
    await tester.pump();

    expect(find.byKey(const Key('city-picker-refreshing')), findsOneWidget);
    expect(option(1), findsOneWidget); // the featured list is still shown
    // The label follows the list on screen, not the text being typed.
    expect(find.text('Popular cities'), findsOneWidget);
    expect(find.text('Results'), findsNothing);

    repo.held['kam']!.complete([kamra]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('city-picker-refreshing')), findsNothing);
    expect(option(101), findsOneWidget);
    expect(find.text('Results'), findsOneWidget);
    expect(option(1), findsNothing);
  });

  testWidgets('an older, slower answer never replaces a newer one', (
    tester,
  ) async {
    final repo = FakeCityRepository()
      ..holdQueries.add('aa')
      ..results['bb'] = [kamraRwp];
    await pumpField(tester, repo: repo);
    await openSheet(tester);

    await typeQuery(tester, 'aa');
    await tester.pump(kCitySearchDebounce);
    await typeQuery(tester, 'bb');
    await tester.pump(kCitySearchDebounce);
    await tester.pump();
    expect(option(102), findsOneWidget);

    repo.held['aa']!.complete([kamra]); // the late answer for "aa"
    await tester.pumpAndSettle();
    expect(option(102), findsOneWidget);
    expect(option(101), findsNothing);
  });

  testWidgets('no match → empty state; clearing the search → featured again', (
    tester,
  ) async {
    final repo = FakeCityRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    await typeQuery(tester, 'zzzz');
    await tester.pump(kCitySearchDebounce);
    await tester.pump();

    expect(find.byKey(const Key('city-picker-empty')), findsOneWidget);
    expect(find.text('No matching city'), findsOneWidget);
    expect(
      find.text('Check the spelling, or choose the nearest city.'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump(kCitySearchDebounce);
    await tester.pump();
    expect(find.byKey(const Key('city-picker-empty')), findsNothing);
    expect(find.text('Popular cities'), findsOneWidget);
    expect(option(1), findsOneWidget);
  });

  testWidgets('a failed load shows the error state; Retry loads again', (
    tester,
  ) async {
    final repo = FakeCityRepository()
      ..failNext = const BackendUnavailableException();
    await pumpField(tester, repo: repo);
    await openSheet(tester);

    expect(find.byKey(const Key('city-picker-error')), findsOneWidget);
    expect(find.text('Couldn\'t load cities'), findsOneWidget);
    expect(option(1), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('city-picker-error')), findsNothing);
    expect(option(1), findsOneWidget);
    expect(repo.queries, ['', '']);
  });

  testWidgets('a failed search can be retried with the same text', (
    tester,
  ) async {
    final repo = FakeCityRepository();
    await pumpField(tester, repo: repo);
    await openSheet(tester);
    repo.failNext = const BackendUnavailableException();
    await typeQuery(tester, 'kam');
    await tester.pump(kCitySearchDebounce);
    await tester.pump();
    expect(find.byKey(const Key('city-picker-error')), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(repo.queries.last, 'kam');
    expect(option(101), findsOneWidget);
  });

  testWidgets('the current city is marked selected; closing keeps it', (
    tester,
  ) async {
    final repo = FakeCityRepository();
    final picked = <CityOption>[];
    await pumpField(tester, repo: repo, picked: picked, initial: featured[1]);
    expect(
      find.descendant(
        of: find.byKey(const Key('city-field')),
        matching: find.text('Lahore'),
      ),
      findsOneWidget,
    );
    await openSheet(tester);

    expect(
      find.bySemanticsLabel('Lahore, Lahore, Punjab, selected'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
    expect(
      find.descendant(
        of: find.byKey(const Key('city-field')),
        matching: find.text('Lahore'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('validates inside a Form', (tester) async {
    await pumpField(
      tester,
      repo: FakeCityRepository(),
      validator: (c) => c == null ? 'Please select your city' : null,
    );
    await tester.tap(find.text('Validate'));
    await tester.pump();
    expect(find.text('Please select your city'), findsOneWidget);

    await openSheet(tester);
    await tester.tap(option(3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Validate'));
    await tester.pump();
    expect(find.text('Please select your city'), findsNothing);
  });

  testWidgets('memory mode by default: the 20 featured cities, prefix search', (
    tester,
  ) async {
    final picked = <CityOption>[];
    await pumpField(tester, picked: picked); // no override: memory mode
    await openSheet(tester);
    expect(find.text('Karachi'), findsOneWidget);
    await typeQuery(tester, 'lah');
    await tester.pump(kCitySearchDebounce);
    await tester.pumpAndSettle();
    expect(find.text('Lahore'), findsOneWidget);
    expect(find.text('Karachi'), findsNothing);
    await tester.tap(find.text('Lahore'));
    await tester.pumpAndSettle();
    expect(picked.single.name, 'Lahore');
  });
}
