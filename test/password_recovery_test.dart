import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/auth_features.dart';
import 'package:criceco/app/config/auth_redirects.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/auth_notice.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// AUTH-04: password recovery in Supabase mode (fake gateways) — the
/// recovery email (code + link), the recovery session, Reset Password, and
/// the router guard. The demo's reset is covered by password_reset_test.dart.
void main() {
  const accountKey = 'criceco.session.accountId';
  const email = 'player@example.com';
  const oldPassword = 'Cricket@2026';
  const newPassword = 'Wicket#2027';
  const invalidCode =
      'That code is incorrect or has expired — check it or request a new one.';
  final supabase = BackendConfig.parse(
    backend: 'supabase',
    supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
    supabasePublishableKey: 'sb_publishable_test_0000000000000000',
  );

  late FakeDb db;
  late FakeAuth auth;
  late SharedPreferences prefs;
  late DateTime t;

  List<Override> overrides({bool codes = true}) => [
    sharedPreferencesProvider.overrideWithValue(prefs),
    clockProvider.overrideWith((ref) => Clock(() => t)),
    emailCodesEnabledProvider.overrideWithValue(codes),
    backendConfigProvider.overrideWithValue(supabase),
    authGatewayProvider.overrideWithValue(auth),
    profileGatewayProvider.overrideWithValue(db),
    clubGatewayProvider.overrideWithValue(FakeClubDb(db)),
    locationGatewayProvider.overrideWithValue(FakeLocationGateway()),
  ];

  Future<void> freshBackend() async {
    t = DateTime(2026, 11, 15, 10);
    db = FakeDb();
    auth = FakeAuth(db)..now = () => t;
    auth.addUser(
      email,
      oldPassword,
      metadata: const {'full_name': 'Hamza Sheikh'},
    );
  }

  group('repository + session (Supabase mode)', () {
    late ProviderContainer c;

    Future<void> start({Map<String, Object> saved = const {}}) async {
      SharedPreferences.setMockInitialValues(saved);
      prefs = await SharedPreferences.getInstance();
      c = ProviderContainer(overrides: overrides());
      addTearDown(c.dispose);
    }

    SessionController session() => c.read(sessionProvider.notifier);
    SessionState state() => c.read(sessionProvider);
    AuthNotice? notice() => c.read(authNoticeProvider);

    setUp(() async {
      await freshBackend();
      await start();
    });

    test('request: one email (code + link back to the app), a neutral masked ticket', () async {
      final ticket = await session().requestPasswordReset(
        ' Player@Example.com ',
      );
      expect(auth.recoveryEmails, [email], reason: 'trimmed, lower-case');
      expect(
        auth.lastRedirect,
        kNativeAuthCallbackUrl,
        reason: 'the link opens the app',
      );
      expect(ticket!.destination, 'p•••@example.com');
      expect(ticket.accountMayNotExist, isTrue);
      expect(ticket.expiresAt, t.add(const Duration(seconds: 900)));
      expect(
        ticket.demoCode,
        isNull,
        reason: 'never a code on screen outside the demo',
      );
      expect(auth.lastRecoveryCode(email), isNotNull);
      expect(state().isAuthenticated, isFalse);
    });

    test('request for an unknown address: the same answer (no account is revealed), no code', () async {
      final ticket = await session().requestPasswordReset('nobody@example.com');
      expect(ticket, isNotNull);
      expect(ticket!.accountMayNotExist, isTrue);
      expect(auth.lastRecoveryCode('nobody@example.com'), isNull);
    });

    test(
      'request: a phone number is refused before any request (email only)',
      () async {
        await expectLater(
          session().requestPasswordReset('03001234567'),
          throwsA(isA<UnsupportedSignInMethodException>()),
        );
        expect(auth.calls, isNot(contains('sendPasswordReset')));
      },
    );

    test(
      'request again within 60 s: rate limited, with the app\'s own message',
      () async {
        await session().requestPasswordReset(email);
        await expectLater(
          session().requestPasswordReset(email),
          throwsA(isA<TooManyRequestsException>()),
        );
        t = t.add(const Duration(seconds: 61));
        await session().requestPasswordReset(email);
        expect(auth.recoveryEmails, [email, email]);
      },
    );

    test('request while offline: BackendUnavailableException', () async {
      auth.failNext = const GatewayNetworkException();
      await expectLater(
        session().requestPasswordReset(email),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test(
      'a wrong code: invalid, no recovery session, nothing signed in',
      () async {
        await session().requestPasswordReset(email);
        expect(
          await session().verifyResetCode(email, '000000'),
          ResetCodeCheck.invalid,
        );
        expect(state().passwordRecovery, isFalse);
        expect(auth.current, isNull);
      },
    );

    test('a malformed code is refused without a request', () async {
      await session().requestPasswordReset(email);
      for (final code in ['12345', '1234567', 'abcdef', '']) {
        expect(
          await session().verifyResetCode(email, code),
          ResetCodeCheck.invalid,
          reason: code,
        );
      }
      expect(auth.calls, isNot(contains('verifyRecoveryCode')));
    });

    test('an expired code (after 900 s): invalid', () async {
      await session().requestPasswordReset(email);
      final code = auth.lastRecoveryCode(email)!;
      t = t.add(const Duration(seconds: 901));
      expect(
        await session().verifyResetCode(email, code),
        ResetCodeCheck.invalid,
      );
      expect(state().passwordRecovery, isFalse);
    });

    test(
      'the right code: a recovery session — not signed in, nothing remembered',
      () async {
        await session().requestPasswordReset(email);
        expect(
          await session().verifyResetCode(email, auth.lastRecoveryCode(email)!),
          ResetCodeCheck.ok,
        );
        final s = state();
        expect(s.passwordRecovery, isTrue);
        expect(s.recoveryEmail, email);
        expect(
          s.isAuthenticated,
          isFalse,
          reason: 'a recovery session is not a sign-in',
        );
        expect(s.account, isNull);
        expect(prefs.getString(accountKey), isNull);
        expect(auth.sessionKind, AuthSessionKind.recovery);
      },
    );

    test('a used code works once', () async {
      await session().requestPasswordReset(email);
      final code = auth.lastRecoveryCode(email)!;
      await session().verifyResetCode(email, code);
      await session().cancelPasswordRecovery();
      expect(
        await session().verifyResetCode(email, code),
        ResetCodeCheck.invalid,
      );
    });

    test('a resent code replaces the previous one', () async {
      await session().requestPasswordReset(email);
      final first = auth.lastRecoveryCode(email)!;
      t = t.add(const Duration(seconds: 61));
      await session().requestPasswordReset(email);
      expect(
        await session().verifyResetCode(email, first),
        ResetCodeCheck.invalid,
      );
      expect(
        await session().verifyResetCode(email, auth.lastRecoveryCode(email)!),
        ResetCodeCheck.ok,
      );
    });

    Future<void> recover() async {
      await session().requestPasswordReset(email);
      await session().verifyResetCode(email, auth.lastRecoveryCode(email)!);
    }

    test(
      'a weak new password is refused before any request; the recovery stays',
      () async {
        await recover();
        await expectLater(
          session().completePasswordRecovery('weakpass'),
          throwsA(isA<WeakPasswordException>()),
        );
        expect(auth.calls, isNot(contains('updatePassword')));
        expect(state().passwordRecovery, isTrue);
      },
    );

    test('the current password again: SamePasswordException; the recovery stays to try again', () async {
      await recover();
      await expectLater(
        session().completePasswordRecovery(oldPassword),
        throwsA(isA<SamePasswordException>()),
      );
      expect(state().passwordRecovery, isTrue);
      expect(auth.passwordOf(email), oldPassword);
    });

    test(
      'success: the new password is set, every session ends, Login says so',
      () async {
        await recover();
        await session().completePasswordRecovery(newPassword);
        expect(auth.passwordOf(email), newPassword);
        expect(auth.globalSignOuts, 1, reason: 'all devices signed out');
        expect(auth.current, isNull);
        expect(state().passwordRecovery, isFalse);
        expect(state().isAuthenticated, isFalse);
        expect(
          notice()!.message,
          'Password updated. Log in with your new password.',
        );
        expect(notice()!.isError, isFalse);
        // Then: the new password logs in, the old one doesn't.
        expect(
          await session().signIn(identifier: email, password: oldPassword),
          isFalse,
        );
        expect(
          await session().signIn(identifier: email, password: newPassword),
          isTrue,
        );
        expect(state().account!.email, email);
      },
    );

    test('the recovery session expired meanwhile: RecoverySessionMissingException; it ends', () async {
      await recover();
      auth.current = null; // the backend dropped it
      await expectLater(
        session().completePasswordRecovery(newPassword),
        throwsA(isA<RecoverySessionMissingException>()),
      );
      expect(state().passwordRecovery, isFalse);
      expect(
        notice()!.message,
        'This reset has expired — request a new code and try again',
      );
      expect(auth.passwordOf(email), oldPassword);
    });

    test('update while offline: the recovery stays to retry', () async {
      await recover();
      auth.failNext = const GatewayNetworkException();
      await expectLater(
        session().completePasswordRecovery(newPassword),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(state().passwordRecovery, isTrue);
      await session().completePasswordRecovery(newPassword);
      expect(auth.passwordOf(email), newPassword);
    });

    test(
      'global sign-out fails: still signed out here, the password is changed',
      () async {
        await recover();
        auth.addFailure('signOutEverywhere', const GatewayNetworkException());
        await session().completePasswordRecovery(newPassword);
        expect(auth.passwordOf(email), newPassword);
        expect(auth.current, isNull, reason: 'at least this device');
        expect(state().passwordRecovery, isFalse);
      },
    );

    test('Cancel: the recovery session ends without a change', () async {
      await recover();
      await session().cancelPasswordRecovery();
      expect(state().passwordRecovery, isFalse);
      expect(auth.current, isNull);
      expect(auth.passwordOf(email), oldPassword);
    });

    test(
      'no recovery session: the repository refuses to set a password',
      () async {
        final repo = c.read(accountRepositoryProvider);
        await expectLater(
          repo.completePasswordRecovery(newPassword, at: t),
          throwsA(isA<RecoverySessionMissingException>()),
        );
        // A normal session is not a recovery session either.
        await session().signIn(identifier: email, password: oldPassword);
        expect(repo.passwordRecoveryActive, isFalse);
        await expectLater(
          repo.completePasswordRecovery(newPassword, at: t),
          throwsA(isA<RecoverySessionMissingException>()),
        );
        expect(auth.passwordOf(email), oldPassword);
      },
    );

    test('resetPassword (the sheet\'s step 3) needs the recovery session of the same address', () async {
      final repo = c.read(accountRepositoryProvider);
      expect(
        await repo.resetPassword(email, '123456', newPassword, at: t),
        ResetCodeCheck.noRequest,
      );
      await recover();
      expect(
        await repo.resetPassword('other@example.com', '', newPassword, at: t),
        ResetCodeCheck.noRequest,
      );
      expect(
        await repo.resetPassword(email, '', newPassword, at: t),
        ResetCodeCheck.ok,
      );
      expect(auth.passwordOf(email), newPassword);
    });

    group('the recovery link', () {
      test(
        'opened at app start (web): restore goes to the recovery, nothing else',
        () async {
          auth
            ..startRecoverySession(email)
            ..startEvent = const GatewayRecoveryStarted();
          await start(saved: {accountKey: 'user-1'});
          await session().restore();
          expect(state().passwordRecovery, isTrue);
          expect(state().recoveryEmail, email);
          expect(state().isAuthenticated, isFalse);
          expect(
            prefs.getString(accountKey),
            isNull,
            reason: 'the recovery replaced the session',
          );
        },
      );

      test('opened while the app runs (Android): the recovery replaces a signed-in session', () async {
        await session().restore();
        await session().signIn(identifier: email, password: oldPassword);
        auth
          ..startRecoverySession(email)
          ..emit(const GatewayRecoveryStarted());
        await pumpEventQueue();
        expect(state().passwordRecovery, isTrue);
        expect(state().isAuthenticated, isFalse);
        expect(prefs.getString(accountKey), isNull);
      });

      test(
        'expired or used link at start: a message on Login, nothing signed in',
        () async {
          auth.startEvent = const GatewayLinkFailed(GatewayLinkError.expired);
          await session().restore();
          expect(state().passwordRecovery, isFalse);
          expect(
            notice()!.message,
            'That link has expired or was already used — request a new one.',
          );
        },
      );

      test(
        'opened on another device or browser (no PKCE verifier): invalid',
        () async {
          auth.startEvent = const GatewayLinkFailed(GatewayLinkError.invalid);
          await session().restore();
          expect(
            notice()!.message,
            contains('open it on the device where you asked for it'),
          );
        },
      );

      test(
        'a recovery left open when the app closed is ended at the next start',
        () async {
          auth.startRecoverySession(email); // persisted, no link this time
          await session().restore();
          expect(state().passwordRecovery, isFalse);
          expect(auth.current, isNull);
        },
      );

      test('a backend session the app never took over (nothing remembered) is ended', () async {
        auth.current = auth.addUser('stray@example.com', oldPassword);
        auth.kind = AuthSessionKind.other;
        await session().restore();
        expect(auth.current, isNull);
        expect(state().isAuthenticated, isFalse);
      });

      test('a remembered sign-in still restores normally', () async {
        await session().signIn(identifier: email, password: oldPassword);
        final id = state().account!.id;
        await start(saved: {accountKey: id});
        await session().restore();
        expect(state().account!.id, id);
        expect(auth.current, isNotNull);
      });
    });

    test('the backend ends the session (e.g. a reset on another device): signed out, told why', () async {
      await session().restore();
      await session().signIn(identifier: email, password: oldPassword);
      auth.emit(const GatewaySessionExpired());
      await pumpEventQueue();
      expect(state().isAuthenticated, isFalse);
      expect(prefs.getString(accountKey), isNull);
      expect(
        notice()!.message,
        'Your session has ended — please log in again.',
      );
    });

    test('an expired session while signed out changes nothing', () async {
      await session().restore();
      auth.emit(const GatewaySessionExpired());
      await pumpEventQueue();
      expect(notice(), isNull);
    });
  });

  group('router guard', () {
    const recovering = SessionState(
      passwordRecovery: true,
      recoveryEmail: email,
    );
    String? r(String loc, SessionState s) =>
        resolveRedirect(location: loc, session: s, activeRole: null);

    test('a recovery session: Reset Password only', () {
      expect(r(Routes.resetPassword, recovering), isNull);
      for (final loc in [
        Routes.login,
        Routes.signup,
        Routes.createAccount,
        Routes.profileSetup,
        Routes.playerHome,
      ]) {
        expect(r(loc, recovering), Routes.resetPassword, reason: loc);
      }
      expect(
        resolveRedirect(
          location: Routes.login,
          session: recovering,
          activeRole: null,
          freshStart: true,
        ),
        Routes.resetPassword,
      );
    });

    test('no recovery session: Reset Password is never shown', () {
      expect(r(Routes.resetPassword, const SessionState()), Routes.login);
      expect(
        r(
          Routes.resetPassword,
          const SessionState(status: SessionStatus.signedIn),
        ),
        Routes.login,
      );
    });
  });

  group('screens (Supabase mode, email-codes switch on)', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      bool codes = true,
      bool restore = false,
    }) async {
      tester.view.physicalSize = const Size(375 * 3, 812 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          ...overrides(codes: codes),
          nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
          cityAreasProvider.overrideWith((ref) async => CityAreas.empty),
        ],
      );
      addTearDown(c.dispose);
      if (restore) await c.read(sessionProvider.notifier).restore();
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const CricEcoApp()),
      );
      await tester.pumpAndSettle();
      return c;
    }

    String loc(ProviderContainer c) =>
        c.read(routerProvider).state.uri.toString();

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> enter(WidgetTester tester, String key, String text) async {
      final f = find.byKey(Key(key));
      await tester.ensureVisible(f);
      await tester.enterText(f, text);
      await tester.pump();
    }

    Finder button(String label) => find.widgetWithText(CeButton, label);

    setUp(freshBackend);

    testWidgets(
      'switch off: no Forgot password in a Supabase build (as before)',
      (tester) async {
        await pump(tester, codes: false);
        expect(find.byKey(const Key('login.forgot')), findsNothing);
      },
    );

    testWidgets(
      'Forgot → email (validated) → code → Reset Password → Login → new password logs in',
      (tester) async {
        final c = await pump(tester);
        await enter(tester, 'login.email', email);
        await tap(tester, find.byKey(const Key('login.forgot')));
        expect(find.byKey(const Key('reset.step.request')), findsOneWidget);
        expect(
          find.text('Phone number or email'),
          findsNothing,
          reason: 'email only',
        );

        // Empty and invalid email.
        await enter(tester, 'reset.identifier', '');
        await tap(tester, button('Send Code'));
        expect(find.text('Email is required'), findsOneWidget);
        await enter(tester, 'reset.identifier', 'not-an-email');
        await tap(tester, button('Send Code'));
        expect(find.text('Enter a valid email address'), findsOneWidget);
        expect(auth.recoveryEmails, isEmpty);

        await enter(tester, 'reset.identifier', email);
        await tap(tester, button('Send Code'));
        expect(find.byKey(const Key('reset.step.code')), findsOneWidget);
        expect(
          find.textContaining(
            'If an account uses this email, we sent a 6-digit code to p•••@example.com',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('No SMS or email is sent'),
          findsNothing,
          reason: 'no demo code',
        );

        // A wrong code first.
        await enter(tester, 'reset.code', '000000');
        await tap(tester, button('Verify Code'));
        expect(find.text(invalidCode), findsOneWidget);
        expect(loc(c), Routes.login);

        await enter(tester, 'reset.code', auth.lastRecoveryCode(email)!);
        await tap(tester, button('Verify Code'));
        expect(loc(c), Routes.resetPassword);
        expect(
          find.byKey(const Key('reset.step.code')),
          findsNothing,
          reason: 'the sheet closed',
        );
        expect(find.byKey(const Key('resetPassword.form')), findsOneWidget);
        expect(find.textContaining('For p•••@example.com'), findsOneWidget);

        // Weak: the button stays off. Mismatch: the confirm field says so.
        await enter(tester, 'resetPassword.password', 'weak');
        expect(
          tester
              .widget<CeButton>(find.byKey(const Key('resetPassword.submit')))
              .onPressed,
          isNull,
        );
        await enter(tester, 'resetPassword.password', newPassword);
        await enter(tester, 'resetPassword.confirm', 'Wicket#2028');
        await tap(tester, find.byKey(const Key('resetPassword.submit')));
        expect(find.text('Passwords do not match'), findsOneWidget);
        expect(auth.calls, isNot(contains('updatePassword')));

        // The old password again: the backend refuses, the screen says why.
        await enter(tester, 'resetPassword.password', oldPassword);
        await enter(tester, 'resetPassword.confirm', oldPassword);
        await tap(tester, find.byKey(const Key('resetPassword.submit')));
        expect(
          find.text('Choose a password you haven’t used for this account'),
          findsOneWidget,
        );
        expect(loc(c), Routes.resetPassword);

        await enter(tester, 'resetPassword.password', newPassword);
        await enter(tester, 'resetPassword.confirm', newPassword);
        await tap(tester, find.byKey(const Key('resetPassword.submit')));
        expect(loc(c), Routes.login);
        expect(
          find.text('Password updated. Log in with your new password.'),
          findsOneWidget,
        );
        expect(auth.globalSignOuts, 1);

        // The old password is refused, the new one logs in.
        await enter(tester, 'login.email', email);
        await enter(tester, 'login.password', oldPassword);
        await tap(tester, button('Login'));
        expect(
          find.text('Incorrect email or password. Please try again.'),
          findsOneWidget,
        );
        await enter(tester, 'login.password', newPassword);
        await tap(tester, button('Login'));
        expect(c.read(sessionProvider).isAuthenticated, isTrue);
        expect(
          loc(c),
          Routes.profileSetup,
          reason: 'this account has not set up its profile yet',
        );
      },
    );

    testWidgets(
      'Forgot: rate limited and offline requests show the app\'s own messages',
      (tester) async {
        await pump(tester);
        await tap(tester, find.byKey(const Key('login.forgot')));
        await enter(tester, 'reset.identifier', email);
        auth.failNext = const GatewayNetworkException();
        await tap(tester, button('Send Code'));
        expect(
          find.text(
            "Couldn't reach the server — check your connection and try again",
          ),
          findsOneWidget,
        );
        await tap(tester, button('Send Code'));
        expect(find.byKey(const Key('reset.step.code')), findsOneWidget);
        await tap(tester, find.text('Resend code'));
        expect(
          find.text('Too many attempts — please wait a moment and try again'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a recovery link at app start opens Reset Password; nothing else is reachable',
      (tester) async {
        auth
          ..startRecoverySession(email)
          ..startEvent = const GatewayRecoveryStarted();
        final c = await pump(tester, restore: true);
        expect(loc(c), Routes.resetPassword);
        c.read(routerProvider).go(Routes.playerHome);
        await tester.pumpAndSettle();
        expect(loc(c), Routes.resetPassword);
        c.read(routerProvider).go(Routes.login);
        await tester.pumpAndSettle();
        expect(loc(c), Routes.resetPassword);
      },
    );

    testWidgets(
      'Reset Password → Cancel: back to Login, the recovery ended, the password unchanged',
      (tester) async {
        auth
          ..startRecoverySession(email)
          ..startEvent = const GatewayRecoveryStarted();
        final c = await pump(tester, restore: true);
        await tap(tester, find.byKey(const Key('resetPassword.cancel')));
        expect(loc(c), Routes.login);
        expect(c.read(sessionProvider).passwordRecovery, isFalse);
        expect(auth.current, isNull);
        expect(auth.passwordOf(email), oldPassword);
      },
    );

    testWidgets('an expired link at app start: Login explains it', (
      tester,
    ) async {
      auth.startEvent = const GatewayLinkFailed(GatewayLinkError.expired);
      final c = await pump(tester, restore: true);
      expect(loc(c), Routes.login);
      expect(
        find.text(
          'That link has expired or was already used — request a new one.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'the recovery expired before the update: back to Login with the reason',
      (tester) async {
        auth
          ..startRecoverySession(email)
          ..startEvent = const GatewayRecoveryStarted();
        final c = await pump(tester, restore: true);
        auth.current = null;
        await enter(tester, 'resetPassword.password', newPassword);
        await enter(tester, 'resetPassword.confirm', newPassword);
        await tap(tester, find.byKey(const Key('resetPassword.submit')));
        expect(loc(c), Routes.login);
        expect(
          find.text(
            'This reset has expired — request a new code and try again',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('Reset Password without a recovery session: Login', (
      tester,
    ) async {
      final c = await pump(tester);
      c.read(routerProvider).go(Routes.resetPassword);
      await tester.pumpAndSettle();
      expect(loc(c), Routes.login);
    });
  });
}
