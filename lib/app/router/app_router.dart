import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/enums/enums.dart';
import '../../features/auth/create_account_screen.dart';
import '../../features/auth/login_screen.dart';
import '../../features/auth/role_selection_screen.dart';
import '../../features/auth/role_setup_screen.dart';
import '../../features/auth/signup_screen.dart';
import '../../features/auth/user_profile_setup_screen.dart';
import '../../features/booking/screens/payment_screens.dart';
import '../../features/booking/screens/schedule_screens.dart';
import '../../features/booking/screens/setup_screens.dart';
import '../../features/challenges/screens/challenge_status_screen.dart';
import '../../features/challenges/screens/challenges_hub_screen.dart';
import '../../features/challenges/screens/club_profile_screen.dart';
import '../../features/challenges/screens/create_slot_screen.dart';
import '../../features/challenges/screens/my_challenges_screen.dart';
import '../../features/club/screens/add_team_players_screen.dart';
import '../../features/club/screens/club_dashboard_screen.dart';
import '../../features/club/screens/join_request_profile_screen.dart';
import '../../features/club/screens/join_requests_screen.dart';
import '../../features/club/screens/members_screen.dart';
import '../../features/club/screens/my_club_screen.dart';
import '../../features/club/screens/player_hunt_screen.dart';
import '../../features/club/screens/team_squad_screen.dart';
import '../../features/club/screens/teams_screen.dart';
import '../../features/club_setup/club_setup_screen.dart';
import '../../features/matches/screens/lineup_screens.dart';
import '../../features/matches/screens/match_management_screen.dart';
import '../../features/membership/enter_club_code_screen.dart';
import '../../features/membership/join_status_screens.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/player/screens/availability_screen.dart';
import '../../features/player/screens/my_matches_screen.dart';
import '../../features/player/screens/open_matches_screen.dart';
import '../../features/player/screens/performance_workspace.dart';
import '../../features/player/screens/player_dashboard_screen.dart';
import '../../features/player/screens/player_match_workspace.dart';
import '../../features/player/screens/player_profile_screen.dart';
import '../../features/settings/settings_screens.dart';
import '../../features/tournaments/screens/browse_screens.dart';
import '../../features/tournaments/screens/create_tournament_screen.dart';
import '../../features/tournaments/screens/hosted_screens.dart';
import '../../features/tournaments/screens/registration_screens.dart';
import '../../features/tournaments/screens/tournament_hub_screen.dart';
import '../../shared/navigation/not_found_screen.dart';
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

  // 1. Signed out → Auth (Login / Sign Up allowed).
  if (!session.isAuthenticated) return isPublic ? null : Routes.login;

  // 2. Common profile incomplete → User Profile Setup. Auth screens stay
  //    reachable so Back from Profile Setup returns to Create Account / Sign Up.
  if (session.status == SessionStatus.onboarding) {
    return (isOnboarding || isPublic) ? null : Routes.profileSetup;
  }

  // 3. Profile complete: auth and profile setup are behind the user. Enter
  //    the active role — or, for a returning user, the single completed role
  //    ([activeRole] is inferred from saved setup state) — else Role Selection.
  if (isPublic || isOnboarding) return activeRole == null ? Routes.roleSelection : Routes.home(activeRole);

  final isPlayer = Routes.isPlayerLocation(location);
  final isClub = Routes.isClubLocation(location);
  if (isPlayer || isClub) {
    // 4. No role chosen or set up yet → Role Selection.
    if (activeRole == null) return Routes.roleSelection;
    // 5. Navigation never changes the role: wrong-role locations bounce to
    //    the active role's home (checked first, so a Player is never sent
    //    into Club Owner setup by a stray link).
    if (isPlayer && activeRole != UserRole.player) return Routes.home(activeRole);
    if (isClub && activeRole != UserRole.clubOwner) return Routes.home(activeRole);
    // 6. Club routes need a Club Owner profile.
    if (isClub && !session.hasClubOwnerProfile) return Routes.clubSetup;
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
    errorBuilder: (context, state) => const NotFoundScreen(),
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

/// Role homes fade in (prototype 160 ms role-switch fade).
Page<void> _fade(Widget child, GoRouterState state) => CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: CeMotion.roleSwitchFade,
      transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: a, child: c),
    );

final List<RouteBase> appRoutes = [
  // ---- Auth page + onboarding (auth architecture update) ----
  // Auth (Login | Sign Up) → User Profile Setup → Role Selection
  //   → Player: details expand on Role Selection → Player Dashboard
  //   → Club Owner: Club Setup Details → Club Owner Dashboard
  GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
  GoRoute(path: Routes.signup, builder: (_, _) => const SignupScreen(), routes: [
    GoRoute(path: 'account', builder: (_, _) => const CreateAccountScreen()),
  ]),
  GoRoute(path: Routes.profileSetup, builder: (_, _) => const UserProfileSetupScreen()),
  GoRoute(
    path: Routes.roleSelection,
    builder: (_, s) => RoleSelectionScreen(expandPlayer: s.uri.queryParameters['expand'] == 'player'),
  ),
  // Old onboarding steps kept for deep links / bookmarks only.
  _legacy(Routes.roleDetails, (_) => Routes.roleSelectionPlayer), // Playing Style
  _legacy(Routes.continueAs, (_) => Routes.roleSelection), // Continue As

  // ---- Shared ----
  GoRoute(path: Routes.roleSetup, builder: (_, _) => const RoleSetupScreen()),
  GoRoute(path: Routes.notifications, builder: (_, _) => const NotificationsScreen()),
  // Settings with the Privacy section inline (`?section=privacy` expands it).
  GoRoute(
    path: Routes.settings,
    builder: (_, s) => SettingsScreen(privacyExpanded: s.uri.queryParameters['section'] == 'privacy'),
    routes: [
      _legacy('privacy', (_) => SettingsScreen.privacyLocation),
      GoRoute(path: 'security', builder: (_, _) => const SecuritySettingsScreen()),
    ],
  ),

  // ---- Club Owner setup (one screen) + club membership by code ----
  GoRoute(path: Routes.clubSetup, builder: (_, _) => const ClubSetupScreen(), routes: [
    // Former Create Club → Club Details steps, kept for compatibility.
    _legacy('create', (_) => Routes.clubSetup),
    _legacy('create/details', (_) => Routes.clubSetup),
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
            // Player Match workspace: Details | Scorecard in `?tab=`.
            GoRoute(
              path: ':matchId',
              builder: (_, s) => PlayerMatchWorkspace(
                matchId: s.pathParameters['matchId']!,
                tab: PlayerMatchView.parse(s.uri.queryParameters['tab']),
              ),
              routes: [
                _legacy('scorecard', (s) => PlayerMatchView.scorecard.location(s.pathParameters['matchId']!)),
              ],
            ),
          ],
        ),
      ]),
      StatefulShellBranch(routes: [
        // Performance workspace: Overview | History in `?tab=`.
        GoRoute(
          path: Routes.myPerformance,
          builder: (_, s) => PerformanceWorkspace(tab: PerformanceView.parse(s.uri.queryParameters['tab'])),
          routes: [_legacy('history', (_) => PerformanceView.history.location)],
        ),
      ]),
      StatefulShellBranch(routes: [
        // My Profile with inline edit mode (`?edit=1`).
        GoRoute(
          path: Routes.playerProfile,
          builder: (_, s) => PlayerProfileScreen(editing: s.uri.queryParameters['edit'] == '1'),
          routes: [_legacy('edit', (_) => '${Routes.playerProfile}?edit=1')],
        ),
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
          pageBuilder: (_, s) => _fade(const ClubDashboardScreen(), s),
          routes: _clubFullRoutes,
        ),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: Routes.teams, builder: (_, _) => const TeamsScreen(), routes: [
          GoRoute(path: 'new', redirect: (_, _) => Routes.teams), // legacy createTeam (P17)
          GoRoute(
            path: ':teamId',
            builder: (_, s) => TeamSquadScreen(teamId: s.pathParameters['teamId']!),
            routes: [
              GoRoute(
                path: 'add-players',
                parentNavigatorKey: rootNavigatorKey,
                builder: (_, s) => AddTeamPlayersScreen(teamId: s.pathParameters['teamId']!),
              ),
            ],
          ),
        ]),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: Routes.members, builder: (_, _) => const MembersScreen()),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: Routes.myClub, builder: (_, _) => const MyClubScreen()),
      ]),
    ],
  ),
];

/// Club Owner routes shown full-screen (no bottom nav), stacked on the
/// dashboard so Back always returns along the path hierarchy.
final List<RouteBase> _clubFullRoutes = [
  GoRoute(
    path: 'requests',
    parentNavigatorKey: rootNavigatorKey,
    builder: (_, s) => JoinRequestsScreen(tab: JoinRequestsScreen.parseTab(s.uri.queryParameters['tab'])),
    routes: [
      GoRoute(
        path: ':requestId',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => JoinRequestProfileScreen(requestId: s.pathParameters['requestId']!),
      ),
    ],
  ),
  GoRoute(
    path: 'player-hunt',
    parentNavigatorKey: rootNavigatorKey,
    builder: (_, s) => PlayerHuntScreen(tab: HuntTab.parse(s.uri.queryParameters['tab'])),
  ),
  GoRoute(
    path: 'challenges',
    parentNavigatorKey: rootNavigatorKey,
    builder: (_, _) => const ChallengesHubScreen(),
    routes: [
      GoRoute(path: 'mine', parentNavigatorKey: rootNavigatorKey, builder: (_, _) => const MyChallengesScreen()),
      GoRoute(path: 'find', parentNavigatorKey: rootNavigatorKey, builder: (_, _) => const FindMatchScreen()),
      GoRoute(path: 'slots/new', parentNavigatorKey: rootNavigatorKey, builder: (_, _) => const CreateSlotScreen()),
      GoRoute(
        path: ':challengeId/accepted',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => ChallengeStatusScreen(challengeId: s.pathParameters['challengeId']!),
      ),
    ],
  ),
  GoRoute(
    path: 'clubs/:clubId',
    parentNavigatorKey: rootNavigatorKey,
    builder: (_, s) => ClubProfileScreen(clubId: s.pathParameters['clubId']!),
  ),
  GoRoute(
    path: 'matches',
    parentNavigatorKey: rootNavigatorKey,
    builder: (_, s) => MatchManagementScreen(tab: MatchManagementScreen.parseTab(s.uri.queryParameters['tab'])),
    routes: [
      GoRoute(
        path: ':matchId/setup',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => MatchSetupScreen(matchId: s.pathParameters['matchId']!),
        routes: [
          GoRoute(
            path: 'ground',
            parentNavigatorKey: rootNavigatorKey,
            builder: (_, s) => BookGroundScreen(matchId: s.pathParameters['matchId']!),
            routes: [
              GoRoute(
                path: ':groundId',
                parentNavigatorKey: rootNavigatorKey,
                builder: (_, s) =>
                    GroundDetailsScreen(matchId: s.pathParameters['matchId']!, groundId: s.pathParameters['groundId']!),
                routes: [
                  GoRoute(
                    path: 'schedule',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (_, s) =>
                        SelectDateScreen(matchId: s.pathParameters['matchId']!, groundId: s.pathParameters['groundId']!),
                    routes: [
                      GoRoute(
                        path: 'summary',
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (_, s) => BookingSummaryScreen(
                            matchId: s.pathParameters['matchId']!, groundId: s.pathParameters['groundId']!),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: ':matchId/payment',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => PaymentScreen(matchId: s.pathParameters['matchId']!),
      ),
      GoRoute(
        path: ':matchId/waiting',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => WaitingForOpponentScreen(matchId: s.pathParameters['matchId']!),
      ),
      GoRoute(
        path: ':matchId/opponent-payment',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => OpponentPaymentScreen(matchId: s.pathParameters['matchId']!),
      ),
      GoRoute(
        path: ':matchId/confirmed',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => BookingConfirmedScreen(matchId: s.pathParameters['matchId']!),
      ),
      GoRoute(
        path: ':matchId/expired',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => ReservationExpiredScreen(matchId: s.pathParameters['matchId']!),
      ),
      GoRoute(
        path: ':matchId/lineup',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => SelectTeamScreen(matchId: s.pathParameters['matchId']!),
        routes: [
          GoRoute(
            path: 'build',
            parentNavigatorKey: rootNavigatorKey,
            builder: (_, s) => TeamBuilderScreen(matchId: s.pathParameters['matchId']!),
          ),
          GoRoute(
            path: 'pick',
            parentNavigatorKey: rootNavigatorKey,
            builder: (_, s) => TeamPickerScreen(matchId: s.pathParameters['matchId']!),
          ),
        ],
      ),
    ],
  ),
  ..._tournamentRoutes,
];

/// Tournaments (revised architecture §9). Every screen is a full route over
/// the club shell; ids travel in the path, tabs / filters in the query.
String _tid(GoRouterState s) => s.pathParameters['tournamentId']!;
String _rid(GoRouterState s) => s.pathParameters['registrationId']!;

GoRoute _full(String path, Widget Function(GoRouterState s) build, {List<RouteBase> routes = const []}) => GoRoute(
      path: path,
      parentNavigatorKey: rootNavigatorKey,
      builder: (_, s) => build(s),
      routes: routes,
    );

/// A pre-consolidation route kept for compatibility (deep links,
/// notifications, bookmarks): it builds no page and redirects to the
/// workspace location that replaced it. Keep it childless: go_router can't
/// rebuild the location on Back through a page-less intermediate route.
/// The redirect fires only when this route is the leaf.
GoRoute _legacy(String path, String Function(GoRouterState s) target) => GoRoute(
      path: path,
      redirect: (_, s) => s.uri.path == s.matchedLocation ? target(s) : null,
    );

/// Host workspace tab: `?tab=`, or Teams while a team request is open on top.
TournamentTab _hostTab(GoRouterState s) =>
    s.uri.path.contains('/teams/') ? TournamentTab.teams : TournamentTab.parse(s.uri.queryParameters['tab']);

final List<RouteBase> _tournamentRoutes = [
  _full('tournaments', (_) => const TournamentHubScreen(), routes: [
    _full('new', (_) => const CreateTournamentScreen()),
    _full('hosted', (_) => const MyTournamentsScreen(), routes: [
      // Tournament host workspace: Overview | Teams | Fixtures | Points Table.
      // Under a request (`…/teams/requests/:rid`, URL unchanged) the
      // workspace page below shows the Teams tab. The request route sits
      // beside the legacy `teams` redirect, not under it, so no page-less
      // route is ever an intermediate match.
      _full(':tournamentId', (s) => TournamentDetailsScreen(tournamentId: _tid(s), tab: _hostTab(s)), routes: [
        _legacy('dashboard', (s) => TournamentTab.overview.location(_tid(s))),
        _legacy('teams', (s) => TournamentTab.teams.location(_tid(s))),
        _full('teams/requests/:registrationId',
            (s) => TeamRequestDetailScreen(tournamentId: _tid(s), registrationId: _rid(s))),
      ]),
    ]),
    _full('browse', (s) => BrowseTournamentsScreen(city: s.uri.queryParameters['city']), routes: [
      _full(':tournamentId', (s) => TournamentRegisterScreen(tournamentId: _tid(s)), routes: [
        _full('team', (s) => TournamentSelectTeamScreen(tournamentId: _tid(s)), routes: [
          _full('build', (s) => TournamentTeamBuilderScreen(tournamentId: _tid(s))),
          _full('pick', (s) => TournamentTeamPickerScreen(tournamentId: _tid(s))),
          _full('summary', (s) => RegistrationSummaryScreen(tournamentId: _tid(s))),
        ]),
      ]),
    ]),
    _full('registrations',
        (s) => MyRegistrationsScreen(tab: MyRegistrationsScreen.parseTab(s.uri.queryParameters['tab'])),
        routes: [
          _full(':registrationId', (s) => RegistrationDetailsScreen(registrationId: _rid(s)), routes: [
            _full('success', (s) => RegistrationSuccessScreen(registrationId: _rid(s))),
          ]),
        ]),
    // Declared after the static children so they win matching.
    _full(':tournamentId/published', (s) => TournamentPublishedScreen(tournamentId: _tid(s))),
  ]),
];
