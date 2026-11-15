import 'dart:async';

import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/auth_features.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// AUTH-02D: the sign-up code sheet ("Verify your email") on Create Account
/// and Login — with the email-codes switch on, and unchanged with it off.

/// [FakeAuth] whose code check waits for [verifyGate] (a request in flight).
class GatedAuth extends FakeAuth {
  GatedAuth(super.db);
  Completer<void>? verifyGate;

  @override
  Future<AuthUser> verifySignUpCode({
    required String email,
    required String code,
  }) async {
    await verifyGate?.future;
    return super.verifySignUpCode(email: email, code: code);
  }
}

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);
const _email = 'hamza@example.com';
const _masked = 'h•••@example.com';
const _password = 'Cricket@123';
const _invalid =
    'That code is incorrect or has expired — check it or request a new one';

late FakeDb db;
late GatedAuth auth;
late DateTime t;

/// The app at Login: Supabase mode (email confirmation on) or the demo;
/// the email-codes switch [codes].
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool codes = true,
  bool supabase = true,
  bool confirmation = true,
  double width = 375,
}) async {
  tester.view.physicalSize = Size(width * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  t = DateTime(2026, 11, 15, 10);
  db = FakeDb();
  auth = GatedAuth(db)
    ..requireConfirmation = confirmation
    ..now = () => t;
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      clockProvider.overrideWith((ref) => Clock(() => t)),
      emailCodesEnabledProvider.overrideWithValue(codes),
      cityAreasProvider.overrideWith((ref) async => CityAreas.empty),
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
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

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

String _fieldText(WidgetTester tester, String key) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

Finder _button(String label) => find.widgetWithText(CeButton, label);
final _sheet = find.byKey(const Key('verify.sheet'));
final _resend = find.byKey(const Key('verify.resend'));

int _count(String call) => auth.calls.where((c) => c == call).length;

/// Advances the clock (the app's and the fake backend's) and the countdown.
Future<void> _wait(WidgetTester tester, Duration d) async {
  t = t.add(d);
  await tester.pump(d);
  await tester.pump();
}

/// Create Account filled in (Full Name, [email], password) and submitted.
Future<void> _signUp(
  WidgetTester tester,
  ProviderContainer c, {
  String email = _email,
}) async {
  c.read(routerProvider).go(Routes.createAccount);
  await tester.pumpAndSettle();
  await _enter(tester, 'signup.name', 'Hamza Sheikh');
  await _enter(tester, 'signup.email', email);
  await _enter(tester, 'signup.password', _password);
  await _enter(tester, 'signup.confirm', _password);
  await _tap(tester, _button('Create Account'));
}

Future<void> _verify(WidgetTester tester, String code) async {
  await _enter(tester, 'verify.code', code);
  await _tap(tester, find.byKey(const Key('verify.submit')));
}

String? _resendLabel(WidgetTester tester) =>
    (tester.widget<TextButton>(_resend).child! as Text).data;

bool _resendEnabled(WidgetTester tester) =>
    tester.widget<TextButton>(_resend).onPressed != null;

void main() {
  group('production safety: the switch and the backend decide', () {
    testWidgets('switch OFF: the existing "Check your email" link panel, no '
        'code sheet', (tester) async {
      final c = await _pump(tester, codes: false);
      await _signUp(tester, c);
      expect(find.byKey(const Key('signup.checkEmail')), findsOneWidget);
      expect(_sheet, findsNothing);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
    });

    testWidgets('switch ON, confirmation off (production today): signed in '
        'at once → Profile Setup, no code asked', (tester) async {
      final c = await _pump(tester, confirmation: false);
      await _signUp(tester, c);
      expect(_sheet, findsNothing);
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
    });

    testWidgets('switch OFF: an unverified login keeps today\'s message, no '
        'Verify Email', (tester) async {
      final c = await _pump(tester, codes: false);
      await _signUp(tester, c);
      await _tap(tester, _button('Go to Login'));
      await _enter(tester, 'login.email', _email);
      await _enter(tester, 'login.password', _password);
      await _tap(tester, _button('Login'));
      expect(
        find.text('Check your email to confirm your account, then sign in'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('login.verifyEmail')), findsNothing);
    });
  });

  group('Create Account → code sheet (Supabase)', () {
    testWidgets('opens with the masked email, neutral wording, and Resend '
        'counting down from 1:00', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      expect(_sheet, findsOneWidget);
      final text = (tester.widget<Text>(
        find.byKey(const Key('verify.destination')),
      )).data!;
      expect(text, contains(_masked));
      expect(text, isNot(contains(_email)), reason: 'never the full address');
      expect(text, contains('If this email can be used'));
      expect(_resendLabel(tester), 'Resend code in 1:00');
      expect(_resendEnabled(tester), isFalse);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
    });

    testWidgets('the code field takes digits only, at most six; fewer → '
        'its message and no request', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      await _enter(tester, 'verify.code', 'ab12cd');
      expect(_fieldText(tester, 'verify.code'), '12');
      await _enter(tester, 'verify.code', '1234567');
      expect(_fieldText(tester, 'verify.code'), '123456');
      await _verify(tester, '123');
      expect(find.text('Enter the 6-digit code'), findsOneWidget);
      expect(_count('verifySignUpCode'), 0);
    });

    testWidgets('a wrong code: its message, the sheet stays, signed out; the '
        'right code → Profile Setup → Role Selection', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      await _verify(tester, '000000');
      expect(find.text(_invalid), findsOneWidget);
      expect(_sheet, findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);

      await _verify(tester, auth.lastCode(_email)!);
      expect(_sheet, findsNothing);
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      expect(_fieldText(tester, 'profile.name'), 'Hamza Sheikh');

      // The existing onboarding continues: Profile Setup → Role Selection.
      await _enter(tester, 'profile.phone', '0333-9876543');
      await _tap(tester, find.byKey(const Key('profile.dob')));
      await _tap(tester, find.text('OK'));
      await _tap(tester, find.byKey(const Key('profile.currentCity')));
      await _tap(tester, find.text('Karachi').last);
      await _enter(tester, 'profile.currentArea', 'Clifton');
      await _enter(tester, 'profile.currentAddress', 'House 12, Street 4');
      await _tap(tester, _button('Continue'));
      expect(_loc(c), Routes.roleSelection);
      expect(c.read(sessionProvider).status, SessionStatus.signedIn);
    });

    testWidgets('an expired code (after 15 minutes): its message', (
      tester,
    ) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      final code = auth.lastCode(_email)!;
      await _wait(tester, const Duration(seconds: 900));
      await _verify(tester, code);
      expect(find.text(_invalid), findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
    });

    testWidgets('the countdown, then Resend: a new code (noted), the old '
        'one refused, the new one accepted', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      final first = auth.lastCode(_email)!;
      await _wait(tester, const Duration(seconds: 30));
      expect(_resendLabel(tester), 'Resend code in 0:30');
      expect(_resendEnabled(tester), isFalse);
      await _wait(tester, const Duration(seconds: 30));
      expect(_resendLabel(tester), 'Resend code');
      expect(_resendEnabled(tester), isTrue);

      await _tap(tester, _resend);
      expect(_count('resendSignUpCode'), 1);
      expect(find.text('A new code was sent to $_masked.'), findsOneWidget);
      expect(
        _resendLabel(tester),
        'Resend code in 1:00',
        reason: 'counts down again',
      );
      final second = auth.lastCode(_email)!;
      expect(second, isNot(first));
      await _verify(tester, first);
      expect(find.text(_invalid), findsOneWidget);
      await _verify(tester, second);
      expect(_loc(c), Routes.profileSetup);
    });

    testWidgets('rate-limited resend: its message, the countdown restarts', (
      tester,
    ) async {
      final c = await _pump(tester);
      auth.resendInterval = const Duration(seconds: 120); // stricter server
      await _signUp(tester, c);
      await _wait(tester, const Duration(seconds: 60));
      await _tap(tester, _resend);
      expect(
        find.text('Too many attempts — please wait a moment and try again'),
        findsOneWidget,
      );
      expect(_resendEnabled(tester), isFalse);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
    });

    testWidgets('offline: the connection message; a retry works', (
      tester,
    ) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      auth.failNext = const GatewayNetworkException();
      await _verify(tester, auth.lastCode(_email)!);
      expect(
        find.text(const BackendUnavailableException().message),
        findsOneWidget,
      );
      expect(_sheet, findsOneWidget);
      await _tap(tester, find.byKey(const Key('verify.submit')));
      expect(_loc(c), Routes.profileSetup);
    });

    testWidgets('while checking: a spinner, and extra taps / Done send no '
        'second request', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      await _enter(tester, 'verify.code', auth.lastCode(_email)!);
      auth.verifyGate = Completer<void>();
      final submit = find.byKey(const Key('verify.submit'));
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      final at = tester.getCenter(submit);
      await tester.tapAt(at);
      await tester.pump();
      await tester.tapAt(at);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<CeButton>(submit).loading, isTrue);
      expect(_resendEnabled(tester), isFalse);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('verify.changeEmail')))
            .onPressed,
        isNull,
      );
      auth.verifyGate!.complete();
      await tester.pumpAndSettle();
      expect(_count('verifySignUpCode'), 1);
      expect(_loc(c), Routes.profileSetup);
    });

    testWidgets('Change email: back to the form as typed; a new address gets '
        'its own sheet', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      await _tap(tester, find.byKey(const Key('verify.changeEmail')));
      expect(_sheet, findsNothing);
      expect(_fieldText(tester, 'signup.email'), _email);
      await _enter(tester, 'signup.email', 'new.mail@example.com');
      await _tap(tester, _button('Create Account'));
      expect(_sheet, findsOneWidget);
      expect(
        (tester.widget<Text>(find.byKey(const Key('verify.destination')))).data,
        contains('n•••@example.com'),
      );
      await _verify(tester, auth.lastCode('new.mail@example.com')!);
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(currentAccountProvider)!.email, 'new.mail@example.com');
    });

    testWidgets('closed: the "Verify your email" panel — Enter Code reopens '
        '(the countdown continues), Login leaves', (tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      await tester.tapAt(const Offset(10, 10)); // outside the sheet
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(find.byKey(const Key('signup.codePending')), findsOneWidget);
      expect(find.textContaining(_masked), findsOneWidget);

      await _wait(tester, const Duration(seconds: 20));
      await _tap(tester, find.byKey(const Key('signup.enterCode')));
      expect(_sheet, findsOneWidget);
      expect(_resendLabel(tester), 'Resend code in 0:40');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await _tap(tester, find.text('Login'));
      expect(_loc(c), Routes.login);
    });

    testWidgets('closed, then Change Email on the panel: the form again', (
      tester,
    ) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('signup.changeEmail')));
      expect(find.byKey(const Key('signup.codePending')), findsNothing);
      expect(_fieldText(tester, 'signup.email'), _email);
      expect(_loc(c), Routes.createAccount);
    });

    testWidgets('the code is accepted but the account read fails: "Email '
        'confirmed — log in", nothing signed in; logging in then works', (
      tester,
    ) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      db.failNext = const GatewayNetworkException(); // the read after verifying
      await _verify(tester, auth.lastCode(_email)!);
      expect(find.byKey(const Key('verify.confirmed')), findsOneWidget);
      expect(find.text('Email confirmed'), findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(auth.current, isNull, reason: 'the half-started session ended');

      await _tap(tester, find.byKey(const Key('verify.goToLogin')));
      expect(_loc(c), Routes.login);
      await _enter(tester, 'login.email', _email);
      await _enter(tester, 'login.password', _password);
      await _tap(tester, _button('Login'));
      expect(
        _loc(c),
        Routes.profileSetup,
        reason: 'the email is confirmed now',
      );
    });
  });

  group('Login → Verify Email (Supabase)', () {
    /// A sign-up that never entered its code, then Login.
    Future<ProviderContainer> unverifiedAtLogin(WidgetTester tester) async {
      final c = await _pump(tester);
      await _signUp(tester, c);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Login'));
      await _enter(tester, 'login.email', _email);
      await _enter(tester, 'login.password', _password);
      await _tap(tester, _button('Login'));
      return c;
    }

    testWidgets('an unverified account: the message and Verify Email; a '
        'fresh code is sent, the code signs in → Profile Setup', (
      tester,
    ) async {
      final c = await unverifiedAtLogin(tester);
      expect(
        find.text(
          'Verify your email to log in — we’ll send you a 6-digit code.',
        ),
        findsOneWidget,
      );
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      await _wait(tester, const Duration(seconds: 61));
      final before = auth.lastCode(_email);
      await _tap(tester, find.byKey(const Key('login.verifyEmail')));
      expect(_sheet, findsOneWidget);
      expect(_count('resendSignUpCode'), 1);
      expect(auth.lastCode(_email), isNot(before), reason: 'a fresh code');
      await _verify(tester, auth.lastCode(_email)!);
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
    });

    testWidgets('right after signing up: "a code was sent recently", the '
        'earlier code still works', (tester) async {
      final c = await unverifiedAtLogin(tester);
      await _tap(tester, find.byKey(const Key('login.verifyEmail')));
      expect(
        find.text('A code was sent recently — check your email.'),
        findsOneWidget,
      );
      expect(_resendEnabled(tester), isFalse);
      await _verify(tester, auth.lastCode(_email)!);
      expect(_loc(c), Routes.profileSetup);
    });

    testWidgets('Change email from Login: the sheet closes, the message goes', (
      tester,
    ) async {
      final c = await unverifiedAtLogin(tester);
      await _tap(tester, find.byKey(const Key('login.verifyEmail')));
      await _tap(tester, find.byKey(const Key('verify.changeEmail')));
      expect(_sheet, findsNothing);
      expect(find.byKey(const Key('login.verifyEmail')), findsNothing);
      expect(_loc(c), Routes.login);
    });
  });

  group('demo mode (email-codes switch on)', () {
    testWidgets('the demo code is shown; "Use code" fills it; verified → '
        'Profile Setup', (tester) async {
      final c = await _pump(tester, supabase: false);
      c.read(routerProvider).go(Routes.createAccount);
      await tester.pumpAndSettle();
      await _enter(tester, 'signup.name', 'Aman Ullah');
      await _tap(tester, find.text('Email'));
      await _enter(tester, 'signup.email', 'aman@example.com');
      await _enter(tester, 'signup.password', _password);
      await _enter(tester, 'signup.confirm', _password);
      await _tap(tester, _button('Create Account'));
      expect(_sheet, findsOneWidget);
      expect(
        find.textContaining('No email is sent in this build'),
        findsOneWidget,
      );
      await _tap(tester, find.text('Use code'));
      expect(_fieldText(tester, 'verify.code'), matches(RegExp(r'^\d{6}$')));
      await _tap(tester, find.byKey(const Key('verify.submit')));
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(currentAccountProvider)!.fullName, 'Aman Ullah');
    });

    testWidgets('demo resend after the countdown shows the new code', (
      tester,
    ) async {
      final c = await _pump(tester, supabase: false);
      c.read(routerProvider).go(Routes.createAccount);
      await tester.pumpAndSettle();
      await _enter(tester, 'signup.name', 'Aman Ullah');
      await _tap(tester, find.text('Email'));
      await _enter(tester, 'signup.email', 'aman@example.com');
      await _enter(tester, 'signup.password', _password);
      await _enter(tester, 'signup.confirm', _password);
      await _tap(tester, _button('Create Account'));
      final first = find.textContaining('Your code is ');
      final firstText = (tester.widget<Text>(first)).data;
      await _wait(tester, const Duration(seconds: 60));
      await _tap(tester, _resend);
      expect(
        (tester.widget<Text>(find.textContaining('Your code is '))).data,
        isNot(firstText),
      );
      await _tap(tester, find.text('Use code'));
      await _tap(tester, find.byKey(const Key('verify.submit')));
      expect(_loc(c), Routes.profileSetup);
    });
  });

  group('layout', () {
    for (final width in [320.0, 414.0]) {
      testWidgets('no overflow at $width px (with an error showing)', (
        tester,
      ) async {
        final c = await _pump(tester, width: width);
        await _signUp(tester, c);
        await _verify(tester, '000000');
        expect(find.text(_invalid), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('signup.codePending')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
