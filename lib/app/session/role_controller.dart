import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/enums/enums.dart';
import '../providers/core_providers.dart';
import '../router/role_destinations.dart';
import '../router/routes.dart';
import 'session_controller.dart';

class RoleState {
  const RoleState({this.active, this.lastRoute = const {}});

  /// `null` until the user picks a role on Continue As.
  final UserRole? active;

  /// Last remembered top-level location per role.
  final Map<UserRole, String> lastRoute;

  String homeFor(UserRole role) => Routes.home(role);
}

/// Where a role switch / Continue As should navigate next.
sealed class RoleNavigation {
  const RoleNavigation();
}

class GoToLocation extends RoleNavigation {
  const GoToLocation(this.location);
  final String location;
}

/// Club Owner profile missing → set up first.
class NeedsClubSetup extends RoleNavigation {
  const NeedsClubSetup(this.location);
  final String location;
}

/// Active role + per-role last route. Persisted across restarts (approved P21)
/// and cleared on logout. Navigation can never change the role — only
/// [continueAs], [switchTo] and club creation do.
class RoleController extends Notifier<RoleState> {
  static const _kActive = 'criceco.activeRole';
  static String _kLast(UserRole r) => 'criceco.lastRoute.${r.name}';

  @override
  RoleState build() {
    // Logout (or any sign-out) clears role state and its persisted copy.
    ref.listen(sessionProvider.select((s) => s.isAuthenticated), (was, isNow) {
      if (was == true && !isNow) clear();
    });
    final prefs = ref.read(sharedPreferencesProvider);
    final activeName = prefs.getString(_kActive);
    final last = <UserRole, String>{};
    for (final r in UserRole.values) {
      final v = prefs.getString(_kLast(r));
      if (v != null && RoleDestinations.topLevel(r).contains(v)) last[r] = v; // heal stale values
    }
    return RoleState(
      active: UserRole.values.where((r) => r.name == activeName).firstOrNull,
      lastRoute: last,
    );
  }

  bool get _hasClubProfile => ref.read(sessionProvider).hasClubOwnerProfile;

  void _setActive(UserRole role) {
    state = RoleState(active: role, lastRoute: state.lastRoute);
    ref.read(sharedPreferencesProvider).setString(_kActive, role.name);
  }

  /// Continue As card tap. Club without profile → Set Up Your Club (prototype
  /// behaviour); the active role is not changed until setup completes.
  RoleNavigation continueAs(UserRole role) {
    if (role == UserRole.clubOwner && !_hasClubProfile) return const NeedsClubSetup(Routes.chooseOption);
    _setActive(role);
    return GoToLocation(Routes.home(role));
  }

  /// Drawer switch row. Returns the location to `go()` to (the stack is
  /// replaced, so system Back cannot undo a switch).
  RoleNavigation switchTo(UserRole role) {
    if (role == UserRole.clubOwner && !_hasClubProfile) return const NeedsClubSetup(Routes.roleSetup);
    if (role == state.active) return GoToLocation(Routes.home(role));
    _setActive(role);
    return GoToLocation(state.lastRoute[role] ?? Routes.home(role));
  }

  /// Called after Create Club succeeds.
  void becomeClubOwner() => _setActive(UserRole.clubOwner);

  /// Called when joining a club completes — membership never grants Club Owner.
  void enterPlayerContext() => _setActive(UserRole.player);

  /// Remember a role's last top-level destination (router observer).
  void recordLocation(String location) {
    final role = state.active;
    if (role == null || !RoleDestinations.topLevel(role).contains(location)) return;
    if (state.lastRoute[role] == location) return;
    state = RoleState(active: role, lastRoute: {...state.lastRoute, role: location});
    ref.read(sharedPreferencesProvider).setString(_kLast(role), location);
  }

  void clear() {
    state = const RoleState();
    final prefs = ref.read(sharedPreferencesProvider);
    prefs.remove(_kActive);
    for (final r in UserRole.values) {
      prefs.remove(_kLast(r));
    }
  }
}

final roleControllerProvider = NotifierProvider<RoleController, RoleState>(RoleController.new);

/// The effective active role. A remembered Club Owner role is ignored if the
/// account no longer has a Club Owner profile (e.g. mock data after restart).
final activeRoleProvider = Provider<UserRole?>((ref) {
  final role = ref.watch(roleControllerProvider).active;
  final hasClubProfile = ref.watch(sessionProvider.select((s) => s.hasClubOwnerProfile));
  if (role == UserRole.clubOwner && !hasClubProfile) return null;
  return role;
});
