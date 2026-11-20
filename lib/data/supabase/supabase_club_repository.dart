import 'package:clock/clock.dart';

import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'club_row_mapper.dart';
import 'local_club_overlay.dart';
import 'match_row_mapper.dart';
import 'membership_row_mapper.dart';
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
/// - Memberships (migration 11): with [membership] — the memberships switch
///   (`CRICECO_MEMBERSHIPS`) — members, join requests, the player pool and
///   join-by-code are the database's, through functions that identify the
///   caller by `auth.uid()`. Without it they come from [local], keyed by the
///   real club id, so they stay empty (D-S2-1), and joining by code isn't
///   offered — never a simulated lookup or request.
/// - Other clubs ([otherClubs], [clubSummary]) have no profile data in
///   Supabase yet: empty — never the demo's clubs (docs/PRODUCTION_DEMO_MODE.md).
///   The opponent directory ([searchOpponents]) is migration 17's
///   public-field lookup, with [matches] (the matches switch); without it,
///   none.
class SupabaseClubRepository implements ClubRepository {
  SupabaseClubRepository({
    required this.auth,
    required this.db,
    required this.overlay,
    required this.local,
    this.membership,
    this.matches,
    this.clock = const Clock(),
  });

  final AuthGateway auth;
  final ClubGateway db;
  final LocalClubOverlay overlay;
  final ClubRepository local;

  /// Migration 11's functions; `null` without the memberships switch.
  final MembershipGateway? membership;

  /// Migration 17's functions; `null` without the matches switch.
  final MatchGateway? matches;
  final Clock clock;

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
  // Other clubs: no directory in Supabase yet — and never the demo's clubs
  // (docs/PRODUCTION_DEMO_MODE.md)
  // ---------------------------------------------------------------------------

  @override
  Future<List<ClubSummary>> otherClubs() async => const [];

  @override
  Future<ClubSummary?> clubSummary(String clubId) async => null;

  // ---------------------------------------------------------------------------
  // Memberships (migration 11) — with [membership] (the CRICECO_MEMBERSHIPS
  // switch). Without it they stay empty: [local] is keyed by the real club
  // id, which has no seeded rows.
  // ---------------------------------------------------------------------------

  @override
  Future<List<ClubMember>> members(String clubId) async {
    final gateway = membership;
    if (gateway == null) return local.members(clubId);
    final rows = await _call(() => gateway.clubMembers(clubId));
    return [for (final r in rows) MembershipRowMapper.memberFromRow(r)];
  }

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
  }) {
    // People join through a request the owner approves; an owner can't add
    // someone who has no account (migration 11).
    if (membership != null) throw const PermissionDeniedException();
    return local.addMember(
      clubId,
      name: name,
      phone: phone,
      role: role,
      playingRole: playingRole,
      battingStyle: battingStyle,
      bowlingStyle: bowlingStyle,
      joinedAt: joinedAt,
    );
  }

  @override
  Future<List<JoinRequest>> joinRequests(String clubId) async {
    final gateway = membership;
    if (gateway == null) return local.joinRequests(clubId);
    final rows = await _call(() => gateway.clubJoinRequests(clubId));
    final now = clock.now();
    return [for (final r in rows) MembershipRowMapper.joinRequestFromRow(r, now: now)];
  }

  /// One database transaction: the request is locked, an already-decided
  /// one comes back unchanged, approval adds the membership (never the
  /// account-level Club Owner role).
  @override
  Future<JoinRequest> decideJoinRequest(
    String clubId,
    String requestId, {
    required bool approve,
    MemberRole role = MemberRole.player,
    required DateTime at,
    String? reason,
  }) async {
    final gateway = membership;
    if (gateway == null) {
      return local.decideJoinRequest(clubId, requestId, approve: approve, role: role, at: at, reason: reason);
    }
    if (approve && role == MemberRole.owner) {
      throw ArgumentError.value(role, 'role', 'A join request can never grant club ownership');
    }
    await _call(() => gateway.decideJoinRequest(
          requestId: requestId,
          approve: approve,
          role: MembershipRowMapper.memberRoleCode(role),
          reason: reason,
        ));
    // Read back the owner's view (with the applicant's details).
    final requests = await joinRequests(clubId);
    final decided = requests.where((r) => r.id == requestId).firstOrNull;
    if (decided == null) throw const ClubMembershipException('This request or member no longer exists.');
    return decided;
  }

  @override
  Future<List<SquadPlayer>> playerPool(String clubId) async {
    if (membership == null) return local.playerPool(clubId);
    final all = await members(clubId);
    return [for (final m in all) ?MembershipRowMapper.poolPlayerFrom(m)];
  }

  /// No match history is stored yet: nothing (never the demo's).
  @override
  Future<Map<String, List<MatchLogEntry>>> memberActivity(String clubId) async =>
      membership == null ? local.memberActivity(clubId) : const {};

  @override
  Future<void> removeMember(String clubId, String memberId) async {
    final gateway = membership;
    if (gateway == null) throw const ClubJoinUnavailableException();
    await _call(() => gateway.removeMember(memberId));
  }

  /// `match_club_directory()`: other clubs' id, name, short name, city and
  /// type only (owners only; the caller's own club never listed).
  @override
  Future<List<ClubDirectoryEntry>> searchOpponents({String? search, String? city}) async {
    final gateway = matches;
    if (gateway == null) return const [];
    final q = search?.trim();
    final c = city?.trim();
    final rows = await _call(() => gateway.clubDirectory(
          search: q == null || q.isEmpty ? null : q,
          city: c == null || c.isEmpty ? null : c,
        ));
    try {
      return [for (final r in rows) MatchRowMapper.directoryEntry(r)];
    } on MatchRowFormatException {
      throw const BackendOperationException();
    }
  }

  // ---------------------------------------------------------------------------
  // Join-by-code (migration 11) — only with the memberships switch
  // ---------------------------------------------------------------------------

  @override
  Future<ClubCodePreview?> findClubByCode(String code) async {
    final gateway = membership;
    if (gateway == null) throw const ClubJoinUnavailableException();
    final row = await _call(() => gateway.lookupClubByCode(code));
    return row == null ? null : MembershipRowMapper.previewFromRow(row, code);
  }

  @override
  Future<ClubJoinRequest> requestToJoin(String code) async {
    final gateway = membership;
    if (gateway == null) throw const ClubJoinUnavailableException();
    final row = await _call(() => gateway.requestToJoin(code));
    if (row == null) throw const ClubCodeNotFoundException();
    // The database's view, with the club's name.
    final mine = await myJoinRequest();
    if (mine == null) throw const BackendOperationException();
    return mine;
  }

  @override
  Future<ClubJoinRequest?> myJoinRequest() async {
    final gateway = membership;
    if (gateway == null) return null;
    final rows = await _call(gateway.myJoinRequests);
    // Newest first; a request the person withdrew isn't shown again.
    final latest = rows.where((r) => r['status'] != 'cancelled').firstOrNull;
    return latest == null ? null : MembershipRowMapper.outgoingFromRow(latest);
  }

  @override
  Future<ClubJoinRequest> cancelJoinRequest(ClubJoinRequest request) async {
    final gateway = membership;
    final id = request.id;
    if (gateway == null || id == null) throw const ClubJoinUnavailableException();
    await _call(() => gateway.cancelJoinRequest(id));
    return request.copyWith(status: JoinRequestStatus.cancelled);
  }

  @override
  Future<List<ClubMembership>> myMemberships() async {
    final gateway = membership;
    if (gateway == null) return const [];
    final rows = await _call(gateway.myMemberships);
    return [for (final r in rows) MembershipRowMapper.membershipFromRow(r)];
  }

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
