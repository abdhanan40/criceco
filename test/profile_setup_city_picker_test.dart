import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/auth/onboarding_controller.dart';
import 'package:criceco/features/location/city_picker.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// Stage 4.3.4: User Profile Setup's city fields are City Pickers; Supabase
/// mode saves the picked city ids through save_profile_setup_v2.

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);
const _email = 'hamza@example.com';
const _password = 'Cricket@123';

late FakeDb db;
late FakeAuth auth;
late FakeLocationGateway locations;

class _Picker implements PhotoPicker {
  @override
  Future<String?> pick(PhotoSource source) async => null;
}

/// The app at User Profile Setup for a signed-in new account. Supabase mode
/// ([supabase]) runs on the fakes; memory mode on the in-memory repositories.
/// [currentRow] (Supabase): an address row already saved for the user (used
/// as both addresses).
Future<ProviderContainer> _onProfileSetup(
  WidgetTester tester, {
  bool supabase = true,
  Map<String, dynamic>? currentRow,
}) async {
  tester.view.physicalSize = const Size(375 * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  db = FakeDb();
  auth = FakeAuth(db);
  locations = FakeLocationGateway();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      photoPickerProvider.overrideWithValue(_Picker()),
      cityAreasProvider.overrideWith((ref) async => CityAreas.empty),
      if (supabase) ...[
        backendConfigProvider.overrideWithValue(_supabase),
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(FakeClubDb(db)),
        locationGatewayProvider.overrideWithValue(locations),
      ],
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const CricEcoApp()),
  );
  await tester.pumpAndSettle();
  if (supabase) {
    final u = auth.addUser(_email, _password);
    if (currentRow != null) {
      db.currentAddresses[u.id] = {'user_id': u.id, ...currentRow};
      db.permanentAddresses[u.id] = {'user_id': u.id, ...currentRow};
    }
    await c
        .read(sessionProvider.notifier)
        .signIn(identifier: _email, password: _password);
  } else {
    await c
        .read(sessionProvider.notifier)
        .signUp(
          fullName: '',
          method: ContactMethod.phone,
          identifier: '03339876543',
          password: _password,
        );
  }
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
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

/// Opens the city picker [key] and picks [label] — via search when [search].
Future<void> _pickCity(
  WidgetTester tester,
  String key,
  String label, {
  String? search,
}) async {
  await _tap(tester, find.byKey(Key(key)));
  expect(find.text('Select City'), findsOneWidget); // the existing sheet title
  if (search != null) {
    await tester.enterText(find.byKey(const Key('city-picker-search')), search);
    await tester.pump(kCitySearchDebounce);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _basics(WidgetTester tester) async {
  await _enter(tester, 'profile.name', 'Hamza Sheikh');
  await _enter(tester, 'profile.phone', '0333-9876543');
  await _tap(tester, find.byKey(const Key('profile.dob')));
  await _tap(tester, find.text('OK'));
}

Future<void> _address(WidgetTester tester, String prefix, String area) async {
  await _enter(tester, '${prefix}Area', area);
  await _enter(tester, '${prefix}Address', 'House 12, Street 4');
}

Future<void> _continue(WidgetTester tester) =>
    _tap(tester, find.widgetWithText(CeButton, 'Continue'));

String _fieldText(WidgetTester tester, String key) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

void main() {
  group('Supabase mode: save_profile_setup_v2 with the picked city ids', () {
    testWidgets('same as current: the current id, no permanent arguments', (
      tester,
    ) async {
      final c = await _onProfileSetup(tester);
      await _basics(tester);
      await _pickCity(tester, 'profile.currentCity', 'Karachi');
      expect(_fieldText(tester, 'profile.currentCity'), 'Karachi');
      await _address(tester, 'profile.current', 'Clifton');
      await _continue(tester);

      final p = db.lastSetupV2Params!;
      expect(p['p_current_city_id'], 1);
      expect(p['p_permanent_same_as_current'], isTrue);
      expect(p['p_permanent_city_id'], isNull);
      expect(p['p_permanent_area'], isNull);
      expect(db.lastSetupParams, isNull); // v1 not used
      expect(_loc(c), Routes.roleSelection);
      final a = c.read(sessionProvider).account!;
      expect((a.currentCityId, a.permanentCityId), (1, 1));
      expect((a.currentCity, a.city), ('Karachi', 'Karachi'));
    });

    testWidgets('a different permanent city: both ids; a qualified city via '
        'search keeps its id with the plain name', (tester) async {
      final c = await _onProfileSetup(tester);
      await _basics(tester);
      await _pickCity(
        tester,
        'profile.currentCity',
        'Kamra (Attock)',
        search: 'kam',
      );
      expect(_fieldText(tester, 'profile.currentCity'), 'Kamra (Attock)');
      await _address(tester, 'profile.current', 'Cantt');
      await _tap(tester, find.text('No'));
      await _pickCity(tester, 'profile.permanentCity', 'Multan');
      await _address(tester, 'profile.permanent', 'Gulgasht');
      await _continue(tester);

      final p = db.lastSetupV2Params!;
      expect(p['p_current_city_id'], 101);
      expect(p['p_permanent_same_as_current'], isFalse);
      expect(p['p_permanent_city_id'], 6);
      expect(p['p_permanent_area'], 'Gulgasht');
      final a = c.read(sessionProvider).account!;
      expect((a.currentCityId, a.currentCity), (101, 'Kamra'));
      expect((a.permanentCityId, a.permanentCity), (6, 'Multan'));
    });

    testWidgets('a city must be picked from the list', (tester) async {
      await _onProfileSetup(tester);
      await _basics(tester);
      await _address(tester, 'profile.current', 'Clifton');
      await _continue(tester);
      expect(find.text('City is required'), findsOneWidget);
      expect(db.lastSetupV2Params, isNull);
    });

    testWidgets('a legacy city text without an id must be picked again', (
      tester,
    ) async {
      final c = await _onProfileSetup(
        tester,
        currentRow: {'city': 'Other', 'area': 'Saddar', 'address': 'House 1'},
      );
      expect(
        _fieldText(tester, 'profile.currentCity'),
        'Other',
      ); // shown as saved
      await _basics(tester);
      await _continue(tester);
      expect(
        find.text('Please choose your city from the list'),
        findsOneWidget,
      );
      expect(db.lastSetupV2Params, isNull);
      expect(db.lastSetupParams, isNull);

      await _pickCity(tester, 'profile.currentCity', 'Lahore');
      await _continue(tester);
      expect(db.lastSetupV2Params!['p_current_city_id'], 2);
      expect(_loc(c), Routes.roleSelection);
    });

    testWidgets('a saved city with an id is accepted without picking again', (
      tester,
    ) async {
      await _onProfileSetup(
        tester,
        currentRow: {
          'city_id': 2,
          'city': 'Lahore',
          'area': 'Gulberg',
          'address': 'House 1',
        },
      );
      expect(_fieldText(tester, 'profile.currentCity'), 'Lahore');
      await _basics(tester);
      await _continue(tester);
      expect(db.lastSetupV2Params!['p_current_city_id'], 2);
    });

    testWidgets('re-picking the same city changes nothing; a different city '
        'replaces the name and id in the draft, and a typed Area stays when the '
        'city has no listed areas', (tester) async {
      final c = await _onProfileSetup(tester);
      OnboardingDraft draft() => c.read(onboardingProvider);
      await _pickCity(tester, 'profile.currentCity', 'Karachi');
      await _address(tester, 'profile.current', 'Clifton');
      expect((draft().currentCity, draft().currentCityId), ('Karachi', 1));
      expect(_fieldText(tester, 'profile.currentArea'), 'Clifton');

      await _pickCity(tester, 'profile.currentCity', 'Karachi'); // same city
      expect((draft().currentCity, draft().currentCityId), ('Karachi', 1));
      expect(_fieldText(tester, 'profile.currentArea'), 'Clifton');

      await _pickCity(
        tester,
        'profile.currentCity',
        'Lahore',
      ); // different city
      expect((draft().currentCity, draft().currentCityId), ('Lahore', 2));
      expect(_fieldText(tester, 'profile.currentCity'), 'Lahore');
      // No listed areas (CityAreas.empty): a typed Area stays, as before.
      expect(draft().currentArea, 'Clifton');
      expect(_fieldText(tester, 'profile.currentArea'), 'Clifton');
    });

    testWidgets('a refused city: the friendly message, the form kept; retry '
        'with another city saves', (tester) async {
      final c = await _onProfileSetup(tester);
      db.cities = const {
        1: 'Karachi',
        2: 'Lahore',
        6: 'Multan',
      }; // Karachi stays
      await _basics(tester);
      await _pickCity(
        tester,
        'profile.currentCity',
        'Kamra (Attock)',
        search: 'kam',
      );
      await _address(tester, 'profile.current', 'Cantt');
      await _continue(tester);

      expect(find.text('Please choose your city again'), findsOneWidget);
      expect(_loc(c), Routes.profileSetup);
      expect(_fieldText(tester, 'profile.currentArea'), 'Cantt'); // kept
      await tester.pump(const Duration(seconds: 3)); // the toast times out
      await tester.pumpAndSettle();

      await _pickCity(tester, 'profile.currentCity', 'Karachi');
      await _continue(tester);
      expect(db.lastSetupV2Params!['p_current_city_id'], 1);
      expect(_loc(c), Routes.roleSelection);
    });

    testWidgets('offline: the connection message; nothing saved', (
      tester,
    ) async {
      final c = await _onProfileSetup(tester);
      await _basics(tester);
      await _pickCity(tester, 'profile.currentCity', 'Karachi');
      await _address(tester, 'profile.current', 'Clifton');
      db.failNext = const GatewayNetworkException();
      await _continue(tester);
      expect(
        find.text(const BackendUnavailableException().message),
        findsOneWidget,
      );
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(sessionProvider).account!.profileComplete, isFalse);
      expect(
        db.lastSetupV2Params,
        isNull,
      ); // the call never reached the database
    });
  });

  group('memory mode', () {
    testWidgets('the 20 featured cities; saving works without database ids', (
      tester,
    ) async {
      final c = await _onProfileSetup(tester, supabase: false);
      await _basics(tester);
      await _tap(tester, find.byKey(const Key('profile.currentCity')));
      expect(find.text('Karachi'), findsOneWidget);
      expect(find.byKey(const Key('province-filter')), findsNothing);
      await tester.tap(find.text('Lahore').last);
      await tester.pumpAndSettle();
      await _address(tester, 'profile.current', 'Gulberg');
      await _continue(tester);

      expect(_loc(c), Routes.roleSelection);
      final a = c.read(sessionProvider).account!;
      expect(a.profileComplete, isTrue);
      expect(
        (a.currentCity, a.permanentCity, a.city),
        ('Lahore', 'Lahore', 'Lahore'),
      );
    });
  });
}
