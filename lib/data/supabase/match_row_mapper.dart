import '../../core/models/models.dart';
import 'membership_row_mapper.dart';

/// A row from migrations 17–19 that this app can't read: a required field
/// missing or of the wrong type, or a status / format this version doesn't
/// know. Repositories turn it into a generic "something went wrong" — the
/// row is never guessed at.
class MatchRowFormatException implements Exception {
  const MatchRowFormatException(this.field);
  final String field;
  @override
  String toString() => 'MatchRowFormatException: $field';
}

/// Rows of migrations 17–19 ↔ the app's models. Domain models never see a
/// response map.
///
/// Time: timestamps (`timestamptz`) are instants — parsed as UTC and shown
/// in the device's local time; sent as UTC ISO-8601. Dates (`proposed_date`,
/// `until_date`) are calendar dates in Pakistan (the database applies its
/// rules in Asia/Karachi): read as a local midnight with the same
/// year-month-day, and sent as that `YYYY-MM-DD`, never shifted.
abstract final class MatchRowMapper {
  /// Pakistan Standard Time: UTC+5 all year (no daylight saving).
  static const karachiOffset = Duration(hours: 5);

  /// The calendar date in Pakistan at [instant] — what the database calls
  /// "today" (`now() at time zone 'Asia/Karachi'`).
  static DateTime karachiDate(DateTime instant) {
    final pk = instant.toUtc().add(karachiOffset);
    return DateTime(pk.year, pk.month, pk.day);
  }

  // ---- Field readers ----

  static String text(Map<String, dynamic> row, String key) {
    final v = row[key];
    if (v is String && v.isNotEmpty) return v;
    throw MatchRowFormatException(key);
  }

  static String? optText(Map<String, dynamic> row, String key) {
    final v = row[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  static int? optInt(Map<String, dynamic> row, String key) =>
      switch (row[key]) {
        final int v => v,
        final num v when v == v.truncate() => v.toInt(),
        _ => null,
      };

  static int integer(Map<String, dynamic> row, String key) =>
      optInt(row, key) ?? (throw MatchRowFormatException(key));

  static bool flag(Map<String, dynamic> row, String key) =>
      row[key] is bool ? row[key] as bool : throw MatchRowFormatException(key);

  static DateTime? optTime(Map<String, dynamic> row, String key) {
    final v = row[key];
    if (v == null) return null;
    final t = v is String ? DateTime.tryParse(v) : null;
    if (t == null) throw MatchRowFormatException(key);
    return t.toLocal();
  }

  static DateTime time(Map<String, dynamic> row, String key) =>
      optTime(row, key) ?? (throw MatchRowFormatException(key));

  /// `YYYY-MM-DD` → that calendar date (local midnight).
  static DateTime? optDate(Map<String, dynamic> row, String key) {
    final v = row[key];
    if (v == null) return null;
    final m = v is String
        ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v)
        : null;
    if (m == null) throw MatchRowFormatException(key);
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  /// [d]'s calendar date as `YYYY-MM-DD` (its own year-month-day).
  static String dateCode(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String instantCode(DateTime t) => t.toUtc().toIso8601String();

  // ---- Codes ----

  static String formatCode(MatchFormat f) => MembershipRowMapper.formatCode(f);

  static MatchFormat format(Object? code) => switch (code) {
    'test' => MatchFormat.test,
    't20' => MatchFormat.t20,
    'odi' => MatchFormat.odi,
    't10' => MatchFormat.t10,
    'custom' => MatchFormat.custom,
    _ => throw const MatchRowFormatException('format'),
  };

  static MatchStatus matchStatus(Object? code) => switch (code) {
    'pending' => MatchStatus.pending,
    'confirmed' => MatchStatus.confirmed,
    'completed' => MatchStatus.completed,
    'cancelled' => MatchStatus.cancelled,
    _ => throw const MatchRowFormatException('status'),
  };

  static ChallengeStatus challengeStatus(Object? code) => switch (code) {
    'pending' => ChallengeStatus.pending,
    'accepted' => ChallengeStatus.accepted,
    'declined' => ChallengeStatus.declined,
    'expired' => ChallengeStatus.expired,
    _ => throw const MatchRowFormatException('status'),
  };

  static ChallengeDirection direction(Object? code) => switch (code) {
    'sent' => ChallengeDirection.sent,
    'received' => ChallengeDirection.received,
    _ => throw const MatchRowFormatException('direction'),
  };

  static SelectionRole selection(Object? code) => switch (code) {
    'playing' => SelectionRole.playing,
    'sub' => SelectionRole.sub,
    _ => throw const MatchRowFormatException('selection'),
  };

  static MemberRole? memberRole(Object? code) =>
      MemberRole.values.where((r) => r.name == code).firstOrNull;

  static PlayerAvailability availabilityStatus(Object? code) => switch (code) {
    'available' => PlayerAvailability.available,
    'limited' => PlayerAvailability.limited,
    'unavailable' => PlayerAvailability.unavailable,
    'injured' => PlayerAvailability.injured,
    'other' => PlayerAvailability.other,
    _ => throw const MatchRowFormatException('status'),
  };

  static String availabilityStatusCode(PlayerAvailability s) => switch (s) {
    PlayerAvailability.available => 'available',
    PlayerAvailability.limited => 'limited',
    PlayerAvailability.unavailable => 'unavailable',
    PlayerAvailability.injured => 'injured',
    PlayerAvailability.other => 'other',
  };

  static const _reasons = {
    'injury': AvailabilityReason.injury,
    'personal': AvailabilityReason.personal,
    'work': AvailabilityReason.work,
    'travel': AvailabilityReason.travel,
    'family_emergency': AvailabilityReason.familyEmergency,
    'rest_day': AvailabilityReason.restDay,
    'other': AvailabilityReason.other,
  };

  /// An unknown reason (a newer server) reads as none: it's optional.
  static AvailabilityReason? reason(Object? code) => _reasons[code];

  static String reasonCode(AvailabilityReason r) =>
      _reasons.entries.firstWhere((e) => e.value == r).key;

  // ---- Directory (migration 17) ----

  static ClubDirectoryEntry directoryEntry(Map<String, dynamic> row) =>
      ClubDirectoryEntry(
        id: text(row, 'club_id'),
        name: text(row, 'name'),
        shortName: optText(row, 'short_name'),
        city: text(row, 'city'),
        type: MembershipRowMapper.clubTypeFromCode(row['club_type'] as String?),
      );

  // ---- Challenges (migration 17) ----

  /// A `club_challenges()` row (one-sided, effective status).
  static Challenge challengeFromListRow(Map<String, dynamic> row) {
    final format = MatchRowMapper.format(row['format']);
    return Challenge(
      id: text(row, 'challenge_id'),
      opponentClubId: text(row, 'opponent_club_id'),
      opponentName: optText(row, 'opponent_name'),
      opponentShortName: optText(row, 'opponent_short_name'),
      opponentCity: optText(row, 'opponent_city'),
      direction: direction(row['direction']),
      status: challengeStatus(row['status']),
      createdAt: time(row, 'created_at'),
      format: format,
      customOvers: format == MatchFormat.custom
          ? optInt(row, 'custom_overs')
          : null,
      proposedAt:
          optDate(row, 'proposed_date') ??
          (throw const MatchRowFormatException('proposed_date')),
      groundName: text(row, 'venue_name'),
      message: optText(row, 'message'),
      matchId: optText(row, 'match_id'),
      expiresAt: time(row, 'expires_at'),
      respondedAt: optTime(row, 'decided_at'),
    );
  }

  /// A `match_challenges` table row (from send / respond), seen from
  /// [ownClubId]. A pending row past its expiry reads as expired.
  static Challenge challengeFromTableRow(
    Map<String, dynamic> row, {
    required String ownClubId,
  }) {
    final from = text(row, 'from_club_id');
    final to = text(row, 'to_club_id');
    if (from != ownClubId && to != ownClubId) {
      throw const MatchRowFormatException('club');
    }
    final format = MatchRowMapper.format(row['format']);
    return Challenge(
      id: text(row, 'id'),
      opponentClubId: from == ownClubId ? to : from,
      direction: from == ownClubId
          ? ChallengeDirection.sent
          : ChallengeDirection.received,
      status: challengeStatus(row['status']),
      createdAt: time(row, 'created_at'),
      format: format,
      customOvers: format == MatchFormat.custom
          ? optInt(row, 'custom_overs')
          : null,
      proposedAt:
          optDate(row, 'proposed_date') ??
          (throw const MatchRowFormatException('proposed_date')),
      groundName: text(row, 'venue_name'),
      message: optText(row, 'message'),
      matchId: optText(row, 'match_id'),
      expiresAt: time(row, 'expires_at'),
      respondedAt: optTime(row, 'decided_at'),
    );
  }

  /// `send_challenge()` parameters. [proposedAt]'s calendar date is sent.
  static Map<String, Object?> sendParams({
    required String fromClubId,
    required String toClubId,
    required MatchFormat format,
    required DateTime proposedAt,
    required String venueName,
    int? customOvers,
    String? message,
  }) => {
    'p_from_club_id': fromClubId,
    'p_to_club_id': toClubId,
    'p_format': formatCode(format),
    'p_custom_overs': format == MatchFormat.custom ? customOvers : null,
    'p_proposed_date': dateCode(proposedAt),
    'p_venue_name': venueName,
    'p_message': message,
  };

  // ---- Matches (migration 17) ----

  static MatchProposal? _proposal(
    Map<String, dynamic> row, {
    required bool? byMe,
  }) {
    final at = optTime(row, 'proposed_starts_at');
    if (at == null) return null;
    return MatchProposal(
      startsAt: at,
      venueName: text(row, 'proposed_venue_name'),
      city: optText(row, 'proposed_city'),
      byMe: byMe ?? (throw const MatchRowFormatException('proposed_by')),
      version: integer(row, 'proposal_version'),
    );
  }

  static MatchCancellation? _cancellation(
    Map<String, dynamic> row, {
    required bool? byMe,
  }) {
    final at = optTime(row, 'cancelled_at');
    if (at == null) return null;
    return MatchCancellation(
      at: at,
      byMe: byMe ?? (throw const MatchRowFormatException('cancelled_by')),
      reason: text(row, 'cancel_reason'),
    );
  }

  static ClubMatch _match(
    Map<String, dynamic> row, {
    required String id,
    required String opponentClubId,
    required bool challengedByMe,
    required bool? proposedByMe,
    required bool? cancelledByMe,
    String? opponentName,
  }) {
    final format = MatchRowMapper.format(row['format']);
    final status = matchStatus(row['status']);
    final cancellation = _cancellation(row, byMe: cancelledByMe);
    if ((status == MatchStatus.cancelled) != (cancellation != null)) {
      throw const MatchRowFormatException('cancelled_at');
    }
    return ClubMatch(
      id: id,
      opponentClubId: opponentClubId,
      opponentName: opponentName,
      status: status,
      format: format,
      customOvers: format == MatchFormat.custom
          ? optInt(row, 'custom_overs')
          : null,
      startsAt: optTime(row, 'starts_at'),
      venueName: optText(row, 'venue_name'),
      city: optText(row, 'city'),
      challengeId: optText(row, 'challenge_id'),
      challengedByMe: challengedByMe,
      proposal: _proposal(row, byMe: proposedByMe),
      cancellation: cancellation,
    );
  }

  /// A `club_matches()` row (one-sided, with the opponent's public name).
  static ClubMatch matchFromListRow(Map<String, dynamic> row) => _match(
    row,
    id: text(row, 'match_id'),
    opponentClubId: text(row, 'opponent_club_id'),
    opponentName: optText(row, 'opponent_name'),
    challengedByMe: flag(row, 'challenged_by_me'),
    proposedByMe: row['proposed_by_me'] as bool?,
    cancelledByMe: row['cancelled_by_me'] as bool?,
  );

  /// A `matches` table row (from propose / respond / cancel), seen from
  /// [ownClubId]. No opponent name in it: callers keep the one they have.
  static ClubMatch matchFromTableRow(
    Map<String, dynamic> row, {
    required String ownClubId,
  }) {
    final a = text(row, 'club_a_id');
    final b = text(row, 'club_b_id');
    if (a != ownClubId && b != ownClubId) {
      throw const MatchRowFormatException('club');
    }
    final proposedBy = optText(row, 'proposed_by_club_id');
    final cancelledBy = optText(row, 'cancelled_by_club_id');
    return _match(
      row,
      id: text(row, 'id'),
      opponentClubId: a == ownClubId ? b : a,
      challengedByMe: a == ownClubId,
      proposedByMe: proposedBy == null ? null : proposedBy == ownClubId,
      cancelledByMe: cancelledBy == null ? null : cancelledBy == ownClubId,
    );
  }

  static Map<String, Object?> proposeParams(
    String matchId,
    DateTime startsAt,
    String venueName,
    String? city,
  ) => {
    'p_match_id': matchId,
    'p_starts_at': instantCode(startsAt),
    'p_venue_name': venueName,
    'p_city': city,
  };

  // ---- Lineups (migration 18) ----

  static Map<String, Object?> lineupParams(
    String matchId,
    Lineup lineup, {
    String? captainMemberId,
    String? viceCaptainMemberId,
  }) => {
    'p_match_id': matchId,
    'p_name': lineup.name,
    'p_source_team_id': lineup.sourceTeamId,
    'p_players': [
      for (final m in lineup.members)
        {
          'member_id': m.playerId,
          'selection': m.selection == SelectionRole.sub ? 'sub' : 'playing',
        },
    ],
    'p_captain_member_id': captainMemberId,
    'p_vice_member_id': viceCaptainMemberId,
  };

  /// A `match_lineups` row from `save_match_lineup()`, with the players as
  /// sent (the function stores them in that order).
  static MatchLineup lineupFromSaved(Map<String, dynamic> row, Lineup sent) =>
      MatchLineup(
        matchId: text(row, 'match_id'),
        clubId: text(row, 'club_id'),
        name: text(row, 'name'),
        sourceTeamId: optText(row, 'source_team_id'),
        captainMemberId: optText(row, 'captain_member_id'),
        viceCaptainMemberId: optText(row, 'vice_captain_member_id'),
        savedAt: time(row, 'saved_at'),
        players: [
          for (final (i, m) in sent.members.indexed)
            MatchLineupPlayer(
              memberId: m.playerId,
              selection: m.selection,
              position: i + 1,
            ),
        ],
      );

  /// `match_lineup()` rows → one [MatchLineup] per club (normally one),
  /// players in position order. A lineup without players has one row with
  /// the player columns `null`.
  static List<MatchLineup> lineupsFromRows(
    String matchId,
    List<Map<String, dynamic>> rows,
  ) {
    final byClub = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      byClub.putIfAbsent(text(r, 'club_id'), () => []).add(r);
    }
    return [
      for (final MapEntry(key: clubId, value: list) in byClub.entries)
        MatchLineup(
          matchId: matchId,
          clubId: clubId,
          name: text(list.first, 'lineup_name'),
          sourceTeamId: optText(list.first, 'source_team_id'),
          captainMemberId: optText(list.first, 'captain_member_id'),
          viceCaptainMemberId: optText(list.first, 'vice_captain_member_id'),
          savedAt: time(list.first, 'saved_at'),
          players: [
            for (final r in list)
              if (optText(r, 'member_id') != null)
                MatchLineupPlayer(
                  memberId: text(r, 'member_id'),
                  selection: selection(r['selection']),
                  position: integer(r, 'position'),
                  name: optText(r, 'full_name'),
                  role: memberRole(r['member_role']),
                ),
          ]..sort((x, y) => x.position.compareTo(y.position)),
        ),
    ];
  }

  // ---- Availability (migration 19) ----

  /// A `player_availability` row. [PlayerAvailabilityRecord.since] is the
  /// row's `updated_at` (when it was last saved: the server keeps no
  /// separate start time). "Open to offers" isn't stored here (Player Hunt).
  static PlayerAvailabilityRecord availabilityFromRow(
    Map<String, dynamic> row,
  ) {
    final status = availabilityStatus(row['status']);
    final available = status == PlayerAvailability.available;
    return PlayerAvailabilityRecord(
      status: status,
      since: time(row, 'updated_at'),
      reason: available ? null : reason(row['reason']),
      untilDate: available ? null : optDate(row, 'until_date'),
      notes: optText(row, 'notes') ?? '',
    );
  }

  static Map<String, Object?> availabilityParams(PlayerAvailabilityRecord r) {
    final available = r.status == PlayerAvailability.available;
    final notes = r.notes.trim();
    return {
      'p_status': availabilityStatusCode(r.status),
      'p_reason': available || r.reason == null ? null : reasonCode(r.reason!),
      'p_until_date': available || r.untilDate == null
          ? null
          : dateCode(r.untilDate!),
      'p_notes': notes.isEmpty ? null : notes,
    };
  }

  /// A `club_player_availability()` row. No `updated_at`: the member set
  /// nothing (available) — no record.
  static ClubMemberAvailability memberAvailabilityFromRow(
    Map<String, dynamic> row,
  ) => ClubMemberAvailability(
    memberId: text(row, 'member_id'),
    userId: text(row, 'user_id'),
    name: optText(row, 'full_name') ?? '',
    role:
        memberRole(row['member_role']) ??
        (throw const MatchRowFormatException('member_role')),
    locksSelection: flag(row, 'locks_selection'),
    record: row['updated_at'] == null ? null : availabilityFromRow(row),
  );
}
