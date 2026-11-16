import '../../core/models/models.dart';
import 'profile_row_mapper.dart';

/// Pure conversions between the membership and team functions' rows
/// (migrations 11–12) and the app's models. Nothing here talks to Supabase,
/// and nothing is invented: details the database doesn't hold stay unknown.
abstract final class MembershipRowMapper {
  /// `club_members.member_role` / `join_requests.assigned_role`.
  static String memberRoleCode(MemberRole r) => switch (r) {
        MemberRole.owner => 'owner',
        MemberRole.player => 'player',
        MemberRole.coach => 'coach',
        MemberRole.manager => 'manager',
      };

  static MemberRole memberRoleFromCode(String? code) => switch (code) {
        'owner' => MemberRole.owner,
        'coach' => MemberRole.coach,
        'manager' => MemberRole.manager,
        _ => MemberRole.player,
      };

  static ClubType? clubTypeFromCode(String? code) => switch (code) {
        'professional' => ClubType.professional,
        'college_university' => ClubType.collegeUniversity,
        'corporate' => ClubType.corporate,
        _ => null,
      };

  static String _text(Object? v) => v is String ? v : '';

  static DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

  /// The display phone: `+923XXXXXXXXX` → `03XXXXXXXXX` (the app's form).
  static String displayPhone(Object? v) {
    final p = _text(v);
    return p.startsWith('+92') ? '0${p.substring(3)}' : p;
  }

  static PlayerRole? _playerRole(Object? v) => v is String ? ProfileRowMapper.playerRoleFromCode(v) : null;
  static BattingStyle? _batting(Object? v) => v is String ? ProfileRowMapper.battingStyleFromCode(v) : null;
  static BowlingStyle? _bowling(Object? v) => v is String ? ProfileRowMapper.bowlingStyleFromCode(v) : null;

  /// A `club_member_list` row → [ClubMember]. Its [ClubMember.poolPlayerId]
  /// is the member id: one person, one id in Members, squads and teams.
  static ClubMember memberFromRow(Map<String, dynamic> row) {
    final id = _text(row['member_id']);
    final role = _playerRole(row['player_role']);
    return ClubMember(
      id: id,
      name: _text(row['full_name']),
      phone: displayPhone(row['phone']),
      role: memberRoleFromCode(row['member_role'] as String?),
      playingRole: role,
      isWicketkeeper: role != null && row['is_wicketkeeper'] == true,
      battingStyle: _batting(row['batting_style']),
      bowlingStyle: _bowling(row['bowling_style']),
      poolPlayerId: role == null ? null : id,
      joinedAt: _time(row['joined_at']),
    );
  }

  /// Members who play → the club's player pool (Add Players, Suggest Team).
  /// Availability isn't stored yet, so nobody is marked unavailable.
  static SquadPlayer? poolPlayerFrom(ClubMember m) {
    final role = m.playingRole;
    if (role == null) return null;
    return SquadPlayer(
      id: m.id,
      name: m.name,
      position: m.isWicketkeeper ? '${role.label} · Wicket Keeper' : role.label,
      availability: PlayerAvailability.available,
    );
  }

  static JoinRequestReview _review(Object? status) => switch (status) {
        'approved' => JoinRequestReview.approved,
        'rejected' => JoinRequestReview.declined,
        _ => JoinRequestReview.pending,
      };

  /// Whole years between [dob] and [now] (`0` when unknown).
  static int ageOn(DateTime? dob, DateTime now) {
    if (dob == null) return 0;
    var age = now.year - dob.year;
    if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) age--;
    return age < 0 ? 0 : age;
  }

  /// "Applied today" / "Applied 1 day ago" / "Applied 5 days ago".
  static String appliedLabel(DateTime? at, DateTime now) {
    if (at == null) return 'Applied';
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
    if (days <= 0) return 'Applied today';
    return days == 1 ? 'Applied 1 day ago' : 'Applied $days days ago';
  }

  /// A `club_join_requests` row → [JoinRequest]. No match history is stored
  /// yet, so [JoinRequest.performance] stays `null` (never made up). A
  /// request from someone without a player profile shows the Batsman /
  /// right-handed defaults the model requires — flagged by [hasPlayerProfile].
  static JoinRequest joinRequestFromRow(Map<String, dynamic> row, {required DateTime now}) {
    final role = _playerRole(row['player_role']);
    return JoinRequest(
      id: _text(row['request_id']),
      name: _text(row['full_name']),
      // The database returns the age only — never the date of birth.
      age: (row['applicant_age'] as num?)?.toInt() ?? 0,
      city: _text(row['city']),
      battingStyle: _batting(row['batting_style']) ?? BattingStyle.rightHanded,
      bowlingStyle: _bowling(row['bowling_style']) ?? BowlingStyle.rightArmMedium,
      role: role ?? PlayerRole.batsman,
      phone: displayPhone(row['phone']),
      appliedLabel: appliedLabel(_time(row['created_at']), now),
      review: _review(row['status']),
      assignedRole: row['assigned_role'] == null ? null : memberRoleFromCode(row['assigned_role'] as String?),
      decidedAt: _time(row['decided_at']),
      declineReason: row['decline_reason'] as String?,
    );
  }

  /// A `lookup_club_by_code` row → [ClubCodePreview] (the code is the one the
  /// person typed; the database never returns it).
  static ClubCodePreview previewFromRow(Map<String, dynamic> row, String code) => ClubCodePreview(
        code: code.trim().toUpperCase(),
        name: _text(row['name']),
        city: row['city'] as String?,
        type: clubTypeFromCode(row['club_type'] as String?),
        memberCount: (row['member_count'] as num?)?.toInt(),
      );

  static JoinRequestStatus requestStatusFromCode(Object? status) => switch (status) {
        'approved' => JoinRequestStatus.approved,
        'rejected' => JoinRequestStatus.declined,
        'cancelled' => JoinRequestStatus.cancelled,
        _ => JoinRequestStatus.pending,
      };

  /// A `my_join_requests` row → the outgoing [ClubJoinRequest].
  static ClubJoinRequest outgoingFromRow(Map<String, dynamic> row) => ClubJoinRequest(
        id: row['request_id'] as String?,
        clubCode: _text(row['club_code']),
        clubName: _text(row['club_name']),
        status: requestStatusFromCode(row['status']),
        approvedRole: row['assigned_role'] == null ? null : memberRoleFromCode(row['assigned_role'] as String?),
        declineReason: row['decline_reason'] as String?,
      );

  /// A `my_club_memberships` row → [ClubMembership].
  static ClubMembership membershipFromRow(Map<String, dynamic> row) => ClubMembership(
        clubId: _text(row['club_id']),
        clubName: _text(row['club_name']),
        clubCode: _text(row['club_code']),
        role: memberRoleFromCode(row['member_role'] as String?),
      );

  // ---- Teams (migration 12) ----

  static String formatCode(MatchFormat f) => switch (f) {
        MatchFormat.test => 'test',
        MatchFormat.t20 => 't20',
        MatchFormat.odi => 'odi',
        MatchFormat.t10 => 't10',
        MatchFormat.custom => 'custom',
      };

  static MatchFormat formatFromCode(Object? code) => switch (code) {
        'test' => MatchFormat.test,
        'odi' => MatchFormat.odi,
        't10' => MatchFormat.t10,
        'custom' => MatchFormat.custom,
        _ => MatchFormat.t20,
      };

  /// A `teams` row with its embedded `team_players` → [Team] (squad in pick
  /// order). Player ids are club member ids.
  static Team teamFromRow(Map<String, dynamic> row) {
    final players = [
      if (row['team_players'] is List)
        for (final p in row['team_players'] as List)
          if (p is Map) Map<String, dynamic>.from(p),
    ]..sort((a, b) => ((a['position'] as num?) ?? 0).compareTo((b['position'] as num?) ?? 0));
    return Team(
      id: _text(row['id']),
      clubId: _text(row['club_id']),
      name: _text(row['name']),
      format: formatFromCode(row['format']),
      customOvers: (row['custom_overs'] as num?)?.toInt(),
      captainId: row['captain_member_id'] as String?,
      viceCaptainId: row['vice_captain_member_id'] as String?,
      status: row['status'] == 'archived' ? TeamStatus.archived : TeamStatus.active,
      createdAt: _time(row['created_at']) ?? DateTime.now(),
      members: [
        for (final p in players)
          TeamMember(
            playerId: _text(p['member_id']),
            selection: p['selection'] == 'sub' ? SelectionRole.sub : SelectionRole.playing,
          ),
      ],
    );
  }

  /// `save_team(...)` parameters for [team] (details, leaders, whole squad).
  static Map<String, Object?> saveParams(Team team) => {
        'p_team_id': team.id,
        'p_name': team.name,
        'p_format': formatCode(team.format),
        'p_custom_overs': team.format == MatchFormat.custom ? team.customOvers : null,
        'p_captain_member_id': team.captainId,
        'p_vice_member_id': team.viceCaptainId,
        'p_players': [
          for (final m in team.members)
            {'member_id': m.playerId, 'selection': m.selection == SelectionRole.sub ? 'sub' : 'playing'},
        ],
      };
}
