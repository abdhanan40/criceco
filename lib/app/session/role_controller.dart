import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
///
/// The remembered role belongs to one account ([_kOwner]): it is restored
/// only for that account, and dropped when another account signs in. An
/// account still in onboarding (new sign-ups included) has no role yet —
/// roles are chosen on Role Selection, after Profile Setup. So a stale role
/// from an earlier session never decides where a new account lands.
class RoleController extends Notifier<RoleState> {
  static const _kActive = 'criceco.activeRole';
  static const _kOwner = 'criceco.activeRole.account';
  static String _kLast(UserRole r) => 'criceco.lastRoute.${r.name}';

  @override
  RoleState build() {
    ref.listen(
      sessionProvider.select((s) => (id: s.account?.id, onboarding: s.status == SessionStatus.onboarding)),
      (was, now) {
        final id = now.id;
        // Logout (or any sign-out) clears role state and its persisted copy.
        if (id == null) {
          if (was?.id != null) clear();
          return;
        }
        // A new account (memory sign-ups reuse the demo id, so this can't
        // rely on the id) or one still in setup: no role.
        if (now.onboarding) {
          clear();
          return;
        }
        // Signed in: that account's own remembered role, or none.
        if (id != was?.id) state = _restoreFor(id);
      },
    );
    // main() restores the session before the router first builds this, so a
    // remembered account is already signed in here. If it isn't (offline at
    // start, or built earlier), the listener restores the role once its
    // owner signs in.
    final prefs = ref.read(sharedPreferencesProvider);
    final session = ref.read(sessionProvider);
    final account = session.account?.id;
    if (account != null && session.status != SessionStatus.onboarding) return _restoreFor(account);
    // Still in setup, or an older install's role saved without an account
    // (nobody owns it): forget it. Otherwise keep it for its owner.
    if (account != null || prefs.getString(_kOwner) == null) _forget(prefs);
    return const RoleState();
  }

  /// [accountId]'s remembered role and last routes. A role saved for
  /// another account — or for none (older installs) — is removed instead.
  RoleState _restoreFor(String accountId) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getString(_kOwner) != accountId) {
      _forget(prefs);
      return const RoleState();
    }
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
    final prefs = ref.read(sharedPreferencesProvider);
    final owner = ref.read(sessionProvider).account?.id;
    if (owner == null) {
      _forget(prefs); // never persist a role that no account owns
      return;
    }
    prefs
      ..setString(_kOwner, owner)
      ..setString(_kActive, role.name);
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
    _forget(ref.read(sharedPreferencesProvider));
  }

  /// Removes the persisted role, its owner and the last routes.
  static void _forget(SharedPreferences prefs) {
    prefs
      ..remove(_kActive)
      ..remove(_kOwner);
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
