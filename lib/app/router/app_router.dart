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
import '../../features/club_setup/choose_option_screen.dart';
import '../../features/club_setup/club_details_screen.dart';
import '../../features/club_setup/create_club_screen.dart';
import '../../features/matches/screens/lineup_screens.dart';
import '../../features/matches/screens/match_management_screen.dart';
import '../../features/membership/enter_club_code_screen.dart';
import '../../features/membership/join_status_screens.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/player/screens/availability_screen.dart';
import '../../features/player/screens/edit_profile_screen.dart';
import '../../features/player/screens/match_scorecard_screen.dart';
import '../../features/player/screens/my_matches_screen.dart';
import '../../features/player/screens/open_matches_screen.dart';
import '../../features/player/screens/performance_screens.dart';
import '../../features/player/screens/player_dashboard_screen.dart';
import '../../features/player/screens/player_match_details_screen.dart';
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
  GoRoute(path: Routes.notifications, builder: (_, _) => const NotificationsScreen()),
  GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen(), routes: [
    GoRoute(path: 'privacy', builder: (_, _) => const PrivacySettingsScreen()),
    GoRoute(path: 'security', builder: (_, _) => const SecuritySettingsScreen()),
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
          GoRoute(path: 'edit', parentNavigatorKey: rootNavigatorKey, builder: (_, _) => const EditProfileScreen()),
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

final List<RouteBase> _tournamentRoutes = [
  _full('tournaments', (_) => const TournamentHubScreen(), routes: [
    _full('new', (_) => const CreateTournamentScreen()),
    _full('hosted', (_) => const MyTournamentsScreen(), routes: [
      _full(':tournamentId',
          (s) => TournamentDetailsScreen(tournamentId: _tid(s), tab: TournamentTab.parse(s.uri.queryParameters['tab'])),
          routes: [
            _full('dashboard', (s) => TournamentDashboardScreen(tournamentId: _tid(s))),
            _full('teams', (s) => ManageTeamsScreen(tournamentId: _tid(s)), routes: [
              _full('requests/:registrationId',
                  (s) => TeamRequestDetailScreen(tournamentId: _tid(s), registrationId: _rid(s))),
            ]),
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
