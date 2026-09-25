// Auth → User Profile Setup → Role Selection → Player (expands in place) →
// Player Dashboard, or → Club Owner → Club Setup Details → Club Dashboard.
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/features/auth/onboarding_controller.dart';
import 'package:criceco/features/auth/role_selection_screen.dart';
import 'package:criceco/features/auth/widgets/auth_widgets.dart';
import 'package:criceco/shared/widgets/ce_brand_logo.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RejectingAccounts implements AccountRepository {
  _RejectingAccounts(this.inner);
  final AccountRepository inner;
  @override
  Future<UserAccount?> signIn({required String identifier, required String password}) async => null;
  @override
  Future<UserAccount> signUp({required String fullName, required ContactMethod method, required String identifier, required String password}) =>
      inner.signUp(fullName: fullName, method: method, identifier: identifier, password: password);
  @override
  Future<UserAccount?> byId(String accountId) => inner.byId(accountId);
  @override
  Future<UserAccount> update(UserAccount account) => inner.update(account);
  @override
  Future<bool> changePassword(String accountId, {required String current, required String next}) =>
      inner.changePassword(accountId, current: current, next: next);
}

Future<ProviderContainer> _pump(WidgetTester tester, {double width = 375, List<dynamic> overrides = const []}) async {
  tester.view.physicalSize = Size(width * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ...overrides.cast(),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

/// Pumps for up to ~1.5 s. Unlike pumpAndSettle this also works on screens
/// with intentionally endless animations (Waiting for Approval pulse).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await _settle(tester);
  await tester.tap(f);
  await _settle(tester);
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

Finder _button(String label) => label == 'Continue with Google'
    ? find.byType(GoogleButton)
    : find.widgetWithText(CeButton, label);

/// Demo credentials (the seed account is a returning, fully set-up Player).
Future<void> _login(WidgetTester tester, {String password = 'secret1'}) async {
  await _enter(tester, 'login.phone', '0312-9020000');
  await _enter(tester, 'login.password', password);
  await _tap(tester, _button('Login'));
}

/// A brand-new account (Sign Up done) sitting on User Profile Setup.
Future<ProviderContainer> _newUser(WidgetTester tester, {double width = 375}) async {
  final c = await _pump(tester, width: width);
  await c.read(sessionProvider.notifier).signUp(
      fullName: '', method: ContactMethod.phone, identifier: '03339876543', password: 'secret1');
  c.read(routerProvider).go(Routes.profileSetup);
  await tester.pumpAndSettle();
  return c;
}

/// A new account with the common profile done, on Role Selection.
Future<ProviderContainer> _profiled(WidgetTester tester, {double width = 375, String name = 'Hamza Sheikh'}) async {
  final c = await _newUser(tester, width: width);
  await c.read(sessionProvider.notifier).completeProfile(
      fullName: name, phone: '0333 9876543', dateOfBirth: DateTime(2000, 5, 1), hasPhoto: false);
  c.read(routerProvider).go(Routes.roleSelection);
  await tester.pumpAndSettle();
  return c;
}

Finder get _playerCard => find.bySemanticsLabel(RegExp(r'^Player\. '));
Finder get _clubCard => find.bySemanticsLabel(RegExp(r'^Club Owner\. '));

void main() {
  group('Auth page', () {
    testWidgets('Login renders the auth page with the CricEco logo', (tester) async {
      final c = await _pump(tester);
      expect(_loc(c), Routes.login);
      expect(find.text('Criceco'), findsOneWidget);
      expect(find.byType(CeBrandLogo), findsOneWidget);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.byKey(const Key('login.phone')), findsOneWidget);
      expect(find.byKey(const Key('login.password')), findsOneWidget);
      expect(find.byTooltip('Show password'), findsOneWidget);
    });

    testWidgets('Login validates phone and password inline', (tester) async {
      final c = await _pump(tester);
      await _tap(tester, _button('Login'));
      expect(find.text('Phone number is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);
      await _enter(tester, 'login.phone', '12345');
      await _tap(tester, _button('Login'));
      expect(find.text('Enter a valid mobile number (03XX-XXXXXXX)'), findsOneWidget);
      expect(_loc(c), Routes.login);
    });

    testWidgets('rejected credentials show a friendly error, no exception', (tester) async {
      final c = await _pump(tester, overrides: [
        accountRepositoryProvider.overrideWith((ref) => _RejectingAccounts(InMemoryAccountRepository(ref.watch(seedDataProvider)))),
      ]);
      await _login(tester);
      expect(find.text('Incorrect phone number or password. Please try again.'), findsOneWidget);
      expect(_loc(c), Routes.login);
    });

    testWidgets('Sign Up tab, Create Account and Back behaviour', (tester) async {
      final c = await _pump(tester);
      await _tap(tester, find.widgetWithText(TextButton, 'Sign Up'));
      expect(_loc(c), Routes.signup);
      expect(_button('Continue with Google'), findsOneWidget);
      await _tap(tester, _button('Create New Account'));
      expect(_loc(c), Routes.createAccount);
      await _tap(tester, find.byTooltip('Back'));
      expect(_loc(c), Routes.signup);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.login, reason: 'system Back on Sign Up returns to Login');
    });

    testWidgets('Create Account asks credentials only and validates them inline', (tester) async {
      final c = await _pump(tester);
      c.read(routerProvider).go(Routes.createAccount);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signup.name')), findsNothing, reason: 'name belongs to User Profile Setup');
      await _tap(tester, _button('Create Account'));
      expect(find.text('Phone number is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);
      await _enter(tester, 'signup.password', 'abc');
      await _enter(tester, 'signup.confirm', 'abd');
      await _tap(tester, _button('Create Account'));
      expect(find.text('Password must be at least 6 characters'), findsOneWidget);
      expect(find.text('Passwords do not match'), findsOneWidget);
      await _tap(tester, find.text('Email'));
      await _enter(tester, 'signup.email', 'not-an-email');
      await _tap(tester, _button('Create Account'));
      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(_loc(c), Routes.createAccount);
    });

    testWidgets('Sign Up → User Profile Setup (phone prefilled); Back returns to Create Account', (tester) async {
      final c = await _pump(tester);
      c.read(routerProvider).go(Routes.createAccount);
      await tester.pumpAndSettle();
      await _enter(tester, 'signup.phone', '0333 9876543');
      await _enter(tester, 'signup.password', 'secret1');
      await _enter(tester, 'signup.confirm', 'secret1');
      await _tap(tester, _button('Create Account'));
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      final a = c.read(currentAccountProvider)!;
      expect((a.profileComplete, a.playerProfile.isComplete, a.hasClubOwnerProfile), (false, false, false),
          reason: 'a new account: nothing set up');
      expect(find.text('03339876543'), findsOneWidget, reason: 'sign-up phone prefilled');
      await _tap(tester, find.byTooltip('Back'));
      expect(_loc(c), Routes.createAccount);
    });

    testWidgets('Continue with Google → User Profile Setup', (tester) async {
      final c = await _pump(tester);
      c.read(routerProvider).go(Routes.signup);
      await tester.pumpAndSettle();
      await _tap(tester, _button('Continue with Google'));
      expect(_loc(c), Routes.profileSetup);
      expect(c.read(currentAccountProvider)!.playerProfile.isComplete, isFalse);
    });
  });

  group('User Profile Setup', () {
    testWidgets('validates Name, Phone and DOB inline; saves the profile to the account → Role Selection',
        (tester) async {
      final c = await _newUser(tester);
      expect(find.text('Step 2 of 3 — Your Profile'), findsOneWidget);
      expect(find.text('Playing Role'), findsNothing, reason: 'no cricket-role questions here');
      await _enter(tester, 'profile.phone', '');
      await _tap(tester, _button('Continue'));
      expect(find.text('Full name is required'), findsOneWidget);
      expect(find.text('Phone number is required'), findsOneWidget);
      expect(find.text('Date of birth is required'), findsOneWidget);
      expect(_loc(c), Routes.profileSetup);

      await _enter(tester, 'profile.name', 'Hamza Sheikh');
      await _enter(tester, 'profile.phone', '0333-9876543');
      await _tap(tester, find.byKey(const Key('profile.dob')));
      await _tap(tester, find.text('OK'));
      await _tap(tester, find.bySemanticsLabel('Add profile picture'));
      await _tap(tester, _button('Continue'));

      expect(_loc(c), Routes.roleSelection);
      final a = c.read(currentAccountProvider)!;
      expect((a.fullName, a.phone, a.hasPhoto, a.profileComplete), ('Hamza Sheikh', '0333 9876543', true, true));
      expect(a.dateOfBirth, isNotNull);
      expect(c.read(sessionProvider).status, SessionStatus.signedIn);
      expect(c.read(activeRoleProvider), isNull, reason: 'no role yet — the user chooses');
    });

    testWidgets('an incomplete profile is always sent back to Profile Setup', (tester) async {
      final c = await _newUser(tester);
      for (final loc in [Routes.roleSelection, Routes.playerHome, Routes.clubSetup, Routes.clubHome]) {
        c.read(routerProvider).go(loc);
        await tester.pumpAndSettle();
        expect(_loc(c), Routes.profileSetup, reason: loc);
      }
    });
  });

  group('Role Selection → Player (same screen)', () {
    testWidgets('selecting Player expands the details in place; Continue reaches the Player Dashboard',
        (tester) async {
      final c = await _profiled(tester);
      expect(find.byType(RoleSelectionScreen), findsOneWidget);
      expect(find.text('Playing Role *'), findsNothing, reason: 'collapsed until Player is chosen');

      await _tap(tester, _playerCard);
      expect(_loc(c), Routes.roleSelection, reason: 'no route transition for Player details');
      expect(find.byType(RoleSelectionScreen), findsOneWidget);
      expect(find.text('Playing Role *'), findsOneWidget);
      expect(find.text('Batting Style *'), findsOneWidget);
      expect(find.text('Bowling Style *'), findsOneWidget);
      expect(find.text('Wicket Keeper'), findsOneWidget);

      await _tap(tester, _button('Continue as Player'));
      expect(find.text('Please select your playing role'), findsOneWidget);
      expect(find.text('Please select your batting style'), findsOneWidget);
      expect(find.text('Please select your bowling style'), findsOneWidget);
      expect(_loc(c), Routes.roleSelection);

      await _tap(tester, find.text('All-Rounder'));
      await _tap(tester, find.text('Left-handed'));
      await _tap(tester, find.text('Left-arm Orthodox'));
      await _tap(tester, find.text('Wicket Keeper'));
      expect(c.read(onboardingProvider).isWicketkeeper, isTrue);
      await _tap(tester, _button('Continue as Player'));

      expect(_loc(c), Routes.playerHome);
      expect(c.read(activeRoleProvider), UserRole.player);
      final p = c.read(currentAccountProvider)!.playerProfile;
      expect((p.role, p.battingStyle, p.bowlingStyle, p.isWicketkeeper),
          (PlayerRole.allRounder, BattingStyle.leftHanded, BowlingStyle.leftArmOrthodox, true));
      expect(c.read(routerProvider).canPop(), isFalse, reason: 'onboarding cleared from the back stack');
    });

    testWidgets('wicket keeper is optional and never the primary role', (tester) async {
      final c = await _profiled(tester);
      await _tap(tester, _playerCard);
      expect(find.text('Wicket-Keeper'), findsNothing, reason: 'not offered as a playing role');
      await _tap(tester, find.text('Bowler'));
      await _tap(tester, find.text('Right-handed'));
      await _tap(tester, find.text('Right-arm Fast'));
      await _tap(tester, _button('Continue as Player'));
      expect(_loc(c), Routes.playerHome);
      final p = c.read(currentAccountProvider)!.playerProfile;
      expect((p.role, p.isWicketkeeper), (PlayerRole.bowler, false));
    });

    testWidgets('Back collapses the Player details first; tapping the header collapses too', (tester) async {
      final c = await _profiled(tester);
      await _tap(tester, _playerCard);
      expect(find.text('Playing Role *'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Playing Role *'), findsNothing, reason: 'collapsed, not navigated away');
      expect(_loc(c), Routes.roleSelection);
      await _tap(tester, _playerCard);
      await _tap(tester, find.text('Batsman'));
      await _tap(tester, _playerCard);
      expect(find.text('Playing Role *'), findsNothing);
      await _tap(tester, _playerCard);
      expect(c.read(onboardingProvider).role, PlayerRole.batsman, reason: 'answers kept while collapsed');
    });
  });

  group('Role Selection → Club Owner (new screen)', () {
    testWidgets('opens Club Setup Details; Back returns to Role Selection', (tester) async {
      final c = await _profiled(tester);
      await _tap(tester, _clubCard);
      expect(_loc(c), Routes.clubSetup);
      expect(c.read(activeRoleProvider), isNull, reason: 'setup must not change the role yet');
      await _tap(tester, find.byTooltip('Back'));
      expect(_loc(c), Routes.roleSelection);
    });

    testWidgets('validates every field inline; completion reaches the Club Owner Dashboard', (tester) async {
      final c = await _profiled(tester);
      await _tap(tester, _clubCard);
      expect(find.byKey(const Key('club.owner')), findsOneWidget);
      await _enter(tester, 'club.owner', '');
      await _tap(tester, _button('Create Club'));
      expect(find.text('Club name is required'), findsOneWidget);
      expect(find.text('Owner name is required'), findsOneWidget);
      expect(find.text('Address is required'), findsOneWidget);
      expect(find.text('Please select a city'), findsOneWidget);
      expect(find.text('Please select a club type'), findsOneWidget);
      expect(find.text('Please choose Yes or No'), findsOneWidget);
      expect(_loc(c), Routes.clubSetup);

      await _enter(tester, 'club.name', 'Lahore Lions CC');
      await _enter(tester, 'club.owner', 'Hamza Sheikh');
      await _enter(tester, 'club.address', 'Mian Mir Road');
      await _tap(tester, find.byKey(const Key('club.city')));
      await _tap(tester, find.text('Lahore').last);
      await _tap(tester, find.byKey(const Key('club.type')));
      await _tap(tester, find.text('Corporate Club').last);
      await _tap(tester, find.text('Yes'));
      await _tap(tester, _button('Create Club'));
      expect(find.text('Please select your home ground'), findsOneWidget);
      await _tap(tester, _button('Select Home Ground'));
      await _tap(tester, find.text('Pindi Cricket Ground'));
      await _tap(tester, find.bySemanticsLabel('Add club picture'));
      await _tap(tester, _button('Create Club'));

      expect(_loc(c), Routes.clubHome);
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
      final club = c.read(currentClubProvider)!;
      expect((club.name, club.city, club.type, club.homeGroundId, club.ownerName, club.address),
          ('Lahore Lions CC', 'Lahore', ClubType.corporate, 'g_pindi', 'Hamza Sheikh', 'Mian Mir Road'));
      expect(c.read(routerProvider).canPop(), isFalse, reason: 'setup screens are not in the back stack');
    });

    testWidgets('Home Ground "No" needs no ground', (tester) async {
      final c = await _profiled(tester);
      await _tap(tester, _clubCard);
      await _enter(tester, 'club.name', 'Karachi Kites');
      await _enter(tester, 'club.address', 'Clifton');
      await _tap(tester, find.byKey(const Key('club.city')));
      await _tap(tester, find.text('Karachi').last);
      await _tap(tester, find.byKey(const Key('club.type')));
      await _tap(tester, find.text('Professional').last);
      await _tap(tester, find.text('No'));
      await _tap(tester, _button('Create Club'));
      expect(_loc(c), Routes.clubHome);
      expect(c.read(currentClubProvider)!.homeGroundId, isNull);
      expect(c.read(currentClubProvider)!.ownerName, 'Hamza Sheikh', reason: 'owner prefilled from the account');
    });
  });

  group('Returning users', () {
    testWidgets('a completed Player logs straight into the Player Dashboard, data intact', (tester) async {
      final c = await _pump(tester);
      final before = c.read(seedDataProvider).account.playerProfile;
      await _login(tester);
      expect(_loc(c), Routes.playerHome);
      expect(c.read(activeRoleProvider), UserRole.player);
      final a = c.read(currentAccountProvider)!;
      expect((a.fullName, a.phone, a.playerProfile.role, a.playerProfile.bowlingStyle),
          ('Aman Ali', '0312 9020000', before.role, before.bowlingStyle));
    });

    testWidgets('a completed Club Owner (no Player setup) logs straight into the Club Dashboard', (tester) async {
      final c = await _profiled(tester);
      await c.read(sessionProvider.notifier).createClub(name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);
      c.read(sessionProvider.notifier).logout();
      c.read(routerProvider).go(Routes.login);
      await tester.pumpAndSettle();
      await _login(tester);
      expect(_loc(c), Routes.clubHome);
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
      expect(c.read(currentClubProvider)!.name, 'Lahore Lions CC');
    });

    testWidgets('both roles set up → Role Selection shows both Ready and enters without setup', (tester) async {
      final c = await _pump(tester);
      await _login(tester);
      await c.read(sessionProvider.notifier).createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
      c.read(sessionProvider.notifier).logout();
      c.read(routerProvider).go(Routes.login);
      await tester.pumpAndSettle();
      await _login(tester);
      expect(_loc(c), Routes.roleSelection);
      expect(find.text('READY'), findsNWidgets(2));
      await _tap(tester, _playerCard);
      expect(_loc(c), Routes.playerHome, reason: 'no expansion for a completed Player');
    });

    testWidgets('profile-complete user without a role lands on Role Selection', (tester) async {
      final c = await _profiled(tester);
      c.read(sessionProvider.notifier).logout();
      c.read(routerProvider).go(Routes.login);
      await tester.pumpAndSettle();
      await _login(tester);
      expect(_loc(c), Routes.roleSelection);
      expect(c.read(currentAccountProvider)!.fullName, 'Hamza Sheikh', reason: 'profile not reset on login');
    });

    testWidgets('no onboarding loop: auth and setup routes bounce a set-up user to their dashboard', (tester) async {
      final c = await _pump(tester);
      await _login(tester);
      for (final loc in [Routes.login, Routes.signup, Routes.profileSetup]) {
        c.read(routerProvider).go(loc);
        await tester.pumpAndSettle();
        expect(_loc(c), Routes.playerHome, reason: loc);
      }
      // Role guard intact: a Club Owner location bounces back to Player home.
      c.read(routerProvider).go(Routes.teams);
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome);
    });
  });

  group('Legacy onboarding routes', () {
    testWidgets('Continue As / Playing Style → Role Selection; Create Club / Club Details → Club Setup', (tester) async {
      final c = await _profiled(tester);
      final router = c.read(routerProvider);
      router.go(Routes.continueAs);
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.roleSelection);
      router.go(Routes.roleDetails);
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.roleSelectionPlayer);
      expect(find.text('Playing Role *'), findsOneWidget, reason: 'opens with Player expanded');
      for (final loc in [Routes.createClub, Routes.clubDetails]) {
        router.go(loc);
        await tester.pumpAndSettle();
        expect(_loc(c), Routes.clubSetup, reason: loc);
      }
    });
  });

  group('Join a Club (membership by code, from Club Setup)', () {
    testWidgets('grants membership only and lands in Player context', (tester) async {
      final c = await _pump(tester);
      await _login(tester);
      c.read(routerProvider).go(Routes.clubSetup);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Enter club code'));
      await _tap(tester, _button('Send Join Request'));
      expect(find.text('Please enter a club code'), findsOneWidget);
      await _enter(tester, 'join.code', 'krc001');
      await _tap(tester, _button('Send Join Request'));
      expect(_loc(c), Routes.waitingApproval);
      await tester.scrollUntilVisible(find.text('PROTOTYPE CONTROLS'), 200);
      await _tap(tester, find.text('As Coach'));
      expect(_loc(c), Routes.joinApproved);
      await _tap(tester, _button('Continue to Dashboard'));
      expect(_loc(c), Routes.playerHome);
      expect(c.read(sessionProvider).hasClubOwnerProfile, isFalse);
      expect(c.read(currentAccountProvider)!.memberships.single.role, MemberRole.coach);
    });

    testWidgets('Cancel Request returns to Club Setup', (tester) async {
      final c = await _pump(tester);
      await _login(tester);
      c.read(routerProvider).go(Routes.clubSetup);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Enter club code'));
      await _enter(tester, 'join.code', 'ABCD12');
      await _tap(tester, _button('Send Join Request'));
      await _tap(tester, _button('Cancel Request'));
      expect(_loc(c), Routes.clubSetup);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('auth + onboarding screens fit at ${width.toInt()} px (long content, expanded, errors)',
          (tester) async {
        final c = await _newUser(tester, width: width);
        final router = c.read(routerProvider);
        for (final loc in [Routes.signup, Routes.createAccount, Routes.profileSetup]) {
          router.go(loc);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        await _tap(tester, _button('Continue')); // profile errors shown
        expect(tester.takeException(), isNull, reason: 'profile errors @ $width');

        await c.read(sessionProvider.notifier).completeProfile(
            fullName: 'Muhammad Abdul Rehman Chaudhry Al-Pakistani the Third',
            phone: '0300 1234567',
            dateOfBirth: DateTime(1999),
            hasPhoto: true);
        router.go(Routes.roleSelection);
        await tester.pumpAndSettle();
        await _tap(tester, _playerCard); // expanded Player details
        await _tap(tester, _button('Continue as Player')); // with inline errors
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'expanded player @ $width');
        expect(_button('Continue as Player').hitTestable(), findsOneWidget, reason: 'reachable by scrolling');

        router.go(Routes.clubSetup);
        await tester.pumpAndSettle();
        await _tap(tester, find.text('Yes'));
        await _tap(tester, _button('Create Club'));
        expect(tester.takeException(), isNull, reason: 'club setup errors @ $width');
        router.go(Routes.enterClubCode);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'join @ $width');
        c.read(sessionProvider.notifier).logout();
        router.go(Routes.login);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'login @ $width');
      });
    }
  });
}
