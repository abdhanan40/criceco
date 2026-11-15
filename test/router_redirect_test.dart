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
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

const _account = UserAccount(id: 'a', fullName: 'Aman Ali', contactMethod: ContactMethod.phone, profileComplete: true);
const _player = PlayerProfile(
    role: PlayerRole.batsman, battingStyle: BattingStyle.rightHanded, bowlingStyle: BowlingStyle.rightArmOffSpin);

SessionState _signedIn({bool clubProfile = false, bool player = false}) => SessionState(
      status: SessionStatus.signedIn,
      account: _account.copyWith(hasClubOwnerProfile: clubProfile, playerProfile: player ? _player : null),
    );

String? _r(String loc, SessionState s, UserRole? role) => resolveRedirect(location: loc, session: s, activeRole: role);

void main() {
  group('signed out', () {
    const out = SessionState();
    test('protected routes go to the Auth page (Login)', () {
      expect(_r(Routes.playerHome, out, null), Routes.login);
      expect(_r(Routes.clubHome, out, null), Routes.login);
      expect(_r(Routes.settings, out, null), Routes.login);
      expect(_r(Routes.roleSelection, out, null), Routes.login);
      expect(_r(Routes.profileSetup, out, null), Routes.login);
    });
    test('Login / Sign Up / Create Account allowed', () {
      expect(_r(Routes.login, out, null), isNull);
      expect(_r(Routes.signup, out, null), isNull);
      expect(_r(Routes.createAccount, out, null), isNull);
    });
  });

  test('incomplete common profile forces User Profile Setup (auth screens stay reachable for Back)', () {
    const s = SessionState(status: SessionStatus.onboarding, account: _account);
    expect(_r(Routes.playerHome, s, null), Routes.profileSetup);
    expect(_r(Routes.roleSelection, s, null), Routes.profileSetup);
    expect(_r(Routes.clubSetup, s, null), Routes.profileSetup);
    expect(_r(Routes.roleDetails, s, null), Routes.profileSetup);
    expect(_r(Routes.profileSetup, s, null), isNull);
    expect(_r(Routes.createAccount, s, null), isNull);
    expect(_r(Routes.signup, s, null), isNull);
  });

  test('profile complete: auth/profile screens go to the role home, else Role Selection', () {
    expect(_r(Routes.login, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.profileSetup, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.login, _signedIn(), UserRole.player), Routes.playerHome);
    expect(_r(Routes.login, _signedIn(clubProfile: true), UserRole.clubOwner), Routes.clubHome);
  });

  test('role routes need a role; Role Selection and Club Setup are open to a signed-in user', () {
    expect(_r(Routes.playerHome, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.clubHome, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.roleSelection, _signedIn(), null), isNull);
    expect(_r(Routes.clubSetup, _signedIn(), null), isNull);
  });

  group('returning users: the single completed role is entered directly', () {
    test('Player set up only → Player', () => expect(inferEntryRole(_signedIn(player: true)), UserRole.player));
    test('Club Owner set up only → Club Owner',
        () => expect(inferEntryRole(_signedIn(clubProfile: true)), UserRole.clubOwner));
    test('both or neither → the user chooses on Role Selection', () {
      expect(inferEntryRole(_signedIn(player: true, clubProfile: true)), isNull);
      expect(inferEntryRole(_signedIn()), isNull);
    });
    test('never before the common profile is complete', () {
      final s = SessionState(status: SessionStatus.onboarding, account: _account.copyWith(playerProfile: _player));
      expect(inferEntryRole(s), isNull);
    });
    test('a Player profile needs role + both styles', () {
      expect(const PlayerProfile(role: PlayerRole.bowler).isComplete, isFalse);
      expect(_player.isComplete, isTrue);
    });
  });

  group('navigation never changes the role (role-leak guard)', () {
    test('player cannot enter club routes', () {
      expect(_r(Routes.teams, _signedIn(clubProfile: true), UserRole.player), Routes.playerHome);
      expect(_r(Routes.matchManagement(MatchTab.scheduled), _signedIn(clubProfile: true), UserRole.player),
          Routes.playerHome);
    });
    test('club owner cannot enter player routes', () {
      expect(_r(Routes.myMatches, _signedIn(clubProfile: true), UserRole.clubOwner), Routes.clubHome);
    });
    test('club routes without a Club Owner profile go to Club Setup Details', () {
      expect(_r(Routes.clubHome, _signedIn(), UserRole.clubOwner), Routes.clubSetup);
    });
    test('correct role passes; shared routes pass for any role', () {
      expect(_r(Routes.playerMatchDetails('pm_1'), _signedIn(), UserRole.player), isNull);
      expect(_r(Routes.tournamentHub, _signedIn(clubProfile: true), UserRole.clubOwner), isNull);
      expect(_r(Routes.notifications, _signedIn(), UserRole.player), isNull);
      expect(_r(Routes.settings, _signedIn(clubProfile: true), UserRole.clubOwner), isNull);
    });
  });

  // AUTH-02G: the first navigation after a cold start / browser reload.
  group('fresh start (cold start or browser reload)', () {
    String? fresh(String loc, SessionState s, UserRole? role) =>
        resolveRedirect(location: loc, session: s, activeRole: role, freshStart: true);
    const onboarding = SessionState(status: SessionStatus.onboarding, account: _account);

    test('onboarding: arriving fresh on an auth screen → User Profile Setup', () {
      expect(fresh(Routes.createAccount, onboarding, null), Routes.profileSetup);
      expect(fresh(Routes.signup, onboarding, null), Routes.profileSetup);
      expect(fresh(Routes.login, onboarding, null), Routes.profileSetup);
      expect(fresh(Routes.profileSetup, onboarding, null), isNull, reason: 'already there');
      expect(fresh(Routes.playerHome, onboarding, null), Routes.profileSetup);
    });

    test('onboarding, in-app navigation: auth screens stay reachable (Back from Profile Setup)', () {
      expect(_r(Routes.createAccount, onboarding, null), isNull);
      expect(_r(Routes.signup, onboarding, null), isNull);
      expect(_r(Routes.login, onboarding, null), isNull);
    });

    test('profile complete: unchanged — the role home, else Role Selection; never Profile Setup', () {
      expect(fresh(Routes.createAccount, _signedIn(player: true), UserRole.player), Routes.playerHome);
      expect(fresh(Routes.login, _signedIn(clubProfile: true), UserRole.clubOwner), Routes.clubHome);
      expect(fresh(Routes.createAccount, _signedIn(), null), Routes.roleSelection);
      expect(fresh(Routes.profileSetup, _signedIn(player: true), UserRole.player), Routes.playerHome);
      expect(fresh(Routes.playerHome, _signedIn(player: true), UserRole.player), isNull);
    });

    test('signed out: unchanged — the auth screens allowed, everything else → Login', () {
      const out = SessionState();
      expect(fresh(Routes.createAccount, out, null), isNull);
      expect(fresh(Routes.signup, out, null), isNull);
      expect(fresh(Routes.login, out, null), isNull);
      expect(fresh(Routes.profileSetup, out, null), Routes.login);
      expect(fresh(Routes.playerHome, out, null), Routes.login);
    });
  });

  group('fresh start in the app (the router)', () {
    final supabase = BackendConfig.parse(
      backend: 'supabase',
      supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
      supabasePublishableKey: 'sb_publishable_test_0000000000000000',
    );

    /// The app started (or reloaded) at [url], after [SessionController.restore]
    /// as `main()` does. [onboarding]: a Supabase user whose Profile Setup isn't
    /// done, with the SDK's stored session; otherwise [saved] decides.
    Future<ProviderContainer> start(WidgetTester tester, String url,
        {bool onboarding = false, Map<String, Object> saved = const {}}) async {
      tester.platformDispatcher.defaultRouteNameTestValue = url; // the address bar
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      final db = FakeDb();
      final auth = FakeAuth(db);
      final user = auth.addUser('new@example.com', 'Cricket@123', metadata: {'full_name': 'New User'});
      if (onboarding) auth.current = user; // the SDK kept the session across the reload
      SharedPreferences.setMockInitialValues({
        if (onboarding) 'criceco.session.accountId': user.id,
        ...saved,
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
        cityAreasProvider.overrideWith((ref) async => CityAreas.empty),
        if (onboarding) ...[
          backendConfigProvider.overrideWithValue(supabase),
          authGatewayProvider.overrideWithValue(auth),
          profileGatewayProvider.overrideWithValue(db),
          clubGatewayProvider.overrideWithValue(FakeClubDb(db)),
          locationGatewayProvider.overrideWithValue(FakeLocationGateway()),
        ],
      ]);
      addTearDown(c.dispose);
      await c.read(sessionProvider.notifier).restore();
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
      await tester.pumpAndSettle();
      return c;
    }

    String loc(ProviderContainer c) => c.read(routerProvider).state.uri.path;

    testWidgets('onboarding user reloading on Create Account → User Profile Setup', (tester) async {
      final c = await start(tester, Routes.createAccount, onboarding: true);
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      expect(loc(c), Routes.profileSetup);
      expect(find.text('Join Criceco'), findsNothing);
    });

    testWidgets('onboarding user reloading on Login → User Profile Setup', (tester) async {
      final c = await start(tester, Routes.login, onboarding: true);
      expect(loc(c), Routes.profileSetup);
    });

    testWidgets('in the app: Create Account → Profile Setup → Back → Create Account (unchanged)', (tester) async {
      final c = await start(tester, Routes.createAccount); // signed out
      expect(loc(c), Routes.createAccount);
      await c.read(sessionProvider.notifier).signUp(
          fullName: 'Aman Ullah', method: ContactMethod.phone, identifier: '03339876543', password: 'Cricket@123');
      await tester.pumpAndSettle();
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      expect(loc(c), Routes.createAccount, reason: 'a session change is not a fresh start');
      unawaited(c.read(routerProvider).push(Routes.completeProfile));
      await tester.pumpAndSettle();
      expect(loc(c), Routes.profileSetup);
      c.read(routerProvider).pop();
      await tester.pumpAndSettle();
      expect(loc(c), Routes.createAccount);
    });

    testWidgets('completed profile reloading on Create Account → its role home', (tester) async {
      final c = await start(tester, Routes.createAccount,
          saved: {'criceco.session.accountId': 'acc_aman', 'criceco.activeRole': 'player'});
      expect(c.read(sessionProvider).status, SessionStatus.signedIn);
      expect(loc(c), Routes.playerHome);
    });

    testWidgets('signed out reloading: Create Account stays; a protected page → Login', (tester) async {
      var c = await start(tester, Routes.createAccount);
      expect(loc(c), Routes.createAccount);
      await tester.pumpWidget(const SizedBox()); // the next app run
      c = await start(tester, Routes.playerHome);
      expect(loc(c), Routes.login);
    });
  });
}
