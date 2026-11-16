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
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/auth/widgets/auth_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// AUTH-05: Google sign-in through Supabase's OAuth redirect (fake
/// gateways): the button and its switch, the browser hand-off, the return
/// (at app start on the web, as an event on Android), new and existing
/// users, failures, restore and logout. The demo's simulated Google sign-in
/// is covered at the end.
void main() {
  const accountKey = 'criceco.session.accountId';
  const email = 'player@gmail.com';
  final supabase = BackendConfig.parse(
    backend: 'supabase',
    supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
    supabasePublishableKey: 'sb_publishable_test_0000000000000000',
  );

  late FakeDb db;
  late FakeAuth auth;
  late SharedPreferences prefs;

  List<Override> overrides({bool google = true, bool memory = false}) => [
    sharedPreferencesProvider.overrideWithValue(prefs),
    clockProvider.overrideWith(
      (ref) => Clock(() => DateTime(2026, 11, 15, 10)),
    ),
    googleSignInEnabledProvider.overrideWithValue(google),
    if (!memory) ...[
      backendConfigProvider.overrideWithValue(supabase),
      authGatewayProvider.overrideWithValue(auth),
      profileGatewayProvider.overrideWithValue(db),
      clubGatewayProvider.overrideWithValue(FakeClubDb(db)),
      locationGatewayProvider.overrideWithValue(FakeLocationGateway()),
    ],
  ];

  setUp(() {
    db = FakeDb();
    auth = FakeAuth(db);
  });

  group('session (Supabase mode)', () {
    late ProviderContainer c;

    Future<void> start({Map<String, Object> saved = const {}}) async {
      SharedPreferences.setMockInitialValues(saved);
      prefs = await SharedPreferences.getInstance();
      c = ProviderContainer(overrides: overrides());
      addTearDown(c.dispose);
    }

    SessionController session() => c.read(sessionProvider.notifier);
    SessionState state() => c.read(sessionProvider);

    setUp(() => start());

    test('Continue with Google opens the browser, back to the app\'s callback; nothing signed in yet', () async {
      expect(
        await session().signInWithGoogle(),
        isFalse,
        reason: 'continues in the browser',
      );
      expect(auth.calls, contains('startGoogleSignIn'));
      expect(auth.lastRedirect, kNativeAuthCallbackUrl);
      expect(state().isAuthenticated, isFalse);
      expect(prefs.getString(accountKey), isNull);
    });

    test(
      'the browser can\'t be opened: GoogleSignInUnavailableException',
      () async {
        auth.googleOpens = false;
        await expectLater(
          session().signInWithGoogle(),
          throwsA(isA<GoogleSignInUnavailableException>()),
        );
        expect(state().isAuthenticated, isFalse);
      },
    );

    test('offline: BackendUnavailableException', () async {
      auth.failNext = const GatewayNetworkException();
      await expectLater(
        session().signInWithGoogle(),
        throwsA(isA<BackendUnavailableException>()),
      );
    });

    test('a new user returns at app start (web): onboarding, the Google name, the id remembered', () async {
      final user = auth.googleReturns(
        email,
        metadata: const {'full_name': 'Aman Ullah'},
      );
      auth.startEvent = GatewayOAuthSignedIn(user);
      await session().restore();
      expect(
        state().status,
        SessionStatus.onboarding,
        reason: 'User Profile Setup next',
      );
      expect(state().account!.email, email);
      expect(state().account!.fullName, 'Aman Ullah');
      expect(prefs.getString(accountKey), user.id);
      expect(db.profiles.keys, [
        user.id,
      ], reason: 'one profiles row (the sign-up trigger)');
    });

    test('an existing user with a complete profile returns: signed in, same account, no new profile', () async {
      final existing = auth.addUser(email, 'Cricket@2026');
      db.completeProfile(existing.id);
      final user = auth.googleReturns(email);
      expect(
        user.id,
        existing.id,
        reason: 'Supabase links Google to the same verified email',
      );
      auth.startEvent = GatewayOAuthSignedIn(user);
      await session().restore();
      expect(state().status, SessionStatus.signedIn);
      expect(state().account!.id, existing.id);
      expect(db.profiles.length, 1, reason: 'no duplicate profile');
    });

    test(
      'Google returns while the app runs (Android): signed in from the event',
      () async {
        await session().restore();
        expect(await session().signInWithGoogle(), isFalse);
        final user = auth.googleReturns(email);
        auth.emit(GatewayOAuthSignedIn(user));
        await pumpEventQueue();
        expect(state().status, SessionStatus.onboarding);
        expect(state().account!.id, user.id);
        expect(prefs.getString(accountKey), user.id);
      },
    );

    test('the same return twice (a replayed event) signs in once', () async {
      await session().restore();
      final user = auth.googleReturns(email);
      auth
        ..emit(GatewayOAuthSignedIn(user))
        ..emit(GatewayOAuthSignedIn(user));
      await pumpEventQueue();
      expect(state().account!.id, user.id);
      expect(
        db.calls.where((c) => c == 'fetchAccountRows').length,
        2,
        reason: 'read for each event, but the session is set once',
      );
    });

    for (final (reason, message) in [
      (GatewayLinkError.cancelled, 'Google sign-in was cancelled.'),
      (
        GatewayLinkError.failed,
        'Couldn’t finish signing in — please try again.',
      ),
      (
        GatewayLinkError.invalid,
        'That link can’t be used here — open it on the device where you asked for it, or request a new one.',
      ),
    ]) {
      test(
        'a failed return at start ($reason): nothing signed in, Login explains',
        () async {
          auth.startEvent = GatewayLinkFailed(reason);
          await session().restore();
          expect(state().isAuthenticated, isFalse);
          expect(c.read(authNoticeProvider)!.message, message);
        },
      );
    }

    test('a failed return while the app runs (Android cancel with an error): the same message', () async {
      await session().restore();
      auth.emit(const GatewayLinkFailed(GatewayLinkError.cancelled));
      await pumpEventQueue();
      expect(
        c.read(authNoticeProvider)!.message,
        'Google sign-in was cancelled.',
      );
    });

    test('signed in with Google but the account can\'t be read: the half-started session ends', () async {
      final user = auth.googleReturns(email);
      auth.startEvent = GatewayOAuthSignedIn(user);
      db.failNext = const GatewayNetworkException();
      await session().restore();
      expect(state().isAuthenticated, isFalse);
      expect(auth.current, isNull, reason: 'nothing stays signed in unseen');
      expect(
        c.read(authNoticeProvider)!.message,
        'Couldn’t finish signing in — please try again.',
      );
    });

    test(
      'restart after a Google sign-in: restored from the remembered account',
      () async {
        final user = auth.googleReturns(email);
        auth.startEvent = GatewayOAuthSignedIn(user);
        await session().restore();
        await start(saved: {accountKey: user.id}); // the SDK kept its session
        await session().restore();
        expect(state().account!.id, user.id);
        expect(auth.current, isNotNull);
      },
    );

    test('logout ends the Google session; Google again signs in to the same account', () async {
      final user = auth.googleReturns(email);
      auth.startEvent = GatewayOAuthSignedIn(user);
      await session().restore();
      session().logout();
      await pumpEventQueue();
      expect(state().isAuthenticated, isFalse);
      expect(auth.current, isNull);
      expect(prefs.getString(accountKey), isNull);
      // Re-login.
      expect(await session().signInWithGoogle(), isFalse);
      auth.emit(GatewayOAuthSignedIn(auth.googleReturns(email)));
      await pumpEventQueue();
      expect(state().account!.id, user.id);
      expect(db.profiles.length, 1);
    });

    test('the session expires later: signed out, told why', () async {
      auth.startEvent = GatewayOAuthSignedIn(auth.googleReturns(email));
      await session().restore();
      auth.emit(const GatewaySessionExpired());
      await pumpEventQueue();
      expect(state().isAuthenticated, isFalse);
      expect(
        c.read(authNoticeProvider)!.message,
        'Your session has ended — please log in again.',
      );
    });
  });

  group('screens', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      bool google = true,
      bool memory = false,
      bool restore = false,
    }) async {
      tester.view.physicalSize = const Size(375 * 3, 812 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          ...overrides(google: google, memory: memory),
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

    testWidgets(
      'Supabase build, Google switch off: no Google button on Login or Sign Up',
      (tester) async {
        final c = await pump(tester, google: false);
        expect(find.byType(GoogleButton), findsNothing);
        c.read(routerProvider).go(Routes.signup);
        await tester.pumpAndSettle();
        expect(find.byType(GoogleButton), findsNothing);
      },
    );

    testWidgets(
      'switch on: Google on Login and Sign Up; tapping opens the browser',
      (tester) async {
        final c = await pump(tester);
        expect(find.byType(GoogleButton), findsOneWidget);
        await tap(tester, find.byType(GoogleButton));
        expect(auth.calls, contains('startGoogleSignIn'));
        expect(loc(c), Routes.login, reason: 'waits for the browser');
        c.read(routerProvider).go(Routes.signup);
        await tester.pumpAndSettle();
        expect(find.byType(GoogleButton), findsOneWidget);
      },
    );

    testWidgets('the browser can\'t be opened: Login says so', (tester) async {
      await pump(tester);
      auth.googleOpens = false;
      await tap(tester, find.byType(GoogleButton));
      expect(
        find.text('Couldn’t open Google sign-in — please try again'),
        findsOneWidget,
      );
    });

    testWidgets(
      'Android: a new user returns while Login is open → User Profile Setup',
      (tester) async {
        final c = await pump(tester, restore: true);
        await tap(tester, find.byType(GoogleButton));
        auth.emit(GatewayOAuthSignedIn(auth.googleReturns(email)));
        await tester.pumpAndSettle();
        expect(loc(c), Routes.profileSetup);
      },
    );

    testWidgets(
      'Android: a new user returns while Sign Up is open → User Profile Setup',
      (tester) async {
        final c = await pump(tester, restore: true);
        c.read(routerProvider).go(Routes.signup);
        await tester.pumpAndSettle();
        await tap(tester, find.byType(GoogleButton));
        auth.emit(GatewayOAuthSignedIn(auth.googleReturns(email)));
        await tester.pumpAndSettle();
        expect(loc(c), Routes.profileSetup);
      },
    );

    // Fix B: a cancelled or failed Google sign-in that comes back while Sign
    // Up is open (Android) is shown there, once — not held for Login.
    for (final (reason, message) in [
      (GatewayLinkError.cancelled, 'Google sign-in was cancelled.'),
      (
        GatewayLinkError.failed,
        'Couldn’t finish signing in — please try again.',
      ),
    ]) {
      testWidgets(
        'Android: Google $reason while Sign Up is open → the message on Sign Up',
        (tester) async {
          final c = await pump(tester, restore: true);
          c.read(routerProvider).go(Routes.signup);
          await tester.pumpAndSettle();
          await tap(tester, find.byType(GoogleButton));
          auth.emit(GatewayLinkFailed(reason));
          await tester.pumpAndSettle(); // the event, then the toast
          expect(find.text(message), findsOneWidget);
          expect(loc(c), Routes.signup, reason: 'stays on Sign Up');
          expect(c.read(sessionProvider).isAuthenticated, isFalse);
          expect(c.read(authNoticeProvider), isNull, reason: 'shown once');

          // Not shown again on Login.
          await tester.pumpAndSettle(const Duration(seconds: 5));
          c.read(routerProvider).go(Routes.login);
          await tester.pumpAndSettle();
          expect(find.text(message), findsNothing);

          // Google still works afterwards.
          c.read(routerProvider).go(Routes.signup);
          await tester.pumpAndSettle();
          await tap(tester, find.byType(GoogleButton));
          auth.emit(GatewayOAuthSignedIn(auth.googleReturns(email)));
          await tester.pumpAndSettle();
          expect(loc(c), Routes.profileSetup);
        },
      );
    }

    testWidgets(
      'web: a new user returns at start → User Profile Setup (the fresh-start rule)',
      (tester) async {
        auth.startEvent = GatewayOAuthSignedIn(auth.googleReturns(email));
        final c = await pump(tester, restore: true);
        expect(loc(c), Routes.profileSetup);
      },
    );

    testWidgets(
      'web: a returning user with a complete profile → Role Selection (no role saved yet)',
      (tester) async {
        final existing = auth.addUser(email, 'Cricket@2026');
        db.completeProfile(existing.id);
        auth.startEvent = GatewayOAuthSignedIn(auth.googleReturns(email));
        final c = await pump(tester, restore: true);
        expect(loc(c), Routes.roleSelection);
      },
    );

    testWidgets('web: cancelled at Google → Login with the message', (
      tester,
    ) async {
      auth.startEvent = const GatewayLinkFailed(GatewayLinkError.cancelled);
      final c = await pump(tester, restore: true);
      expect(loc(c), Routes.login);
      expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    });

    testWidgets(
      'demo: Google on Login signs in at once → User Profile Setup (no browser)',
      (tester) async {
        final c = await pump(tester, memory: true);
        await tap(tester, find.byType(GoogleButton));
        expect(c.read(sessionProvider).status, SessionStatus.onboarding);
        expect(loc(c), Routes.profileSetup);
      },
    );
  });
}
