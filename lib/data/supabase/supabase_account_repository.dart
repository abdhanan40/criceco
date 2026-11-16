import 'package:clock/clock.dart';

import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../repositories/repositories.dart';
import 'local_account_overlay.dart';
import 'profile_row_mapper.dart';
import 'supabase_error_mapper.dart';
import 'supabase_gateways.dart';

/// [AccountRepository] on Supabase (Auth + the four ERD v8 tables), through
/// [AuthGateway] / [ProfileGateway].
///
/// - Every read and write is for the signed-in user only: another account id
///   is refused before any database call.
/// - Phones are stored as `+923XXXXXXXXX`.
/// - D5: the sign-up name goes to Auth metadata; Profile Setup saves it to
///   `profiles`. Until then the metadata name is shown.
/// - The Club Owner profile is the user's own `clubs` row (Stage 3B), read
///   with the account. D6: memberships stay in memory. D9: photo and
///   settings stay on the device ([LocalAccountOverlay]).
/// - Password change is not supported yet (D13). Password reset (AUTH-04)
///   and Google sign-in (AUTH-05) go through the backend's email and OAuth
///   flows, which come back to [authCallbackUrl].
class SupabaseAccountRepository implements AccountRepository {
  SupabaseAccountRepository({
    required this.auth,
    required this.db,
    required this.overlay,
    this.clock = const Clock(),
    this.authCallbackUrl,
  });

  final AuthGateway auth;
  final ProfileGateway db;
  final LocalAccountOverlay overlay;
  final Clock clock;

  /// Where recovery links and Google sign-in return to: the web app's own
  /// address, or the Android app's `com.criceco.criceco://login-callback`.
  /// It must be on the backend's Redirect URLs allow list.
  final String? authCallbackUrl;

  /// The account as last read from the database (before local parts), per
  /// user id — what `update` compares against.
  final Map<String, UserAccount> _remote = {};

  /// D6: the last saved account per user id, for this app run — only its
  /// memberships are used (the club flags come from the database).
  final Map<String, UserAccount> _inMemory = {};

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  @override
  Future<UserAccount?> signIn({
    required String identifier,
    required String password,
  }) async {
    final email = _email(identifier);
    final user = await _call(
      () => auth.signInWithPassword(email: email, password: password),
    );
    if (user == null) return null;
    return _read(user);
  }

  @override
  Future<UserAccount> signUp({
    required String fullName,
    required ContactMethod method,
    required String identifier,
    required String password,
  }) async {
    if (method != ContactMethod.email) {
      throw const UnsupportedSignInMethodException();
    }
    final email = _email(identifier);
    final result = await _call(
      () => auth.signUp(
        email: email,
        password: password,
        metadata: {'full_name': fullName.trim()},
      ),
    );
    if (!result.hasSession) throw const EmailConfirmationRequiredException();
    return _read(result.user);
  }

  /// AUTH-02: the code from the sign-up email starts the session; then the
  /// account is read as after a sign-in. A code that can't be one (not 6
  /// digits) is refused without a request.
  @override
  Future<UserAccount> verifySignUpCode(
    String email,
    String code, {
    required DateTime at,
  }) async {
    final address = _email(email);
    final digits = code.trim();
    if (!_sixDigits.hasMatch(digits)) {
      throw const InvalidVerificationCodeException();
    }
    final user = await _call(
      () => auth.verifySignUpCode(email: address, code: digits),
    );
    try {
      return await _read(user);
    } on AccountException {
      // AUTH-02D: the code was accepted (the email is confirmed and used up)
      // but the account couldn't be read. End the half-started session so
      // nothing stays signed in unseen; the user logs in next.
      try {
        await auth.signOut();
      } on GatewayException {
        // Already gone locally, or offline: it expires on its own.
      }
      throw const EmailConfirmedSignInRequiredException();
    }
  }

  /// AUTH-02: a new sign-up code (the backend decides whether one is sent —
  /// never revealed here, so an address in use can't be told apart).
  @override
  Future<SignUpCodeTicket> resendSignUpCode(
    String email, {
    required DateTime at,
  }) async {
    final address = _email(email);
    await _call(() => auth.resendSignUpCode(email: address));
    return SignUpCodeTicket(destination: SignUpCodeTicket.maskEmail(address));
  }

  static final _sixDigits = RegExp(r'^\d{6}$');

  @override
  Future<void> signOut() async {
    await _call(auth.signOut);
    _remote.clear();
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// `null` when signed out or when [accountId] isn't the signed-in user —
  /// never a database read for another account.
  @override
  Future<UserAccount?> byId(String accountId) async {
    final user = auth.currentUser;
    if (user == null || user.id != accountId) return null;
    return _read(user);
  }

  /// Database rows → account (the Club Owner profile from the own `clubs`
  /// row), plus the metadata name (D5), this device's photo and settings
  /// (D9) and this run's memberships (D6).
  Future<UserAccount> _read(AuthUser user) async {
    final rows = await _call(() => db.fetchAccountRows(user.id));
    if (rows == null) throw const BackendOperationException();
    var remote = ProfileRowMapper.accountFromRows(
      profile: rows.profile,
      currentAddress: rows.currentAddress,
      permanentAddress: rows.permanentAddress,
      playerProfile: rows.playerProfile,
      club: rows.club,
      roles: rows.roles,
      email: user.email,
    );
    if (remote.fullName.isEmpty && user.fullName != null) {
      remote = remote.copyWith(fullName: user.fullName);
    }
    _remote[user.id] = remote;
    return _withLocal(remote);
  }

  /// The club flags always come from the database ([remote]); only the
  /// memberships are this run's (D6).
  UserAccount _withLocal(UserAccount remote) {
    final local = overlay.applyTo(remote);
    final run = _inMemory[remote.id];
    return run == null ? local : local.copyWith(memberships: run.memberships);
  }

  // ---------------------------------------------------------------------------
  // Writes (signed-in account only)
  // ---------------------------------------------------------------------------

  @override
  Future<UserAccount> saveProfileSetup(
    UserAccount account, {
    required DateTime at,
  }) async {
    final user = _signedIn(account.id);
    ProfileRules.checkProfileSetup(account, at);
    final stored = account.copyWith(
      phone: SupabaseErrorMapper.storedPhone(account.phone!),
    );
    // City ids picked from the list → save_profile_setup_v2 (migration 8);
    // without them (e.g. an older caller) → v1 with the city text, as before.
    if (ProfileRowMapper.hasCityIds(stored)) {
      final params = ProfileRowMapper.saveProfileSetupV2Params(stored);
      await _call(() => db.saveProfileSetupV2(params));
    } else {
      final params = ProfileRowMapper.saveProfileSetupParams(stored);
      await _call(() => db.saveProfileSetup(params));
    }
    await _keepLocal(account);
    return _read(user);
  }

  @override
  Future<UserAccount> savePlayerProfile(
    String accountId,
    PlayerProfile profile,
  ) async {
    final user = _signedIn(accountId);
    ProfileRules.checkPlayerProfile(profile);
    await _call(
      () => db.upsertPlayerProfile(
        ProfileRowMapper.playerProfileRow(user.id, profile),
      ),
    );
    await _call(
      () => db.setRoleIfUnset(
        user.id,
        ProfileRowMapper.userRoleCode(UserRole.player),
      ),
    );
    return _read(user);
  }

  /// Edit Profile's save (Stage 4.3.6b): full name, phone, date of birth and
  /// the existing address rows in ONE call, `update_profile_details()`
  /// (migration 9) — all written or nothing. Photo and settings stay on the
  /// device (D9), memberships in memory (D6); they are saved only after the
  /// call succeeded. The Club Owner flags aren't written: they follow the
  /// `clubs` row (created by `create_club()`), so a change to them re-reads
  /// the account from the database.
  ///
  /// Only changed values are checked here (the database checks them again);
  /// the date of birth can't be cleared (D3: a profile without one is
  /// incomplete); a changed address needs its row (D1: Profile Setup creates
  /// it — the function never does). No change to any of these fields → no
  /// call at all.
  @override
  Future<UserAccount> update(UserAccount account) async {
    final user = _signedIn(account.id);
    final before = _remote[user.id] ?? await _read(user);

    final name = account.fullName.trim();
    final nameChanged = name != before.fullName.trim();
    if (nameChanged) ProfileRules.check([ProfileRules.nameError(name)]);
    final phoneChanged = _phoneChanged(before.phone, account.phone);
    final dobChanged = account.dateOfBirth != before.dateOfBirth;
    if (dobChanged) {
      ProfileRules.check([
        ProfileRules.dateOfBirthError(account.dateOfBirth, clock.now()),
      ]);
    }
    final current = _addressArgs(
      before.currentCity == null
          ? null
          : (
              before.currentCity,
              before.currentArea,
              before.currentAddress,
              before.currentCityId,
            ),
      (
        account.currentCity,
        account.currentArea,
        account.currentAddress,
        account.currentCityId,
      ),
    );
    // "Same as current" is the STORED flag, as in the function: the
    // database copies the current row itself, so no permanent arguments.
    final permanent = before.isPermanentSameAsCurrent
        ? null
        : _addressArgs(
            before.permanentCity == null
                ? null
                : (
                    before.permanentCity,
                    before.permanentArea,
                    before.permanentAddress,
                    before.permanentCityId,
                  ),
            (
              account.permanentCity,
              account.permanentArea,
              account.permanentAddress,
              account.permanentCityId,
            ),
          );

    final remoteChanged =
        nameChanged ||
        phoneChanged ||
        dobChanged ||
        current != null ||
        permanent != null;
    if (remoteChanged) {
      final params = ProfileRowMapper.updateProfileDetailsParams(
        fullName: name.isEmpty ? null : name,
        // Unchanged: the stored value as read — the function compares it in
        // its canonical form, so it is never re-checked or rewritten.
        phone: !phoneChanged
            ? before.phone
            : account.phone == null
            ? null
            : SupabaseErrorMapper.storedPhone(account.phone!),
        dateOfBirth: account.dateOfBirth,
        current: current,
        permanent: permanent,
      );
      await _call(() => db.updateProfileDetails(params));
    }
    await _keepLocal(account);

    // A club was just created (or is gone): read the flags back from the
    // database rather than trusting the ones passed in.
    final clubChanged =
        account.hasClubOwnerProfile != before.hasClubOwnerProfile ||
        account.ownedClubId != before.ownedClubId;
    return remoteChanged || clubChanged ? _read(user) : _withLocal(before);
  }

  /// The four address arguments for a changed address, `null` when it is
  /// unchanged (the function then leaves the row alone).
  ///
  /// A new city id (picked from the list, also a town with the same name as
  /// the stored one) is sent with the text: the database stores that city's
  /// plain name (migration 9). No new id → text only, as before (the
  /// database keeps or re-resolves the id from the text); an id is never
  /// cleared from here. D1: a changed address without a stored row is
  /// refused — the function would ignore it, and it never creates the row.
  static ProfileAddressArgs? _addressArgs(
    (String?, String?, String?, int?)? stored,
    (String?, String?, String?, int?) next,
  ) {
    String t(String? v) => (v ?? '').trim();
    final (city, area, address, cityId) = next;
    final newId = cityId != null && cityId != stored?.$4 ? cityId : null;
    if (stored == null) {
      if (newId == null &&
          t(city).isEmpty &&
          t(area).isEmpty &&
          t(address).isEmpty) {
        return null;
      }
      throw const ProfileValidationException(noAddressRow);
    }
    if (newId == null &&
        t(city) == t(stored.$1) &&
        t(area) == t(stored.$2) &&
        t(address) == t(stored.$3)) {
      return null;
    }
    ProfileRules.check(ProfileRules.addressErrors(city, area, address));
    return (city: t(city), cityId: newId, area: t(area), address: t(address));
  }

  /// D1: an address can only be changed once Profile Setup has saved it.
  static const noAddressRow = 'Please complete Profile Setup first';

  static bool _phoneChanged(String? before, String? after) {
    String? canonical(String? p) =>
        p == null ? null : (CeValidators.normalizePkPhone(p) ?? p.trim());
    return canonical(before) != canonical(after);
  }

  /// D9 photo / settings on the device; D6 memberships in memory.
  Future<void> _keepLocal(UserAccount account) async {
    await overlay.save(account);
    _inMemory[account.id] = account;
  }

  // ---------------------------------------------------------------------------
  // Password change: not supported yet (D13 — Settings hides it)
  // ---------------------------------------------------------------------------

  @override
  Future<bool> changePassword(
    String accountId, {
    required String current,
    required String next,
  }) => throw UnsupportedError(
    'Password change is not supported in Supabase mode yet',
  );

  // ---------------------------------------------------------------------------
  // AUTH-04: password recovery
  // ---------------------------------------------------------------------------
  // One email carries a 6-digit code (entered in the Forgot Password sheet,
  // works from any device) and a link back to the app ([authCallbackUrl];
  // works on the device that asked for it). Both start a recovery session,
  // which is only used to set the new password; then every session of the
  // account is ended and the user logs in again.

  /// How long a recovery code works (the backend's OTP expiry, 900 s).
  static const recoveryCodeLifetime = Duration(seconds: 900);

  /// The backend answers the same for unknown addresses, so this never
  /// returns `null` (which would reveal that no account exists).
  @override
  Future<PasswordResetTicket?> requestPasswordReset(
    String identifier, {
    required DateTime at,
  }) async {
    final email = _email(identifier);
    await _call(
      () => auth.sendPasswordReset(email: email, redirectTo: authCallbackUrl),
    );
    return PasswordResetTicket(
      destination: SignUpCodeTicket.maskEmail(email),
      expiresAt: at.add(recoveryCodeLifetime),
      accountMayNotExist: true,
    );
  }

  /// Unlike the demo, checking the code uses it up: the backend starts the
  /// recovery session ([passwordRecoveryActive]). Wrong, expired or used:
  /// [ResetCodeCheck.invalid].
  @override
  Future<ResetCodeCheck> verifyResetCode(
    String identifier,
    String code, {
    required DateTime at,
  }) async {
    final email = _email(identifier);
    final digits = code.trim();
    if (!_sixDigits.hasMatch(digits)) return ResetCodeCheck.invalid;
    try {
      await _call(() => auth.verifyRecoveryCode(email: email, code: digits));
    } on InvalidVerificationCodeException {
      return ResetCodeCheck.invalid;
    }
    _remote.clear();
    return ResetCodeCheck.ok;
  }

  /// The code was used by [verifyResetCode]; this needs its recovery session
  /// for the same address ([ResetCodeCheck.noRequest] otherwise).
  @override
  Future<ResetCodeCheck> resetPassword(
    String identifier,
    String code,
    String newPassword, {
    required DateTime at,
  }) async {
    final email = _email(identifier);
    final user = auth.currentUser;
    if (!passwordRecoveryActive || user?.email?.toLowerCase() != email) {
      return ResetCodeCheck.noRequest;
    }
    await completePasswordRecovery(newPassword, at: at);
    return ResetCodeCheck.ok;
  }

  @override
  bool get passwordRecoveryActive =>
      auth.sessionKind == AuthSessionKind.recovery;

  @override
  Future<void> completePasswordRecovery(
    String newPassword, {
    required DateTime at,
  }) async {
    if (!passwordRecoveryActive) {
      throw const RecoverySessionMissingException();
    }
    try {
      await _call(() => auth.updatePassword(newPassword));
    } on NotSignedInException {
      // The recovery session expired or was ended meanwhile.
      await _endLocally();
      throw const RecoverySessionMissingException();
    }
    // A reset often means someone else may know the old password: end the
    // account's sessions everywhere, this one included.
    try {
      await _call(auth.signOutEverywhere);
    } on AccountException {
      await _endLocally(); // at least here; the others expire on their own
    }
    _remote.clear();
  }

  @override
  Future<void> cancelPasswordRecovery() async {
    if (passwordRecoveryActive) await _endLocally();
    _remote.clear();
  }

  // ---------------------------------------------------------------------------
  // AUTH-05: Google
  // ---------------------------------------------------------------------------

  /// Opens the backend's Google sign-in. The account (new or existing — the
  /// sign-up trigger creates a new user's `profiles` row, once) arrives as
  /// [ExternalSignIn]: on the web after the page comes back
  /// ([sessionAtStart]), on Android while the app runs ([authEvents]).
  @override
  Future<bool> startGoogleSignIn() async {
    final opened = await _call(
      () => auth.startGoogleSignIn(redirectTo: authCallbackUrl),
    );
    if (!opened) throw const GoogleSignInUnavailableException();
    return true;
  }

  // ---------------------------------------------------------------------------
  // Auth events (AUTH-04/05)
  // ---------------------------------------------------------------------------

  @override
  Future<AccountAuthEvent?> sessionAtStart({required bool remembered}) async {
    final event = await _accountEvent(await auth.takeStartEvent());
    if (event is PasswordRecoveryStarted || event is ExternalSignIn) {
      return event;
    }
    // A session nobody can use: a recovery left open when the app closed,
    // or one the app never took over (nothing remembered).
    final kind = auth.sessionKind;
    if (kind == AuthSessionKind.recovery ||
        (!remembered && kind != AuthSessionKind.none)) {
      await _endLocally();
    }
    return event;
  }

  @override
  Stream<AccountAuthEvent> get authEvents => auth.events
      .asyncMap(_accountEvent)
      .where((e) => e != null)
      .cast<AccountAuthEvent>();

  Future<AccountAuthEvent?> _accountEvent(AuthGatewayEvent? e) async =>
      switch (e) {
        null => null,
        GatewayRecoveryStarted() => PasswordRecoveryStarted(
          email: auth.currentUser?.email,
        ),
        GatewayOAuthSignedIn(:final user) => await _externalSignIn(user),
        GatewayLinkFailed(:final reason) => AuthLinkFailed(switch (reason) {
          GatewayLinkError.expired => AuthLinkFailure.expired,
          GatewayLinkError.cancelled => AuthLinkFailure.cancelled,
          GatewayLinkError.invalid => AuthLinkFailure.invalid,
          GatewayLinkError.failed => AuthLinkFailure.failed,
        }),
        GatewaySessionExpired() => const SessionExpired(),
      };

  /// Google came back signed in: read the account as after a sign-in. If it
  /// can't be read, end the half-started session so nothing stays signed in
  /// unseen.
  Future<AccountAuthEvent> _externalSignIn(AuthUser user) async {
    try {
      return ExternalSignIn(await _read(user));
    } on AccountException {
      await _endLocally();
      return const AuthLinkFailed(AuthLinkFailure.failed);
    }
  }

  /// Ends the session on this device; a failure (offline) is left to expire.
  Future<void> _endLocally() async {
    try {
      await auth.signOut();
    } on GatewayException {
      // Already gone, or offline: it expires on its own.
    }
    _remote.clear();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// The signed-in user, who must own [accountId].
  AuthUser _signedIn(String accountId) {
    final user = auth.currentUser;
    if (user == null) throw const NotSignedInException();
    if (user.id != accountId) throw const AccountMismatchException();
    return user;
  }

  /// Email sign-in only (D1): a phone number is refused.
  static String _email(String identifier) {
    final v = identifier.trim().toLowerCase();
    if (CeValidators.email(v) != null) {
      throw const UnsupportedSignInMethodException();
    }
    return v;
  }

  /// Runs a gateway call, turning its failures into app errors.
  static Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on GatewayException catch (e) {
      throw SupabaseErrorMapper.map(e);
    }
  }
}
