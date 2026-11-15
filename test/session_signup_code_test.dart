import 'package:clock/clock.dart';
import 'package:criceco/app/config/auth_features.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// AUTH-02B: [SessionController.verifySignUpCode] / [SessionController.resendSignUpCode]
/// — the session after a sign-up code, its persistence, restore and logout,
/// in Supabase mode (fake gateways) and in the demo (the email-codes switch).
void main() {
  const accountKey = 'criceco.session.accountId';
  const email = 'player@example.com';
  const password = 'Cricket@2026';
  final today = DateTime(2026, 11, 15, 10);

  group('Supabase mode', () {
    late FakeDb db;
    late FakeAuth auth;
    late SharedPreferences prefs;
    late ProviderContainer c;
    late DateTime t;

    /// A (re)started app: [db] / [auth] are the server and the SDK's stored
    /// session, so they outlive a restart; [saved] is what the device kept.
    Future<void> start({Map<String, Object> saved = const {}}) async {
      SharedPreferences.setMockInitialValues(saved);
      prefs = await SharedPreferences.getInstance();
      c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          clockProvider.overrideWith((ref) => Clock(() => t)),
          backendConfigProvider.overrideWithValue(
            BackendConfig.parse(
              backend: 'supabase',
              supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
              supabasePublishableKey: 'sb_publishable_test_0000000000000000',
            ),
          ),
          authGatewayProvider.overrideWithValue(auth),
          profileGatewayProvider.overrideWithValue(db),
          clubGatewayProvider.overrideWithValue(db.clubDb ?? FakeClubDb(db)),
        ],
      );
      addTearDown(c.dispose);
    }

    Map<String, Object> kept() => {
      for (final k in prefs.getKeys()) k: prefs.get(k)!,
    };

    SessionController session() => c.read(sessionProvider.notifier);
    SessionState state() => c.read(sessionProvider);

    /// Sign-up with email confirmation on: no session, a code is "emailed".
    Future<void> signUpPending() async {
      await expectLater(
        session().signUp(
          fullName: 'Hamza Sheikh',
          method: ContactMethod.email,
          identifier: email,
          password: password,
        ),
        throwsA(isA<EmailConfirmationRequiredException>()),
      );
    }

    setUp(() async {
      t = today;
      db = FakeDb();
      auth = FakeAuth(db)
        ..requireConfirmation = true
        ..now = () => t;
      await start();
    });

    test('before the code: signed out, nothing remembered', () async {
      await signUpPending();
      expect(state().isAuthenticated, isFalse);
      expect(state().account, isNull);
      expect(prefs.getString(accountKey), isNull);
      expect(auth.current, isNull);
    });

    test(
      'the right code: onboarding with the new account, its id '
      'remembered; no role yet (Role Selection after Profile Setup)',
      () async {
        await signUpPending();
        await session().verifySignUpCode(
          email: email,
          code: auth.lastCode(email)!,
        );
        final s = state();
        expect(s.status, SessionStatus.onboarding);
        expect(s.account!.email, email);
        expect(
          s.account!.fullName,
          'Hamza Sheikh',
          reason: 'the sign-up name (Auth metadata)',
        );
        expect(s.account!.profileComplete, isFalse);
        expect(prefs.getString(accountKey), s.account!.id);
        expect(c.read(activeRoleProvider), isNull);
      },
    );

    test('a wrong code: typed error, still signed out, nothing remembered; '
        'the right code then works', () async {
      await signUpPending();
      await expectLater(
        session().verifySignUpCode(email: email, code: '000000'),
        throwsA(isA<InvalidVerificationCodeException>()),
      );
      expect(state().isAuthenticated, isFalse);
      expect(prefs.getString(accountKey), isNull);
      await session().verifySignUpCode(
        email: email,
        code: auth.lastCode(email)!,
      );
      expect(state().status, SessionStatus.onboarding);
    });

    test('an expired code (900 s): typed error, still signed out', () async {
      await signUpPending();
      final code = auth.lastCode(email)!;
      t = today.add(const Duration(seconds: 900));
      await expectLater(
        session().verifySignUpCode(email: email, code: code),
        throwsA(isA<InvalidVerificationCodeException>()),
      );
      expect(state().isAuthenticated, isFalse);
      expect(prefs.getString(accountKey), isNull);
    });

    test('a code works once: after logout it no longer signs in', () async {
      await signUpPending();
      final code = auth.lastCode(email)!;
      await session().verifySignUpCode(email: email, code: code);
      session().logout();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        session().verifySignUpCode(email: email, code: code),
        throwsA(isA<InvalidVerificationCodeException>()),
      );
      expect(state().isAuthenticated, isFalse);
    });

    test('a failed check never touches a session already there', () async {
      db.completeProfile(auth.addUser('owner@example.com', password).id);
      await session().signIn(
        identifier: 'owner@example.com',
        password: password,
      );
      final before = state();
      final keptBefore = kept();
      expect(before.status, SessionStatus.signedIn);

      await expectLater(
        session().verifySignUpCode(email: email, code: '000000'),
        throwsA(isA<InvalidVerificationCodeException>()),
      );
      expect(state().status, before.status);
      expect(state().account!.id, before.account!.id);
      expect(kept(), keptBefore);
    });

    test(
      'offline: typed error, nothing changes, the code still works later',
      () async {
        await signUpPending();
        auth.failNext = const GatewayNetworkException();
        await expectLater(
          session().verifySignUpCode(email: email, code: auth.lastCode(email)!),
          throwsA(isA<BackendUnavailableException>()),
        );
        expect(state().isAuthenticated, isFalse);
        await session().verifySignUpCode(
          email: email,
          code: auth.lastCode(email)!,
        );
        expect(state().status, SessionStatus.onboarding);
      },
    );

    test('resend too soon: typed error; the session and the code are '
        'unchanged', () async {
      await signUpPending();
      final code = auth.lastCode(email);
      await expectLater(
        session().resendSignUpCode(email),
        throwsA(isA<TooManyRequestsException>()),
      );
      expect(auth.lastCode(email), code);
      expect(state().isAuthenticated, isFalse);
    });

    test('resend later: a masked ticket and a new code; the old one stops '
        'working; still signed out until verified', () async {
      await signUpPending();
      final first = auth.lastCode(email)!;
      t = today.add(const Duration(seconds: 61));
      final ticket = await session().resendSignUpCode(email);
      expect(ticket.destination, 'p•••@example.com');
      expect(ticket.demoCode, isNull);
      expect(state().isAuthenticated, isFalse);
      await expectLater(
        session().verifySignUpCode(email: email, code: first),
        throwsA(isA<InvalidVerificationCodeException>()),
      );
      await session().verifySignUpCode(
        email: email,
        code: auth.lastCode(email)!,
      );
      expect(state().status, SessionStatus.onboarding);
    });

    test('restart after verifying: restore brings the same account back '
        '(still onboarding)', () async {
      await signUpPending();
      await session().verifySignUpCode(
        email: email,
        code: auth.lastCode(email)!,
      );
      final id = state().account!.id;
      final saved = kept();

      await start(saved: saved); // a new app run; the SDK kept its session
      expect(state().isAuthenticated, isFalse);
      await session().restore();
      expect(state().status, SessionStatus.onboarding);
      expect(state().account!.id, id);
    });

    test('logout after verifying: signed out locally and on the backend; a '
        'restart stays signed out', () async {
      await signUpPending();
      await session().verifySignUpCode(
        email: email,
        code: auth.lastCode(email)!,
      );
      session().logout();
      await Future<void>.delayed(Duration.zero);
      expect(state().isAuthenticated, isFalse);
      expect(prefs.getString(accountKey), isNull);
      expect(auth.current, isNull);

      await start(saved: kept());
      await session().restore();
      expect(state().isAuthenticated, isFalse);
    });

    test(
      'after verifying, Profile Setup completes as for any sign-up',
      () async {
        await signUpPending();
        await session().verifySignUpCode(
          email: email,
          code: auth.lastCode(email)!,
        );
        await session().completeProfile(
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
        expect(state().status, SessionStatus.signedIn);
        expect(
          c.read(activeRoleProvider),
          isNull,
          reason: 'Role Selection next',
        );
      },
    );

    test(
      'regression: confirmation off → sign-up signs in directly (no code)',
      () async {
        auth.requireConfirmation = false;
        await session().signUp(
          fullName: 'Hamza Sheikh',
          method: ContactMethod.email,
          identifier: email,
          password: password,
        );
        expect(state().status, SessionStatus.onboarding);
        expect(auth.lastCode(email), isNull);
        expect(prefs.getString(accountKey), state().account!.id);
      },
    );
  });

  group('demo mode (email-codes switch)', () {
    late SharedPreferences prefs;
    late ProviderContainer c;
    late DateTime t;

    Future<void> start({required bool codes}) async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          clockProvider.overrideWith((ref) => Clock(() => t)),
          emailCodesEnabledProvider.overrideWithValue(codes),
        ],
      );
      addTearDown(c.dispose);
    }

    SessionController session() => c.read(sessionProvider.notifier);

    Future<String> signUpForCode() async {
      try {
        await session().signUp(
          fullName: 'New User',
          method: ContactMethod.email,
          identifier: 'new.user@example.com',
          password: password,
        );
      } on EmailConfirmationRequiredException catch (e) {
        return e.demoCode!;
      }
      fail('the switch is on: the sign-up must wait for its code');
    }

    setUp(() => t = today);

    test(
      'switch OFF (default): sign-up signs in directly, as before',
      () async {
        await start(codes: false);
        await session().signUp(
          fullName: 'New User',
          method: ContactMethod.email,
          identifier: 'new.user@example.com',
          password: password,
        );
        expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      },
    );

    test('switch ON: the demo code signs in (onboarding, id remembered); a '
        'wrong one is refused first', () async {
      await start(codes: true);
      final code = await signUpForCode();
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      await expectLater(
        session().verifySignUpCode(
          email: 'new.user@example.com',
          code: '000000',
        ),
        throwsA(isA<InvalidVerificationCodeException>()),
      );
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      await session().verifySignUpCode(
        email: 'new.user@example.com',
        code: code,
      );
      final s = c.read(sessionProvider);
      expect(s.status, SessionStatus.onboarding);
      expect(
        (s.account!.fullName, s.account!.email),
        ('New User', 'new.user@example.com'),
      );
      expect(prefs.getString(accountKey), s.account!.id);
    });

    test(
      'switch ON: resend uses the session clock (60 s), a new demo code',
      () async {
        await start(codes: true);
        final first = await signUpForCode();
        await expectLater(
          session().resendSignUpCode('new.user@example.com'),
          throwsA(isA<TooManyRequestsException>()),
        );
        t = today.add(InMemoryAccountRepository.signUpCodeResendInterval);
        final ticket = await session().resendSignUpCode('new.user@example.com');
        expect(ticket.demoCode, isNot(first));
        await session().verifySignUpCode(
          email: 'new.user@example.com',
          code: ticket.demoCode!,
        );
        expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      },
    );

    test('switch ON: an expired demo code (900 s) is refused', () async {
      await start(codes: true);
      final code = await signUpForCode();
      t = today.add(InMemoryAccountRepository.signUpCodeLifetime);
      await expectLater(
        session().verifySignUpCode(email: 'new.user@example.com', code: code),
        throwsA(isA<InvalidVerificationCodeException>()),
      );
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
    });

    test('switch ON: phone sign-ups still sign in directly', () async {
      await start(codes: true);
      await session().signUp(
        fullName: 'Phone User',
        method: ContactMethod.phone,
        identifier: '03001234567',
        password: password,
      );
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
    });
  });
}
