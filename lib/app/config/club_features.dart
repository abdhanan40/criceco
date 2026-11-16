import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'backend_modules.dart';

/// Which club features this build offers. Screens ask this instead of the
/// backend mode (as with `AuthFeatures`).
///
/// Memory mode (the demo) keeps joining a club by its code. Supabase mode
/// offers it with the memberships switch (`CRICECO_MEMBERSHIPS`, migration
/// 11); without it the Join a Club screens show [joinComingSoon] instead of
/// a simulated lookup.
class ClubFeatures {
  const ClubFeatures({required this.joinByCode});

  /// Memory mode: join a club by its code (the demo flow).
  const ClubFeatures.all() : joinByCode = true;

  /// Supabase mode without the memberships switch.
  const ClubFeatures.noJoinByCode() : joinByCode = false;

  factory ClubFeatures.of(BackendConfig config, {bool memberships = kMembershipsBuild}) =>
      config.isSupabase && !memberships ? const ClubFeatures.noJoinByCode() : const ClubFeatures.all();

  /// Join a Club: enter a club code, preview the club, send a request.
  final bool joinByCode;

  /// Shown where joining by code isn't available (D-3B-4).
  static const joinComingSoon = 'Joining a club by code is coming soon';
}

/// The build's club features, derived from [backendConfigProvider] and
/// [membershipsEnabledProvider].
final clubFeaturesProvider = Provider<ClubFeatures>(
  (ref) => ClubFeatures.of(
    ref.watch(backendConfigProvider),
    memberships: ref.watch(membershipsEnabledProvider),
  ),
);
