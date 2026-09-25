import '../../core/enums/enums.dart';

/// Route locations. Names match the prototype screen keys; paths follow the
/// approved revised architecture §1. Entity ids always travel in the path.
abstract final class Routes {
  // Auth page (Login | Sign Up) and onboarding:
  // Auth → User Profile Setup → Role Selection → Player (expands in place)
  //                                             → Club Owner → Club Setup Details
  static const login = '/login';
  static const signup = '/signup';
  static const createAccount = '/signup/account';

  /// User Profile Setup (name, phone, date of birth, picture).
  static const completeProfile = '/onboarding/profile';
  static const profileSetup = completeProfile;

  /// Role Selection: Player (details expand on the same screen) or Club Owner.
  static const roleSelection = '/onboarding/role';

  /// Role Selection opened with the Player details expanded.
  static const roleSelectionPlayer = '$roleSelection?expand=player';

  /// Legacy (auth architecture update) → Role Selection, Player expanded.
  static const roleDetails = '/onboarding/playing-style';

  // Shared
  /// Legacy (auth architecture update) → Role Selection.
  static const continueAs = '/continue-as';
  static const roleSetup = '/role-setup';
  static const notifications = '/notifications';
  static const settings = '/settings';
  /// Legacy (consolidation Phase A) → Settings with Privacy expanded.
  static const privacySettings = '/settings/privacy';
  static const securitySettings = '/settings/security';

  // Club Owner setup + club membership (join by code)
  /// Club Setup Details (one screen: name, logo, owner, address, city, type,
  /// home ground) → Club Owner Dashboard.
  static const clubSetup = '/setup/club';

  /// Former "Set Up Your Club" chooser; the same path now opens Club Setup Details.
  static const chooseOption = clubSetup;

  /// Legacy (auth architecture update) → Club Setup Details.
  static const createClub = '/setup/club/create';

  /// Legacy (auth architecture update) → Club Setup Details.
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
  /// Legacy (consolidation Phase A) → Match workspace, Scorecard tab.
  static String matchScorecard(String matchId) => '/player/matches/$matchId/scorecard';
  static const myPerformance = '/player/performance';
  /// Legacy (consolidation Phase A) → Performance workspace, History tab.
  static const matchHistory = '/player/performance/history';
  static const playerProfile = '/player/profile';
  /// Legacy (consolidation Phase A) → My Profile in edit mode.
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
  /// Legacy (consolidation Phase A) → host workspace, Overview tab.
  static String tournamentDashboard(String id) => '/club/tournaments/hosted/$id/dashboard';
  /// Legacy (consolidation Phase A) → host workspace, Teams tab.
  static String tournamentTeamsManage(String id) => '/club/tournaments/hosted/$id/teams';
  static String teamRequestDetail(String id, String registrationId) =>
      '/club/tournaments/hosted/$id/teams/requests/$registrationId';
  static const browseTournaments = '/club/tournaments/browse';
  static String browseTournamentsIn(String city) =>
      '/club/tournaments/browse?city=${Uri.encodeQueryComponent(city)}';
  static String tournamentRegister(String id) => '/club/tournaments/browse/$id';
  static String tournamentTeam(String id) => '/club/tournaments/browse/$id/team';
  static String tournamentTeamBuild(String id) => '/club/tournaments/browse/$id/team/build';
  static String tournamentTeamPick(String id) => '/club/tournaments/browse/$id/team/pick';
  static String registrationSummary(String id) => '/club/tournaments/browse/$id/team/summary';
  static const myRegistrations = '/club/tournaments/registrations';
  static String myRegistrationsIn(RegistrationStatus tab) => '$myRegistrations?tab=${tab.name}';
  static String registrationDetails(String registrationId) => '/club/tournaments/registrations/$registrationId';
  static String registrationSuccess(String registrationId) =>
      '/club/tournaments/registrations/$registrationId/success';

  static String home(UserRole role) => role == UserRole.player ? playerHome : clubHome;

  static const publicRoutes = {login, signup, createAccount};
  /// Reachable while the common profile is incomplete.
  static const onboardingRoutes = {completeProfile};

  static bool isPlayerLocation(String path) => path == playerHome || path.startsWith('$playerHome/');
  static bool isClubLocation(String path) => path == clubHome || path.startsWith('$clubHome/');
}
