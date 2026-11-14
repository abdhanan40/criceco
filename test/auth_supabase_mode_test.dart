// Phase 2 Step 5: the auth and onboarding screens in Supabase mode (email
// only; Google, password reset and change hidden; typed errors), on the
// in-memory gateway fakes — no live project. Memory mode must look exactly
// as before.
import 'dart:async';

import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/auth/onboarding_controller.dart';
import 'package:criceco/features/auth/role_selection_screen.dart';
import 'package:criceco/features/auth/widgets/auth_widgets.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// [FakeAuth] whose sign-up waits for [gate] (a request in flight).
class SlowAuth extends FakeAuth {
  SlowAuth(super.db);
  Completer<void>? gate;

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required Map<String, Object?> metadata,
  }) async {
    await gate?.future;
    return super.signUp(email: email, password: password, metadata: metadata);
  }
}

/// [FakeDb] whose player-profile save waits for [gate].
class SlowDb extends FakeDb {
  Completer<void>? gate;

  @override
  Future<void> upsertPlayerProfile(Map<String, Object?> row) async {
    await gate?.future;
    return super.upsertPlayerProfile(row);
  }
}

/// The memory-mode repository with failures on demand, for the screens'
/// error paths that only memory mode shows (Google, password change).
class FlakyAccounts extends InMemoryAccountRepository {
  FlakyAccounts(super.seed);
  Object? failGoogle;
  Object? failUpdate;
  Object? failChangePassword;

  @override
  Future<UserAccount?> signIn({
    required String identifier,
    required String password,
  }) async {
    if (identifier == 'google' && failGoogle != null) throw failGoogle!;
    return super.signIn(identifier: identifier, password: password);
  }

  @override
  Future<UserAccount> update(UserAccount account) async {
    if (failUpdate != null) throw failUpdate!;
    return super.update(account);
  }

  @override
  Future<bool> changePassword(
    String accountId, {
    required String current,
    required String next,
  }) async {
    if (failChangePassword != null) throw failChangePassword!;
    return super.changePassword(accountId, current: current, next: next);
  }
}

class _Picker implements PhotoPicker {
  @override
  Future<String?> pick(PhotoSource source) async => '/photos/gallery.jpg';
}

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

const _email = 'hamza@example.com';
const _password = 'Cricket@123';

late SlowDb db;
late SlowAuth auth;
late FlakyAccounts accounts;
late FakeClubDb clubDb;

/// The app in Supabase mode ([supabase] true) or memory mode, at Login.
/// [flaky] (memory mode): the account repository is [accounts].
/// [saved]: what an earlier session left in SharedPreferences.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool supabase = true,
  bool flaky = false,
  Map<String, Object> saved = const {},
}) async {
  tester.view.physicalSize = const Size(375 * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  db = SlowDb();
  auth = SlowAuth(db);
  clubDb = FakeClubDb(db);
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
        clubGatewayProvider.overrideWithValue(clubDb),
      ],
      if (flaky)
        accountRepositoryProvider.overrideWith(
          (ref) => accounts = FlakyAccounts(ref.watch(seedDataProvider)),
        ),
    ],
  );
  addTearDown(c.dispose);
  if (flaky) c.read(accountRepositoryProvider); // creates [accounts]
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const CricEcoApp()),
  );
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String route) async {
  c.read(routerProvider).go(route);
  await tester.pumpAndSettle();
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

Finder _button(String label) => find.widgetWithText(CeButton, label);

int _count(List<String> calls, String name) =>
    calls.where((c) => c == name).length;

Future<void> _login(WidgetTester tester, {String password = _password}) async {
  await _enter(tester, 'login.email', _email);
  await _enter(tester, 'login.password', password);
  await _tap(tester, _button('Login'));
}

/// Lets the error toast time out (it floats over the bottom buttons), as a
/// user would before trying again.
Future<void> _toastGone(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

Future<void> _signUp(WidgetTester tester, ProviderContainer c) async {
  await _go(tester, c, Routes.createAccount);
  await _enter(tester, 'signup.email', _email);
  await _enter(tester, 'signup.password', _password);
  await _enter(tester, 'signup.confirm', _password);
  await _tap(tester, _button('Create Account'));
}

/// A signed-in new Supabase user on User Profile Setup.
Future<ProviderContainer> _onProfileSetup(WidgetTester tester) async {
  final c = await _pump(tester);
  auth.addUser(_email, _password);
  await c
      .read(sessionProvider.notifier)
      .signIn(identifier: _email, password: _password);
  await _go(tester, c, Routes.profileSetup);
  return c;
}

/// Profile Setup filled in with valid details (permanent address: Yes).
Future<void> _fillProfile(WidgetTester tester) async {
  await _enter(tester, 'profile.name', 'Hamza Sheikh');
  await _enter(tester, 'profile.phone', '0333-9876543');
  await _tap(tester, find.byKey(const Key('profile.dob')));
  await _tap(tester, find.text('OK'));
  await _tap(tester, find.byKey(const Key('profile.currentCity')));
  await _tap(tester, find.text('Karachi').last);
  await _enter(tester, 'profile.currentArea', 'Clifton');
  await _enter(tester, 'profile.currentAddress', 'House 12, Street 4');
}

/// The text shown in the field with key [key].
String _fieldText(WidgetTester tester, String key) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

/// A signed-in Supabase user with the common profile saved.
Future<ProviderContainer> _profiled(WidgetTester tester) async {
  final c = await _onProfileSetup(tester);
  await c
      .read(sessionProvider.notifier)
      .completeProfile(
        fullName: 'Hamza Sheikh',
        phone: '0333 9876543',
        dateOfBirth: DateTime(2000, 5, 1),
        currentCity: 'Karachi',
        currentArea: 'Clifton',
        currentAddress: 'Street 1',
        permanentCity: 'Karachi',
        permanentArea: 'Clifton',
        permanentAddress: 'Street 1',
        isPermanentSameAsCurrent: true,
      );
  return c;
}

/// A Supabase user with the common profile saved, on Role Selection with
/// the Player details open: All-Rounder, Left-handed, Left-arm Orthodox.
Future<ProviderContainer> _playerChosen(WidgetTester tester) async {
  final c = await _profiled(tester);
  await _go(tester, c, Routes.roleSelection);
  await _tap(tester, find.bySemanticsLabel(RegExp(r'^Player\. ')));
  await _tap(tester, find.text('All-Rounder'));
  await _tap(tester, find.text('Left-handed'));
  await _tap(tester, find.text('Left-arm Orthodox'));
  return c;
}

/// Player details still open with the same choices.
void _expectPlayerChoicesKept(ProviderContainer c) {
  expect(find.text('Playing Role *'), findsOneWidget, reason: 'still open');
  final p = c.read(onboardingProvider).playerProfile;
  expect(
    (p.role, p.battingStyle, p.bowlingStyle),
    (
      PlayerRole.allRounder,
      BattingStyle.leftHanded,
      BowlingStyle.leftArmOrthodox,
    ),
  );
}

void main() {
  group('memory mode is unchanged', () {
    testWidgets('phone login, Forgot password, Google and the chooser', (
      tester,
    ) async {
      final c = await _pump(tester, supabase: false);
      expect(find.byKey(const Key('login.phone')), findsOneWidget);
      expect(find.byKey(const Key('login.email')), findsNothing);
      expect(find.byKey(const Key('login.forgot')), findsOneWidget);
      await _go(tester, c, Routes.signup);
      expect(find.byType(GoogleButton), findsOneWidget);
      await _go(tester, c, Routes.createAccount);
      expect(find.text('Sign up with'), findsOneWidget);
      expect(find.byKey(const Key('signup.phone')), findsOneWidget);
    });

    testWidgets('logging in with an incomplete profile → Profile Setup', (
      tester,
    ) async {
      final c = await _pump(tester, supabase: false);
      final session = c.read(sessionProvider.notifier);
      await session.signUp(
        fullName: '',
        method: ContactMethod.phone,
        identifier: '03339876543',
        password: _password,
      );
      session.logout();
      await tester.pumpAndSettle();
      await _enter(tester, 'login.phone', '0333-9876543');
      await _enter(tester, 'login.password', _password);
      await _tap(tester, _button('Login'));
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      expect(_loc(c), Routes.profileSetup, reason: 'not stuck on Login');
    });
  });

  group('Login (Supabase)', () {
    testWidgets('email field instead of phone; no Forgot password', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byKey(const Key('login.email')), findsOneWidget);
      expect(find.byKey(const Key('login.phone')), findsNothing);
      expect(find.text('Email address'), findsOneWidget);
      expect(find.byKey(const Key('login.forgot')), findsNothing);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('login.email')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.keyboardType, TextInputType.emailAddress);
      expect(field.autofillHints, [AutofillHints.email]);
    });

    testWidgets('validates the email inline, before any request', (
      tester,
    ) async {
      await _pump(tester);
      await _enter(tester, 'login.email', '03001234567');
      await _enter(tester, 'login.password', 'x');
      await _tap(tester, _button('Login'));
      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(auth.calls, isEmpty);
    });

    testWidgets('wrong password → friendly error; the right one signs in', (
      tester,
    ) async {
      final c = await _pump(tester);
      auth.addUser(_email, _password);
      await _login(tester, password: 'Wrong@123');
      expect(
        find.text('Incorrect email or password. Please try again.'),
        findsOneWidget,
      );
      expect(_loc(c), Routes.login);
      await _login(tester);
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      expect(_loc(c), Routes.profileSetup);
    });

    testWidgets('offline → connection message, button usable; retry works', (
      tester,
    ) async {
      final c = await _pump(tester);
      auth.addUser(_email, _password);
      auth.failNext = const GatewayNetworkException();
      await _login(tester);
      expect(
        find.text(
          "Couldn't reach the server — check your connection and try again",
        ),
        findsOneWidget,
      );
      final button = tester.widget<CeButton>(_button('Login'));
      expect(button.loading, isFalse, reason: 'the spinner resets');
      await _login(tester);
      expect(_loc(c), Routes.profileSetup);
    });

    testWidgets('unconfirmed email → asks to confirm it first', (tester) async {
      final c = await _pump(tester);
      auth.addUser(_email, _password);
      auth.failNext = const GatewayEmailNotConfirmedException();
      await _login(tester);
      expect(
        find.text('Check your email to confirm your account, then sign in'),
        findsOneWidget,
      );
      expect(_loc(c), Routes.login);
    });

    testWidgets('an unexpected backend error shows the generic text only', (
      tester,
    ) async {
      await _pump(tester);
      auth.failNext = const GatewayUnexpectedException('auth:secret_detail');
      await _login(tester);
      expect(
        find.text('Something went wrong — please try again'),
        findsOneWidget,
      );
      expect(find.textContaining('secret_detail'), findsNothing);
    });
  });

  group('Sign Up (Supabase)', () {
    testWidgets('no Continue with Google', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.signup);
      expect(find.byType(GoogleButton), findsNothing);
      expect(find.byType(AuthDivider), findsNothing);
      expect(_button('Create New Account'), findsOneWidget);
    });

    testWidgets('Create Account: email only, no Phone / Email chooser', (
      tester,
    ) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.createAccount);
      expect(find.text('Sign up with'), findsNothing);
      expect(find.byKey(const Key('signup.phone')), findsNothing);
      expect(find.byKey(const Key('signup.email')), findsOneWidget);
    });

    testWidgets('sign-up with a session → User Profile Setup', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(currentAccountProvider)!.email, _email);
    });

    testWidgets('confirmation required → "Check your email", then Login', (
      tester,
    ) async {
      final c = await _pump(tester);
      auth.requireConfirmation = true;
      await _signUp(tester, c);
      expect(find.byKey(const Key('signup.checkEmail')), findsOneWidget);
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining(_email), findsOneWidget);
      expect(
        find.text("Couldn't create your account — please try again"),
        findsNothing,
      );
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(_loc(c), Routes.createAccount);
      await _tap(tester, _button('Go to Login'));
      expect(_loc(c), Routes.login);
    });

    testWidgets('an existing account → "please log in"', (tester) async {
      final c = await _pump(tester);
      auth.failNext = const GatewayConstraintException(
        sqlState: '23505',
        message: 'user already exists',
      );
      await _signUp(tester, c);
      expect(
        find.text('An account with this email already exists — please log in'),
        findsOneWidget,
      );
      expect(_loc(c), Routes.createAccount);
      expect(
        tester.widget<CeButton>(_button('Create Account')).loading,
        isFalse,
      );
    });

    testWidgets('a double tap sends one sign-up request', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.createAccount);
      await _enter(tester, 'signup.email', _email);
      await _enter(tester, 'signup.password', _password);
      await _enter(tester, 'signup.confirm', _password);
      auth.gate = Completer<void>();
      final button = _button('Create Account');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      // While loading the label gives way to a spinner: tap the same spot.
      final at = tester.getCenter(button);
      await tester.tapAt(at);
      await tester.tapAt(at);
      await tester.pump();
      await tester.tapAt(at);
      await tester.pump();
      expect(
        find.byWidgetPredicate((w) => w is CeButton && w.loading),
        findsOneWidget,
      );
      auth.gate!.complete();
      await tester.pumpAndSettle();
      expect(_count(auth.calls, 'signUp'), 1);
      expect(_loc(c), Routes.profileSetup);
    });
  });

  group('Step 6 fix: a stale role never skips Role Selection', () {
    for (final (label, saved) in [
      (
        'another account\'s role',
        {
          'criceco.activeRole': 'player',
          'criceco.activeRole.account': 'user-old',
        },
      ),
      ('a legacy role (no account)', {'criceco.activeRole': 'player'}),
    ]) {
      testWidgets('$label: Sign up → Profile Setup → Role Selection', (
        tester,
      ) async {
        final c = await _pump(tester, saved: saved);
        await _signUp(tester, c);
        expect(_loc(c), Routes.profileSetup);
        await _fillProfile(tester);
        await _tap(tester, _button('Continue'));
        expect(
          _loc(c),
          Routes.roleSelection,
          reason: 'not the Player Dashboard',
        );
        expect(find.byType(RoleSelectionScreen), findsOneWidget);
        final uid = c.read(currentAccountProvider)!.id;
        expect(
          db.profiles[uid]!['role'],
          isNull,
          reason: 'Profile Setup writes no role',
        );
        // Both roles are still offered from here.
        expect(find.bySemanticsLabel(RegExp(r'^Player\. ')), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp(r'^Club Owner\. ')),
          findsOneWidget,
        );
      });
    }
  });

  group('User Profile Setup (Supabase)', () {
    testWidgets('a database refusal: its message, the form kept, retry saves', (
      tester,
    ) async {
      final c = await _onProfileSetup(tester);
      await _fillProfile(tester);
      db.failNext = const GatewayConstraintException(
        sqlState: '23502',
        message: 'null value in column "area"',
      );
      await _tap(tester, _button('Continue'));
      expect(find.text('Please complete all address fields'), findsOneWidget);
      expect(_loc(c), Routes.profileSetup);
      expect(_fieldText(tester, 'profile.name'), 'Hamza Sheikh');
      expect(_fieldText(tester, 'profile.currentArea'), 'Clifton');
      expect(
        _fieldText(tester, 'profile.currentAddress'),
        'House 12, Street 4',
      );
      expect(tester.widget<CeButton>(_button('Continue')).loading, isFalse);

      await _toastGone(tester);
      await _tap(tester, _button('Continue'));
      expect(_loc(c), Routes.roleSelection);
      final uid = c.read(currentAccountProvider)!.id;
      expect(db.profiles[uid]!['full_name'], 'Hamza Sheikh');
      expect(db.profiles[uid]!['profile_completed'], isTrue);
    });

    testWidgets('offline: the connection message; retry saves', (tester) async {
      final c = await _onProfileSetup(tester);
      await _fillProfile(tester);
      db.failNext = const GatewayNetworkException();
      await _tap(tester, _button('Continue'));
      expect(
        find.text(
          "Couldn't reach the server — check your connection and try again",
        ),
        findsOneWidget,
      );
      expect(_fieldText(tester, 'profile.name'), 'Hamza Sheikh');
      await _toastGone(tester);
      await _tap(tester, _button('Continue'));
      expect(_loc(c), Routes.roleSelection);
    });

    testWidgets('session gone: signed out locally, back at Login', (
      tester,
    ) async {
      final c = await _onProfileSetup(tester);
      await _fillProfile(tester);
      auth.current = null; // expired / revoked on the backend
      await _tap(tester, _button('Continue'));
      expect(find.text('Please sign in again'), findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(_loc(c), Routes.login);
    });

    testWidgets('signed in as someone else: signed out, back at Login', (
      tester,
    ) async {
      final c = await _onProfileSetup(tester);
      await _fillProfile(tester);
      auth.current = auth.addUser('other@example.com', _password);
      await _tap(tester, _button('Continue'));
      expect(
        find.text(
          'This account is not the one signed in — please sign in again',
        ),
        findsOneWidget,
      );
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(_loc(c), Routes.login);
    });
  });

  group('Role Selection → Player (Supabase)', () {
    testWidgets('a failed save: message, choices kept open, retry works', (
      tester,
    ) async {
      final c = await _playerChosen(tester);
      db.failNext = const GatewayNetworkException();
      await _tap(tester, _button('Continue as Player'));
      expect(
        find.text(
          "Couldn't reach the server — check your connection and try again",
        ),
        findsOneWidget,
      );
      expect(_loc(c), Routes.roleSelection);
      _expectPlayerChoicesKept(c);
      expect(
        tester.widget<CeButton>(_button('Continue as Player')).loading,
        isFalse,
        reason: 'the spinner resets',
      );

      await _toastGone(tester);
      await _tap(tester, _button('Continue as Player'));
      expect(_loc(c), Routes.playerHome);
      final uid = c.read(currentAccountProvider)!.id;
      expect(db.players[uid]!['player_role'], isNotNull);
      expect(db.profiles[uid]!['role'], 'player');
    });

    testWidgets('a role rule refused by the database shows its message', (
      tester,
    ) async {
      final c = await _playerChosen(tester);
      db.failNext = const GatewayConstraintException(
        sqlState: '23514',
        message: 'new row violates check constraint "x"',
      );
      await _tap(tester, _button('Continue as Player'));
      expect(_loc(c), Routes.roleSelection);
      _expectPlayerChoicesKept(c);
      expect(find.textContaining('violates'), findsNothing);
    });

    testWidgets('a double tap saves once', (tester) async {
      final c = await _playerChosen(tester);
      db.gate = Completer<void>();
      final button = _button('Continue as Player');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final at = tester.getCenter(button);
      await tester.tapAt(at);
      await tester.tapAt(at);
      await tester.pump();
      await tester.tapAt(at);
      await tester.pump();
      db.gate!.complete();
      await tester.pumpAndSettle();
      expect(_count(db.calls, 'upsertPlayerProfile'), 1);
      expect(_loc(c), Routes.playerHome);
    });

    testWidgets('session gone: signed out, back at Login', (tester) async {
      final c = await _playerChosen(tester);
      auth.current = null;
      await _tap(tester, _button('Continue as Player'));
      expect(find.text('Please sign in again'), findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(_loc(c), Routes.login);
    });
  });

  group('Settings → Password & security', () {
    Finder toggle(String title) => find.widgetWithText(CeToggleRow, title);

    testWidgets('memory mode: password change and Forgot stay', (tester) async {
      final c = await _pump(tester, supabase: false);
      await _enter(tester, 'login.phone', '0312-9020000');
      await _enter(tester, 'login.password', 'secret1');
      await _tap(tester, _button('Login'));
      await _go(tester, c, Routes.settings);
      expect(find.text('Change password, sign-in alerts'), findsOneWidget);
      await _go(tester, c, Routes.securitySettings);
      expect(find.byKey(const Key('security.current')), findsOneWidget);
      expect(find.byKey(const Key('security.new')), findsOneWidget);
      expect(find.byKey(const Key('security.forgot')), findsOneWidget);
      expect(_button('Update Password'), findsOneWidget);
      expect(toggle('Two-step verification'), findsOneWidget);
      expect(toggle('Login alerts'), findsOneWidget);
    });

    testWidgets('supabase: no password controls; sign-in toggles kept', (
      tester,
    ) async {
      final c = await _profiled(tester);
      await _go(tester, c, Routes.settings);
      expect(find.text('Sign-in alerts'), findsOneWidget);
      expect(find.text('Change password, sign-in alerts'), findsNothing);
      await _go(tester, c, Routes.securitySettings);
      expect(_loc(c), Routes.securitySettings);
      expect(find.byKey(const Key('security.current')), findsNothing);
      expect(find.byKey(const Key('security.new')), findsNothing);
      expect(find.byKey(const Key('security.forgot')), findsNothing);
      expect(_button('Update Password'), findsNothing);
      expect(toggle('Two-step verification'), findsOneWidget);
      expect(toggle('Login alerts'), findsOneWidget);

      // The toggles still save (this device's settings, D9).
      final before = c.read(currentAccountProvider)!.settings.loginAlerts;
      tester.widget<CeToggleRow>(toggle('Login alerts')).onChanged(!before);
      await tester.pumpAndSettle();
      expect(c.read(currentAccountProvider)!.settings.loginAlerts, !before);
    });
  });

  group('M1: an RLS refusal keeps the user signed in', () {
    testWidgets('Profile Setup: the permission message, no logout', (
      tester,
    ) async {
      final c = await _onProfileSetup(tester);
      await _fillProfile(tester);
      db.failNext = const GatewayConstraintException(
        sqlState: '42501',
        message: 'new row violates row-level security policy',
      );
      await _tap(tester, _button('Continue'));
      expect(find.text("You don't have permission to do that"), findsOneWidget);
      expect(find.textContaining('row-level'), findsNothing);
      expect(c.read(sessionProvider).isAuthenticated, isTrue);
      expect(_loc(c), Routes.profileSetup);
      expect(_fieldText(tester, 'profile.name'), 'Hamza Sheikh');
      expect(auth.calls, isNot(contains('signOut')));
    });
  });

  group('error paths (M3)', () {
    const offline =
        "Couldn't reach the server — check your connection and try again";

    /// Memory mode, signed in as the demo Player (seed credentials).
    Future<ProviderContainer> demoPlayer(WidgetTester tester) async {
      final c = await _pump(tester, supabase: false, flaky: true);
      await _enter(tester, 'login.phone', '0312-9020000');
      await _enter(tester, 'login.password', 'secret1');
      await _tap(tester, _button('Login'));
      return c;
    }

    testWidgets('Google sign-in failure: message, loader reset, retry works', (
      tester,
    ) async {
      final c = await _pump(tester, supabase: false, flaky: true);
      await _go(tester, c, Routes.signup);
      accounts.failGoogle = const BackendUnavailableException();
      await _tap(tester, find.byType(GoogleButton));
      expect(find.text(offline), findsOneWidget);
      expect(
        tester.widget<GoogleButton>(find.byType(GoogleButton)).loading,
        isFalse,
      );
      expect(_loc(c), Routes.signup);
      await _toastGone(tester);

      accounts.failGoogle = StateError('oauth: client secret missing');
      await _tap(tester, find.byType(GoogleButton));
      expect(
        find.text("Couldn't sign in with Google — please try again"),
        findsOneWidget,
      );
      expect(find.textContaining('oauth'), findsNothing);
      await _toastGone(tester);

      accounts.failGoogle = null;
      await _tap(tester, find.byType(GoogleButton));
      expect(_loc(c), Routes.profileSetup);
    });

    /// Club Setup Details with valid answers (Home Ground: No).
    Future<void> fillClub(WidgetTester tester) async {
      await _enter(tester, 'club.name', 'Karachi Kites');
      await _enter(tester, 'club.owner', 'Hamza Sheikh');
      await _enter(tester, 'club.address', 'Clifton');
      await _tap(tester, find.byKey(const Key('club.city')));
      await _tap(tester, find.text('Karachi').last);
      await _tap(tester, find.text('Professional'));
      await _tap(tester, find.text('No'));
    }

    testWidgets('Club Setup failure: typed or fallback text, retry works', (
      tester,
    ) async {
      final c = await demoPlayer(tester);
      await _go(tester, c, Routes.roleSelection);
      await _tap(tester, find.bySemanticsLabel(RegExp(r'^Club Owner\. ')));
      expect(_loc(c), Routes.clubSetup);
      await fillClub(tester);

      accounts.failUpdate = const BackendUnavailableException();
      await _tap(tester, _button('Create Club'));
      expect(find.text(offline), findsOneWidget);
      expect(_loc(c), Routes.clubSetup);
      expect(tester.widget<CeButton>(_button('Create Club')).loading, isFalse);

      accounts.failUpdate = StateError('club_owner flag: internal');
      await _tap(tester, _button('Create Club'));
      expect(
        find.text("We couldn't create your club. Please try again."),
        findsOneWidget,
      );
      expect(find.textContaining('internal'), findsNothing);

      accounts.failUpdate = null;
      await _tap(tester, _button('Create Club'));
      expect(_loc(c), Routes.clubHome);
    });

    testWidgets('Club Setup with the session gone: signed out, Login', (
      tester,
    ) async {
      final c = await _profiled(tester);
      await _go(tester, c, Routes.roleSelection);
      await _tap(tester, find.bySemanticsLabel(RegExp(r'^Club Owner\. ')));
      await fillClub(tester);
      auth.current = null;
      await _tap(tester, _button('Create Club'));
      expect(find.text('Please sign in again'), findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(_loc(c), Routes.login);
    });

    testWidgets(
      'Club Owner: offline first, retry → Dashboard; the club and role saved',
      (tester) async {
        final c = await _profiled(tester);
        final uid = c.read(currentAccountProvider)!.id;
        await _go(tester, c, Routes.roleSelection);
        await _tap(tester, find.bySemanticsLabel(RegExp(r'^Club Owner\. ')));
        await fillClub(tester);

        clubDb.failNext = const GatewayNetworkException();
        await _tap(tester, _button('Create Club'));
        expect(find.text(offline), findsOneWidget);
        expect(_loc(c), Routes.clubSetup);
        expect(db.profiles[uid]!['role'], isNull);
        expect(clubDb.clubs, isEmpty);
        expect(c.read(sessionProvider).hasClubOwnerProfile, isFalse);

        await _tap(tester, _button('Create Club')); // retry
        expect(_loc(c), Routes.clubHome);
        expect(clubDb.clubs[uid]!['name'], 'Karachi Kites');
        expect(db.profiles[uid]!['role'], 'club_owner');
        expect(c.read(sessionProvider).hasClubOwnerProfile, isTrue);
      },
    );

    testWidgets('Edit Profile photo failure: message, picture unchanged', (
      tester,
    ) async {
      final c = await demoPlayer(tester);
      await _go(tester, c, Routes.playerProfile);
      final before = c.read(currentAccountProvider)!.photoPath;
      accounts.failUpdate = const BackendUnavailableException();
      await _tap(tester, find.byKey(const Key('profile.photo')));
      await _tap(tester, find.text('Choose from gallery'));
      expect(find.text(offline), findsOneWidget);
      expect(find.text('Profile picture updated'), findsNothing);
      expect(c.read(currentAccountProvider)!.photoPath, before);
      expect(_loc(c), Routes.playerProfile);
    });

    testWidgets('Edit Profile photo with the session gone: Login', (
      tester,
    ) async {
      final c = await _playerChosen(tester);
      await _tap(tester, _button('Continue as Player'));
      await _go(tester, c, Routes.playerProfile);
      auth.current = null;
      await _tap(tester, find.byKey(const Key('profile.photo')));
      await _tap(tester, find.text('Choose from gallery'));
      expect(find.text('Please sign in again'), findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(_loc(c), Routes.login);
    });

    testWidgets('password change failure: message, spinner reset, retry', (
      tester,
    ) async {
      final c = await demoPlayer(tester);
      await _go(tester, c, Routes.securitySettings);
      await _enter(tester, 'security.current', 'secret1');
      await _enter(tester, 'security.new', 'Cricket@123');

      accounts.failChangePassword = const BackendUnavailableException();
      await _tap(tester, _button('Update Password'));
      expect(find.text(offline), findsOneWidget);
      expect(_loc(c), Routes.securitySettings);
      expect(
        tester.widget<CeButton>(_button('Update Password')).loading,
        isFalse,
      );
      await _toastGone(tester);

      accounts.failChangePassword = UnsupportedError('reset not configured');
      await _tap(tester, _button('Update Password'));
      expect(
        find.text("Couldn't update your password — please try again"),
        findsOneWidget,
      );
      expect(find.textContaining('configured'), findsNothing);
      await _toastGone(tester);

      accounts.failChangePassword = null;
      await _tap(tester, _button('Update Password'));
      expect(_loc(c), Routes.settings);
      expect(find.text('Password updated'), findsOneWidget);
    });
  });
}
