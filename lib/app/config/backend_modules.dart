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
/// memberships and matches switches too. It only selects the results data
/// layer ([resultsBackendLiveProvider]); no screen uses it before M2 P4–P5,
/// so turn it on only with those (docs/MATCH_RESULTS_BACKEND.md).
const bool kResultsBuild = bool.fromEnvironment('CRICECO_RESULTS');

/// The results switch: [kResultsBuild], overridden in tests.
final resultsEnabledProvider = Provider<bool>((ref) => kResultsBuild);

/// App areas whose data needs a backend.
enum BackendModule {
  memberships('Club memberships'),
  teams('Teams and squads'),
  matches('Matches'),
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
