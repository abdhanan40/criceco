import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The two narrow seams between [SupabaseAccountRepository] and Supabase.
/// They use the app's own types only, so the repository is tested with
/// fakes; the real implementations (on `supabase_flutter`) are in
/// `supabase_sdk_gateways.dart`. Every method throws a [GatewayException] on
/// failure.

/// The signed-in Supabase Auth user, as the app needs it.
class AuthUser {
  const AuthUser({required this.id, this.email, this.metadata = const {}});
  final String id;
  final String? email;

  /// Auth user metadata (`raw_user_meta_data`), e.g. `full_name` (D5).
  final Map<String, Object?> metadata;

  String? get fullName {
    final v = metadata['full_name'];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }
}

class SignUpResult {
  const SignUpResult({required this.user, required this.hasSession});
  final AuthUser user;

  /// `false` when the email address must be confirmed first.
  final bool hasSession;
}

abstract interface class AuthGateway {
  /// The user of the persisted session, or `null` when signed out.
  AuthUser? get currentUser;

  /// `null` for wrong credentials.
  Future<AuthUser?> signInWithPassword({
    required String email,
    required String password,
  });

  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required Map<String, Object?> metadata,
  });

  /// Confirms a sign-up with the 6-digit code from the email (AUTH-02) and
  /// starts the session. A wrong, expired or already used code is a
  /// [GatewayInvalidCodeException] (the backend doesn't tell them apart).
  Future<AuthUser> verifySignUpCode({
    required String email,
    required String code,
  });

  /// Sends a new sign-up code to [email]. Too soon after the last one, or
  /// too many: [GatewayRateLimitedException].
  Future<void> resendSignUpCode({required String email});

  /// Ends the session on this device.
  Future<void> signOut();

  // ---- AUTH-04: password recovery ----

  /// Sends the password-recovery email to [email]: a 6-digit code, and a
  /// link back to [redirectTo] (the app's auth callback). The backend
  /// answers the same whether or not the address has an account.
  Future<void> sendPasswordReset({required String email, String? redirectTo});

  /// Checks the 6-digit recovery code and starts a recovery session for that
  /// user. Wrong, expired or used: [GatewayInvalidCodeException].
  Future<AuthUser> verifyRecoveryCode({
    required String email,
    required String code,
  });

  /// Sets a new password for the signed-in user (here: the recovery session).
  /// The old password: [GatewaySamePasswordException].
  Future<void> updatePassword(String password);

  /// Ends every session of the signed-in user, on all devices (after a
  /// password reset).
  Future<void> signOutEverywhere();

  // ---- AUTH-05: Google ----

  /// Opens Google sign-in (the backend's OAuth flow) in the browser. Returns
  /// once it is open; the session arrives later through [events] (Android)
  /// or as [takeStartEvent] after the page comes back (web). `false` when
  /// the browser couldn't be opened.
  Future<bool> startGoogleSignIn({String? redirectTo});

  // ---- Sessions that don't come from a call the app is waiting on ----

  /// How the current session was started (from its token), or
  /// [AuthSessionKind.none] when signed out.
  AuthSessionKind get sessionKind;

  /// The auth event of the app start (a recovery link, a Google return or a
  /// failed link handled while the backend started), or `null`. Call once,
  /// at app start: events after it arrive through [events].
  Future<AuthGatewayEvent?> takeStartEvent();

  /// Auth events after [takeStartEvent]: recovery links and Google returns
  /// opened while the app runs (Android), failed links, expired sessions.
  Stream<AuthGatewayEvent> get events;
}

/// How a session was started (the token's `amr` claim).
enum AuthSessionKind {
  none,

  /// A password-recovery code or link: only good for setting a new password.
  recovery,

  /// Google (OAuth).
  oauth,

  /// Password, sign-up code or anything else.
  other,
}

/// An auth event the app didn't start a call for (AUTH-04/05).
sealed class AuthGatewayEvent {
  const AuthGatewayEvent();
}

/// A password-recovery link (or code) started a recovery session.
final class GatewayRecoveryStarted extends AuthGatewayEvent {
  const GatewayRecoveryStarted();
}

/// Google sign-in came back with a session for [user].
final class GatewayOAuthSignedIn extends AuthGatewayEvent {
  const GatewayOAuthSignedIn(this.user);
  final AuthUser user;
}

/// An auth link (recovery or Google) came back with an error.
final class GatewayLinkFailed extends AuthGatewayEvent {
  const GatewayLinkFailed(this.reason);
  final GatewayLinkError reason;
}

/// The backend ended the session (refresh token expired or revoked).
final class GatewaySessionExpired extends AuthGatewayEvent {
  const GatewaySessionExpired();
}

enum GatewayLinkError {
  /// Expired or already used (`otp_expired`).
  expired,

  /// Google sign-in was cancelled or permission refused (`access_denied`).
  cancelled,

  /// Not usable here: opened on another device or browser, or malformed.
  invalid,

  /// The provider or backend reported an error.
  failed,
}

/// One account's rows: `profiles` plus its (optional) address and player
/// rows, and the id of the club it owns (`clubs(id)`, migration 5), as JSON
/// maps.
class AccountRows {
  const AccountRows({
    required this.profile,
    this.currentAddress,
    this.permanentAddress,
    this.playerProfile,
    this.club,
    this.roles = const [],
  });
  final Map<String, dynamic> profile;
  final Map<String, dynamic>? currentAddress;
  final Map<String, dynamic>? permanentAddress;
  final Map<String, dynamic>? playerProfile;

  /// `{id}` of the user's own club, `null` when they have none.
  final Map<String, dynamic>? club;

  /// The user's `user_roles` rows (`{role}`, migration 7); empty when none.
  final List<Map<String, dynamic>> roles;
}

abstract interface class ProfileGateway {
  /// `null` when the user has no `profiles` row (RLS: own row only).
  Future<AccountRows?> fetchAccountRows(String userId);

  /// `rpc('save_profile_setup', params)` — one transaction.
  Future<void> saveProfileSetup(Map<String, Object?> params);

  /// `rpc('save_profile_setup_v2', params)` — the same with city ids
  /// (migration 8); one transaction.
  Future<void> saveProfileSetupV2(Map<String, Object?> params);

  /// `rpc('update_profile_details', params)` — Edit Profile's save
  /// (migration 9): the profile details and the existing address rows in
  /// one transaction.
  Future<void> updateProfileDetails(Map<String, Object?> params);

  /// Upsert into `player_profiles` on `user_id`.
  Future<void> upsertPlayerProfile(Map<String, Object?> row);

  /// `update profiles set role = role where id = userId and role is null`:
  /// never overwrites a role that is already set.
  Future<void> setRoleIfUnset(String userId, String role);
}

/// The signed-in owner's own `clubs` row (migration 5). Rows are the JSON
/// maps the REST API returns; RLS limits every call to the caller's club.
abstract interface class ClubGateway {
  /// `select * from clubs where owner_id = userId` — `null` when the user
  /// has no club.
  Future<Map<String, dynamic>?> fetchOwnClub(String userId);

  /// `rpc('create_club', params)` — the club, its join code and
  /// `profiles.role` in one transaction; returns the club row (the existing
  /// one when the user already has a club).
  Future<Map<String, dynamic>> createClub(Map<String, Object?> params);

  /// `update clubs set columns where id = clubId and owner_id = userId`,
  /// returning the updated row — `null` when no row was updated (not the
  /// caller's club).
  Future<Map<String, dynamic>?> updateClub(
    String clubId,
    String userId,
    Map<String, Object?> columns,
  );
}

/// Club memberships (migration 11). Every call is a database function that
/// identifies the caller by `auth.uid()` — never by an id the app sends —
/// and returns JSON maps (one row) or lists of them.
abstract interface class MembershipGateway {
  /// `rpc('lookup_club_by_code')` — `null` for an unknown code.
  Future<Map<String, dynamic>?> lookupClubByCode(String code);

  /// `rpc('request_to_join_club')` — the new `join_requests` row, or `null`
  /// for an unknown code (counted by the database's brute-force throttle).
  Future<Map<String, dynamic>?> requestToJoin(String code);

  /// `rpc('cancel_join_request')` — the cancelled row.
  Future<Map<String, dynamic>> cancelJoinRequest(String requestId);

  /// `rpc('my_join_requests')` — the caller's requests, newest first.
  Future<List<Map<String, dynamic>>> myJoinRequests();

  /// `rpc('my_club_memberships')` — the caller's active memberships.
  Future<List<Map<String, dynamic>>> myMemberships();

  /// `rpc('club_join_requests')` — the owner's view of [clubId]'s requests.
  Future<List<Map<String, dynamic>>> clubJoinRequests(String clubId);

  /// `rpc('decide_join_request')` — the decided (or unchanged) request.
  Future<Map<String, dynamic>> decideJoinRequest({
    required String requestId,
    required bool approve,
    required String role,
    String? reason,
  });

  /// `rpc('club_member_list')` — the owner's view of [clubId]'s members.
  Future<List<Map<String, dynamic>>> clubMembers(String clubId);

  /// `rpc('remove_club_member')` — the member row, now removed.
  Future<Map<String, dynamic>> removeMember(String memberId);
}

/// Teams and squads (migration 12). Reads go through RLS (the club owner
/// only); writes are database functions.
abstract interface class TeamGateway {
  /// `select *, team_players(*) from teams where club_id = … and status =
  /// 'active' order by created_at`.
  Future<List<Map<String, dynamic>>> fetchTeams(String clubId);

  /// `rpc('create_team', params)` — the new team row.
  Future<Map<String, dynamic>> createTeam(Map<String, Object?> params);

  /// `rpc('save_team', params)` — details and whole squad, one transaction.
  Future<Map<String, dynamic>> saveTeam(Map<String, Object?> params);

  /// `rpc('archive_team')` — the archived team row.
  Future<Map<String, dynamic>> archiveTeam(String teamId);
}

/// The location lookup (migration 6), read-only. Rows are the JSON maps the
/// REST API returns; RLS lets any signed-in user read them.
abstract interface class LocationGateway {
  /// `select id, name, display_name, kind, sort_order from provinces
  /// where is_active order by sort_order`.
  Future<List<Map<String, dynamic>>> fetchProvinces();

  /// `select id, province_id, name from districts where province_id = …
  /// and is_active order by name`.
  Future<List<Map<String, dynamic>>> fetchDistricts(int provinceId);

  /// `rpc('search_cities', params)` — rows of `v_city_options`.
  Future<List<Map<String, dynamic>>> searchCities(Map<String, Object?> params);

  /// `select * from v_city_options where id = …` — `null` when not listed.
  Future<Map<String, dynamic>?> fetchCity(int id);
}

/// What a gateway reports when a call fails.
sealed class GatewayException implements Exception {
  const GatewayException();
}

/// Offline, timeout, DNS, 5xx — the call may not have reached the server.
class GatewayNetworkException extends GatewayException {
  const GatewayNetworkException();
}

/// The database refused the data (`23514` check, `23502` not-null, …).
/// [constraint] is the constraint name when the backend reports one.
class GatewayConstraintException extends GatewayException {
  const GatewayConstraintException({
    required this.sqlState,
    required this.message,
    this.constraint,
  });
  final String sqlState;
  final String message;
  final String? constraint;
}

/// No valid session: missing, invalid or expired JWT (HTTP 401 / 403,
/// `PGRST301`–`PGRST303`). A `42501` privilege / RLS refusal is a
/// [GatewayConstraintException] instead (sqlState `42501`): the session is
/// fine there.
class GatewayPermissionException extends GatewayException {
  const GatewayPermissionException();
}

/// Sign-in for an account whose email address isn't confirmed yet.
class GatewayEmailNotConfirmedException extends GatewayException {
  const GatewayEmailNotConfirmedException();
}

/// A verification code that is wrong, expired or already used (Supabase
/// answers all three with `otp_expired`).
class GatewayInvalidCodeException extends GatewayException {
  const GatewayInvalidCodeException();
}

/// Too many requests or emails in a short time (HTTP 429,
/// `over_email_send_rate_limit`, `over_request_rate_limit`).
class GatewayRateLimitedException extends GatewayException {
  const GatewayRateLimitedException();
}

/// A new password equal to the current one (`same_password`).
class GatewaySamePasswordException extends GatewayException {
  const GatewaySamePasswordException();
}

/// Account deletion: the password given to confirm it is wrong.
class GatewayWrongPasswordException extends GatewayException {
  const GatewayWrongPasswordException();
}

/// Account deletion refused: the user still owns a club (migration 15,
/// `CLUB_OWNERSHIP_TRANSFER_REQUIRED`).
class GatewayOwnershipTransferRequiredException extends GatewayException {
  const GatewayOwnershipTransferRequiredException();
}

/// Account deletion: the data was deleted but the sign-in account wasn't
/// (`auth_delete_failed`). Repeating the same request completes it.
class GatewayDeletionIncompleteException extends GatewayException {
  const GatewayDeletionIncompleteException();
}

/// Anything else (bad response, unexpected error). [detail] is a short code,
/// never user data.
class GatewayUnexpectedException extends GatewayException {
  const GatewayUnexpectedException(this.detail);
  final String detail;
}

const _notInitialized =
    'Supabase is not initialized: start the app through main() '
    '(backendOverrides), or override the gateway providers in tests';

/// Overridden at startup in Supabase mode (`backendOverrides`) with the
/// real gateways, and with fakes in tests.
final authGatewayProvider = Provider<AuthGateway>(
  (ref) => throw StateError(_notInitialized),
);
final profileGatewayProvider = Provider<ProfileGateway>(
  (ref) => throw StateError(_notInitialized),
);
final clubGatewayProvider = Provider<ClubGateway>(
  (ref) => throw StateError(_notInitialized),
);
final locationGatewayProvider = Provider<LocationGateway>(
  (ref) => throw StateError(_notInitialized),
);
final membershipGatewayProvider = Provider<MembershipGateway>(
  (ref) => throw StateError(_notInitialized),
);
final teamGatewayProvider = Provider<TeamGateway>(
  (ref) => throw StateError(_notInitialized),
);
final accountPrivacyGatewayProvider = Provider<AccountPrivacyGateway>(
  (ref) => throw StateError(_notInitialized),
);
final ownershipGatewayProvider = Provider<OwnershipGateway>(
  (ref) => throw StateError(_notInitialized),
);
final matchGatewayProvider = Provider<MatchGateway>(
  (ref) => throw StateError(_notInitialized),
);

/// Challenges, matches, lineups and player availability (migrations 17–19,
/// with the `CRICECO_MATCHES` switch). Every call is a database function
/// that identifies the caller by `auth.uid()` and checks club ownership or
/// membership itself; the app never sends a user id. Write functions return
/// the changed table row; read functions return their own row shapes
/// (docs/MATCHES_BACKEND.md).
abstract interface class MatchGateway {
  /// `rpc('match_club_directory', {p_search, p_city})` — other clubs'
  /// public fields, at most 50.
  Future<List<Map<String, dynamic>>> clubDirectory({
    String? search,
    String? city,
  });

  /// `rpc('send_challenge', {p_from_club_id, p_to_club_id, p_format,
  /// p_custom_overs, p_proposed_date, p_venue_name, p_message})` — the new
  /// `match_challenges` row.
  Future<Map<String, dynamic>> sendChallenge(Map<String, Object?> params);

  /// `rpc('respond_to_challenge', {p_challenge_id, p_accept})` — the
  /// challenge row: accepted (with `match_id`), declined or expired.
  Future<Map<String, dynamic>> respondToChallenge(
    String challengeId, {
    required bool accept,
  });

  /// `rpc('club_challenges', {p_club_id})` — sent and received, newest first.
  Future<List<Map<String, dynamic>>> clubChallenges(String clubId);

  /// `rpc('club_matches', {p_club_id})` — one-sided match rows.
  Future<List<Map<String, dynamic>>> clubMatches(String clubId);

  /// `rpc('propose_match_schedule', {p_match_id, p_starts_at, p_venue_name,
  /// p_city})` — the `matches` row.
  Future<Map<String, dynamic>> proposeSchedule(Map<String, Object?> params);

  /// `rpc('respond_to_match_schedule', {p_match_id, p_proposal_version,
  /// p_accept})` — the `matches` row.
  Future<Map<String, dynamic>> respondToSchedule(
    String matchId, {
    required int proposalVersion,
    required bool accept,
  });

  /// `rpc('cancel_match', {p_match_id, p_reason})` — the `matches` row.
  Future<Map<String, dynamic>> cancelMatch(String matchId, String reason);

  /// `rpc('save_match_lineup', {p_match_id, p_name, p_source_team_id,
  /// p_players, p_captain_member_id, p_vice_member_id})` — the
  /// `match_lineups` row (the players are stored in the order sent).
  Future<Map<String, dynamic>> saveLineup(Map<String, Object?> params);

  /// `rpc('match_lineup', {p_match_id})` — one row per player of the
  /// caller's own club(s) lineup; none when nothing is saved.
  Future<List<Map<String, dynamic>>> matchLineup(String matchId);

  /// `rpc('set_my_availability', {p_status, p_reason, p_until_date,
  /// p_notes})` — the caller's `player_availability` row.
  Future<Map<String, dynamic>> setMyAvailability(Map<String, Object?> params);

  /// `rpc('my_availability')` — the caller's row, or `null` (available).
  Future<Map<String, dynamic>?> myAvailability();

  /// `rpc('club_player_availability', {p_club_id})` — the owner's view of
  /// the club's active members.
  Future<List<Map<String, dynamic>>> clubAvailability(String clubId);
}

/// Phone-number consent and account deletion (migrations 13–14 and the
/// `delete-account` Edge Function, with the `CRICECO_ACCOUNT_PRIVACY`
/// switch). Every call is for the signed-in user only: the functions read
/// the user from the session, never from a parameter.
abstract interface class AccountPrivacyGateway {
  /// `rpc('my_privacy_settings')` — whether the signed-in user shares their
  /// phone number with the owners of clubs they join or apply to.
  Future<bool> fetchPhoneSharing();

  /// `rpc('set_phone_sharing', {p_share})`.
  Future<void> setPhoneSharing(bool share);

  /// `functions.invoke('delete-account')`: re-checks [password] on the
  /// server, deletes the user's data, then the Auth user. Throws
  /// [GatewayWrongPasswordException] for a wrong password.
  Future<void> deleteAccount({required String password});
}

/// Club ownership transfer (migration 16, with the `CRICECO_ACCOUNT_PRIVACY`
/// switch): offers and the history through database functions. The user is
/// always the session's (auth.uid()), never a parameter.
abstract interface class OwnershipGateway {
  /// `rpc('offer_club_ownership', {p_club_id, p_member_id, p_previous_owner_role})`.
  Future<Map<String, dynamic>> offer(Map<String, Object?> params);

  /// `rpc('cancel_ownership_transfer', {p_transfer_id})` — by the owner.
  Future<Map<String, dynamic>> cancel(String transferId);

  /// `rpc('reject_ownership_transfer', {p_transfer_id})` — by the recipient.
  Future<Map<String, dynamic>> reject(String transferId);

  /// `rpc('accept_ownership_transfer', {p_transfer_id})` — by the recipient;
  /// the only call that moves the club.
  Future<Map<String, dynamic>> accept(String transferId);

  /// `rpc('club_ownership_transfers', {p_club_id})` — the club's history.
  Future<List<Map<String, dynamic>>> clubTransfers(String clubId);

  /// `rpc('my_ownership_offers')` — open offers to the signed-in user.
  Future<List<Map<String, dynamic>>> myOffers();
}
