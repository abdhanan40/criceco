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

  /// Role Selection card for an already set-up role (the former Continue As).
  /// Club Owner without a profile → Club Setup Details; the active role is not
  /// changed until setup completes.
  RoleNavigation continueAs(UserRole role) {
    if (role == UserRole.clubOwner && !_hasClubProfile) return const NeedsClubSetup(Routes.clubSetup);
    _setActive(role);
    return GoToLocation(Routes.home(role));
  }

  /// Drawer switch row. Returns the location to `go()` to (the stack is
  /// replaced, so system Back cannot undo a switch).
  RoleNavigation switchTo(UserRole role) {
    if (role == UserRole.clubOwner && !_hasClubProfile) return const NeedsClubSetup(Routes.roleSetup);
    if (role == effectiveRole(state.active, ref.read(sessionProvider))) {
      _setActive(role); // make an inferred role explicit
      return GoToLocation(Routes.home(role));
    }
    _setActive(role);
    return GoToLocation(state.lastRoute[role] ?? Routes.home(role));
  }

  /// Called after Club Setup Details creates the club.
  void becomeClubOwner() => _setActive(UserRole.clubOwner);

  /// Called when Player setup completes on Role Selection.
  void becomePlayer() => _setActive(UserRole.player);

  /// Called when joining a club completes — membership never grants Club Owner.
  void enterPlayerContext() => _setActive(UserRole.player);

  /// Remember a role's last top-level destination (router observer).
  void recordLocation(String location) {
    // Explicit roles only: writing here during the router's first build is
    // not allowed, and an inferred role becomes explicit on the first switch.
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

/// The effective active role.
///
/// * An explicitly chosen role wins (Role Selection, drawer switch, club
///   creation, completing Player setup) — except a remembered Club Owner role
///   when the account no longer has a Club Owner profile (mock data restart).
/// * Otherwise a returning user with exactly ONE completed role enters it
///   directly (no onboarding repeat): a complete Player profile → Player; a
///   Club Owner profile → Club Owner. With both (or neither) the user picks
///   on Role Selection.
///
/// Derived — never written as a side effect — so the router's redirect and
/// this value can't race each other after login.
final activeRoleProvider = Provider<UserRole?>(
  (ref) => effectiveRole(ref.watch(roleControllerProvider).active, ref.watch(sessionProvider)),
);

/// [explicit] if still valid, else the returning user's inferred role.
UserRole? effectiveRole(UserRole? explicit, SessionState session) {
  if (explicit == UserRole.clubOwner && session.hasClubOwnerProfile) return explicit;
  if (explicit == UserRole.player) return explicit;
  return inferEntryRole(session);
}

/// The single completed role of a signed-in, profile-complete account
/// (`null` when none or both are set up).
UserRole? inferEntryRole(SessionState session) {
  if (session.status != SessionStatus.signedIn) return null;
  final player = session.account?.playerProfile.isComplete ?? false;
  final club = session.hasClubOwnerProfile;
  if (player && !club) return UserRole.player;
  if (club && !player) return UserRole.clubOwner;
  return null;
}
