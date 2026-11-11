import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/cities.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/club/hunt/player_hunt_controller.dart';
import 'package:criceco/features/location/city_picker.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// Stage 4.3.5: Edit Profile's City is the City Picker; a changed City asks
/// for its Area (kept while it still fits) and saves the picked city id.

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);
const _email = 'hamza@example.com';
const _password = 'Cricket@123';

/// Listed areas for the tests (Kamra and Multan have none: a typed Area).
const _areas = CityAreas({
  'Karachi': ['Clifton', 'DHA'],
  'Lahore': ['Gulberg', 'DHA'],
});

late FakeDb db;
late FakeAuth auth;

class _Picker implements PhotoPicker {
  @override
  Future<String?> pick(PhotoSource source) async => null;
}

/// The app on My Profile in edit mode for a player whose Profile Setup saved
/// [city] (with [cityId] in Supabase mode) and [area]. [permanent] (with
/// [permanentId]): a separate permanent city; none → "same as current".
Future<ProviderContainer> _editing(
  WidgetTester tester, {
  bool supabase = true,
  String city = 'Karachi',
  int? cityId = 1,
  String area = 'Clifton',
  String? permanent,
  int? permanentId,
}) async {
  tester.view.physicalSize = const Size(375 * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  db = FakeDb();
  auth = FakeAuth(db);
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      photoPickerProvider.overrideWithValue(_Picker()),
      cityAreasProvider.overrideWith((ref) async => _areas),
      if (supabase) ...[
        backendConfigProvider.overrideWithValue(_supabase),
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(FakeClubDb(db)),
        locationGatewayProvider.overrideWithValue(FakeLocationGateway()),
      ],
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const CricEcoApp()),
  );
  await tester.pumpAndSettle();
  final session = c.read(sessionProvider.notifier);
  if (supabase) {
    auth.addUser(_email, _password);
    await session.signIn(identifier: _email, password: _password);
  } else {
    await session.signIn(identifier: 'x', password: 'y'); // the demo player
  }
  await session.completeProfile(
    fullName: 'Hamza Sheikh',
    phone: '0333 9876543',
    dateOfBirth: DateTime(2000, 5, 1),
    currentCity: city,
    currentCityId: supabase ? cityId : null,
    currentArea: area,
    currentAddress: 'Street 1',
    permanentCity: permanent ?? city,
    permanentCityId: supabase ? permanentId : null,
    permanentArea: permanent == null ? area : 'Cantt',
    permanentAddress: permanent == null ? 'Street 1' : 'Street 9',
    isPermanentSameAsCurrent: permanent == null,
  );
  if (supabase) {
    c.read(routerProvider).go(Routes.roleSelection);
    await tester.pumpAndSettle();
    await _tap(tester, find.bySemanticsLabel(RegExp(r'^Player\. ')));
    await _tap(tester, find.text('All-Rounder'));
    await _tap(tester, find.text('Left-handed'));
    await _tap(tester, find.text('Left-arm Orthodox'));
    await _tap(tester, _button('Continue as Player'));
  }
  c.read(routerProvider).go(Routes.playerProfile);
  await tester.pumpAndSettle();
  await _tap(tester, find.text('Edit'));
  db.calls.clear();
  db.lastAddressUpdate.clear();
  return c;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    // Below the built part of the page (a lazy list): scroll to it.
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

/// Opens Edit Profile's City and picks [label] — via search when [search].
Future<void> _pickCity(
  WidgetTester tester,
  String label, {
  String? search,
}) async {
  await _tap(tester, find.byKey(const Key('edit.city')));
  if (search != null) {
    await tester.enterText(find.byKey(const Key('city-picker-search')), search);
    await tester.pump(kCitySearchDebounce);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _pickArea(WidgetTester tester, String area) async {
  await _tap(tester, find.byKey(const Key('edit.currentAreaPicker')));
  await tester.tap(find.text(area).last);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) =>
    _tap(tester, _button('Save Changes'));

String _fieldText(WidgetTester tester, String key) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

final _areaPicker = find.byKey(const Key('edit.currentAreaPicker'));
final _areaTyped = find.byKey(const Key('edit.currentArea'));

UserAccount _account(ProviderContainer c) => c.read(currentAccountProvider)!;

void main() {
  group('Supabase mode', () {
    testWidgets('a non-featured saved city shows as it is; a name-only save '
        'leaves the address alone', (tester) async {
      final c = await _editing(
        tester,
        city: 'Kamra',
        cityId: 101,
        area: 'Cantt',
      );
      expect(_fieldText(tester, 'edit.city'), 'Kamra'); // not blank any more
      expect(_areaPicker, findsNothing);
      expect(
        _areaTyped,
        findsNothing,
        reason: 'no Area until the City changes',
      );

      await tester.enterText(find.byKey(const Key('edit.name')), 'Hamza S.');
      await _save(tester);
      expect(find.text('Profile updated'), findsOneWidget);
      expect(db.lastAddressUpdate, isEmpty);
      final a = _account(c);
      expect(
        (a.fullName, a.city, a.currentCityId, a.currentArea),
        ('Hamza S.', 'Kamra', 101, 'Cantt'),
      );
    });

    testWidgets('picking Kamra (Attock) saves id 101 with the plain name; '
        '"same as current" moves the permanent copy too', (tester) async {
      final c = await _editing(tester); // Karachi (1), Clifton
      await _pickCity(tester, 'Kamra (Attock)', search: 'kam');
      // Kamra has no listed areas; Clifton came from Karachi's list → cleared.
      expect(_areaPicker, findsNothing);
      expect(_fieldText(tester, 'edit.currentArea'), '');
      await tester.enterText(_areaTyped, 'Cantt');
      await _save(tester);

      expect(find.text('Profile updated'), findsOneWidget);
      const columns = {
        'city': 'Kamra',
        'area': 'Cantt',
        'address': 'Street 1',
        'city_id': 101,
      };
      expect(db.lastAddressUpdate['current_addresses'], columns);
      expect(db.lastAddressUpdate['permanent_addresses'], columns);
      final a = _account(c);
      expect((a.city, a.currentCity, a.currentCityId), ('Kamra', 'Kamra', 101));
      expect((a.permanentCity, a.permanentCityId), ('Kamra', 101));
      expect((a.currentArea, a.permanentArea), ('Cantt', 'Cantt'));
      expect(find.text('Kamra'), findsOneWidget); // the City row
    });

    testWidgets('two towns with the same name: Kamra (Attock) → Kamra '
        '(Rawalpindi) writes the new id and keeps the Area', (tester) async {
      final c = await _editing(
        tester,
        city: 'Kamra',
        cityId: 101,
        area: 'Cantt',
      );
      await _pickCity(tester, 'Kamra (Rawalpindi)', search: 'kam');
      expect(
        _fieldText(tester, 'edit.currentArea'),
        'Cantt',
      ); // same name: kept
      await _save(tester);
      expect(db.lastAddressUpdate['current_addresses']!['city_id'], 102);
      final a = _account(c);
      expect((a.city, a.currentCityId, a.currentArea), ('Kamra', 102, 'Cantt'));
      expect(a.permanentCityId, 102);
    });

    testWidgets('a saved city without an id (text only): re-picking the '
        'same-named city from the list saves its id', (tester) async {
      // Profile Setup without ids → save_profile_setup v1 (text only).
      final c = await _editing(
        tester,
        city: 'Lahore',
        cityId: null,
        area: 'Gulberg',
      );
      expect(db.currentAddresses.values.single['city_id'], isNull);
      expect(
        (_account(c).currentCityId, _account(c).permanentCityId),
        (null, null),
      );
      expect(_fieldText(tester, 'edit.city'), 'Lahore');
      expect(_areaPicker, findsNothing);

      await _pickCity(tester, 'Lahore'); // the listed Lahore (id 2)
      // A city change by id: the Area shows, and Gulberg still fits Lahore.
      expect(_fieldText(tester, 'edit.currentAreaPicker'), 'Gulberg');
      await _save(tester);

      expect(find.text('Profile updated'), findsOneWidget);
      const columns = {
        'city': 'Lahore',
        'area': 'Gulberg',
        'address': 'Street 1',
        'city_id': 2,
      };
      expect(db.lastAddressUpdate['current_addresses'], columns);
      expect(db.lastAddressUpdate['permanent_addresses'], columns);
      expect(db.currentAddresses.values.single['city_id'], 2);
      expect(db.permanentAddresses.values.single['city_id'], 2);
      final a = _account(c);
      expect(
        (a.city, a.currentCity, a.currentCityId, a.currentArea),
        ('Lahore', 'Lahore', 2, 'Gulberg'),
      );
      expect((a.permanentCity, a.permanentCityId), ('Lahore', 2));
    });

    testWidgets('"Other (type it)" in the Area picker: the typed Area is '
        'saved', (tester) async {
      final c = await _editing(tester); // Karachi (1), Clifton
      await _pickCity(tester, 'Lahore');
      expect(_areaTyped, findsNothing); // a listed city: the picker only
      await _pickArea(tester, kOtherArea);
      expect(_fieldText(tester, 'edit.currentAreaPicker'), kOtherArea);
      expect(_areaTyped, findsOneWidget);
      expect(_fieldText(tester, 'edit.currentArea'), ''); // Clifton was cleared
      await tester.enterText(_areaTyped, 'Township');
      await tester.pump();
      expect(_fieldText(tester, 'edit.currentAreaPicker'), kOtherArea);
      await _save(tester);

      expect(find.text('Profile updated'), findsOneWidget);
      expect(db.lastAddressUpdate['current_addresses'], {
        'city': 'Lahore',
        'area': 'Township',
        'address': 'Street 1',
        'city_id': 2,
      });
      final a = _account(c);
      expect(
        (a.city, a.currentCityId, a.currentArea),
        ('Lahore', 2, 'Township'),
      );
      expect(a.permanentArea, 'Township'); // same as current
    });

    testWidgets('a listed Area that fits the new city is kept', (tester) async {
      final c = await _editing(tester, area: 'DHA'); // Karachi, DHA
      await _pickCity(tester, 'Lahore');
      expect(_fieldText(tester, 'edit.currentAreaPicker'), 'DHA');
      await _save(tester);
      final a = _account(c);
      expect((a.city, a.currentCityId, a.currentArea), ('Lahore', 2, 'DHA'));
    });

    testWidgets('the Area is required after the City changes', (tester) async {
      final c = await _editing(tester);
      await _pickCity(tester, 'Lahore');
      expect(
        _fieldText(tester, 'edit.currentAreaPicker'),
        '',
      ); // Clifton cleared
      await _save(tester);
      expect(find.text('Area is required'), findsOneWidget);
      expect(find.text('Profile updated'), findsNothing);
      expect(db.lastAddressUpdate, isEmpty);
      expect(_account(c).city, 'Karachi');

      await _pickArea(tester, 'Gulberg');
      await _save(tester);
      expect(
        (_account(c).city, _account(c).currentArea),
        ('Lahore', 'Gulberg'),
      );
    });

    testWidgets('back to the saved city: the Area hides and the saved Area '
        'is kept; nothing is written', (tester) async {
      final c = await _editing(tester);
      await _pickCity(tester, 'Lahore');
      expect(_areaPicker, findsOneWidget);
      await _pickCity(tester, 'Karachi');
      expect(_areaPicker, findsNothing);
      await _save(tester);
      expect(find.text('Profile updated'), findsOneWidget);
      expect(db.lastAddressUpdate, isEmpty);
      expect(
        (_account(c).city, _account(c).currentArea),
        ('Karachi', 'Clifton'),
      );
    });

    testWidgets('a separate permanent address stays as it is', (tester) async {
      final c = await _editing(tester, permanent: 'Multan', permanentId: 6);
      await _pickCity(tester, 'Lahore');
      await _pickArea(tester, 'Gulberg');
      await _save(tester);
      expect(db.lastAddressUpdate.keys, ['current_addresses']);
      final a = _account(c);
      expect((a.city, a.currentCityId), ('Lahore', 2));
      expect(
        (a.permanentCity, a.permanentCityId, a.permanentArea),
        ('Multan', 6, 'Cantt'),
      );
    });

    testWidgets('a refused city id: "Please choose your city again", still '
        'editing, account unchanged', (tester) async {
      final c = await _editing(tester);
      db.cities = const {1: 'Karachi', 2: 'Lahore', 6: 'Multan'};
      await _pickCity(tester, 'Kamra (Attock)', search: 'kam');
      await tester.enterText(_areaTyped, 'Cantt');
      await _save(tester);
      expect(find.text('Please choose your city again'), findsOneWidget);
      expect(find.byKey(const Key('edit.city')), findsOneWidget);
      final a = _account(c);
      expect(
        (a.city, a.currentCityId, a.currentArea),
        ('Karachi', 1, 'Clifton'),
      );
    });

    testWidgets('offline: the connection message; account unchanged', (
      tester,
    ) async {
      final c = await _editing(tester);
      await _pickCity(tester, 'Lahore');
      await _pickArea(tester, 'Gulberg');
      db.failNext = const GatewayNetworkException();
      await _save(tester);
      expect(
        find.text(const BackendUnavailableException().message),
        findsOneWidget,
      );
      expect(find.byKey(const Key('edit.city')), findsOneWidget);
      expect((_account(c).city, _account(c).currentCityId), ('Karachi', 1));
    });

    testWidgets('Cancel drops the picked city and Area', (tester) async {
      final c = await _editing(tester);
      await _pickCity(tester, 'Lahore');
      await _pickArea(tester, 'Gulberg');
      await _tap(tester, _button('Cancel'));
      expect(find.byKey(const Key('edit.city')), findsNothing);
      expect(db.calls, isNot(contains('updateAddress:current_addresses')));
      expect(
        (_account(c).city, _account(c).currentArea),
        ('Karachi', 'Clifton'),
      );

      await _tap(tester, find.text('Edit')); // starts from the saved city
      expect(_fieldText(tester, 'edit.city'), 'Karachi');
      expect(_areaPicker, findsNothing);
    });
  });

  group('memory mode', () {
    testWidgets('a picked city keeps its local id; same as current follows; '
        '"available to clubs" lists the new city', (tester) async {
      final c = await _editing(tester, supabase: false);
      await c.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
      await _pickCity(tester, 'Multan');
      expect(_fieldText(tester, 'edit.currentArea'), ''); // a typed Area now
      await tester.enterText(_areaTyped, 'Cantt');
      await _save(tester);

      expect(find.text('Profile updated'), findsOneWidget);
      final multan = kPakistanCities.indexOf('Multan') + 1;
      final a = _account(c);
      expect(
        (a.city, a.currentCity, a.currentCityId, a.currentArea),
        ('Multan', 'Multan', multan, 'Cantt'),
      );
      expect(
        (a.permanentCity, a.permanentCityId, a.permanentArea),
        ('Multan', multan, 'Cantt'),
      );
      final me = (await c.read(openPlayersProvider.future))
          .where((p) => p.isMe)
          .single;
      expect(me.city, 'Multan');
    });

    testWidgets('name and phone edits leave the city alone', (tester) async {
      final c = await _editing(tester, supabase: false);
      await tester.enterText(
        find.byKey(const Key('edit.phone')),
        '0300-1234567',
      );
      await _save(tester);
      final a = _account(c);
      expect(a.phone, '0300 1234567');
      expect(
        (a.city, a.currentCity, a.currentCityId, a.currentArea),
        ('Karachi', 'Karachi', null, 'Clifton'),
      );
    });
  });
}
