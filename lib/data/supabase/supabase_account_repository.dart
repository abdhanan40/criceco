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
/// - D6: Club Owner flags and memberships stay in memory (clubs are
///   in-memory too). D9: photo and settings stay on the device
///   ([LocalAccountOverlay]).
/// - Password change / reset are not supported yet (D13).
class SupabaseAccountRepository implements AccountRepository {
  SupabaseAccountRepository({
    required this.auth,
    required this.db,
    required this.overlay,
    this.clock = const Clock(),
  });

  final AuthGateway auth;
  final ProfileGateway db;
  final LocalAccountOverlay overlay;
  final Clock clock;

  /// The account as last read from the database (before local parts), per
  /// user id — what `update` compares against.
  final Map<String, UserAccount> _remote = {};

  /// D6: Club Owner flags and memberships, per user id, for this app run.
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

  /// Database rows → account, plus the metadata name (D5), this device's
  /// photo and settings (D9) and this run's Club Owner state (D6).
  Future<UserAccount> _read(AuthUser user) async {
    final rows = await _call(() => db.fetchAccountRows(user.id));
    if (rows == null) throw const BackendOperationException();
    var remote = ProfileRowMapper.accountFromRows(
      profile: rows.profile,
      currentAddress: rows.currentAddress,
      permanentAddress: rows.permanentAddress,
      playerProfile: rows.playerProfile,
      email: user.email,
    );
    if (remote.fullName.isEmpty && user.fullName != null) {
      remote = remote.copyWith(fullName: user.fullName);
    }
    _remote[user.id] = remote;
    return _withLocal(remote);
  }

  UserAccount _withLocal(UserAccount remote) {
    final local = overlay.applyTo(remote);
    final run = _inMemory[remote.id];
    return run == null
        ? local
        : local.copyWith(
            hasClubOwnerProfile: run.hasClubOwnerProfile,
            ownedClubId: run.ownedClubId,
            memberships: run.memberships,
          );
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
    final params = ProfileRowMapper.saveProfileSetupParams(
      account.copyWith(phone: SupabaseErrorMapper.storedPhone(account.phone!)),
    );
    await _call(() => db.saveProfileSetup(params));
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

  /// Writes only what changed: full name, phone and date of birth on
  /// `profiles`, and existing address rows; photo and settings locally
  /// (D9); Club Owner flags and memberships in memory (D6).
  @override
  Future<UserAccount> update(UserAccount account) async {
    final user = _signedIn(account.id);
    final before = _remote[user.id] ?? await _read(user);

    final columns = <String, Object?>{};
    if (account.fullName.trim() != before.fullName.trim()) {
      ProfileRules.check([ProfileRules.nameError(account.fullName)]);
      columns['full_name'] = account.fullName.trim();
    }
    if (_phoneChanged(before.phone, account.phone)) {
      columns['phone'] = account.phone == null
          ? null
          : SupabaseErrorMapper.storedPhone(account.phone!);
    }
    if (account.dateOfBirth != before.dateOfBirth) {
      ProfileRules.check([
        ProfileRules.dateOfBirthError(account.dateOfBirth, clock.now()),
      ]);
      columns['date_of_birth'] = ProfileRowMapper.formatDate(
        account.dateOfBirth!,
      );
    }

    final current = _addressChange(
      before.currentCity == null
          ? null
          : (before.currentCity, before.currentArea, before.currentAddress),
      (account.currentCity, account.currentArea, account.currentAddress),
    );
    // "Same as current": the stored permanent address is the current copy.
    final permanent = account.isPermanentSameAsCurrent
        ? (before.permanentCity == null ? null : current)
        : _addressChange(
            before.permanentCity == null
                ? null
                : (
                    before.permanentCity,
                    before.permanentArea,
                    before.permanentAddress,
                  ),
            (
              account.permanentCity,
              account.permanentArea,
              account.permanentAddress,
            ),
          );

    if (columns.isNotEmpty) {
      await _call(() => db.updateProfileColumns(user.id, columns));
    }
    if (current != null) {
      await _call(
        () => db.updateAddress('current_addresses', user.id, current),
      );
    }
    if (permanent != null) {
      await _call(
        () => db.updateAddress('permanent_addresses', user.id, permanent),
      );
    }
    await _keepLocal(account);

    final remoteChanged =
        columns.isNotEmpty || current != null || permanent != null;
    return remoteChanged ? _read(user) : _withLocal(before);
  }

  /// The columns to write for a changed address, `null` when unchanged or
  /// when there is no stored row to update (Profile Setup creates it).
  Map<String, Object?>? _addressChange(
    (String?, String?, String?)? stored,
    (String?, String?, String?) next,
  ) {
    if (stored == null) return null;
    String t(String? v) => (v ?? '').trim();
    final (city, area, address) = next;
    if (t(city) == t(stored.$1) &&
        t(area) == t(stored.$2) &&
        t(address) == t(stored.$3)) {
      return null;
    }
    ProfileRules.check(ProfileRules.addressErrors(city, area, address));
    return {'city': t(city), 'area': t(area), 'address': t(address)};
  }

  static bool _phoneChanged(String? before, String? after) {
    String? canonical(String? p) =>
        p == null ? null : (CeValidators.normalizePkPhone(p) ?? p.trim());
    return canonical(before) != canonical(after);
  }

  /// D9 photo / settings on the device; D6 Club Owner state in memory.
  Future<void> _keepLocal(UserAccount account) async {
    await overlay.save(account);
    _inMemory[account.id] = account;
  }

  // ---------------------------------------------------------------------------
  // Not supported yet (D13 — the screens are hidden in Step 5)
  // ---------------------------------------------------------------------------

  static const _noPasswordFlows =
      'Password change / reset is not supported in Supabase mode yet';

  @override
  Future<bool> changePassword(
    String accountId, {
    required String current,
    required String next,
  }) => throw UnsupportedError(_noPasswordFlows);

  @override
  Future<PasswordResetTicket?> requestPasswordReset(
    String identifier, {
    required DateTime at,
  }) => throw UnsupportedError(_noPasswordFlows);

  @override
  Future<ResetCodeCheck> verifyResetCode(
    String identifier,
    String code, {
    required DateTime at,
  }) => throw UnsupportedError(_noPasswordFlows);

  @override
  Future<ResetCodeCheck> resetPassword(
    String identifier,
    String code,
    String newPassword, {
    required DateTime at,
  }) => throw UnsupportedError(_noPasswordFlows);

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
