import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';

/// The memberships switch as built: `--dart-define=CRICECO_MEMBERSHIPS=true`
/// once migrations 11 (club memberships) and 12 (teams) are live on the
/// Supabase project. OFF by default: before those migrations the functions
/// the membership and team screens call don't exist, so a Supabase build
/// without the switch shows those modules as "not available yet" instead.
const bool kMembershipsBuild = bool.fromEnvironment('CRICECO_MEMBERSHIPS');

/// The memberships switch: [kMembershipsBuild], overridden in tests.
final membershipsEnabledProvider = Provider<bool>((ref) => kMembershipsBuild);

/// The matches switch as built: `--dart-define=CRICECO_MATCHES=true` once
/// migrations 17–19 (challenges and matches, lineups, player availability)
/// are live on the Supabase project. OFF by default — and it needs the
/// memberships switch too: before those migrations the functions don't
/// exist, so the match, challenge and availability screens stay "not
/// available yet". Turn it on only with the P4–P6 screens (docs/MATCHES_BACKEND.md).
const bool kMatchesBuild = bool.fromEnvironment('CRICECO_MATCHES');

/// The matches switch: [kMatchesBuild], overridden in tests.
final matchesEnabledProvider = Provider<bool>((ref) => kMatchesBuild);

/// The results switch as built: `--dart-define=CRICECO_RESULTS=true` once
/// migrations 20–23 (results, scorecards, player statistics, my_matches)
/// are live on the Supabase project. OFF by default — and it needs the
/// memberships and matches switches too. It selects the results data layer
/// ([resultsBackendLiveProvider]) and the [BackendModule.matchStats] screens
/// (official results, scorecards and statistics — display only;
/// docs/MATCH_RESULTS_BACKEND.md).
const bool kResultsBuild = bool.fromEnvironment('CRICECO_RESULTS');

/// The results switch: [kResultsBuild], overridden in tests.
final resultsEnabledProvider = Provider<bool>((ref) => kResultsBuild);

/// The notifications switch as built: `--dart-define=CRICECO_NOTIFICATIONS=true`
/// once migration 25 (the server inbox and club announcements) is live on
/// the Supabase project. OFF by default — and it needs the memberships switch
/// too (every notification is about a club). It selects the server inbox
/// ([notificationsBackendLiveProvider]) and the [BackendModule.notifications]
/// and [BackendModule.announcements] screens (docs/NOTIFICATIONS_BACKEND.md).
const bool kNotificationsBuild = bool.fromEnvironment('CRICECO_NOTIFICATIONS');

/// The notifications switch: [kNotificationsBuild], overridden in tests.
final notificationsEnabledProvider = Provider<bool>((ref) => kNotificationsBuild);

/// The fitness switch as built: `--dart-define=CRICECO_FITNESS=true` once
/// migration 34 (logged workouts and the owner's squad fitness view) is live
/// on the Supabase project. OFF by default — and it needs the memberships,
/// matches and results switches too: the Fitness Meter is worked out from the
/// player's official match log (results), their availability (matches) and
/// their logged workouts, and the owner's view is per club member. It selects
/// the fitness data layer ([fitnessBackendLiveProvider]) and the
/// [BackendModule.playerStats] screens (docs/M9_FITNESS.md).
const bool kFitnessBuild = bool.fromEnvironment('CRICECO_FITNESS');

/// The fitness switch: [kFitnessBuild], overridden in tests.
final fitnessEnabledProvider = Provider<bool>((ref) => kFitnessBuild);

/// The club-discovery switch as built: `--dart-define=CRICECO_DISCOVERY=true`
/// once migration 32 (public club profiles and directory, availability
/// slots, the shared player rankings and the applicants' statistics) is live
/// on the Supabase project. OFF by default — and it needs the memberships and
/// matches switches too: Find Opponent, the club profile and the slots belong
/// to the challenge screens (docs/M7_CLUB_DISCOVERY.md). It adds no module: it
/// selects the server data behind screens that already exist
/// ([discoveryBackendLiveProvider]).
const bool kDiscoveryBuild = bool.fromEnvironment('CRICECO_DISCOVERY');

/// The club-discovery switch: [kDiscoveryBuild], overridden in tests.
final discoveryEnabledProvider = Provider<bool>((ref) => kDiscoveryBuild);

/// The Player Hunt switch as built: `--dart-define=CRICECO_PLAYER_HUNT=true`
/// once migration 33 (player listings, requirement posts, interest and
/// invites) is live on the Supabase project. OFF by default — and it needs
/// the memberships switch too. It selects the hunt data layer
/// ([huntBackendLiveProvider]) and the [BackendModule.playerHunt] screens
/// (docs/M8_PLAYER_HUNT.md).
const bool kPlayerHuntBuild = bool.fromEnvironment('CRICECO_PLAYER_HUNT');

/// The Player Hunt switch: [kPlayerHuntBuild], overridden in tests.
final playerHuntEnabledProvider = Provider<bool>((ref) => kPlayerHuntBuild);

/// The tournaments switch as built: `--dart-define=CRICECO_TOURNAMENTS=true`
/// once migration 35 (tournaments, entries and squads, the draw, the points
/// table and the awards) is live on the Supabase project. OFF by default —
/// and it needs the memberships switch too (an entry is a club's squad). It
/// selects the tournament data layer ([tournamentsBackendLiveProvider]) and
/// the [BackendModule.tournaments] screens (docs/M10_TOURNAMENTS.md).
const bool kTournamentsBuild = bool.fromEnvironment('CRICECO_TOURNAMENTS');

/// The tournaments switch: [kTournamentsBuild], overridden in tests.
final tournamentsEnabledProvider = Provider<bool>((ref) => kTournamentsBuild);

/// App areas whose data needs a backend.
enum BackendModule {
  memberships('Club memberships'),
  teams('Teams and squads'),
  matches('Matches'),
  /// Official match results, scorecards and player statistics (migrations
  /// 20–23, the results switch). Read-only: they come from a trusted
  /// source, never typed in the app.
  matchStats('Match results and statistics'),
  /// Fitness records and the player's own stats settings (migration 34, the
  /// fitness switch).
  playerStats('Player statistics'),
  grounds('Ground booking'),
  payments('Payments and wallet'),
  challenges('Challenges and opponent search'),
  playerHunt('Player Hunt'),
  tournaments('Tournaments'),
  notifications('Notifications'),
  announcements('Club announcements'),
  availability('Player availability');

  const BackendModule(this.label);
  final String label;
}

/// Which [BackendModule]s have real data in this build.
///
/// * Memory mode (the demo): every module, on the demo's seeded data.
/// * Supabase mode: only what the database holds. Club memberships and teams
///   come with the memberships switch; matches, challenges and player
///   availability with the matches switch on top of it; every other module
///   has no backend yet and starts EMPTY (its repository is never seeded) —
///   its screens say it isn't available yet rather than showing invented
///   data (docs/PRODUCTION_DEMO_MODE.md).
class BackendModules {
  const BackendModules._(this._available, {required this.isDemo});

  factory BackendModules.of(
    BackendConfig config, {
    bool memberships = kMembershipsBuild,
    bool matches = kMatchesBuild,
    bool results = kResultsBuild,
    bool notifications = kNotificationsBuild,
    bool fitness = kFitnessBuild,
    bool playerHunt = kPlayerHuntBuild,
    bool tournaments = kTournamentsBuild,
  }) =>
      config.isSupabase
          ? BackendModules._(
              {
                if (memberships) ...{BackendModule.memberships, BackendModule.teams},
                if (memberships && matches) ...{
                  BackendModule.matches,
                  BackendModule.challenges,
                  BackendModule.availability,
                },
                if (memberships && matches && results) BackendModule.matchStats,
                if (memberships && notifications) ...{BackendModule.notifications, BackendModule.announcements},
                if (memberships && matches && results && fitness) BackendModule.playerStats,
                if (memberships && playerHunt) BackendModule.playerHunt,
                if (memberships && tournaments) BackendModule.tournaments,
              },
              isDemo: false,
            )
          : BackendModules._(BackendModule.values.toSet(), isDemo: true);

  /// Supabase with both switches: migrations 17–19 are used.
  static bool matchesLive(BackendConfig config, {required bool memberships, required bool matches}) =>
      config.isSupabase && memberships && matches;

  /// Supabase with the memberships, matches AND results switches:
  /// migrations 20–23 are used.
  static bool resultsLive(
    BackendConfig config, {
    required bool memberships,
    required bool matches,
    required bool results,
  }) =>
      matchesLive(config, memberships: memberships, matches: matches) && results;

  /// Supabase with the memberships AND notifications switches: migration 25
  /// is used.
  static bool notificationsLive(
    BackendConfig config, {
    required bool memberships,
    required bool notifications,
  }) =>
      config.isSupabase && memberships && notifications;

  /// Supabase with the memberships, matches, results AND fitness switches:
  /// migration 34 is used.
  static bool fitnessLive(
    BackendConfig config, {
    required bool memberships,
    required bool matches,
    required bool results,
    required bool fitness,
  }) =>
      resultsLive(config, memberships: memberships, matches: matches, results: results) && fitness;

  /// Supabase with the memberships, matches AND discovery switches:
  /// migration 32 is used.
  static bool discoveryLive(
    BackendConfig config, {
    required bool memberships,
    required bool matches,
    required bool discovery,
  }) =>
      matchesLive(config, memberships: memberships, matches: matches) && discovery;

  /// Supabase with the memberships AND Player Hunt switches: migration 33 is
  /// used.
  static bool playerHuntLive(
    BackendConfig config, {
    required bool memberships,
    required bool playerHunt,
  }) =>
      config.isSupabase && memberships && playerHunt;

  /// Supabase with the memberships AND tournaments switches: migration 35 is
  /// used.
  static bool tournamentsLive(
    BackendConfig config, {
    required bool memberships,
    required bool tournaments,
  }) =>
      config.isSupabase && memberships && tournaments;

  final Set<BackendModule> _available;

  /// Memory mode: everything shown is the demo's sample data.
  final bool isDemo;

  bool has(BackendModule module) => _available.contains(module);

  /// Title and body of the "not available yet" panel.
  static const pendingTitle = 'Not available yet';
  static String pendingBody(BackendModule module) =>
      '${module.label}: not connected to the CricEco server yet. Nothing is shown or saved here until it is — '
      'no sample data.';
}

/// The build's backend modules, from [backendConfigProvider],
/// [membershipsEnabledProvider] and [matchesEnabledProvider].
final backendModulesProvider = Provider<BackendModules>(
  (ref) => BackendModules.of(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    matches: ref.watch(matchesEnabledProvider),
    results: ref.watch(resultsEnabledProvider),
    notifications: ref.watch(notificationsEnabledProvider),
    fitness: ref.watch(fitnessEnabledProvider),
    playerHunt: ref.watch(playerHuntEnabledProvider),
    tournaments: ref.watch(tournamentsEnabledProvider),
  ),
);

/// `true` when the tournament screens use the server (Supabase + the
/// memberships and tournaments switches).
final tournamentsBackendLiveProvider = Provider<bool>(
  (ref) => BackendModules.tournamentsLive(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    tournaments: ref.watch(tournamentsEnabledProvider),
  ),
);

/// `true` when the club directory and profiles, the availability slots, the
/// player rankings and the applicants' statistics use the server (Supabase +
/// the memberships, matches and discovery switches).
final discoveryBackendLiveProvider = Provider<bool>(
  (ref) => BackendModules.discoveryLive(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    matches: ref.watch(matchesEnabledProvider),
    discovery: ref.watch(discoveryEnabledProvider),
  ),
);

/// `true` when Player Hunt / Playing Opportunities use the server (Supabase
/// + the memberships and Player Hunt switches).
final huntBackendLiveProvider = Provider<bool>(
  (ref) => BackendModules.playerHuntLive(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    playerHunt: ref.watch(playerHuntEnabledProvider),
  ),
);

/// `true` when workouts and the owner's squad fitness use the server
/// (Supabase + the memberships, matches, results and fitness switches).
final fitnessBackendLiveProvider = Provider<bool>(
  (ref) => BackendModules.fitnessLive(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    matches: ref.watch(matchesEnabledProvider),
    results: ref.watch(resultsEnabledProvider),
    fitness: ref.watch(fitnessEnabledProvider),
  ),
);

/// `true` when the match, challenge and availability repositories use the
/// server (Supabase + memberships + matches switches).
final matchesBackendLiveProvider = Provider<bool>(
  (ref) => BackendModules.matchesLive(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    matches: ref.watch(matchesEnabledProvider),
  ),
);

/// `true` when the results repository uses the server (Supabase + the
/// memberships, matches and results switches).
final resultsBackendLiveProvider = Provider<bool>(
  (ref) => BackendModules.resultsLive(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    matches: ref.watch(matchesEnabledProvider),
    results: ref.watch(resultsEnabledProvider),
  ),
);

/// `true` when the notification inbox and announcement repositories use the
/// server (Supabase + the memberships and notifications switches).
final notificationsBackendLiveProvider = Provider<bool>(
  (ref) => BackendModules.notificationsLive(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
    notifications: ref.watch(notificationsEnabledProvider),
  ),
);
