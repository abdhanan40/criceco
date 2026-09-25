import 'dart:ui' show Tristate;

import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _pumpApp(WidgetTester tester, {bool clubOwner = false}) async {
  // Phone-sized surface (prototype frame is 375 × 812).
  tester.view.physicalSize = const Size(1125, 2436);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();

  await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
  if (clubOwner) {
    await c.read(sessionProvider.notifier).createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  }
  final nav = c.read(roleControllerProvider.notifier).continueAs(clubOwner ? UserRole.clubOwner : UserRole.player);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

String _location(ProviderContainer c) => c.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

Future<void> _openDrawerAndTap(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Open menu'));
  await tester.pumpAndSettle();
  final item = find.descendant(of: find.byType(Drawer), matching: find.text(label));
  await tester.scrollUntilVisible(item, 80,
      scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)));
  await tester.tap(item);
  await tester.pumpAndSettle();
}

bool _navSelected(WidgetTester tester, String label) =>
    tester.getSemantics(find.bySemanticsLabel(label).last).flagsCollection.isSelected == Tristate.isTrue;

void main() {
  testWidgets('signed-in user lands on Continue As; Player lands on the dashboard', (tester) async {
    final c = await _pumpApp(tester);
    expect(_location(c), Routes.playerHome);
    expect(find.text('Welcome back,'), findsOneWidget);
    expect(_navSelected(tester, 'Home'), isTrue);
  });

  testWidgets('drawer is not a route: Back after a drawer destination returns to the dashboard', (tester) async {
    final c = await _pumpApp(tester, clubOwner: true);
    await _openDrawerAndTap(tester, 'Challenges');
    expect(_location(c), Routes.challenges);
    expect(find.byType(Drawer), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(_location(c), Routes.clubHome);
    expect(find.byType(Drawer), findsNothing, reason: 'Back must not reopen the drawer');
  });

  testWidgets('club drawer "Tournaments" opens the hub', (tester) async {
    final c = await _pumpApp(tester, clubOwner: true);
    await _openDrawerAndTap(tester, 'Tournaments');
    expect(_location(c), Routes.tournamentHub);
  });

  testWidgets('role switch replaces the stack: Back cannot return to the previous role', (tester) async {
    final c = await _pumpApp(tester, clubOwner: true);
    await _openDrawerAndTap(tester, 'Switch to Player profile');
    expect(_location(c), Routes.playerHome);
    expect(c.read(activeRoleProvider), UserRole.player);
    expect(c.read(routerProvider).canPop(), isFalse);
  });

  testWidgets('Player Match Details lives in the Matches tab and stays in Player context', (tester) async {
    final c = await _pumpApp(tester);
    final details = find.text('View Match Details');
    await tester.scrollUntilVisible(details, 150, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(_location(c), Routes.playerMatchDetails('pm_1'));
    expect(c.read(activeRoleProvider), UserRole.player);
    expect(_navSelected(tester, 'Matches'), isTrue);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(_location(c), Routes.myMatches);
  });

  testWidgets('a Player cannot reach a Club Owner screen by navigation', (tester) async {
    final c = await _pumpApp(tester);
    c.read(routerProvider).go(Routes.teams);
    await tester.pumpAndSettle();
    expect(_location(c), Routes.playerHome);
    expect(c.read(activeRoleProvider), UserRole.player);
  });

  testWidgets('logout clears navigation and returns to Login', (tester) async {
    final c = await _pumpApp(tester);
    await _openDrawerAndTap(tester, 'Logout');
    expect(_location(c), Routes.login);
    expect(c.read(routerProvider).canPop(), isFalse);
    c.read(routerProvider).go(Routes.playerHome);
    await tester.pumpAndSettle();
    expect(_location(c), Routes.login);
  });

  testWidgets('terminal booking screens intercept system Back', (tester) async {
    final c = await _pumpApp(tester, clubOwner: true);
    c.read(routerProvider).go(Routes.bookingConfirmed('m_2'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsNothing);
    final popped = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    expect(_location(c), Routes.matchManagement(MatchTab.scheduled));
  });

  testWidgets('legacy createTeam route redirects to My Teams', (tester) async {
    final c = await _pumpApp(tester, clubOwner: true);
    c.read(routerProvider).go(Routes.createTeamLegacy);
    await tester.pumpAndSettle();
    expect(_location(c), Routes.teams);
    expect(_navSelected(tester, 'Teams'), isTrue);
  });

  testWidgets('every declared route builds without error', (tester) async {
    final c = await _pumpApp(tester, clubOwner: true);
    final clubLocations = <String>[
      Routes.clubHome, Routes.teams, Routes.teamSquad('team_cs'), Routes.addTeamPlayers('team_cs'), Routes.members,
      Routes.myClub, Routes.joinRequests, Routes.joinRequestProfile('jr_1'), Routes.playerHunt, Routes.challenges,
      Routes.myChallenges, Routes.findMatch, Routes.createAvailabilitySlot, Routes.challengeAccepted('ch_gt'),
      Routes.clubProfile('club_kk'), Routes.matchManagement(), Routes.matchSetup('m_3'), Routes.bookGround('m_3'),
      Routes.groundDetails('m_3', 'g_pindi'), Routes.selectDate('m_3', 'g_pindi'), Routes.bookingSummary('m_3', 'g_pindi'),
      Routes.payment('m_3'), Routes.waitingForOpponent('m_3'), Routes.opponentPayment('m_3'),
      Routes.bookingConfirmed('m_3'), Routes.reservationExpired('m_3'), Routes.matchLineup('m_3'),
      Routes.matchLineupBuild('m_3'), Routes.matchLineupPick('m_3'), Routes.tournamentHub, Routes.createTournament,
      Routes.tournamentPublished('t_1'), Routes.myTournaments, Routes.tournamentDetails('t_1'),
      Routes.tournamentDashboard('t_1'), Routes.tournamentTeamsManage('t_1'), Routes.teamRequestDetail('t_1', 'r_1'),
      Routes.browseTournaments, Routes.tournamentRegister('t_1'), Routes.tournamentTeam('t_1'),
      Routes.tournamentTeamBuild('t_1'), Routes.tournamentTeamPick('t_1'), Routes.registrationSummary('t_1'),
      Routes.myRegistrations, Routes.registrationDetails('r_1'), Routes.registrationSuccess('r_1'),
      Routes.notifications, Routes.settings, Routes.privacySettings, Routes.securitySettings, Routes.roleSetup,
      Routes.continueAs, Routes.roleSelection, Routes.roleDetails, Routes.clubSetup, Routes.createClub,
      Routes.clubDetails, Routes.enterClubCode,
      Routes.waitingApproval, Routes.joinApproved,
    ];
    // Screen consolidation Phase A: pre-consolidation routes still resolve,
    // opening the workspace that replaced them in the right tab / mode /
    // section. Every other route stays where it is.
    final consolidated = <String, String>{
      Routes.tournamentDashboard('t_1'): '/club/tournaments/hosted/t_1',
      Routes.tournamentTeamsManage('t_1'): '/club/tournaments/hosted/t_1?tab=teams',
      Routes.privacySettings: '/settings?section=privacy',
      Routes.matchScorecard('pm_2'): '/player/matches/pm_2?tab=scorecard',
      Routes.matchHistory: '/player/performance?tab=history',
      Routes.editProfile: '/player/profile?edit=1',
      // Auth architecture update: old onboarding steps.
      Routes.continueAs: '/onboarding/role',
      Routes.roleDetails: '/onboarding/role?expand=player',
      Routes.createClub: '/setup/club',
      Routes.clubDetails: '/setup/club',
    };
    final router = c.read(routerProvider);
    for (final loc in clubLocations) {
      router.go(loc);
      await tester.pumpAndSettle();
      expect(_location(c), consolidated[loc] ?? loc, reason: 'route $loc');
      expect(tester.takeException(), isNull, reason: 'route $loc');
      expect(find.text('Not found'), findsNothing, reason: 'route $loc resolved to the error page');
    }

    c.read(roleControllerProvider.notifier).switchTo(UserRole.player);
    final playerLocations = <String>[
      Routes.playerHome, Routes.availability, Routes.openMatches, Routes.myMatches, Routes.playerMatchDetails('pm_2'),
      Routes.matchScorecard('pm_2'), Routes.myPerformance, Routes.matchHistory, Routes.playerProfile, Routes.editProfile,
    ];
    for (final loc in playerLocations) {
      router.go(loc);
      await tester.pumpAndSettle();
      expect(_location(c), consolidated[loc] ?? loc, reason: 'route $loc');
      expect(tester.takeException(), isNull, reason: 'route $loc');
      expect(find.text('Not found'), findsNothing, reason: 'route $loc resolved to the error page');
    }
    expect(consolidated.keys, everyElement(isIn([...clubLocations, ...playerLocations])),
        reason: 'every consolidated route is still smoke-tested');
  });
}
