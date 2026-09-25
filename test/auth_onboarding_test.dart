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
import 'package:criceco/features/auth/widgets/auth_widgets.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_icons.dart';
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

Future<void> _login(WidgetTester tester) async {
  await _enter(tester, 'login.phone', '0312-9020000');
  await _enter(tester, 'login.password', 'secret1');
  await _tap(tester, _button('Login'));
}

void main() {
  group('Login', () {
    testWidgets('renders the prototype layout', (tester) async {
      final c = await _pump(tester);
      expect(_loc(c), Routes.login);
      expect(find.text('Criceco'), findsOneWidget);
      expect(find.text('Your cricket club, organized.'), findsOneWidget);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Login to manage your cricket club'), findsOneWidget);
      expect(find.byKey(const Key('login.phone')), findsOneWidget);
      expect(find.byKey(const Key('login.password')), findsOneWidget);
      expect(find.byTooltip('Show password'), findsOneWidget);
      expect(find.text("Don't have an account? "), findsOneWidget);
    });

    testWidgets('validates phone and password', (tester) async {
      final c = await _pump(tester);
      await _tap(tester, _button('Login'));
      expect(find.text('Phone number is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);
      await _enter(tester, 'login.phone', '12345');
      await _tap(tester, _button('Login'));
      expect(find.text('Enter a valid mobile number (03XX-XXXXXXX)'), findsOneWidget);
      expect(_loc(c), Routes.login);
    });

    testWidgets('password visibility toggles', (tester) async {
      await _pump(tester);
      await _tap(tester, find.byTooltip('Show password'));
      expect(find.byTooltip('Hide password'), findsOneWidget);
    });

    testWidgets('successful login goes to Continue As', (tester) async {
      final c = await _pump(tester);
      await _login(tester);
      expect(_loc(c), Routes.continueAs);
      expect(c.read(sessionProvider).status, SessionStatus.signedIn);
    });

    testWidgets('rejected credentials show a friendly error, no exception', (tester) async {
      final c = await _pump(tester, overrides: [
        accountRepositoryProvider.overrideWith((ref) => _RejectingAccounts(InMemoryAccountRepository(ref.watch(seedDataProvider)))),
      ]);
      await _login(tester);
      expect(find.text('Incorrect phone number or password. Please try again.'), findsOneWidget);
      expect(_loc(c), Routes.login);
    });
  });

  group('Sign Up', () {
    testWidgets('toggle, landing, Create Account and Back behaviour', (tester) async {
      final c = await _pump(tester);
      await _tap(tester, find.widgetWithText(TextButton, 'Sign Up'));
      expect(_loc(c), Routes.signup);
      expect(find.text('Create account'), findsOneWidget);
      expect(_button('Continue with Google'), findsOneWidget);

      await _tap(tester, _button('Create New Account'));
      expect(_loc(c), Routes.createAccount);
      await _tap(tester, find.byTooltip('Back'));
      expect(_loc(c), Routes.signup);

      // System Back on the Sign Up tab returns to Login.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.login);
    });

    testWidgets('Create Account validates required fields, phone/email and passwords', (tester) async {
      final c = await _pump(tester);
      c.read(routerProvider).go(Routes.createAccount);
      await tester.pumpAndSettle();
      await _tap(tester, _button('Create Account'));
      expect(find.text('Full name is required'), findsOneWidget);
      expect(find.text('Phone number is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);

      await _enter(tester, 'signup.password', 'abc');
      await _enter(tester, 'signup.confirm', 'abd');
      await _tap(tester, _button('Create Account'));
      expect(find.text('Password must be at least 6 characters'), findsOneWidget);
      expect(find.text('Passwords do not match'), findsOneWidget);

      await _tap(tester, find.text('Email'));
      expect(find.byKey(const Key('signup.email')), findsOneWidget);
      expect(find.byKey(const Key('signup.phone')), findsNothing);
      await _enter(tester, 'signup.email', 'not-an-email');
      await _tap(tester, _button('Create Account'));
      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(_loc(c), Routes.createAccount);
    });

    testWidgets('successful sign up continues to Complete Profile; Back returns to Create Account', (tester) async {
      final c = await _pump(tester);
      c.read(routerProvider).go(Routes.createAccount);
      await tester.pumpAndSettle();
      await _enter(tester, 'signup.name', 'Hamza Sheikh');
      await _enter(tester, 'signup.phone', '0333 9876543');
      await _enter(tester, 'signup.password', 'secret1');
      await _enter(tester, 'signup.confirm', 'secret1');
      await _tap(tester, _button('Create Account'));
      expect(_loc(c), Routes.completeProfile);
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      expect(c.read(currentAccountProvider)!.fullName, 'Hamza Sheikh');
      expect(c.read(currentAccountProvider)!.phone, '03339876543');

      await _tap(tester, find.byTooltip('Back'));
      expect(_loc(c), Routes.createAccount);
    });
  });

  group('Onboarding', () {
    Future<ProviderContainer> toCompleteProfile(WidgetTester tester) async {
      final c = await _pump(tester);
      await c.read(sessionProvider.notifier).signUp(
          fullName: 'Hamza Sheikh', method: ContactMethod.phone, identifier: '03339876543', password: 'secret1');
      c.read(routerProvider).go(Routes.completeProfile);
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('Complete Profile requires DOB and role, then progresses to Playing Style', (tester) async {
      final c = await toCompleteProfile(tester);
      expect(find.text('Step 2 of 3 — Player Details'), findsOneWidget);
      expect(find.byKey(const Key('profile.name')), findsOneWidget);
      await _tap(tester, _button('Continue'));
      expect(find.text('Date of birth is required'), findsOneWidget);
      expect(find.text('Please select your role'), findsOneWidget);
      expect(_loc(c), Routes.completeProfile);

      await _tap(tester, find.byKey(const Key('profile.dob')));
      await _tap(tester, find.text('OK'));
      await _tap(tester, find.text('Bowler'));
      await _tap(tester, _button('Continue'));
      expect(_loc(c), Routes.roleDetails);
      expect(find.text('Step 3 of 3 — Bowler'), findsOneWidget);
      expect(c.read(currentAccountProvider)!.dateOfBirth, isNotNull);
      expect(c.read(currentAccountProvider)!.playerProfile.role, PlayerRole.bowler);
    });

    testWidgets('Playing Style: role-specific blocks, selections persist across Back, Save completes onboarding',
        (tester) async {
      final c = await toCompleteProfile(tester);
      c.read(onboardingProvider.notifier)
        ..setDateOfBirth(DateTime(2001, 4, 15))
        ..setRole(PlayerRole.bowler);
      await tester.pumpAndSettle();
      await _tap(tester, _button('Continue'));

      // Bowler: Bowling block before Batting, no wicketkeeper option.
      final bowlingY = tester.getTopLeft(find.text('Bowling Style *')).dy;
      final battingY = tester.getTopLeft(find.text('Batting Style *')).dy;
      expect(bowlingY, lessThan(battingY));
      expect(find.text('Also a Wicketkeeper?'), findsNothing);

      await _tap(tester, _button('Save Profile'));
      expect(find.text('Please select both styles'), findsOneWidget);

      await _tap(tester, find.text('Left-arm Orthodox'));
      await _tap(tester, find.byTooltip('Back'));
      expect(_loc(c), Routes.completeProfile);
      // Role still selected after Back; go forward again — style kept.
      await _tap(tester, _button('Continue'));
      expect(c.read(onboardingProvider).bowlingStyle, BowlingStyle.leftArmOrthodox);

      await _tap(tester, find.text('Right-handed'));
      await _tap(tester, _button('Save Profile'));
      expect(_loc(c), Routes.continueAs);
      final p = c.read(currentAccountProvider)!.playerProfile;
      expect(p.bowlingStyle, BowlingStyle.leftArmOrthodox);
      expect(p.battingStyle, BattingStyle.rightHanded);
      expect(c.read(sessionProvider).status, SessionStatus.signedIn);
    });

    testWidgets('Batsman gets the wicketkeeper toggle; Skip completes onboarding', (tester) async {
      final c = await toCompleteProfile(tester);
      c.read(onboardingProvider.notifier).setRole(PlayerRole.batsman);
      c.read(routerProvider).go(Routes.roleDetails);
      await tester.pumpAndSettle();
      await _tap(tester, _button('Mark as Wicketkeeper'));
      expect(c.read(onboardingProvider).isWicketkeeper, isTrue);
      expect(_button('Wicketkeeper'), findsOneWidget);
      await _tap(tester, find.text('Skip'));
      expect(_loc(c), Routes.continueAs);
    });
  });

  group('Continue As and role guards', () {
    Future<ProviderContainer> signedIn(WidgetTester tester) async {
      final c = await _pump(tester);
      await _login(tester);
      return c;
    }

    testWidgets('renders both profiles with the setup tag', (tester) async {
      await signedIn(tester);
      expect(find.text('Continue as'), findsOneWidget);
      expect(find.text('Signed in as Aman Ali · one account, every role'), findsOneWidget);
      expect(find.text('Player Profile'), findsOneWidget);
      expect(find.text('Club Owner'), findsOneWidget);
      expect(find.text('SETUP REQUIRED'), findsOneWidget);
      expect(find.text('You can switch profiles any time from the menu — no second login.'), findsOneWidget);
      // Regression (found on emulator): banner must be full-bleed without a toggle row.
      expect(tester.getSize(find.byType(AuthBanner)).width, 375);
      expect(tester.getSize(find.ancestor(of: find.byIcon(CeIcons.of('circle-dot')), matching: find.byType(Container)).first).width, 74);
    });

    testWidgets('Player Profile opens the Player dashboard and sets the role', (tester) async {
      final c = await signedIn(tester);
      await _tap(tester, find.text('Player Profile'));
      expect(_loc(c), Routes.playerHome);
      expect(c.read(activeRoleProvider), UserRole.player);
      // Role guard intact: a Club Owner location bounces back to Player home.
      c.read(routerProvider).go(Routes.teams);
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome);
    });

    testWidgets('Club Owner without a profile follows the setup path and ends on the Club dashboard', (tester) async {
      final c = await signedIn(tester);
      await _tap(tester, find.text('Club Owner'));
      expect(_loc(c), Routes.chooseOption);
      expect(c.read(activeRoleProvider), isNull, reason: 'setup must not change the role yet');
      expect(find.text('Set up your club'), findsOneWidget);

      await _tap(tester, find.text('Create a Club'));
      expect(_loc(c), Routes.createClub);
      await _tap(tester, _button('Continue'));
      expect(find.text('Club name is required'), findsOneWidget);
      expect(find.text('Please select a city'), findsOneWidget);

      await _enter(tester, 'club.name', 'Lahore Lions CC');
      await _tap(tester, find.byKey(const Key('club.city')));
      await _tap(tester, find.text('Lahore').last);
      await _tap(tester, _button('Continue'));
      expect(_loc(c), Routes.clubDetails);
      expect(find.text('Lahore Lions CC'), findsOneWidget);

      await _tap(tester, _button('Create Club'));
      expect(find.text('Please select a club type'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('club.type')));
      await _tap(tester, find.text('Corporate Club').last);
      await _tap(tester, _button('Add Home Ground'));
      await _tap(tester, find.text('Pindi Cricket Ground'));
      expect(_button('Pindi Cricket Ground'), findsOneWidget);
      await _tap(tester, _button('Create Club'));

      expect(_loc(c), Routes.clubHome);
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
      expect(c.read(sessionProvider).hasClubOwnerProfile, isTrue);
      final club = c.read(currentClubProvider)!;
      expect((club.name, club.city, club.type, club.homeGroundId), ('Lahore Lions CC', 'Lahore', ClubType.corporate, 'g_pindi'));
      // Setup screens are not in the back stack.
      expect(c.read(routerProvider).canPop(), isFalse);
    });

    testWidgets('Club Owner with a profile opens the Club dashboard directly', (tester) async {
      final c = await signedIn(tester);
      await c.read(sessionProvider.notifier).createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
      await tester.pumpAndSettle();
      expect(find.text('SETUP REQUIRED'), findsNothing);
      await _tap(tester, find.text('Club Owner'));
      expect(_loc(c), Routes.clubHome);
    });

    testWidgets('Join a Club as Coach grants membership only and lands in Player context', (tester) async {
      final c = await signedIn(tester);
      await _tap(tester, find.text('Club Owner'));
      await _tap(tester, find.text('Join a Club'));
      await _tap(tester, _button('Send Join Request'));
      expect(find.text('Please enter a club code'), findsOneWidget);
      await _enter(tester, 'join.code', 'krc001');
      await _tap(tester, _button('Send Join Request'));
      expect(_loc(c), Routes.waitingApproval);
      expect(find.text('Waiting for Approval'), findsOneWidget);
      expect(find.text('KRC001'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('PROTOTYPE CONTROLS'), 200);
      expect(find.text('PROTOTYPE CONTROLS'), findsOneWidget);

      await _tap(tester, find.text('As Coach'));
      expect(_loc(c), Routes.joinApproved);
      expect(find.text("You're In!"), findsOneWidget);
      await _tap(tester, _button('Continue to Dashboard'));
      expect(_loc(c), Routes.playerHome);
      expect(c.read(activeRoleProvider), UserRole.player);
      expect(c.read(sessionProvider).hasClubOwnerProfile, isFalse);
      expect(c.read(currentAccountProvider)!.memberships.single.role, MemberRole.coach);
    });

    testWidgets('Cancel Request returns to Set Up Your Club', (tester) async {
      final c = await signedIn(tester);
      await _tap(tester, find.text('Club Owner'));
      await _tap(tester, find.text('Join a Club'));
      await _enter(tester, 'join.code', 'ABCD12');
      await _tap(tester, _button('Send Join Request'));
      expect(find.text('Club ABCD12'), findsWidgets);
      await _tap(tester, _button('Cancel Request'));
      expect(_loc(c), Routes.chooseOption);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 1 screens render without overflow at ${width.toInt()} px (long content)', (tester) async {
        final c = await _pump(tester, width: width);
        await c.read(sessionProvider.notifier).signUp(
            fullName: 'Muhammad Abdul Rehman Chaudhry Al-Pakistani the Third',
            method: ContactMethod.phone,
            identifier: '03001234567',
            password: 'secret1');
        c.read(onboardingProvider.notifier).setRole(PlayerRole.batsman);
        final router = c.read(routerProvider);
        for (final loc in [Routes.signup, Routes.createAccount, Routes.completeProfile, Routes.roleDetails]) {
          router.go(loc);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        await c.read(sessionProvider.notifier).completeOnboarding();
        for (final loc in [Routes.continueAs, Routes.chooseOption, Routes.createClub, Routes.clubDetails, Routes.enterClubCode]) {
          router.go(loc);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        c.read(sessionProvider.notifier).logout();
        router.go(Routes.login);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'login @ $width');
      });
    }
  });
}

