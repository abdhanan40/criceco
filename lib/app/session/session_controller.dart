import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../providers/core_providers.dart';

enum SessionStatus { signedOut, onboarding, signedIn }

class SessionState {
  const SessionState({this.status = SessionStatus.signedOut, this.account, this.ownClub});

  final SessionStatus status;
  final UserAccount? account;

  /// The account's own club (only when it has a Club Owner profile).
  final Club? ownClub;

  bool get isAuthenticated => status != SessionStatus.signedOut;
  bool get hasClubOwnerProfile => account?.hasClubOwnerProfile ?? false;

  SessionState copyWith({SessionStatus? status, UserAccount? account, Club? ownClub}) =>
      SessionState(status: status ?? this.status, account: account ?? this.account, ownClub: ownClub ?? this.ownClub);
}

/// Authentication + account state. The single account owns both role
/// profiles; the active role lives in `RoleController`.
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState();

  /// Returns `false` when the credentials are rejected (the screen shows a
  /// friendly error; no exception reaches the UI).
  Future<bool> signIn({required String identifier, required String password}) async {
    final account = await ref.read(accountRepositoryProvider).signIn(identifier: identifier, password: password);
    if (account == null) return false;
    await _setAccount(account);
    return true;
  }

  Future<void> signUp({
    required String fullName,
    required ContactMethod method,
    required String identifier,
    required String password,
  }) async {
    final account = await ref
        .read(accountRepositoryProvider)
        .signUp(fullName: fullName, method: method, identifier: identifier, password: password);
    await _setAccount(account);
  }

  /// "Continue with Google" — prototype jumps straight to Complete Profile.
  Future<void> signInWithGoogle() async {
    final repo = ref.read(accountRepositoryProvider);
    final base = await repo.signIn(identifier: 'google', password: '');
    if (base == null) return;
    await _setAccount(await repo.update(base.copyWith(onboardingComplete: false)));
  }

  static const _kAccount = 'criceco.session.accountId';

  Future<void> _setAccount(UserAccount account) async {
    final club = account.hasClubOwnerProfile ? await ref.read(clubRepositoryProvider).ownClub(account.id) : null;
    state = SessionState(
      status: account.onboardingComplete ? SessionStatus.signedIn : SessionStatus.onboarding,
      account: account,
      ownClub: club,
    );
    await ref.read(sharedPreferencesProvider).setString(_kAccount, account.id);
  }

  /// App start: restore a remembered session so the persisted active role
  /// (approved P21) takes the user straight back into their role.
  Future<void> restore() async {
    final id = ref.read(sharedPreferencesProvider).getString(_kAccount);
    if (id == null) return;
    final account = await ref.read(accountRepositoryProvider).byId(id);
    if (account != null) await _setAccount(account);
  }

  Future<void> updateAccount(UserAccount Function(UserAccount a) change) async {
    final current = state.account;
    if (current == null) return;
    final saved = await ref.read(accountRepositoryProvider).update(change(current));
    state = state.copyWith(account: saved);
  }

  /// Privacy / sign-in toggles (Settings).
  Future<void> updateSettings(AccountSettings Function(AccountSettings s) change) =>
      updateAccount((a) => a.copyWith(settings: change(a.settings)));

  /// Password & security → Update Password. `false` when [current] is wrong.
  Future<bool> changePassword({required String current, required String next}) async {
    final account = state.account;
    if (account == null) return false;
    final ok = await ref.read(accountRepositoryProvider).changePassword(account.id, current: current, next: next);
    if (!ok) return false;
    final at = ref.read(clockProvider).now();
    await updateSettings((s) => s.copyWith(passwordChangedAt: at));
    return true;
  }

  /// Save Profile or Skip on onboarding.
  Future<void> completeOnboarding() async {
    await updateAccount((a) => a.copyWith(onboardingComplete: true));
    state = state.copyWith(status: SessionStatus.signedIn);
  }

  /// Create Club → Club Details submit. The only path that grants the
  /// account-level Club Owner profile.
  Future<Club> createClub({
    required String name,
    required String city,
    required ClubType type,
    String? ownerName,
    String? address,
    String? email,
    String? homeGroundId,
    bool hasLogo = false,
  }) async {
    final account = state.account!;
    final club = await ref.read(clubRepositoryProvider).createClub(
          accountId: account.id,
          name: name,
          city: city,
          type: type,
          ownerName: ownerName,
          address: address,
          email: email,
          homeGroundId: homeGroundId,
          hasLogo: hasLogo,
        );
    await updateAccount((a) => a.copyWith(hasClubOwnerProfile: true, ownedClubId: club.id));
    state = state.copyWith(ownClub: club);
    return club;
  }

  /// Join approval adds a membership only — never the Club Owner role (fix C).
  Future<void> addMembership(ClubMembership membership) =>
      updateAccount((a) => a.copyWith(memberships: [...a.memberships.where((m) => m.clubId != membership.clubId), membership]));

  /// Clears the session; `RoleController` clears the active role in response
  /// and the router guard sends the user to Login with an empty stack.
  void logout() {
    state = const SessionState();
    ref.read(sharedPreferencesProvider).remove(_kAccount);
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// Convenience: the signed-in account (null when signed out).
final currentAccountProvider = Provider<UserAccount?>((ref) => ref.watch(sessionProvider).account);

/// selectedClub — the owner's own club.
final currentClubProvider = Provider<Club?>((ref) => ref.watch(sessionProvider).ownClub);
