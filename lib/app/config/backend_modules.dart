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
///   come with the memberships switch; every other module has no backend yet
///   and starts EMPTY (its repository is never seeded) — its screens say
///   it isn't available yet rather than showing invented data
///   (docs/PRODUCTION_DEMO_MODE.md).
class BackendModules {
  const BackendModules._(this._available, {required this.isDemo});

  factory BackendModules.of(BackendConfig config, {bool memberships = kMembershipsBuild}) => config.isSupabase
      ? BackendModules._(
          {if (memberships) ...{BackendModule.memberships, BackendModule.teams}},
          isDemo: false,
        )
      : BackendModules._(BackendModule.values.toSet(), isDemo: true);

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

/// The build's backend modules, from [backendConfigProvider] and
/// [membershipsEnabledProvider].
final backendModulesProvider = Provider<BackendModules>(
  (ref) => BackendModules.of(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
  ),
);
