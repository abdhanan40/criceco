import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../../data/repositories/repositories.dart';
import '../config/backend_modules.dart';
import '../providers/core_providers.dart';
import 'auth_notice.dart';

/// `onboarding` = authenticated, common user profile not yet complete.
/// `signedIn` = profile complete (role setup is tracked per role on the
/// account: a complete player profile / a Club Owner profile).
enum SessionStatus { signedOut, onboarding, signedIn }

class SessionState {
  const SessionState({
    this.status = SessionStatus.signedOut,
    this.account,
    this.ownClub,
    this.passwordRecovery = false,
    this.recoveryEmail,
  });

  final SessionStatus status;
  final UserAccount? account;

  /// The account's own club (only when it has a Club Owner profile).
  final Club? ownClub;

  /// AUTH-04: a recovery code or link opened a recovery session. Nobody is
  /// signed in; the only screen is Reset Password (the router guard).
  final bool passwordRecovery;

  /// The address being reset, when known (shown on Reset Password).
  final String? recoveryEmail;

  bool get isAuthenticated => status != SessionStatus.signedOut;
  bool get hasClubOwnerProfile => account?.hasClubOwnerProfile ?? false;

  SessionState copyWith({SessionStatus? status, UserAccount? account, Club? ownClub}) => SessionState(
        status: status ?? this.status,
        account: account ?? this.account,
        ownClub: ownClub ?? this.ownClub,
        passwordRecovery: passwordRecovery,
        recoveryEmail: recoveryEmail,
      );
}

/// A new password that fails the shared strong-password rules
/// ([CeValidators.password]) reached the session layer. [message] is the
/// validator's own text (e.g. "Add a number (0–9)").
class WeakPasswordException implements Exception {
  const WeakPasswordException(this.message);
  final String message;
  @override
  String toString() => message;
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
    _requireStrongPassword(password);
    final account = await ref
        .read(accountRepositoryProvider)
        .signUp(fullName: fullName, method: method, identifier: identifier, password: password);
    await _setAccount(account);
  }

  /// AUTH-02: confirms a sign-up with the 6-digit code from its email (after
  /// [signUp] threw [EmailConfirmationRequiredException]). Success signs the
  /// account in exactly as a sign-up with a session does ([_setAccount]:
  /// onboarding until User Profile Setup is done, the account id remembered
  /// for [restore]). A wrong, expired or used code throws
  /// [InvalidVerificationCodeException]; other failures their own
  /// [AccountException]. On any failure the session stays as it was.
  Future<void> verifySignUpCode({required String email, required String code}) async {
    final account = await ref
        .read(accountRepositoryProvider)
        .verifySignUpCode(email, code, at: ref.read(clockProvider).now());
    await _setAccount(account);
  }

  /// AUTH-02: sends a new sign-up code to [email]; the previous one stops
  /// working. Too soon or too often: [TooManyRequestsException]. Never
  /// changes the session.
  Future<SignUpCodeTicket> resendSignUpCode(String email) =>
      ref.read(accountRepositoryProvider).resendSignUpCode(email, at: ref.read(clockProvider).now());

  /// "Continue with Google". `true` when signed in here: the demo's new
  /// account, which goes straight to User Profile Setup (no password step),
  /// then Role Selection. `false` when it continues in the browser (AUTH-05,
  /// Supabase): the account arrives later — after the page comes back on
  /// the web ([restore]), or as an event on Android — and the router guard
  /// sends a new user to Profile Setup and a returning one to their role.
  Future<bool> signInWithGoogle() async {
    final repo = ref.read(accountRepositoryProvider);
    _listenToAuthEvents();
    if (await repo.startGoogleSignIn()) return false;
    final base = await repo.signIn(identifier: 'google', password: '');
    if (base == null) return true;
    await _setAccount(await repo.update(
      base.copyWith(profileComplete: false, playerProfile: const PlayerProfile()),
    ));
    return true;
  }

  // ---- AUTH-04 / AUTH-05: auth events from outside a call ----

  StreamSubscription<AccountAuthEvent>? _authEvents;

  /// Listens (once) for recovery links, Google returns, failed links and
  /// sessions the backend ended.
  void _listenToAuthEvents() {
    if (_authEvents != null) return;
    final sub = _authEvents = ref
        .read(accountRepositoryProvider)
        .authEvents
        .listen((e) => _onAuthEvent(e), onError: (Object _, StackTrace _) {});
    ref.onDispose(() {
      sub.cancel();
      _authEvents = null;
    });
  }

  Future<void> _onAuthEvent(AccountAuthEvent event) async {
    switch (event) {
      case PasswordRecoveryStarted(:final email):
        _startRecovery(email);
      case ExternalSignIn(:final account):
        if (state.account?.id == account.id && state.isAuthenticated) return;
        await _setAccount(account);
      case AuthLinkFailed(:final reason):
        ref.read(authNoticeProvider.notifier).show(AuthNotice.forLink(reason));
      case SessionExpired():
        if (!state.isAuthenticated && !state.passwordRecovery) return;
        _forgetLocally();
        ref.read(authNoticeProvider.notifier).show(AuthNotice.sessionEnded);
    }
  }

  /// A recovery session replaces whatever was signed in.
  void _startRecovery(String? email) {
    if (state.passwordRecovery) return;
    state = SessionState(passwordRecovery: true, recoveryEmail: email);
    ref.read(sharedPreferencesProvider).remove(_kAccount);
  }

  void _forgetLocally() {
    state = const SessionState();
    ref.read(sharedPreferencesProvider).remove(_kAccount);
  }

  /// Every path that sets or updates a password (Sign Up, reset, change)
  /// goes through the shared rules — never only the screens. Signing in is
  /// not checked, so existing passwords keep working.
  static void _requireStrongPassword(String password) {
    final error = CeValidators.password(password);
    if (error != null) throw WeakPasswordException(error);
  }

  static const _kAccount = 'criceco.session.accountId';

  Future<void> _setAccount(UserAccount read) async {
    final club = read.hasClubOwnerProfile ? await ref.read(clubRepositoryProvider).ownClub(read.id) : null;
    final account = await _withStoredMemberships(read);
    state = SessionState(
      // Saved setup state decides where the user lands — never reset on login.
      status: account.profileComplete ? SessionStatus.signedIn : SessionStatus.onboarding,
      account: account,
      ownClub: club,
    );
    await ref.read(sharedPreferencesProvider).setString(_kAccount, account.id);
  }

  /// App start: restore a remembered session so the persisted active role
  /// (approved P21) takes the user straight back into their role.
  /// Offline (a remote backend can't be reached): stays signed out for now
  /// and clears nothing, so the next start can restore normally.
  /// Any other failure — an invalid or expired session, a missing or
  /// unreadable profile — must not stop the app from starting (`main()`
  /// awaits this before `runApp`): the remembered account is forgotten, the
  /// backend session ended, and the user starts at Login. Never throws.
  ///
  /// AUTH-04/05 first: what the backend handled while starting — a recovery
  /// link (→ Reset Password), a Google return (→ that account), or a failed
  /// link (→ a message on Login). A leftover recovery session is ended there.
  Future<void> restore() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final id = prefs.getString(_kAccount);
    final repo = ref.read(accountRepositoryProvider);
    _listenToAuthEvents();
    AccountAuthEvent? start;
    try {
      start = await repo.sessionAtStart(remembered: id != null);
    } catch (_) {
      start = null; // must not stop the app from starting
    }
    switch (start) {
      case PasswordRecoveryStarted(:final email):
        _startRecovery(email);
        return;
      case ExternalSignIn(:final account):
        try {
          await _setAccount(account);
          return;
        } catch (_) {
          // Fall back to the remembered account below.
        }
      case AuthLinkFailed(:final reason):
        ref.read(authNoticeProvider.notifier).show(AuthNotice.forLink(reason));
      case SessionExpired():
        if (id != null) ref.read(authNoticeProvider.notifier).show(AuthNotice.sessionEnded);
      case null:
        break;
    }
    if (id == null) return;
    try {
      final account = await repo.byId(id);
      if (account != null) await _setAccount(account);
    } on BackendUnavailableException {
      return;
    } catch (_) {
      state = const SessionState();
      await prefs.remove(_kAccount);
      try {
        await repo.signOut();
      } catch (_) {
        // Already signed out locally; the backend session is cleared or
        // expires on its own.
      }
    }
  }

  Future<void> updateAccount(UserAccount Function(UserAccount a) change) async {
    final current = state.account;
    if (current == null) return;
    final saved = await ref.read(accountRepositoryProvider).update(syncProfileCity(current, change(current)));
    state = state.copyWith(account: saved);
  }

  /// The profile City (My Profile, Edit Profile, the "available to clubs"
  /// listing) and the Current Address city are one value: a changed Current
  /// City (Profile Setup) sets City, a changed City (Edit Profile) sets
  /// Current City. A Permanent City never sets City or Current City.
  /// Unchanged or empty values leave both as they are, so existing accounts
  /// keep their City.
  ///
  /// Edit Profile (Stage 4.3.5): a City picked from the list comes with its
  /// id (a new [UserAccount.currentCityId]), which is kept — also for a town
  /// with the same name as the old one; a City set without a new id clears
  /// the old one (the database resolves the text). The permanent address
  /// changes only when it is "same as current" (before and after the edit)
  /// and already exists: its city, id and Area then follow the changed
  /// current ones. A separate permanent address is never changed, and Profile
  /// Setup (a new Current City) keeps its own permanent answers.
  static UserAccount syncProfileCity(UserAccount before, UserAccount after) {
    String? picked(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();
    final current = picked(after.currentCity);
    if (current != null && current != picked(before.currentCity)) {
      return current == after.city ? after : after.copyWith(city: current);
    }
    final city = picked(after.city);
    final newId = after.currentCityId != before.currentCityId ? after.currentCityId : null;
    if (city != null && city != picked(before.city) && city != current) {
      return _samePermanent(
        before,
        after.copyWith(currentCity: city, currentCityId: newId, clearCurrentCityId: newId == null),
      );
    }
    return _samePermanent(before, after);
  }

  /// "Same as current": the permanent copy takes a changed current city, id
  /// and Area (Edit Profile). Only an existing copy (Profile Setup made it).
  static UserAccount _samePermanent(UserAccount before, UserAccount after) {
    if (!before.isPermanentSameAsCurrent || !after.isPermanentSameAsCurrent || before.permanentCity == null) {
      return after;
    }
    final changed = after.currentCity != before.currentCity ||
        after.currentCityId != before.currentCityId ||
        after.currentArea != before.currentArea;
    if (!changed) return after;
    return after.copyWith(
      permanentCity: after.currentCity,
      permanentCityId: after.currentCityId,
      clearPermanentCityId: after.currentCityId == null,
      permanentArea: after.currentArea,
    );
  }

  /// Privacy / sign-in toggles (Settings).
  Future<void> updateSettings(AccountSettings Function(AccountSettings s) change) =>
      updateAccount((a) => a.copyWith(settings: change(a.settings)));

  /// Password & security → Update Password. `false` when [current] is wrong.
  /// Throws [WeakPasswordException] if [next] fails the strong-password rules.
  Future<bool> changePassword({required String current, required String next}) async {
    _requireStrongPassword(next);
    final account = state.account;
    if (account == null) return false;
    final ok = await ref.read(accountRepositoryProvider).changePassword(account.id, current: current, next: next);
    if (!ok) return false;
    final at = ref.read(clockProvider).now();
    await updateSettings((s) => s.copyWith(passwordChangedAt: at));
    return true;
  }

  /// Login → "Forgot password?": sends a 6-digit code to the account with
  /// this phone number or email (`null` = no such account; a remote backend
  /// never says, [PasswordResetTicket.accountMayNotExist]). Its email may
  /// also carry a link that opens Reset Password (AUTH-04).
  Future<PasswordResetTicket?> requestPasswordReset(String identifier) {
    _listenToAuthEvents();
    return ref.read(accountRepositoryProvider).requestPasswordReset(identifier, at: ref.read(clockProvider).now());
  }

  /// Checks the code. On a remote backend an accepted code opens the
  /// recovery session (AUTH-04): the session enters [SessionState.passwordRecovery]
  /// and the router shows Reset Password.
  Future<ResetCodeCheck> verifyResetCode(String identifier, String code) async {
    final repo = ref.read(accountRepositoryProvider);
    final check = await repo.verifyResetCode(identifier, code, at: ref.read(clockProvider).now());
    if (check == ResetCodeCheck.ok && repo.passwordRecoveryActive) {
      _startRecovery(identifier.trim().toLowerCase());
    }
    return check;
  }

  /// Reset Password (AUTH-04): sets [newPassword] with the recovery session;
  /// every session of the account then ends and the user logs in again
  /// (Login shows "Password updated"). Throws [WeakPasswordException] before
  /// any request; [SamePasswordException] and other [AccountException]s leave
  /// the recovery open to try again — except [RecoverySessionMissingException]
  /// (expired or used), which ends it.
  Future<void> completePasswordRecovery(String newPassword) async {
    _requireStrongPassword(newPassword);
    try {
      await ref.read(accountRepositoryProvider).completePasswordRecovery(newPassword, at: ref.read(clockProvider).now());
    } on RecoverySessionMissingException catch (e) {
      _forgetLocally();
      ref.read(authNoticeProvider.notifier).show(AuthNotice(e.message));
      // Whatever backend session is left belonged to the recovery: end it.
      try {
        await ref.read(accountRepositoryProvider).signOut();
      } catch (_) {
        // Gone already, or offline: it expires on its own.
      }
      rethrow;
    }
    _forgetLocally();
    ref.read(authNoticeProvider.notifier).show(AuthNotice.passwordUpdated);
  }

  /// Reset Password → Cancel: leaves the recovery without a new password.
  Future<void> cancelPasswordRecovery() async {
    _forgetLocally();
    try {
      await ref.read(accountRepositoryProvider).cancelPasswordRecovery();
    } catch (_) {
      // Signed out locally either way; the recovery session expires.
    }
  }

  /// Sets the new password; afterwards only it signs in. Signed in (Settings),
  /// the account is reloaded so "Last changed" updates straight away.
  /// Throws [WeakPasswordException] if [newPassword] fails the strong-password
  /// rules (checked before the code, so nothing changes).
  Future<ResetCodeCheck> resetPassword(String identifier, String code, String newPassword) async {
    _requireStrongPassword(newPassword);
    final repo = ref.read(accountRepositoryProvider);
    final check = await repo.resetPassword(identifier, code, newPassword, at: ref.read(clockProvider).now());
    final signedIn = state.account;
    if (check == ResetCodeCheck.ok && signedIn != null) {
      final fresh = await repo.byId(signedIn.id);
      if (fresh != null) state = state.copyWith(account: fresh);
    }
    return check;
  }

  /// User Profile Setup → Continue: saves the common profile (it belongs to
  /// the account, not a role) and moves on to Role Selection.
  /// When [isPermanentSameAsCurrent] is true, the permanent address mirrors
  /// the current address so the account stays consistent. The current city
  /// also becomes the profile City ([syncProfileCity]). Saved in one step by
  /// [AccountRepository.saveProfileSetup], which re-checks the profile rules
  /// (throws [ProfileValidationException]; the screen validates first).
  Future<void> completeProfile({
    required String fullName,
    required String phone,
    required DateTime dateOfBirth,
    String? photoPath,
    required String currentCity,
    int? currentCityId,
    required String currentArea,
    required String currentAddress,
    required String permanentCity,
    int? permanentCityId,
    required String permanentArea,
    required String permanentAddress,
    required bool isPermanentSameAsCurrent,
  }) async {
    final same = isPermanentSameAsCurrent;
    final current = state.account;
    if (current != null) {
      final setup = syncProfileCity(
          current,
          current.copyWith(
            fullName: fullName,
            phone: phone,
            dateOfBirth: dateOfBirth,
            hasPhoto: photoPath != null,
            photoPath: photoPath,
            clearPhoto: photoPath == null,
            currentCity: currentCity,
            // The ids of cities picked from the list (none → v1 / memory mode).
            currentCityId: currentCityId,
            clearCurrentCityId: currentCityId == null,
            currentArea: currentArea,
            currentAddress: currentAddress,
            permanentCity: same ? currentCity : permanentCity,
            permanentCityId: same ? currentCityId : permanentCityId,
            clearPermanentCityId: (same ? currentCityId : permanentCityId) == null,
            permanentArea: same ? currentArea : permanentArea,
            permanentAddress: same ? currentAddress : permanentAddress,
            isPermanentSameAsCurrent: isPermanentSameAsCurrent,
            profileComplete: true,
          ));
      final saved =
          await ref.read(accountRepositoryProvider).saveProfileSetup(setup, at: ref.read(clockProvider).now());
      state = state.copyWith(account: saved);
    }
    state = state.copyWith(status: SessionStatus.signedIn);
  }

  /// Role Selection → Player → Continue: saves the Player role profile
  /// through [AccountRepository.savePlayerProfile], which re-checks the role
  /// rules (throws [ProfileValidationException]; the screen validates first).
  Future<void> savePlayerProfile(PlayerProfile profile) async {
    final account = state.account;
    if (account == null) return;
    final saved = await ref.read(accountRepositoryProvider).savePlayerProfile(account.id, profile);
    state = state.copyWith(account: saved);
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

  /// My Club → club picture: saves the change and updates the session.
  Future<void> updateClub(Club Function(Club c) change) async {
    final account = state.account;
    final current = state.ownClub;
    if (account == null || current == null) return;
    final saved = await ref.read(clubRepositoryProvider).updateClub(account.id, change(current));
    state = state.copyWith(ownClub: saved);
  }

  /// Join approval adds a membership only — never the Club Owner role (fix C).
  /// Supabase builds with stored memberships (migration 11, the memberships
  /// switch): the database's list replaces the account's. The demo keeps the
  /// run's own list. A failure never blocks signing in — the account is kept
  /// as read.
  Future<UserAccount> _withStoredMemberships(UserAccount account) async {
    final modules = ref.read(backendModulesProvider);
    if (modules.isDemo || !modules.has(BackendModule.memberships)) return account;
    try {
      return account.copyWith(memberships: await ref.read(clubRepositoryProvider).myMemberships());
    } on AccountException {
      return account; // offline: shown again on the next refresh
    }
  }

  /// Re-reads the signed-in account and its own club from the backend — after
  /// a club ownership transfer, so the former owner loses the Club Owner
  /// profile and the new owner gains it. No-op when signed out.
  Future<void> reloadAccount() async {
    final account = state.account;
    if (account == null) return;
    final read = await ref.read(accountRepositoryProvider).byId(account.id);
    if (read != null) await _setAccount(read);
  }

  /// Re-reads the signed-in account's stored memberships (after a join
  /// request is approved). No-op in the demo and when signed out.
  Future<void> refreshMemberships() async {
    final account = state.account;
    if (account == null) return;
    final updated = await _withStoredMemberships(account);
    if (!identical(updated, account)) state = state.copyWith(account: updated);
  }

  Future<void> addMembership(ClubMembership membership) =>
      updateAccount((a) => a.copyWith(memberships: [...a.memberships.where((m) => m.clubId != membership.clubId), membership]));

  /// Clears the session; `RoleController` clears the active role in response
  /// and the router guard sends the user to Login with an empty stack.
  /// The backend session is ended too ([AccountRepository.signOut]; a no-op
  /// in memory mode). The app signs out locally even if that call fails.
  /// Settings → Delete Account: the account and its personal data are deleted
  /// on the backend (after [password] is checked again), then this device
  /// forgets the session. The caller clears the saved role and leaves for
  /// Login. Errors (wrong password, offline, not available) leave everything
  /// as it was.
  Future<void> deleteAccount(String password) async {
    final account = state.account;
    if (account == null) throw const NotSignedInException();
    await ref.read(accountRepositoryProvider).deleteAccount(account.id, password: password);
    state = const SessionState();
    await ref.read(sharedPreferencesProvider).remove(_kAccount);
  }

  void logout() {
    state = const SessionState();
    ref.read(sharedPreferencesProvider).remove(_kAccount);
    ref.read(accountRepositoryProvider).signOut().catchError((Object _) {});
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// Convenience: the signed-in account (null when signed out).
final currentAccountProvider = Provider<UserAccount?>((ref) => ref.watch(sessionProvider).account);

/// selectedClub — the owner's own club.
final currentClubProvider = Provider<Club?>((ref) => ref.watch(sessionProvider).ownClub);
