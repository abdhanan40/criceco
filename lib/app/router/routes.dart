import '../../core/enums/enums.dart';

/// Route locations. Names match the prototype screen keys; paths follow the
/// approved revised architecture §1. Entity ids always travel in the path.
abstract final class Routes {
  // Public / auth
  static const login = '/login';
  static const signup = '/signup';
  static const createAccount = '/signup/account';
  static const completeProfile = '/onboarding/profile';
  static const roleDetails = '/onboarding/playing-style';

  // Shared
  static const continueAs = '/continue-as';
  static const roleSetup = '/role-setup';
  static const notifications = '/notifications';
  static const settings = '/settings';
  static const privacySettings = '/settings/privacy';
  static const securitySettings = '/settings/security';

  // Club setup + membership onboarding
  static const chooseOption = '/setup/club';
  static const createClub = '/setup/club/create';
  static const clubDetails = '/setup/club/create/details';
  static const enterClubCode = '/join';
  static const waitingApproval = '/join/waiting';
  static const joinApproved = '/join/approved';

  // Player
  static const playerHome = '/player';
  static const availability = '/player/availability';
  static const openMatches = '/player/open-matches';
  static const myMatches = '/player/matches';
  static String playerMatchDetails(String matchId) => '/player/matches/$matchId';
  static String matchScorecard(String matchId) => '/player/matches/$matchId/scorecard';
  static const myPerformance = '/player/performance';
  static const matchHistory = '/player/performance/history';
  static const playerProfile = '/player/profile';
  static const editProfile = '/player/profile/edit';

  // Club Owner
  static const clubHome = '/club';
  static const teams = '/club/teams';
  static const createTeamLegacy = '/club/teams/new';
  static String teamSquad(String teamId) => '/club/teams/$teamId';
  static String addTeamPlayers(String teamId) => '/club/teams/$teamId/add-players';
  static const members = '/club/members';
  static const myClub = '/club/my-club';
  static const joinRequests = '/club/requests';
  static String joinRequestProfile(String requestId) => '/club/requests/$requestId';
  static const playerHunt = '/club/player-hunt';
  static const challenges = '/club/challenges';
  static const myChallenges = '/club/challenges/mine';
  static const findMatch = '/club/challenges/find';
  static const createAvailabilitySlot = '/club/challenges/slots/new';
  static String challengeAccepted(String challengeId) => '/club/challenges/$challengeId/accepted';
  static String clubProfile(String clubId) => '/club/clubs/$clubId';
  static String matchManagement([MatchTab? tab]) => tab == null ? '/club/matches' : '/club/matches?tab=${tab.name}';
  static String matchSetup(String matchId) => '/club/matches/$matchId/setup';
  static String bookGround(String matchId) => '/club/matches/$matchId/setup/ground';
  static String groundDetails(String matchId, String groundId) => '/club/matches/$matchId/setup/ground/$groundId';
  static String selectDate(String matchId, String groundId) => '/club/matches/$matchId/setup/ground/$groundId/schedule';
  static String bookingSummary(String matchId, String groundId) =>
      '/club/matches/$matchId/setup/ground/$groundId/schedule/summary';
  static String payment(String matchId) => '/club/matches/$matchId/payment';
  static String waitingForOpponent(String matchId) => '/club/matches/$matchId/waiting';
  static String opponentPayment(String matchId) => '/club/matches/$matchId/opponent-payment';
  static String bookingConfirmed(String matchId) => '/club/matches/$matchId/confirmed';
  static String reservationExpired(String matchId) => '/club/matches/$matchId/expired';
  static String matchLineup(String matchId) => '/club/matches/$matchId/lineup';
  static String matchLineupBuild(String matchId) => '/club/matches/$matchId/lineup/build';
  static String matchLineupPick(String matchId) => '/club/matches/$matchId/lineup/pick';
  static const tournamentHub = '/club/tournaments';
  static const createTournament = '/club/tournaments/new';
  static String tournamentPublished(String id) => '/club/tournaments/$id/published';
  static const myTournaments = '/club/tournaments/hosted';
  static String tournamentDetails(String id) => '/club/tournaments/hosted/$id';
  static String tournamentDashboard(String id) => '/club/tournaments/hosted/$id/dashboard';
  static String tournamentTeamsManage(String id) => '/club/tournaments/hosted/$id/teams';
  static String teamRequestDetail(String id, String registrationId) =>
      '/club/tournaments/hosted/$id/teams/requests/$registrationId';
  static const browseTournaments = '/club/tournaments/browse';
  static String tournamentRegister(String id) => '/club/tournaments/browse/$id';
  static String tournamentTeam(String id) => '/club/tournaments/browse/$id/team';
  static String tournamentTeamBuild(String id) => '/club/tournaments/browse/$id/team/build';
  static String tournamentTeamPick(String id) => '/club/tournaments/browse/$id/team/pick';
  static String registrationSummary(String id) => '/club/tournaments/browse/$id/team/summary';
  static const myRegistrations = '/club/tournaments/registrations';
  static String registrationDetails(String registrationId) => '/club/tournaments/registrations/$registrationId';
  static String registrationSuccess(String registrationId) =>
      '/club/tournaments/registrations/$registrationId/success';

  static String home(UserRole role) => role == UserRole.player ? playerHome : clubHome;

  static const publicRoutes = {login, signup, createAccount};
  static const onboardingRoutes = {completeProfile, roleDetails};

  static bool isPlayerLocation(String path) => path == playerHome || path.startsWith('$playerHome/');
  static bool isClubLocation(String path) => path == clubHome || path.startsWith('$clubHome/');
}
