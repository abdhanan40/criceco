import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/enums/enums.dart';
import '../../features/auth/complete_profile_screen.dart';
import '../../features/auth/continue_as_screen.dart';
import '../../features/auth/create_account_screen.dart';
import '../../features/auth/login_screen.dart';
import '../../features/auth/playing_style_screen.dart';
import '../../features/auth/role_setup_screen.dart';
import '../../features/auth/signup_screen.dart';
import '../../features/club_setup/choose_option_screen.dart';
import '../../features/club_setup/club_details_screen.dart';
import '../../features/club_setup/create_club_screen.dart';
import '../../features/membership/enter_club_code_screen.dart';
import '../../features/membership/join_status_screens.dart';
import '../../features/player/screens/availability_screen.dart';
import '../../features/player/screens/match_scorecard_screen.dart';
import '../../features/player/screens/my_matches_screen.dart';
import '../../features/player/screens/open_matches_screen.dart';
import '../../features/player/screens/performance_screens.dart';
import '../../features/player/screens/player_dashboard_screen.dart';
import '../../features/player/screens/player_match_details_screen.dart';
import '../../features/player/screens/player_profile_screen.dart';
import '../../shared/navigation/placeholder_screen.dart';
import '../../shared/navigation/role_shells.dart';
import '../session/role_controller.dart';
import '../session/session_controller.dart';
import '../theme/tokens.dart';
import 'routes.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Pure redirect rules (approved revised architecture §4.4) — unit tested.
String? resolveRedirect({
  required String location,
  required SessionState session,
  required UserRole? activeRole,
}) {
  final isPublic = Routes.publicRoutes.contains(location);
  final isOnboarding = Routes.onboardingRoutes.contains(location);

  // 1. Signed out → Login (public routes allowed).
  if (!session.isAuthenticated) return isPublic ? null : Routes.login;

  // 2. Onboarding incomplete → Complete Profile. Auth screens stay reachable
  //    so Back from Complete Profile can return to Create Account / Sign Up.
  if (session.status == SessionStatus.onboarding) {
    return (isOnboarding || isPublic) ? null : Routes.completeProfile;
  }

  // 6. Authenticated users never see auth screens.
  if (isPublic || isOnboarding) return activeRole == null ? Routes.continueAs : Routes.home(activeRole);

  final isPlayer = Routes.isPlayerLocation(location);
  final isClub = Routes.isClubLocation(location);
  if (isPlayer || isClub) {
    // 3. No active role → Continue As.
    if (activeRole == null) return Routes.continueAs;
    // 4. Navigation never changes the role: wrong-role locations bounce to
    //    the active role's home (checked first, so a Player is never sent
    //    into Club Owner setup by a stray link).
    if (isPlayer && activeRole != UserRole.player) return Routes.home(activeRole);
    if (isClub && activeRole != UserRole.clubOwner) return Routes.home(activeRole);
    // 5. Club routes need a Club Owner profile.
    if (isClub && !session.hasClubOwnerProfile) return Routes.chooseOption;
  }
  return null;
}

/// Re-runs redirects whenever session or role changes.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(sessionProvider, (_, _) => notifyListeners());
    ref.listen(activeRoleProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: Routes.login,
    refreshListenable: refresh,
    redirect: (context, state) => resolveRedirect(
      location: state.uri.path,
      session: ref.read(sessionProvider),
      activeRole: ref.read(activeRoleProvider),
    ),
    routes: appRoutes,
    errorBuilder: (context, state) => const PlaceholderScreen(
      title: 'Not found',
      screenKey: 'ceNotFound',
      fallbackLocation: Routes.continueAs,
    ),
  );
  // Remember each role's last top-level destination (prototype ceLastScreen).
  void record() => ref
      .read(roleControllerProvider.notifier)
      .recordLocation(router.routerDelegate.currentConfiguration.uri.path);
  router.routerDelegate.addListener(record);
  ref.onDispose(() {
    router.routerDelegate.removeListener(record);
    router.dispose();
    refresh.dispose();
  });
  return router;
});

// ---------------------------------------------------------------------------
// Route table
// ---------------------------------------------------------------------------

GoRoute _ph(
  String path,
  String title,
  String key, {
  String? fallback,
  String? terminal,
  bool root = false,
  bool menu = false,
  List<PlaceholderLink> links = const [],
  List<RouteBase> routes = const [],
}) =>
    GoRoute(
      path: path,
      parentNavigatorKey: root ? rootNavigatorKey : null,
      builder: (_, _) => PlaceholderScreen(
        title: title,
        screenKey: key,
        showMenu: menu,
        fallbackLocation: fallback,
        terminalRedirect: terminal,
        links: links,
      ),
      routes: routes,
    );

/// Role homes fade in (prototype 160 ms role-switch fade).
Page<void> _fade(Widget child, GoRouterState state) => CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: CeMotion.roleSwitchFade,
      transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: a, child: c),
    );

final List<RouteBase> appRoutes = [
  // ---- Public / auth (Phase 1: migrated) ----
  GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
  GoRoute(path: Routes.signup, builder: (_, _) => const SignupScreen(), routes: [
    GoRoute(path: 'account', builder: (_, _) => const CreateAccountScreen()),
  ]),
  GoRoute(path: Routes.completeProfile, builder: (_, _) => const CompleteProfileScreen()),
  GoRoute(path: Routes.roleDetails, builder: (_, _) => const PlayingStyleScreen()),

  // ---- Shared ----
  GoRoute(path: Routes.continueAs, builder: (_, _) => const ContinueAsScreen()),
  GoRoute(path: Routes.roleSetup, builder: (_, _) => const RoleSetupScreen()),
  _ph(Routes.notifications, 'Notifications', 'notifications', fallback: Routes.continueAs),
  _ph(Routes.settings, 'Settings', 'settings', fallback: Routes.continueAs, links: const [
    PlaceholderLink('Privacy', Routes.privacySettings),
    PlaceholderLink('Password & security', Routes.securitySettings),
  ], routes: [
    _ph('privacy', 'Privacy', 'privacySettings', fallback: Routes.settings),
    _ph('security', 'Password & security', 'securitySettings', fallback: Routes.settings),
  ]),

  // ---- Club setup + membership onboarding (Phase 1: migrated) ----
  GoRoute(path: Routes.chooseOption, builder: (_, _) => const ChooseOptionScreen(), routes: [
    GoRoute(path: 'create', builder: (_, _) => const CreateClubScreen(), routes: [
      GoRoute(path: 'details', builder: (_, _) => const ClubDetailsScreen()),
    ]),
  ]),
  GoRoute(path: Routes.enterClubCode, builder: (_, _) => const EnterClubCodeScreen(), routes: [
    GoRoute(path: 'waiting', builder: (_, _) => const WaitingApprovalScreen()),
    GoRoute(path: 'approved', builder: (_, _) => const JoinApprovedScreen()),
  ]),

  // ---- Player shell: Home · Matches · Performance · Profile (Phase 2: migrated) ----
  StatefulShellRoute.indexedStack(
    builder: (_, _, shell) => RoleShellScaffold(shell: shell, items: RoleNavItems.player),
    branches: [
      StatefulShellBranch(routes: [
        GoRoute(
          path: Routes.playerHome,
          pageBuilder: (_, s) => _fade(const PlayerDashboardScreen(), s),
          routes: [
            GoRoute(path: 'availability', builder: (_, _) => const AvailabilityScreen()),
            GoRoute(path: 'open-matches', builder: (_, _) => const OpenMatchesScreen()),
          ],
        ),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(
          path: Routes.myMatches,
          builder: (_, s) => MyMatchesScreen(tab: MyMatchesScreen.parseTab(s.uri.queryParameters['tab'])),
          routes: [
            GoRoute(
              path: ':matchId',
              builder: (_, s) => PlayerMatchDetailsScreen(matchId: s.pathParameters['matchId']!),
              routes: [
                GoRoute(
                  path: 'scorecard',
                  builder: (_, s) => MatchScorecardScreen(matchId: s.pathParameters['matchId']!),
                ),
              ],
            ),
          ],
        ),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: Routes.myPerformance, builder: (_, _) => const MyPerformanceScreen(), routes: [
          GoRoute(path: 'history', builder: (_, _) => const MatchHistoryScreen()),
        ]),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: Routes.playerProfile, builder: (_, _) => const PlayerProfileScreen(), routes: [
          // Edit Profile is migrated with Profile & Settings (Phase 8).
          _ph('edit', 'Edit profile', 'editProfile', root: true, fallback: Routes.playerProfile),
        ]),
      ]),
    ],
  ),

  // ---- Club Owner shell: Home · Teams · Members · Profile (→ My Club) ----
  StatefulShellRoute.indexedStack(
    builder: (_, _, shell) => RoleShellScaffold(shell: shell, items: RoleNavItems.club),
    branches: [
      StatefulShellBranch(routes: [
        GoRoute(
          path: Routes.clubHome,
          pageBuilder: (_, s) => _fade(
            const PlaceholderScreen(title: 'Club Owner Dashboard', screenKey: 'clubHome', showMenu: true, links: [
              PlaceholderLink('Requests', Routes.joinRequests),
              PlaceholderLink('Challenges', Routes.challenges),
              PlaceholderLink('Player Hunt', Routes.playerHunt),
              PlaceholderLink('Match Management', '/club/matches'),
              PlaceholderLink('Tournament', Routes.tournamentHub),
            ]),
            s,
          ),
          routes: _clubFullRoutes,
        ),
      ]),
      StatefulShellBranch(routes: [
        _ph(Routes.teams, 'My Teams', 'teams', fallback: Routes.clubHome, routes: [
          GoRoute(path: 'new', redirect: (_, _) => Routes.teams), // legacy createTeam (P17)
          _ph(':teamId', 'Team Squad', 'teamSquad', fallback: Routes.teams, routes: [
            _ph('add-players', 'Add Players', 'addTeamPlayers', root: true, fallback: Routes.teams),
          ]),
        ]),
      ]),
      StatefulShellBranch(routes: [
        _ph(Routes.members, 'Members', 'members', fallback: Routes.clubHome),
      ]),
      StatefulShellBranch(routes: [
        _ph(Routes.myClub, 'My Club', 'myClub', fallback: Routes.clubHome),
      ]),
    ],
  ),
];

/// Club Owner routes shown full-screen (no bottom nav), stacked on the
/// dashboard so Back always returns along the path hierarchy.
final List<RouteBase> _clubFullRoutes = [
  _ph('requests', 'Requests', 'joinRequests', root: true, fallback: Routes.clubHome, routes: [
    _ph(':requestId', 'Player Profile', 'joinRequestProfile', root: true, fallback: Routes.joinRequests),
  ]),
  _ph('player-hunt', 'Open Players', 'openPlayers', root: true, fallback: Routes.clubHome),
  _ph('challenges', 'Challenges', 'challenges', root: true, fallback: Routes.clubHome, links: const [
    PlaceholderLink('My Challenges', Routes.myChallenges),
    PlaceholderLink('Find Match', Routes.findMatch),
    PlaceholderLink('Create Availability Slot', Routes.createAvailabilitySlot),
    PlaceholderLink('Opponent club profile', '/club/clubs/club_kk'),
  ], routes: [
    _ph('mine', 'Challenges', 'myChallenges', root: true, fallback: Routes.challenges),
    _ph('find', 'Find a Match', 'findMatch', root: true, fallback: Routes.challenges),
    _ph('slots/new', 'Create Availability Slot', 'createAvailabilitySlot', root: true, fallback: Routes.challenges),
    _ph(':challengeId/accepted', 'Challenge Status', 'challengeAccepted',
        root: true, terminal: '/club/matches?tab=waiting'),
  ]),
  _ph('clubs/:clubId', 'Club Profile', 'clubProfile', root: true, fallback: Routes.challenges),
  _ph('matches', 'Upcoming Matches', 'upcomingMatches', root: true, fallback: Routes.clubHome, links: const [
    PlaceholderLink('Pending match → Match Setup', '/club/matches/m_3/setup'),
  ], routes: [
    _ph(':matchId/setup', 'Match Setup', 'matchSetup', root: true, fallback: '/club/matches', routes: [
      _ph('ground', 'Book a Ground', 'bookGround', root: true, fallback: '/club/matches', routes: [
        _ph(':groundId', 'Ground Details', 'groundDetails', root: true, fallback: '/club/matches', routes: [
          _ph('schedule', 'Select Date & Time', 'selectDate', root: true, fallback: '/club/matches', routes: [
            _ph('summary', 'Booking Summary', 'bookingSummary', root: true, fallback: '/club/matches'),
          ]),
        ]),
      ]),
    ]),
    _ph(':matchId/payment', 'Pay Your Share', 'payment', root: true, fallback: '/club/matches'),
    _ph(':matchId/waiting', 'Waiting for Opponent', 'waitingForOpponent', root: true, terminal: '/club/matches'),
    _ph(':matchId/opponent-payment', 'Opponent Payment', 'opponentPayment', root: true, terminal: '/club/matches'),
    _ph(':matchId/confirmed', 'Booking Confirmed', 'bookingConfirmed',
        root: true, terminal: '/club/matches?tab=scheduled'),
    _ph(':matchId/expired', 'Reservation Expired', 'reservationExpired',
        root: true, terminal: '/club/matches?tab=waiting'),
    _ph(':matchId/lineup', 'Select Team', 'selectTeam', root: true, fallback: '/club/matches', routes: [
      _ph('build', 'Build Your Team', 'teamBuilder', root: true, fallback: '/club/matches'),
      _ph('pick', 'Select Existing Team', 'teamPicker', root: true, fallback: '/club/matches'),
    ]),
  ]),
  _ph('tournaments', 'Tournament', 'hostTournament', root: true, fallback: Routes.clubHome, links: const [
    PlaceholderLink('Create Tournament', Routes.createTournament),
    PlaceholderLink('Browse Tournaments', Routes.browseTournaments),
    PlaceholderLink('My Tournaments', Routes.myTournaments),
    PlaceholderLink('My Registrations', Routes.myRegistrations),
  ], routes: [
    _ph('new', 'Create Tournament', 'createTournament', root: true, fallback: Routes.tournamentHub),
    _ph('hosted', 'My Tournaments', 'myTournaments', root: true, fallback: Routes.tournamentHub, routes: [
      _ph(':tournamentId', 'Tournament Details', 'tournamentDetails', root: true, fallback: Routes.myTournaments, routes: [
        _ph('dashboard', 'Tournament Dashboard', 'tournamentDashboard', root: true, fallback: Routes.myTournaments),
        _ph('teams', 'Manage Teams', 'tournamentTeamsManage', root: true, fallback: Routes.myTournaments, routes: [
          _ph('requests/:registrationId', 'Registration Request', 'teamRequestDetail',
              root: true, fallback: Routes.myTournaments),
        ]),
      ]),
    ]),
    _ph('browse', 'Browse Tournaments', 'browseTournaments', root: true, fallback: Routes.tournamentHub, routes: [
      _ph(':tournamentId', 'Tournament', 'tournamentRegister', root: true, fallback: Routes.browseTournaments, routes: [
        _ph('team', 'Select Team', 'selectTeam (tournament)', root: true, fallback: Routes.browseTournaments, routes: [
          _ph('build', 'Build Your Team', 'teamBuilder (tournament)', root: true, fallback: Routes.browseTournaments),
          _ph('pick', 'Select Existing Team', 'teamPicker (tournament)', root: true, fallback: Routes.browseTournaments),
          _ph('summary', 'Registration Summary', 'registrationSummary', root: true, fallback: Routes.browseTournaments),
        ]),
      ]),
    ]),
    _ph('registrations', 'My Registrations', 'myRegistrations', root: true, fallback: Routes.tournamentHub, routes: [
      _ph(':registrationId', 'Registration Details', 'registrationDetails',
          root: true, fallback: Routes.myRegistrations, routes: [
        _ph('success', 'Registration Status', 'registrationSuccess', root: true, terminal: Routes.myRegistrations),
      ]),
    ]),
    // Declared after the static children so they win matching.
    _ph(':tournamentId/published', 'Tournament Status', 'tournamentPublished',
        root: true, terminal: Routes.tournamentHub),
  ]),
];
