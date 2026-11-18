// Production safety & UX hardening (docs/PRODUCTION_DEMO_MODE.md,
// docs/ACCOUNT_PRIVACY_AND_DELETION.md): with a production build's modules
// (memberships and teams only) every other module's route, sheet and
// dashboard value says "not available yet" — nothing invented, nothing
// pretended. The app runs on the demo repositories with the production
// module set ([backendModulesProvider] overridden), so the screens have data
// to (not) show. Also: fitness without match data, Suggest Team, navigation
// fixes, privacy and security settings, and Delete Account.
import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/account_privacy.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/teams/team_suggestion.dart';
import 'package:criceco/features/fitness/fitness_providers.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 9, 23, 10);

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// A production build's modules: memberships and teams only.
final _production = BackendModules.of(_supabase, memberships: true);

/// The app signed in (demo password "y") as [role]; [production]: the
/// production module set.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required UserRole role,
  bool production = true,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      if (production) backendModulesProvider.overrideWithValue(_production),
      ...overrides,
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  if (role == UserRole.clubOwner) {
    await s.createClub(name: 'Hardening CC', city: 'Islamabad', type: ClubType.professional);
  }
  final nav = c.read(roleControllerProvider.notifier).continueAs(role);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder _pending(BackendModule m) => find.byKey(Key('backendPending.${m.name}'));
Finder _pendingSheet(BackendModule m) => find.byKey(Key('backendPendingSheet.${m.name}'));

void main() {
  group('WS1: match booking, payment and line-up routes are gated', () {
    const m = Routes.matchManagementPath;
    final routes = <(String, BackendModule)>[
      ('$m/m1/setup/ground', BackendModule.grounds),
      ('$m/m1/setup/ground/g1', BackendModule.grounds),
      ('$m/m1/setup/ground/g1/schedule', BackendModule.grounds),
      ('$m/m1/setup/ground/g1/schedule/summary', BackendModule.grounds),
      ('$m/m1/payment', BackendModule.payments),
      ('$m/m1/waiting', BackendModule.payments),
      ('$m/m1/opponent-payment', BackendModule.payments),
      ('$m/m1/confirmed', BackendModule.payments),
      ('$m/m1/expired', BackendModule.payments),
      ('$m/m1/lineup', BackendModule.matches),
      ('$m/m1/lineup/build', BackendModule.matches),
      ('$m/m1/lineup/pick', BackendModule.matches),
    ];

    testWidgets('every deep link shows "not available yet", never "Match not found" or a booking', (tester) async {
      final c = await _pump(tester, role: UserRole.clubOwner);
      for (final (path, module) in routes) {
        await _go(tester, c, path);
        expect(_pending(module), findsOneWidget, reason: path);
        expect(find.text('Match not found'), findsNothing, reason: path);
        expect(find.textContaining('Simulated payment'), findsNothing, reason: path);
      }
    });

    testWidgets('demo builds still reach the real screens', (tester) async {
      final c = await _pump(tester, role: UserRole.clubOwner, production: false);
      await _go(tester, c, '$m/m1/payment');
      expect(_pending(BackendModule.payments), findsNothing);
    });
  });

  group('WS2 / WS3: player dashboard and sheets in production', () {
    testWidgets('no availability pill, stats "–", fitness not recorded; sheets say not available', (tester) async {
      final c = await _pump(tester, role: UserRole.player);
      expect(_loc(c), Routes.playerHome);
      expect(find.text('Available'), findsNothing, reason: 'availability isn\'t saved anywhere');
      await tester.scrollUntilVisible(
        find.byKey(const Key('player.fitnessPending')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('player.fitnessPending')), findsOneWidget);
      expect(find.textContaining('/10'), findsNothing, reason: 'never a fitness score without match data');
      expect(c.read(playerFitnessProvider), isNull);

      await _tap(tester, find.text('Match Availability'));
      expect(_pendingSheet(BackendModule.availability), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await _tap(tester, find.text('Performance'));
      expect(_pendingSheet(BackendModule.playerStats), findsOneWidget);
    });

    testWidgets('the Availability route is gated', (tester) async {
      final c = await _pump(tester, role: UserRole.player);
      await _go(tester, c, Routes.availability);
      expect(_pending(BackendModule.availability), findsOneWidget);
    });
  });

  group('WS2: club dashboard in production', () {
    testWidgets('Announcement opens "not available", saves nothing; no match record or results chart', (tester) async {
      await _pump(tester, role: UserRole.clubOwner);
      expect(find.text('Match Results'), findsNothing);
      expect(find.text('Played'), findsOneWidget);
      await _tap(tester, find.text('Announcement'));
      expect(_pendingSheet(BackendModule.announcements), findsOneWidget);
      expect(find.textContaining('published'), findsNothing);
    });

    testWidgets('Notifications: gated, and Back goes to the role home (not Role Selection)', (tester) async {
      final c = await _pump(tester, role: UserRole.clubOwner);
      await _go(tester, c, Routes.notifications);
      expect(_pending(BackendModule.notifications), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.clubHome);
    });
  });

  group('WS3: fitness without match data', () {
    test('providers say "not recorded" (null / empty), never a perfect score', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          backendModulesProvider.overrideWithValue(_production),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(fitnessRecordedProvider), isFalse);
      expect(c.read(playerFitnessProvider), isNull);
      expect(c.read(poolFitnessProvider), isEmpty);
    });

    test('Suggest Team: a player with no fitness record never outranks one with a good score', () {
      const known = SquadPlayer(
        id: 'p1',
        name: 'Known',
        position: 'Batsman',
        availability: PlayerAvailability.available,
      );
      const unknown = SquadPlayer(
        id: 'p2',
        name: 'Unknown',
        position: 'Batsman',
        availability: PlayerAvailability.available,
      );
      const report = FitnessReport(
        score: 8,
        level: FitnessLevel.fresh,
        recommendation: 'Good to play',
        restDays: 0,
        alerts: [],
        matches: 1,
        oversBowled: '0',
        ballsFaced: 0,
        backToBack: 0,
        daysSinceLastMatch: 1,
        avoidPlaying: false,
      );
      final s = TeamSuggestion.build([unknown, known], stats: const {}, fitness: {'p1': report});
      expect(s.picks.keys.first, 'p1', reason: 'missing fitness counts 0, not 10');
      expect(suggestTeamBasis(recorded: false), contains('aren’t recorded'));
    });
  });

  group('WS4: navigation and Club Setup', () {
    testWidgets('Join a Club: Back goes to the player\'s home, not Club Setup', (tester) async {
      final c = await _pump(tester, role: UserRole.player, production: false);
      await _go(tester, c, Routes.enterClubCode);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome);
    });

    testWidgets('Club Setup: no home-ground question without a grounds backend; the city picker', (tester) async {
      final c = await _pump(tester, role: UserRole.player);
      await _go(tester, c, Routes.clubSetup);
      expect(find.byKey(const Key('club.homeGround')), findsNothing);
      expect(find.byKey(const Key('club.city')), findsOneWidget);
    });

    testWidgets('Club Setup in the demo keeps the home-ground question', (tester) async {
      final c = await _pump(tester, role: UserRole.player, production: false);
      await _go(tester, c, Routes.clubSetup);
      expect(find.byKey(const Key('club.homeGround')), findsOneWidget);
    });
  });

  group('WS2 / WS7: privacy and security settings', () {
    testWidgets('production without the privacy switch: a truthful note, no inert switches', (tester) async {
      final c = await _pump(
        tester,
        role: UserRole.player,
        overrides: [
          accountControlsProvider.overrideWithValue(
            const AccountControls(phoneSharing: PhoneSharingMode.ownersSee, canDeleteAccount: false),
          ),
        ],
      );
      await _go(tester, c, '${Routes.settings}?section=privacy');
      expect(find.byKey(const Key('privacy.phoneVisibleToOwners')), findsOneWidget);
      expect(find.text('Share my phone number'), findsNothing);
      expect(find.text('Public profile'), findsNothing, reason: 'Find Player has no backend');
      expect(find.text('Show my stats'), findsNothing, reason: 'statistics have no backend');
      await _go(tester, c, Routes.securitySettings);
      expect(find.byKey(const Key('security.signInPending')), findsOneWidget);
      expect(find.text('Two-step verification'), findsNothing);
    });

    testWidgets('with the server consent: the switch saves the setting', (tester) async {
      final c = await _pump(
        tester,
        role: UserRole.player,
        overrides: [
          accountControlsProvider.overrideWithValue(
            const AccountControls(phoneSharing: PhoneSharingMode.server, canDeleteAccount: true),
          ),
        ],
      );
      await _go(tester, c, '${Routes.settings}?section=privacy');
      expect(c.read(currentAccountProvider)!.settings.showPhone, isFalse, reason: 'off by default');
      await _tap(tester, find.byKey(const Key('privacy.sharePhone')));
      expect(c.read(currentAccountProvider)!.settings.showPhone, isTrue);
    });
  });

  group('WS8: Delete Account', () {
    Finder submit() => find.byKey(const Key('deleteAccount.submit'));
    bool enabled(WidgetTester tester) => tester.widget<CeButton>(submit()).onPressed != null;

    testWidgets('a club owner is stopped: transfer the club first; no password form, nothing deleted', (tester) async {
      final c = await _pump(tester, role: UserRole.clubOwner, production: false);
      await _go(tester, c, Routes.settings);
      await _tap(tester, find.byKey(const Key('settings.deleteAccount')));
      expect(_loc(c), Routes.deleteAccount);
      expect(find.byKey(const Key('deleteAccount.ownershipRequired')), findsOneWidget);
      expect(find.textContaining('Hardening CC'), findsOneWidget, reason: 'the owned club is named');
      expect(find.byKey(const Key('deleteAccount.password')), findsNothing);
      expect(submit(), findsNothing);
      expect(c.read(sessionProvider).isAuthenticated, isTrue);
      expect(c.read(currentClubProvider), isNotNull);
    });

    testWidgets('a player: names what is deleted; needs the password and DELETE; a wrong password changes '
        'nothing; then the account is gone and the app is at Login', (tester) async {
      final c = await _pump(tester, role: UserRole.player, production: false);
      expect(c.read(currentClubProvider), isNull, reason: 'this player owns no club');
      await _go(tester, c, Routes.settings);
      await _tap(tester, find.byKey(const Key('settings.deleteAccount')));
      expect(_loc(c), Routes.deleteAccount);
      expect(find.byKey(const Key('deleteAccount.warning')), findsOneWidget);
      expect(enabled(tester), isFalse);

      await tester.enterText(find.byKey(const Key('deleteAccount.password')), 'wrong');
      await tester.enterText(find.byKey(const Key('deleteAccount.confirm')), 'delete');
      await tester.pump();
      expect(enabled(tester), isFalse, reason: 'DELETE must be typed in capitals');
      await tester.enterText(find.byKey(const Key('deleteAccount.confirm')), 'DELETE');
      await tester.pump();
      expect(enabled(tester), isTrue);
      await _tap(tester, submit());
      expect(find.text('That password is incorrect'), findsOneWidget);
      expect(c.read(sessionProvider).isAuthenticated, isTrue);

      await tester.enterText(find.byKey(const Key('deleteAccount.password')), 'y');
      await tester.pump();
      await _tap(tester, submit());
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(_loc(c), Routes.login);
      expect(c.read(activeRoleProvider), isNull);
    });

    testWidgets('where this build can\'t delete accounts it says so', (tester) async {
      final c = await _pump(
        tester,
        role: UserRole.player,
        overrides: [
          accountControlsProvider.overrideWithValue(
            const AccountControls(phoneSharing: PhoneSharingMode.ownersSee, canDeleteAccount: false),
          ),
        ],
      );
      await _go(tester, c, Routes.deleteAccount);
      expect(find.byKey(const Key('deleteAccount.unavailable')), findsOneWidget);
      expect(submit(), findsNothing);
    });
  });
}
