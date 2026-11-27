import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/models/models.dart';
import '../../core/utils/media_ref.dart';
import '../../core/utils/validators.dart';
import '../repositories/repositories.dart';
import 'local_account_overlay.dart';
import 'media_uploader.dart';
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
/// - M5 / M6 with [media] (the `CRICECO_PROFILE_MEDIA` switch, migration
///   31): the profile picture is in Storage (`avatars/<uid>/…`, set with
///   `set_my_avatar`) and the profile visibility on the server
///   (`my_privacy_settings` / `set_profile_visibility`). Without it both stay
///   on the device, as before.
/// - Password change (M6) re-checks the current password by signing in
///   again, sets the new one and ends the account's other sessions.
///   Password reset (AUTH-04) and Google sign-in (AUTH-05) go through the
///   backend's email and OAuth flows, which come back to [authCallbackUrl].
class SupabaseAccountRepository implements AccountRepository {
  SupabaseAccountRepository({
    required this.auth,
    required this.db,
    required this.overlay,
    this.clock = const Clock(),
    this.authCallbackUrl,
    this.privacy,
    this.media,
    LocalMediaFiles files = const LocalMediaFiles(),
    String Function()? newObjectId,
  }) : _uploader = media == null ? null : MediaUploader(gateway: media, files: files, newId: newObjectId);

  final AuthGateway auth;
  final ProfileGateway db;
  final LocalAccountOverlay overlay;
  final Clock clock;

  /// Profile picture in Storage and profile visibility on the server (the
  /// `CRICECO_PROFILE_MEDIA` switch, migration 31). `null`: both stay on
  /// this device ([LocalAccountOverlay]), exactly as before.
  final MediaGateway? media;
  final MediaUploader? _uploader;

  /// With [media]: the stored `profiles.avatar_path` per user id (`null` =
  /// no picture on the server).
  final Map<String, String?> _avatar = {};

  /// With [media]: the server's visibility settings per user id.
  final Map<String, ProfileVisibility> _visibility = {};

  /// The picture of the account last returned per user id — a different
  /// one in [update] / [saveProfileSetup] is a picture change.
  final Map<String, String?> _shownPhoto = {};

  /// Users whose device photo was offered to the server this app run (M5's
  /// one-time move of a device photo).
  final Set<String> _photoMoveTried = {};

  /// The device photo being moved to the server, if any (tests wait for it).
  @visibleForTesting
  Future<void>? pendingPhotoMove;

  /// Where recovery links and Google sign-in return to: the web app's own
  /// address, or the Android app's `com.criceco.criceco://login-callback`.
  /// It must be on the backend's Redirect URLs allow list.
  final String? authCallbackUrl;

  /// Phone-sharing consent and account deletion on the server (the
  /// `CRICECO_ACCOUNT_PRIVACY` switch). `null`: the "Show phone number"
  /// setting stays on this device and accounts can't be deleted.
  final AccountPrivacyGateway? privacy;

  /// The stored phone-sharing consent per user id (with [privacy]).
  final Map<String, bool> _phoneSharing = {};

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
    final gateway = privacy;
    final m = media;
    if (m != null) {
      // M5 / M6: the picture column and the visibility (migration 31).
      final avatar = rows.profile['avatar_path'];
      _avatar[user.id] = avatar is String && avatar.trim().isNotEmpty ? avatar.trim() : null;
      // `my_profile_visibility()`; unreadable → the profile row's columns
      // (never blocks signing in).
      ProfileVisibility? v;
      try {
        v = await _call(m.fetchProfileVisibility);
      } on AccountException {
        v = null;
      }
      _visibility[user.id] = ProfileVisibility(
        publicProfile: v?.publicProfile ?? _flag(rows.profile['public_profile']),
        showStats: v?.showStats ?? _flag(rows.profile['show_stats']),
      );
    }
    // The phone consent stays `my_privacy_settings()` (migration 13).
    if (gateway != null) _phoneSharing[user.id] = await _call(gateway.fetchPhoneSharing);
    return _afterRead(remote);
  }

  static bool? _flag(Object? v) => v is bool ? v : null;

  /// The account as shown, and (M5) the one-time move of a device photo.
  UserAccount _afterRead(UserAccount remote) {
    final account = _withLocal(remote);
    _maybeMovePhoto(account);
    return account;
  }

  /// The club flags always come from the database ([remote]); only the
  /// memberships are this run's (D6).
  UserAccount _withLocal(UserAccount remote) {
    var local = overlay.applyTo(remote);
    if (media != null) {
      // M5: the server's picture wins; without one, a device photo not
      // moved to the server yet is still shown.
      final stored = MediaRef.of(MediaRef.avatarsBucket, _avatar[remote.id]);
      if (stored != null) local = local.copyWith(hasPhoto: true, photoPath: stored);
      // M6: the server's visibility wins over this device's copy.
      final v = _visibility[remote.id];
      if (v != null) {
        local = local.copyWith(
          settings: local.settings.copyWith(
            publicProfile: v.publicProfile ?? local.settings.publicProfile,
            showStats: v.showStats ?? local.settings.showStats,
          ),
        );
      }
    }
    // The server's consent wins over this device's copy of the setting.
    final sharing = _phoneSharing[remote.id];
    if (sharing != null) local = local.copyWith(settings: local.settings.copyWith(showPhone: sharing));
    final run = _inMemory[remote.id];
    final shown = run == null ? local : local.copyWith(memberships: run.memberships);
    _shownPhoto[remote.id] = shown.photoPath;
    return shown;
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
    if (media != null) {
      // M5: the setup's picture goes to the server. The profile is saved
      // already, so a picture that can't be uploaded now never fails the
      // setup: it stays on this device and moves to the server later.
      try {
        await _savePhoto(user.id, account.photoPath);
      } on AccountException {
        // Kept on the device ([_keepLocal]); moved once on a later read.
      }
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
    // "Show phone number" is the user's consent on the server (with
    // [privacy]): sent only when it changed.
    final gateway = privacy;
    final share = account.settings.showPhone;
    if (gateway != null && share != (_phoneSharing[user.id] ?? false)) {
      await _call(() => gateway.setPhoneSharing(share));
      _phoneSharing[user.id] = share;
    }
    if (media != null) {
      // M6: the visibility, sent only when it changed; M5: the picture.
      await _saveVisibility(user.id, account.settings);
      await _savePhoto(user.id, account.photoPath);
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

  /// D9 photo / settings on the device; D6 memberships in memory. With
  /// [media], a picture the server holds isn't kept on the device (only a
  /// device photo not moved to the server yet is).
  Future<void> _keepLocal(UserAccount account) async {
    final onServer =
        media != null && (_avatar[account.id] != null || MediaRef.isStored(account.photoPath));
    await overlay.save(onServer ? account.copyWith(hasPhoto: false, clearPhoto: true) : account);
    _inMemory[account.id] = account;
  }

  // ---------------------------------------------------------------------------
  // M5: the profile picture in Storage (with [media])
  // ---------------------------------------------------------------------------

  /// [next] is the picture of the account being saved: a new device photo
  /// is uploaded to `avatars/<uid>/<uuid>.<ext>` and set with
  /// `set_my_avatar`; none removes the stored one. The replaced object is
  /// deleted afterwards (best effort). Unchanged → no call.
  Future<void> _savePhoto(String userId, String? next) async {
    final m = media!;
    final uploader = _uploader!;
    if (next == _shownPhoto[userId] || MediaRef.isStored(next)) return;
    final old = _avatar[userId];
    if (next == null) {
      if (old == null) return; // a device photo only: removed on the device
      await _call(() => m.setMyAvatar(null));
      _avatar[userId] = null;
      await uploader.removeQuietly(MediaRef.avatarsBucket, old);
      return;
    }
    final path = await uploader.upload(bucket: MediaRef.avatarsBucket, folder: userId, localPath: next);
    try {
      await _call(() => m.setMyAvatar(path));
    } on Exception {
      await uploader.removeQuietly(MediaRef.avatarsBucket, path); // never left unused
      rethrow;
    }
    _avatar[userId] = path;
    _shownPhoto[userId] = MediaRef.of(MediaRef.avatarsBucket, path);
    await uploader.removeQuietly(MediaRef.avatarsBucket, old);
  }

  /// M6: `set_profile_visibility` with only the settings that changed.
  /// Refused → nothing is kept (the screen shows the stored value again).
  Future<void> _saveVisibility(String userId, AccountSettings next) async {
    final m = media!;
    final v = _visibility[userId];
    // Not known from the server: its default (visible).
    final public = next.publicProfile != (v?.publicProfile ?? true) ? next.publicProfile : null;
    final stats = next.showStats != (v?.showStats ?? true) ? next.showStats : null;
    if (public == null && stats == null) return;
    await _call(() => m.setProfileVisibility(publicProfile: public, showStats: stats));
    _visibility[userId] = ProfileVisibility(publicProfile: next.publicProfile, showStats: next.showStats);
  }

  /// M5's one-time move: with [media], no picture on the server and a
  /// device photo from before ([LocalAccountOverlay]) — it is uploaded
  /// silently in the background (never blocking the screen), then the
  /// device copy is forgotten. Tried once per app run; a picture the server
  /// refuses for good (size, type) is never tried again, a file that is gone
  /// is forgotten.
  void _maybeMovePhoto(UserAccount account) {
    final m = media;
    final id = account.id;
    final local = account.photoPath;
    if (m == null || _avatar[id] != null || local == null || MediaRef.isStored(local)) return;
    if (_photoMoveTried.contains(id) || overlay.refusedPhoto(id) == local) return;
    _photoMoveTried.add(id);
    pendingPhotoMove = _movePhoto(m, id, local);
  }

  Future<void> _movePhoto(MediaGateway m, String userId, String local) async {
    final uploader = _uploader!;
    try {
      final path = await uploader.upload(bucket: MediaRef.avatarsBucket, folder: userId, localPath: local);
      try {
        await _call(() => m.setMyAvatar(path));
      } on Exception {
        await uploader.removeQuietly(MediaRef.avatarsBucket, path);
        rethrow;
      }
      // Changed meanwhile (another picture saved)? Then that one stays.
      if (_avatar[userId] != null) {
        await uploader.removeQuietly(MediaRef.avatarsBucket, path);
        return;
      }
      _avatar[userId] = path;
      await overlay.clearPhoto(userId);
    } on MediaException catch (e) {
      if (e.kind == MediaFailure.unreadable) {
        await overlay.clearPhoto(userId); // the file is gone
      } else if (e.isPermanent) {
        await overlay.markPhotoRefused(userId, local);
      }
    } on Exception {
      // Offline, signed out meanwhile…: tried again on the next app run.
    }
  }

  /// Before Delete Account (with [media]): the password is checked by
  /// signing in again (wrong → [WrongPasswordException], nothing removed),
  /// then the picture is cleared and every object in the user's own
  /// `avatars/<uid>/` folder is deleted — best effort: a failure never
  /// blocks the deletion.
  Future<void> _removeOwnPictures(AuthUser user, String password) async {
    final email = user.email;
    if (email == null) return;
    final again = await _call(() => auth.signInWithPassword(email: email, password: password));
    if (again == null) throw const WrongPasswordException();
    final m = media!;
    final folder = user.id.toLowerCase();
    final paths = <String>{?_avatar[user.id]};
    try {
      paths.addAll(await m.list(MediaRef.avatarsBucket, folder));
    } on GatewayException {
      // Listing failed: at least the known picture.
    }
    try {
      if (_avatar[user.id] != null) await m.setMyAvatar(null);
    } on GatewayException {
      // The row goes with the account anyway.
    }
    if (paths.isEmpty) return;
    try {
      await m.remove(MediaRef.avatarsBucket, paths.toList());
    } on GatewayException {
      // Left behind; the account is deleted regardless.
    }
    _avatar[user.id] = null;
  }

  // ---------------------------------------------------------------------------
  // M6: password change (signed in)
  // ---------------------------------------------------------------------------

  /// Settings → Password & security → Update Password. [current] is checked
  /// by signing in again with the account's email (wrong → `false`, nothing
  /// changes); then the new password is set and the account's OTHER sessions
  /// are ended (this one stays). The backend's password rules: a weak one is
  /// [ProfileValidationException] ("Choose a stronger password"), the same
  /// one [SamePasswordException].
  @override
  Future<bool> changePassword(
    String accountId, {
    required String current,
    required String next,
  }) async {
    final user = _signedIn(accountId);
    final email = user.email;
    if (email == null || current.isEmpty) return false;
    final again = await _call(
      () => auth.signInWithPassword(email: email, password: current),
    );
    if (again == null) return false;
    if (again.id != user.id) throw const AccountMismatchException();
    await _call(() => auth.updatePassword(next));
    try {
      await _call(auth.signOutOthers);
    } on AccountException {
      // The password is changed; the other sessions end when their tokens
      // can't be refreshed any more.
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Account deletion (the `delete-account` Edge Function, with [privacy])
  // ---------------------------------------------------------------------------

  /// The server refuses club owners, re-checks [password], deletes the
  /// user's data (migrations 14–15), then the Auth user. Afterwards this device forgets the account:
  /// its session (already invalid) and its local photo / settings.
  @override
  Future<void> deleteAccount(String accountId, {required String password}) async {
    final gateway = privacy;
    if (gateway == null) throw const AccountDeletionUnavailableException();
    final user = _signedIn(accountId);
    // Approved policy: a club owner transfers the club first. The server
    // refuses owners too (the Edge Function and migration 15) — this only
    // answers before any password is sent.
    if ((_remote[user.id] ?? await _read(user)).hasClubOwnerProfile) {
      throw const ClubOwnershipTransferRequiredException();
    }
    if (password.isEmpty) throw const WrongPasswordException();
    // M5: the server doesn't remove the user's pictures (migration 31), so
    // the app does, first — after checking the password, so a typo never
    // costs the picture.
    if (media != null) await _removeOwnPictures(user, password);
    await _call(() => gateway.deleteAccount(password: password));
    try {
      await auth.signOut();
    } on GatewayException {
      // The user no longer exists: the server may refuse to end the session.
    }
    await overlay.clear(user.id);
    _remote.remove(user.id);
    _inMemory.remove(user.id);
    _phoneSharing.remove(user.id);
    _avatar.remove(user.id);
    _visibility.remove(user.id);
    _shownPhoto.remove(user.id);
  }

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
