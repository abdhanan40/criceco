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

/// App areas whose data needs a backend.
enum BackendModule {
  memberships('Club memberships'),
  teams('Teams and squads'),
  matches('Matches'),
  /// Official match results, scorecards and player statistics (migrations
  /// 20–23, the results switch). Read-only: they come from a trusted
  /// source, never typed in the app.
  matchStats('Match results and statistics'),
  /// Fitness records and the player's own stats settings (no backend yet).
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
