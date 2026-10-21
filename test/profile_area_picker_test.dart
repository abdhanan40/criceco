import 'dart:convert';
import 'dart:io';

import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/cities.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/auth/onboarding_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test fixture only — deliberately fake names. Real areas come from
/// `assets/data/city_areas.json`, supplied by the CricEco team.
const _fixture = '''
{
  "Karachi": ["Test Area K1", "Test Area K2", "Shared Test Area"],
  "Lahore": ["Test Area L1", "Shared Test Area"],
  "Islamabad": []
}
''';

Future<ProviderContainer> _pump(WidgetTester tester, {String areas = _fixture}) async {
  tester.view.physicalSize = const Size(375 * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    cityAreasProvider.overrideWith((ref) async => CityAreas.parse(areas)),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  await c.read(sessionProvider.notifier).signUp(
      fullName: '', method: ContactMethod.phone, identifier: '03001234567', password: 'Cricket@123');
  c.read(routerProvider).go(Routes.profileSetup);
  await tester.pumpAndSettle();
  return c;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

/// Opens the picker with field key [key] and picks [option] (the sheet is on top).
Future<void> _pick(WidgetTester tester, String key, String option) async {
  await _tap(tester, find.byKey(Key(key)));
  await _tap(tester, find.text(option).last);
}

/// Name, phone and date of birth (the rest of the form is the address).
Future<void> _basics(WidgetTester tester) async {
  await _enter(tester, 'profile.name', 'Hamza Sheikh');
  await _enter(tester, 'profile.phone', '0333-9876543');
  await _tap(tester, find.byKey(const Key('profile.dob')));
  await _tap(tester, find.text('OK'));
}

String _fieldText(WidgetTester tester, String key) => tester
    .widget<TextField>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField)))
    .controller!
    .text;

UserAccount _account(ProviderContainer c) => c.read(currentAccountProvider)!;

void main() {
  group('CityAreas data', () {
    test('parse trims, drops blanks and repeats, ignores malformed entries', () {
      final a = CityAreas.parse('{"Karachi": [" A ", "a", "", "B", 3], "Lahore": "x", "Multan": []}');
      expect(a.areasFor('Karachi'), ['A', 'B']);
      expect(a.areasFor('Lahore'), isEmpty);
      expect(a.areasFor('Multan'), isEmpty);
      expect(a.areasFor(null), isEmpty);
      expect(CityAreas.parse('[]').isNotEmpty, isFalse);
      expect(a.isListed('Karachi', 'A'), isTrue);
      expect(a.isListed('Lahore', 'A'), isFalse);
    });

    test('the bundled (demo) file covers exactly the City picker cities, 5–10 distinct areas each', () {
      final json = File('assets/data/city_areas.json').readAsStringSync();
      final raw = jsonDecode(json) as Map<String, dynamic>;
      expect(raw.keys.toSet(), kPakistanCities.toSet(), reason: 'cities must match the City picker exactly');
      final areas = CityAreas.parse(json);
      for (final e in raw.entries) {
        expect(e.value, isA<List<dynamic>>(), reason: e.key);
        expect(e.value as List<dynamic>, everyElement(isA<String>()), reason: e.key);
        expect(areas.areasFor(e.key).length, (e.value as List<dynamic>).length, reason: '${e.key}: no blanks or repeats');
        expect(areas.areasFor(e.key).length, inInclusiveRange(5, 10), reason: e.key);
      }
    });
  });

  group('Onboarding draft', () {
    ProviderContainer container(String areas) {
      final c = ProviderContainer(overrides: [cityAreasProvider.overrideWith((ref) async => CityAreas.parse(areas))]);
      addTearDown(c.dispose);
      return c;
    }

    test('changing city clears an area that is not listed there, keeps one that is', () async {
      final c = container(_fixture);
      await c.read(cityAreasProvider.future);
      final n = c.read(onboardingProvider.notifier)
        ..setCurrentCity('Karachi')
        ..setCurrentArea('Test Area K1')
        ..setCurrentCity('Lahore');
      expect(c.read(onboardingProvider).currentArea, isNull);
      n
        ..setCurrentArea('Shared Test Area')
        ..setCurrentCity('Karachi');
      expect(c.read(onboardingProvider).currentArea, 'Shared Test Area');
      n.setCurrentCity('Islamabad'); // no listed areas; the area came from Karachi's list
      expect(c.read(onboardingProvider).currentArea, isNull);
    });

    test('with no area data a typed area survives a city change (as before)', () async {
      final c = container('{}');
      await c.read(cityAreasProvider.future);
      c.read(onboardingProvider.notifier)
        ..setPermanentArea('Typed Area')
        ..setPermanentCity('Karachi')
        ..setPermanentCity('Lahore');
      expect(c.read(onboardingProvider).permanentArea, 'Typed Area');
    });
  });

  testWidgets('bundled demo areas: the picker shows the selected city\'s areas and follows a city change',
      (tester) async {
    tester.view.physicalSize = const Size(375 * 3, 812 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ]);
    addTearDown(c.dispose);
    // The real asset (no override); its file read needs real async.
    final data = await tester.runAsync(() => c.read(cityAreasProvider.future));
    expect(data!.areasFor('Karachi'), contains('Clifton'));
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
    await tester.pumpAndSettle();
    await c.read(sessionProvider.notifier).signUp(
        fullName: '', method: ContactMethod.phone, identifier: '03001234567', password: 'Cricket@123');
    c.read(routerProvider).go(Routes.profileSetup);
    await tester.pumpAndSettle();

    Finder inSheet(String text) => find.descendant(of: find.byType(BottomSheet), matching: find.text(text));
    await _pick(tester, 'profile.currentCity', 'Karachi');
    await _tap(tester, find.byKey(const Key('profile.currentAreaPicker')));
    for (final a in [...data.areasFor('Karachi'), kOtherArea]) {
      expect(inSheet(a), findsOneWidget, reason: a);
    }
    expect(inSheet('Model Town'), findsNothing, reason: 'not a Karachi demo area');
    await _tap(tester, inSheet('Clifton'));
    expect(c.read(onboardingProvider).currentArea, 'Clifton');

    await _pick(tester, 'profile.currentCity', 'Lahore');
    expect(c.read(onboardingProvider).currentArea, isNull, reason: 'Clifton is not a Lahore area');
    await _tap(tester, find.byKey(const Key('profile.currentAreaPicker')));
    expect(inSheet('Model Town'), findsOneWidget);
    expect(inSheet('Clifton'), findsNothing);
    expect(inSheet(kOtherArea), findsOneWidget);
    await _tap(tester, inSheet('DHA')); // listed in both Lahore and Karachi
    await _pick(tester, 'profile.currentCity', 'Karachi');
    expect(c.read(onboardingProvider).currentArea, 'DHA', reason: 'kept: listed in both');
  });

  group('Profile Setup Area picker', () {
    testWidgets('locked until a city is chosen; shows only that city\'s areas; resets on a new city',
        (tester) async {
      final c = await _pump(tester);
      expect(find.byKey(const Key('profile.currentAreaPicker')), findsOneWidget);
      expect(find.byKey(const Key('profile.currentArea')), findsNothing, reason: 'no typed field yet');
      expect(find.text('Select a city first'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('profile.currentAreaPicker')));
      expect(find.text('Select Area'), findsNothing, reason: 'nothing to pick before a city');

      await _pick(tester, 'profile.currentCity', 'Karachi');
      await _tap(tester, find.byKey(const Key('profile.currentAreaPicker')));
      expect(find.text('Select Area'), findsOneWidget);
      for (final a in ['Test Area K1', 'Test Area K2', 'Shared Test Area', kOtherArea]) {
        expect(find.text(a), findsOneWidget, reason: a);
      }
      expect(find.text('Test Area L1'), findsNothing, reason: 'Lahore areas are not offered for Karachi');
      await _tap(tester, find.text('Test Area K1').last);
      expect(c.read(onboardingProvider).currentArea, 'Test Area K1');
      expect(_fieldText(tester, 'profile.currentAreaPicker'), 'Test Area K1');

      await _pick(tester, 'profile.currentCity', 'Lahore');
      expect(c.read(onboardingProvider).currentArea, isNull, reason: 'K1 is not a Lahore area');
      expect(_fieldText(tester, 'profile.currentAreaPicker'), '');
      await _tap(tester, find.byKey(const Key('profile.currentAreaPicker')));
      expect(find.text('Test Area L1'), findsOneWidget);
      expect(find.text('Test Area K1'), findsNothing);
      await _tap(tester, find.text('Shared Test Area').last);
      await _pick(tester, 'profile.currentCity', 'Karachi');
      expect(c.read(onboardingProvider).currentArea, 'Shared Test Area', reason: 'listed in both cities');
    });

    testWidgets('a city with no listed areas keeps the typed Area field', (tester) async {
      final c = await _pump(tester);
      await _pick(tester, 'profile.currentCity', 'Islamabad');
      expect(find.byKey(const Key('profile.currentAreaPicker')), findsNothing);
      await _enter(tester, 'profile.currentArea', 'Typed Area');
      expect(c.read(onboardingProvider).currentArea, 'Typed Area');
    });

    testWidgets('validation; Other (type it); Yes saves current as permanent', (tester) async {
      final c = await _pump(tester);
      await _basics(tester);
      await _pick(tester, 'profile.currentCity', 'Karachi');
      await _enter(tester, 'profile.currentAddress', 'House 12, Street 4');
      await _tap(tester, find.widgetWithText(CeButton, 'Continue'));
      expect(find.text('Area is required'), findsOneWidget, reason: 'picker left empty');
      expect(c.read(routerProvider).state.uri.path, Routes.profileSetup);

      await _pick(tester, 'profile.currentAreaPicker', kOtherArea);
      expect(find.byKey(const Key('profile.currentArea')), findsOneWidget, reason: 'typed field under Other');
      await _tap(tester, find.widgetWithText(CeButton, 'Continue'));
      expect(find.text('Area is required'), findsOneWidget, reason: 'typed area still required');
      await _enter(tester, 'profile.currentArea', '123');
      await _tap(tester, find.widgetWithText(CeButton, 'Continue'));
      expect(find.text('Enter a valid area'), findsOneWidget);
      await _enter(tester, 'profile.currentArea', 'My Own Area');
      await _tap(tester, find.widgetWithText(CeButton, 'Continue'));

      expect(c.read(routerProvider).state.uri.path, Routes.roleSelection);
      final a = _account(c);
      expect((a.currentCity, a.currentArea), ('Karachi', 'My Own Area'));
      expect((a.isPermanentSameAsCurrent, a.permanentCity, a.permanentArea), (true, 'Karachi', 'My Own Area'));
    });

    testWidgets('Permanent Address (No): its own linked City → Area picker, saved separately', (tester) async {
      final c = await _pump(tester);
      await _basics(tester);
      await _pick(tester, 'profile.currentCity', 'Karachi');
      await _pick(tester, 'profile.currentAreaPicker', 'Test Area K2');
      await _enter(tester, 'profile.currentAddress', 'House 12, Street 4');
      await _tap(tester, find.text('No'));

      expect(find.text('Select a city first'), findsOneWidget, reason: 'permanent area waits for its city');
      await _tap(tester, find.widgetWithText(CeButton, 'Continue'));
      expect(find.text('Area is required'), findsOneWidget, reason: 'permanent area required under No');

      await _pick(tester, 'profile.permanentCity', 'Lahore');
      await _tap(tester, find.byKey(const Key('profile.permanentAreaPicker')));
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Test Area K2')), findsNothing,
          reason: 'only Lahore areas');
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Test Area L1')), findsOneWidget);
      await _tap(tester, find.text('Test Area L1').last);
      await _enter(tester, 'profile.permanentAddress', 'Street 9');

      // Yes / No keeps the permanent picks.
      await _tap(tester, find.text('Yes'));
      await _tap(tester, find.text('No'));
      expect(_fieldText(tester, 'profile.permanentAreaPicker'), 'Test Area L1');

      await _tap(tester, find.widgetWithText(CeButton, 'Continue'));
      final a = _account(c);
      expect((a.currentCity, a.currentArea), ('Karachi', 'Test Area K2'));
      expect((a.isPermanentSameAsCurrent, a.permanentCity, a.permanentArea), (false, 'Lahore', 'Test Area L1'));
    });

    for (final width in [320.0, 414.0]) {
      testWidgets('fits at ${width.toInt()} px with pickers, Other and No', (tester) async {
        final c = await _pump(tester);
        tester.view.physicalSize = Size(width * 3, 812 * 3);
        await tester.pumpAndSettle();
        await _pick(tester, 'profile.currentCity', 'Karachi');
        await _pick(tester, 'profile.currentAreaPicker', kOtherArea);
        await _tap(tester, find.text('No'));
        await _tap(tester, find.widgetWithText(CeButton, 'Continue')); // errors shown
        await _tap(tester, find.byKey(const Key('profile.permanentAreaPicker')));
        expect(tester.takeException(), isNull, reason: '@ $width');
        expect(c.read(routerProvider).state.uri.path, Routes.profileSetup);
      });
    }

    testWidgets('a saved typed area comes back as Other with its text', (tester) async {
      final c = await _pump(tester);
      // As when the draft is restored from the account: set before the screen opens.
      c.read(routerProvider).go(Routes.createAccount);
      await tester.pumpAndSettle();
      c.read(onboardingProvider.notifier)
        ..setCurrentCity('Karachi')
        ..setCurrentArea('My Own Area');
      c.read(routerProvider).go(Routes.profileSetup);
      await tester.pumpAndSettle();
      expect(_fieldText(tester, 'profile.currentAreaPicker'), kOtherArea);
      expect(_fieldText(tester, 'profile.currentArea'), 'My Own Area');
      await _pick(tester, 'profile.currentAreaPicker', 'Test Area K1');
      expect(find.byKey(const Key('profile.currentArea')), findsNothing, reason: 'listed area: no typed field');
      expect(c.read(onboardingProvider).currentArea, 'Test Area K1');
    });
  });
}
