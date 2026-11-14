import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'club_row_mapper.dart';
import 'local_club_overlay.dart';
import 'supabase_error_mapper.dart';
import 'supabase_gateways.dart';

/// [ClubRepository] on Supabase (Stage 3, migration 5): the signed-in
/// owner's own club lives in `public.clubs`.
///
/// - Creating a club is one `create_club()` call: the club, its join code and
///   `profiles.role` in one transaction; a retry returns the existing club.
/// - Every own-club call is for the signed-in user only: another account id
///   is refused (or, for [ownClub], answered with `null`) before any
///   database call.
/// - The club picture stays on this device ([LocalClubOverlay], D-S2-2).
/// - Members, join requests, the squad pool and activity aren't stored in
///   Supabase yet: they come from [local], keyed by the real club id, so a
///   new club starts empty (D-S2-1). The opponent clubs ([otherClubs],
///   [clubSummary]) stay the demo data (D-3A-4).
/// - Joining a club by its code isn't available yet (Phase 3E): never a
///   simulated lookup or request.
class SupabaseClubRepository implements ClubRepository {
  SupabaseClubRepository({
    required this.auth,
    required this.db,
    required this.overlay,
    required this.local,
  });

  final AuthGateway auth;
  final ClubGateway db;
  final LocalClubOverlay overlay;
  final ClubRepository local;

  /// The club as last read from the database (without the picture), per
  /// owner id — what [updateClub] compares against.
  final Map<String, Club> _remote = {};

  // ---------------------------------------------------------------------------
  // The owner's own club (public.clubs)
  // ---------------------------------------------------------------------------

  /// `null` when signed out, when [accountId] isn't the signed-in user (no
  /// database call), or when the user has no club.
  @override
  Future<Club?> ownClub(String accountId) async {
    final user = auth.currentUser;
    if (user == null || user.id != accountId) return null;
    final row = await _call(() => db.fetchOwnClub(user.id));
    if (row == null) {
      _remote.remove(user.id);
      return null;
    }
    return _keep(user.id, row);
  }

  /// [hasLogo] isn't stored: the picture follows through [updateClub]
  /// (`withLogo`), and stays on this device.
  @override
  Future<Club> createClub({
    required String accountId,
    required String name,
    required String city,
    required ClubType type,
    String? ownerName,
    String? address,
    String? email,
    String? homeGroundId,
    bool hasLogo = false,
  }) async {
    final user = _signedIn(accountId);
    final row = await _call(
      () => db.createClub(
        ClubRowMapper.createParams(
          name: name,
          city: city,
          type: type,
          ownerName: ownerName,
          address: address,
          email: email,
          homeGroundId: homeGroundId,
        ),
      ),
    );
    return _keep(user.id, row);
  }

  /// Writes only the columns that changed; the picture is saved on this
  /// device (a picture-only change makes no database call).
  @override
  Future<Club> updateClub(String accountId, Club club) async {
    final user = _signedIn(accountId);
    var saved = _remote[user.id];
    if (saved == null) {
      final row = await _call(() => db.fetchOwnClub(user.id));
      if (row == null) throw const PermissionDeniedException();
      saved = ClubRowMapper.clubFromRow(row);
      _remote[user.id] = saved;
    }
    if (club.id != saved.id) throw const PermissionDeniedException();

    final columns = ClubRowMapper.updateColumns(saved, club);
    if (columns.isNotEmpty) {
      final row = await _call(() => db.updateClub(club.id, user.id, columns));
      // No row updated: not this user's club (D-3A-3).
      if (row == null) throw const PermissionDeniedException();
      saved = ClubRowMapper.clubFromRow(row);
      _remote[user.id] = saved;
    }
    await overlay.save(club);
    return saved.withLogo(club.logoPath);
  }

  // ---------------------------------------------------------------------------
  // Not in Supabase yet: delegated to [local] (keyed by the real club id)
  // ---------------------------------------------------------------------------

  @override
  Future<List<ClubSummary>> otherClubs() => local.otherClubs();

  @override
  Future<ClubSummary?> clubSummary(String clubId) => local.clubSummary(clubId);

  @override
  Future<List<ClubMember>> members(String clubId) => local.members(clubId);

  @override
  Future<ClubMember> addMember(
    String clubId, {
    required String name,
    required String phone,
    required MemberRole role,
    PlayerRole? playingRole,
    BattingStyle? battingStyle,
    BowlingStyle? bowlingStyle,
    DateTime? joinedAt,
  }) => local.addMember(
    clubId,
    name: name,
    phone: phone,
    role: role,
    playingRole: playingRole,
    battingStyle: battingStyle,
    bowlingStyle: bowlingStyle,
    joinedAt: joinedAt,
  );

  @override
  Future<List<JoinRequest>> joinRequests(String clubId) =>
      local.joinRequests(clubId);

  @override
  Future<JoinRequest> decideJoinRequest(
    String clubId,
    String requestId, {
    required bool approve,
    MemberRole role = MemberRole.player,
    required DateTime at,
    String? reason,
  }) => local.decideJoinRequest(
    clubId,
    requestId,
    approve: approve,
    role: role,
    at: at,
    reason: reason,
  );

  @override
  Future<List<SquadPlayer>> playerPool(String clubId) =>
      local.playerPool(clubId);

  @override
  Future<Map<String, List<MatchLogEntry>>> memberActivity(String clubId) =>
      local.memberActivity(clubId);

  // ---------------------------------------------------------------------------
  // Join-by-code: Phase 3E (needs its own migration)
  // ---------------------------------------------------------------------------

  @override
  Future<ClubCodePreview?> findClubByCode(String code) async =>
      throw const ClubJoinUnavailableException();

  @override
  Future<ClubJoinRequest> requestToJoin(String code) async =>
      throw const ClubJoinUnavailableException();

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Caches the database club and returns it with this device's picture.
  Club _keep(String userId, Map<String, dynamic> row) {
    final club = ClubRowMapper.clubFromRow(row);
    _remote[userId] = club;
    return overlay.applyTo(club);
  }

  /// The signed-in user, who must own [accountId].
  AuthUser _signedIn(String accountId) {
    final user = auth.currentUser;
    if (user == null) throw const NotSignedInException();
    if (user.id != accountId) throw const AccountMismatchException();
    return user;
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
