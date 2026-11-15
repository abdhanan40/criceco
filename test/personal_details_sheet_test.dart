import 'dart:async';

import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/formatters.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// Club Owner → Settings → Account: the Personal Details sheet (Full name,
/// City, Area, Date of Birth, Phone), saved with My Profile's flow (one
/// update_profile_details call in Supabase mode). Player → My Profile, as
/// before; the role guard is unchanged.

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);
const _email = 'owner@example.com';
const _password = 'Cricket@123';

const _areas = CityAreas({
  'Karachi': ['Clifton', 'DHA'],
  'Lahore': ['Gulberg', 'DHA'],
});

late FakeDb db;
late FakeAuth auth;
late FakeClubDb clubDb;

/// [FakeDb] whose update_profile_details call waits for [hold] (when set):
/// a save still in progress.
class _HeldDb extends FakeDb {
  Completer<void>? hold;

  /// The call has started (and is waiting for [hold]).
  bool started = false;

  @override
  Future<void> updateProfileDetails(Map<String, Object?> params) async {
    started = true;
    final h = hold;
    if (h != null) await h.future;
    return super.updateProfileDetails(params);
  }
}

class _Picker implements PhotoPicker {
  @override
  Future<String?> pick(PhotoSource source) async => null;
}

/// The app on Settings for a Club Owner — in Supabase mode a user whose
/// Profile Setup saved Test Owner / +923001234567 / 1 May 2000 / Lahore (id
/// 2), Gulberg and who owns a club; otherwise the demo
/// account with a club ([player]: the demo Player instead).
Future<ProviderContainer> _onSettings(
  WidgetTester tester, {
  bool supabase = true,
  bool player = false,
  double width = 375,
  FakeDb? profileDb,
}) async {
  tester.view.physicalSize = Size(width * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  db = profileDb ?? FakeDb();
  auth = FakeAuth(db);
  clubDb = FakeClubDb(db);
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
        clubGatewayProvider.overrideWithValue(clubDb),
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
    final u = auth.addUser(_email, _password);
    db.completeProfile(u.id);
    db.profiles[u.id] = {...db.profiles[u.id]!, 'role': 'club_owner'};
    // Lahore saved with its city id (2), as Profile Setup v2 leaves it.
    db.currentAddresses[u.id] = {...db.currentAddresses[u.id]!, 'city_id': 2};
    db.permanentAddresses[u.id] = {
      ...db.permanentAddresses[u.id]!,
      'city_id': 2,
    };
    final before = auth.current;
    auth.current = u;
    await clubDb.createClub({
      'p_name': 'Lahore Lions CC',
      'p_city': 'Lahore',
      'p_club_type': 'corporate',
    });
    auth.current = before;
    await session.signIn(identifier: _email, password: _password);
  } else {
    await session.signIn(
      identifier: 'x',
      password: 'secret1',
    ); // the demo account
    if (!player) {
      await session.createClub(
        name: 'Shalimar Cricket Club',
        city: 'Islamabad',
        type: ClubType.professional,
      );
    }
  }
  c
      .read(roleControllerProvider.notifier)
      .continueAs(player ? UserRole.player : UserRole.clubOwner);
  c.read(routerProvider).go(Routes.settings);
  await tester.pumpAndSettle();
  db.calls.clear();
  db.lastDetailsParams = null;
  return c;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Settings → Account.
Future<void> _openAccount(WidgetTester tester) =>
    _tap(tester, find.text('Account').last);

Future<void> _save(WidgetTester tester) =>
    _tap(tester, find.byKey(const Key('personalDetails.save')));

Future<void> _pickCity(WidgetTester tester, String label) async {
  await _tap(tester, find.byKey(const Key('personal.city')));
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _pickArea(WidgetTester tester, String area) async {
  await _tap(tester, find.byKey(const Key('personal.currentAreaPicker')));
  await tester.tap(find.text(area).last);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final f = find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(TextField),
  );
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

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

UserAccount _account(ProviderContainer c) => c.read(currentAccountProvider)!;

final _sheet = find.byKey(const Key('personalDetails.sheet'));

int get _detailsCalls =>
    db.calls.where((call) => call == 'updateProfileDetails').length;

/// The current-address arguments of the last update_profile_details call.
(Object?, Object?, Object?, Object?) _sentCurrent() {
  final p = db.lastDetailsParams!;
  return (
    p['p_current_city'],
    p['p_current_city_id'],
    p['p_current_area'],
    p['p_current_address'],
  );
}

/// Everything shown inside the sheet.
Finder _inSheet(Finder f) => find.descendant(of: _sheet, matching: f);

void main() {
  group('Club Owner: Settings → Account', () {
    testWidgets(
      'opens the Personal Details sheet, filled from the account; the route stays /settings',
      (tester) async {
        final c = await _onSettings(tester);
        await _openAccount(tester);

        expect(_sheet, findsOneWidget);
        expect(_inSheet(find.text('Personal Details')), findsOneWidget);
        expect(
          _loc(c),
          Routes.settings,
          reason: 'not My Club, and no route change',
        );
        final a = _account(c);
        expect(_fieldText(tester, 'personal.name'), 'Test Owner');
        expect(_fieldText(tester, 'personal.phone'), a.phone);
        expect(
          _fieldText(tester, 'personal.dob'),
          CeFormat.date(DateTime(2000, 5, 1)),
        );
        expect(_fieldText(tester, 'personal.city'), 'Lahore');
        // Area shows only once the City changes (E1-B).
        expect(
          find.byKey(const Key('personal.currentAreaPicker')),
          findsNothing,
        );
        expect(find.byKey(const Key('personal.currentArea')), findsNothing);
      },
    );

    testWidgets(
      'field order: Full name → City → Date of Birth → Phone (Area after City once it changes)',
      (tester) async {
        await _onSettings(tester);
        await _openAccount(tester);
        double y(String key) => tester.getTopLeft(find.byKey(Key(key))).dy;
        expect(y('personal.name'), lessThan(y('personal.city')));
        expect(y('personal.city'), lessThan(y('personal.dob')));
        expect(y('personal.dob'), lessThan(y('personal.phone')));
        await _pickCity(tester, 'Karachi');
        final area = find.byKey(const Key('personal.currentAreaPicker'));
        expect(area, findsOneWidget);
        expect(tester.getTopLeft(area).dy, greaterThan(y('personal.city')));
        expect(tester.getTopLeft(area).dy, lessThan(y('personal.dob')));
      },
    );

    testWidgets(
      'keeps player-only details out: no Club code, no Availability',
      (tester) async {
        final c = await _onSettings(tester);
        await _openAccount(tester);
        expect(_inSheet(find.text('Club')), findsNothing);
        expect(_inSheet(find.text('Availability')), findsNothing);
        final code = c.read(currentClubProvider)?.code;
        if (code != null) expect(_inSheet(find.text(code)), findsNothing);
      },
    );

    testWidgets(
      'a name and phone change: one update_profile_details call; toast; the sheet closes',
      (tester) async {
        final c = await _onSettings(tester);
        await _openAccount(tester);
        await _enter(tester, 'personal.name', 'Hamza Owner');
        await _enter(tester, 'personal.phone', '0333 9876543');
        await _save(tester);

        expect(_detailsCalls, 1);
        expect(db.lastDetailsParams!['p_full_name'], 'Hamza Owner');
        expect(db.lastDetailsParams!['p_phone'], '+923339876543');
        expect(_sentCurrent(), (
          null,
          null,
          null,
          null,
        ), reason: 'an unchanged City leaves the address alone');
        expect(_account(c).fullName, 'Hamza Owner');
        expect(find.text('Profile updated'), findsOneWidget);
        expect(_sheet, findsNothing);
        expect(_loc(c), Routes.settings);
      },
    );

    testWidgets('an unchanged save sends nothing', (tester) async {
      await _onSettings(tester);
      await _openAccount(tester);
      await _save(tester);
      expect(_detailsCalls, 0);
      expect(_sheet, findsNothing);
    });

    testWidgets(
      'Date of Birth: picked in the calendar and saved; required, never cleared',
      (tester) async {
        final c = await _onSettings(tester);
        await _openAccount(tester);
        await _tap(tester, find.byKey(const Key('personal.dob')));
        expect(
          find.text('Date of birth'),
          findsOneWidget,
          reason: 'the date picker',
        );
        await tester.tap(find.text('20').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(
          _fieldText(tester, 'personal.dob'),
          CeFormat.date(DateTime(2000, 5, 20)),
        );
        await _save(tester);

        expect(_detailsCalls, 1);
        expect(
          '${db.lastDetailsParams!['p_date_of_birth']}',
          contains('2000-05-20'),
        );
        expect(_account(c).dateOfBirth, DateTime(2000, 5, 20));
        expect(_sheet, findsNothing);
      },
    );

    testWidgets('a cancelled date picker keeps the saved date', (tester) async {
      final c = await _onSettings(tester);
      await _openAccount(tester);
      await _tap(tester, find.byKey(const Key('personal.dob')));
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(
        _fieldText(tester, 'personal.dob'),
        CeFormat.date(DateTime(2000, 5, 1)),
      );
      await _save(tester);
      expect(_detailsCalls, 0);
      expect(_account(c).dateOfBirth, DateTime(2000, 5, 1));
    });

    testWidgets(
      'a City change asks for its Area (required), then saves the id and Area',
      (tester) async {
        final c = await _onSettings(tester);
        await _openAccount(tester);
        await _pickCity(tester, 'Karachi');
        expect(
          find.byKey(const Key('personal.currentAreaPicker')),
          findsOneWidget,
        );
        await _save(tester);
        expect(
          _detailsCalls,
          0,
          reason: 'the Area is required after the City changes',
        );
        expect(_sheet, findsOneWidget);

        await _pickArea(tester, 'Clifton');
        await _save(tester);
        expect(_detailsCalls, 1);
        final (city, id, area, _) = _sentCurrent();
        expect((city, id, area), ('Karachi', 1, 'Clifton'));
        expect(
          (
            _account(c).city,
            _account(c).currentCityId,
            _account(c).currentArea,
          ),
          ('Karachi', 1, 'Clifton'),
        );
        expect(_sheet, findsNothing);
      },
    );

    testWidgets(
      'back to the saved City: the Area hides again and the address is left alone',
      (tester) async {
        await _onSettings(tester);
        await _openAccount(tester);
        await _pickCity(tester, 'Karachi');
        await _pickArea(tester, 'Clifton');
        await _pickCity(tester, 'Lahore');
        expect(
          find.byKey(const Key('personal.currentAreaPicker')),
          findsNothing,
        );
        await _enter(tester, 'personal.name', 'Hamza Owner');
        await _save(tester);
        expect(_detailsCalls, 1);
        expect(_sentCurrent(), (null, null, null, null));
      },
    );

    testWidgets('invalid input keeps the sheet open and saves nothing', (
      tester,
    ) async {
      final c = await _onSettings(tester);
      await _openAccount(tester);
      await _enter(tester, 'personal.name', 'A');
      await _save(tester);
      expect(_detailsCalls, 0);
      expect(_sheet, findsOneWidget);

      await _enter(tester, 'personal.name', 'Hamza Owner');
      await _enter(tester, 'personal.phone', '12345');
      await _save(tester);
      expect(_detailsCalls, 0);
      expect(_sheet, findsOneWidget);
      expect(_account(c).fullName, 'Test Owner');
    });

    testWidgets('an email account may clear its phone: sent as no phone', (
      tester,
    ) async {
      final c = await _onSettings(tester);
      expect(_account(c).contactMethod, ContactMethod.email);
      await _openAccount(tester);
      await _enter(tester, 'personal.phone', '');
      await _save(tester);
      expect(_detailsCalls, 1);
      expect(db.lastDetailsParams!['p_phone'], isNull);
      expect(_account(c).phone, isNull);
    });

    testWidgets('Cancel and the close button discard the changes', (
      tester,
    ) async {
      final c = await _onSettings(tester);
      await _openAccount(tester);
      await _enter(tester, 'personal.name', 'Hamza Owner');
      await _tap(tester, find.byKey(const Key('personalDetails.cancel')));
      expect(_sheet, findsNothing);

      await _openAccount(tester);
      expect(
        _fieldText(tester, 'personal.name'),
        'Test Owner',
        reason: 'reopened from the saved account',
      );
      await _enter(tester, 'personal.name', 'Hamza Owner');
      await _tap(tester, _inSheet(find.byTooltip('Close')));
      expect(_sheet, findsNothing);
      expect(_detailsCalls, 0);
      expect(_account(c).fullName, 'Test Owner');
      expect(_loc(c), Routes.settings);
    });

    testWidgets(
      'offline: the connection message; the sheet stays open with what was typed',
      (tester) async {
        final c = await _onSettings(tester);
        await _openAccount(tester);
        await _enter(tester, 'personal.name', 'Hamza Owner');
        db.failNext = const GatewayNetworkException();
        await _save(tester);
        expect(
          find.text(const BackendUnavailableException().message),
          findsOneWidget,
        );
        expect(_sheet, findsOneWidget);
        expect(_fieldText(tester, 'personal.name'), 'Hamza Owner');
        expect(_account(c).fullName, 'Test Owner');
      },
    );

    testWidgets(
      'session gone: signed out locally, back at Login, the sheet closed',
      (tester) async {
        final c = await _onSettings(tester);
        await _openAccount(tester);
        await _enter(tester, 'personal.name', 'Hamza Owner');
        auth.current = null; // expired / revoked on the backend
        await _save(tester);
        expect(find.text('Please sign in again'), findsOneWidget);
        expect(c.read(sessionProvider).isAuthenticated, isFalse);
        expect(_loc(c), Routes.login);
        expect(_sheet, findsNothing);
      },
    );

    testWidgets('demo (memory) mode: the sheet saves on the local account', (
      tester,
    ) async {
      final c = await _onSettings(tester, supabase: false);
      await _openAccount(tester);
      expect(_fieldText(tester, 'personal.name'), 'Aman Ali');
      expect(
        _fieldText(tester, 'personal.dob'),
        CeFormat.date(DateTime(2001, 3, 14)),
      );
      await _enter(tester, 'personal.name', 'Aman Ali Khan');
      await _save(tester);
      expect(_account(c).fullName, 'Aman Ali Khan');
      expect(_account(c).dateOfBirth, DateTime(2001, 3, 14));
      expect(_sheet, findsNothing);
    });

    for (final width in [320.0, 414.0]) {
      testWidgets('no overflow at $width px (with the Area showing)', (
        tester,
      ) async {
        await _onSettings(tester, width: width);
        await _openAccount(tester);
        expect(tester.takeException(), isNull);
        await _pickCity(tester, 'Karachi');
        expect(tester.takeException(), isNull);
        await tester.drag(
          _inSheet(find.byType(Scrollable)).first,
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('personalDetails.save')), findsOneWidget);
      });
    }

    testWidgets(
      'closed while a save is in progress: Settings stays open when the save completes',
      (tester) async {
        final held = _HeldDb();
        final c = await _onSettings(tester, profileDb: held);
        await _openAccount(tester);
        await _enter(tester, 'personal.name', 'Hamza Owner');
        held.hold = Completer<void>();
        // Save starts (the button's spinner runs: pump, never pumpAndSettle).
        await tester.tap(find.byKey(const Key('personalDetails.save')));
        for (var i = 0; i < 20 && !held.started; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(held.started, isTrue, reason: 'the save is in progress');
        expect(_detailsCalls, 0, reason: 'and has not completed');
        // The sheet is closed (its close button) and starts to slide away…
        await tester.tap(_inSheet(find.byTooltip('Close')));
        await tester.pump(const Duration(milliseconds: 50));
        // …and the save completes while it is still on its way out.
        held.hold!.complete();
        await tester.pump();
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(_sheet, findsNothing);
        expect(_loc(c), Routes.settings, reason: 'nothing else was popped');
        expect(find.text('Settings'), findsWidgets);
        expect(find.text('Account'), findsWidgets);
        expect(
          _account(c).fullName,
          'Hamza Owner',
          reason: 'the save itself went through',
        );
      },
    );

    testWidgets(
      'a save completing under the City picker: the sheet stays, its controls work again',
      (tester) async {
        final held = _HeldDb();
        final c = await _onSettings(tester, profileDb: held);
        await _openAccount(tester);
        await _enter(tester, 'personal.name', 'Hamza Owner');
        held.hold = Completer<void>();
        // Save starts (the button's spinner runs: pump, never pumpAndSettle).
        await tester.tap(find.byKey(const Key('personalDetails.save')));
        for (var i = 0; i < 20 && !held.started; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(held.started, isTrue, reason: 'the save is in progress');
        // The City picker opens above the sheet while the save runs…
        await tester.tap(find.byKey(const Key('personal.city')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(const Key('city-picker-search')), findsOneWidget);
        // …and the save completes while the picker is still open.
        held.hold!.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Profile updated'), findsOneWidget);
        expect(_sheet, findsOneWidget, reason: 'the sheet is not popped');
        expect(
          find.byKey(const Key('city-picker-search')),
          findsOneWidget,
          reason: 'nor the picker',
        );

        // Back from the picker (nothing picked): the sheet's controls work.
        await tester.tap(find.byTooltip('Close').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('city-picker-search')), findsNothing);
        expect(_sheet, findsOneWidget);
        expect(_loc(c), Routes.settings);
        CeButton button(String key) =>
            tester.widget<CeButton>(find.byKey(Key(key)));
        expect(button('personalDetails.save').loading, isFalse);
        expect(button('personalDetails.save').onPressed, isNotNull);
        expect(button('personalDetails.cancel').onPressed, isNotNull);
        expect(_detailsCalls, 1);
        expect(db.lastDetailsParams!['p_full_name'], 'Hamza Owner');
        expect(_account(c).fullName, 'Hamza Owner');

        // Save again: nothing more to send; the sheet closes as usual.
        await _save(tester);
        expect(_detailsCalls, 1);
        expect(_sheet, findsNothing);
        expect(_loc(c), Routes.settings);
      },
    );
  });

  group('unchanged for the Player and the router', () {
    testWidgets(
      'Player: Settings → Account still opens My Profile; its edit form has no Date of Birth',
      (tester) async {
        final c = await _onSettings(tester, supabase: false, player: true);
        await _openAccount(tester);
        expect(_loc(c), Routes.playerProfile);
        expect(_sheet, findsNothing);
        c.read(routerProvider).go('${Routes.playerProfile}?edit=1');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('edit.name')), findsOneWidget);
        expect(find.byKey(const Key('edit.phone')), findsOneWidget);
        expect(find.byKey(const Key('edit.dob')), findsNothing);
      },
    );

    testWidgets(
      'the role guard still keeps a Club Owner out of the Player edit screen',
      (tester) async {
        final c = await _onSettings(tester, supabase: false);
        c.read(routerProvider).go('${Routes.playerProfile}?edit=1');
        await tester.pumpAndSettle();
        expect(_loc(c), Routes.clubHome);
        expect(find.byKey(const Key('edit.name')), findsNothing);
      },
    );
  });
}
