import '../../app/theme/tokens.dart' show CeColors;
import '../../core/domain/player_ranking.dart';
import '../../core/models/models.dart';
import '../../core/utils/pakistan_time.dart';
import 'match_row_mapper.dart';
import 'membership_row_mapper.dart';

/// Rows of migration 32 (club discovery, availability slots, rankings,
/// applicant statistics) ↔ the app's models (docs/M7_CLUB_DISCOVERY.md). A
/// required field missing or of the wrong type is a
/// [MatchRowFormatException] — never a guessed value. No owner or coach
/// name, captain, key player or rating exists on the server: those stay
/// empty, never invented.
abstract final class DiscoveryRowMapper {
  static const _formResults = {
    'won': MatchResult.won,
    'lost': MatchResult.lost,
    'tied': MatchResult.tied,
    'no_result': MatchResult.noResult,
    'abandoned': MatchResult.abandoned,
  };

  static List<String> _texts(Map<String, dynamic> row, String key) =>
      switch (row[key]) {
        null => const [],
        final List<dynamic> l => [
          for (final v in l)
            if (v is String && v.isNotEmpty) v,
        ],
        _ => throw MatchRowFormatException(key),
      };

  static double? _num(Map<String, dynamic> row, String key) =>
      switch (row[key]) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };

  static int _count(Map<String, dynamic> row, String key) =>
      MatchRowMapper.optInt(row, key) ?? 0;

  /// Badge letters: the short name (≤ 4 characters), else the name's initials.
  static String abbr(String name, String? shortName) {
    final s = shortName?.trim() ?? '';
    if (s.isNotEmpty && s.length <= 4) return s.toUpperCase();
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    return words
        .take(2)
        .map((w) => String.fromCharCode(w.runes.first).toUpperCase())
        .join();
  }

  /// A `club_public_profile` / `club_directory` row → [ClubSummary].
  /// [groundName] names a home ground id (none known: "Not listed").
  static ClubSummary clubSummary(
    Map<String, dynamic> row, {
    String? Function(String id)? groundName,
  }) {
    final name = MatchRowMapper.text(row, 'name');
    final city = MatchRowMapper.text(row, 'city');
    final shortName = MatchRowMapper.optText(row, 'short_name');
    final type = MembershipRowMapper.clubTypeFromCode(
      row['club_type'] as String?,
    );
    final played = _count(row, 'played');
    final won = _count(row, 'won');
    final groundId = MatchRowMapper.optText(row, 'home_ground_id');
    return ClubSummary(
      id: MatchRowMapper.text(row, 'club_id'),
      abbr: abbr(name, shortName),
      name: name,
      city: city,
      level: type?.label ?? 'Club',
      meta: [city, ?type?.label].join(' · '),
      established: MatchRowMapper.optInt(row, 'established_year') ?? 0,
      squadSize: _count(row, 'member_count'),
      formats: [
        for (final code in _texts(row, 'played_formats'))
          if (MatchFormat.values
                  .where((f) => MatchRowMapper.formatCode(f) == code)
                  .firstOrNull
              case final f?)
            f.label,
      ].join(' / '),
      homeGround:
          (groundId == null ? null : groundName?.call(groundId)) ??
          'Not listed',
      keyPlayers: const [],
      recentForm: [
        for (final code in _texts(row, 'recent_form')) ?_formResults[code],
      ],
      winRate: played > 0 ? (won * 100 / played).round() : 0,
      wins: won,
      losses: _count(row, 'lost'),
      played: played,
      about: '',
      color: CeColors.primaryDark,
    );
  }

  /// A `club_public_profile` row's record (the Club Dashboard's results).
  static ClubRecord record(Map<String, dynamic> row) => ClubRecord(
    played: _count(row, 'played'),
    won: _count(row, 'won'),
    lost: _count(row, 'lost'),
    tied: _count(row, 'tied'),
    noResult: _count(row, 'no_result'),
    abandoned: _count(row, 'abandoned'),
  );

  // ---- Availability slots ----

  /// `"14:00:00"` / `"14:00"` → (14, 0).
  static (int, int) _clock(Map<String, dynamic> row, String key) {
    final m = RegExp(r'^(\d{2}):(\d{2})')
        .firstMatch(MatchRowMapper.text(row, key));
    if (m == null) throw MatchRowFormatException(key);
    return (int.parse(m[1]!), int.parse(m[2]!));
  }

  static TimeSlot _slot(Map<String, dynamic> row) {
    final (sh, sm) = _clock(row, 'start_time');
    final (eh, em) = _clock(row, 'end_time');
    // A slot ends on the hour in this app; 23:59 (the latest end) reads as 24.
    final end = eh == 23 && em == 59 ? 24 : (em > 0 ? eh + 1 : eh);
    if (end <= sh) throw const MatchRowFormatException('end_time');
    return TimeSlot(startHour: sh, startMinute: sm, endHour: end);
  }

  /// A `post_match_slot` / `withdraw_match_slot` / `my_club_slots` row.
  static AvailabilitySlot slot(Map<String, dynamic> row) {
    final format = MatchRowMapper.format(row['format']);
    return AvailabilitySlot(
      id: MatchRowMapper.text(row, 'slot_id'),
      format: format,
      customOvers: format == MatchFormat.custom
          ? MatchRowMapper.optInt(row, 'custom_overs')
          : null,
      city: MatchRowMapper.text(row, 'city'),
      groundId: MatchRowMapper.optText(row, 'ground_id'),
      date:
          MatchRowMapper.optDate(row, 'slot_date') ??
          (throw const MatchRowFormatException('slot_date')),
      slot: _slot(row),
      notes: MatchRowMapper.optText(row, 'notes') ?? '',
    );
  }

  /// `HH:MM` for an hour / minute (24 → the latest end, 23:59).
  static String clockCode(int hour, int minute) => hour >= 24
      ? '23:59'
      : '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// `post_match_slot` parameters for [slot] of club [clubId] (its date is a
  /// Pakistan calendar date; its times Pakistan wall-clock times).
  static Map<String, Object?> postParams(String clubId, AvailabilitySlot slot) {
    String? blank(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
    return {
      'p_club_id': clubId,
      'p_format': MatchRowMapper.formatCode(slot.format),
      'p_custom_overs': slot.format == MatchFormat.custom
          ? slot.customOvers
          : null,
      'p_city': slot.city.trim(),
      'p_slot_date': MatchRowMapper.dateCode(slot.date),
      'p_start_time': clockCode(slot.slot.startHour, slot.slot.startMinute),
      'p_end_time': clockCode(slot.slot.endHour, 0),
      'p_ground_id': blank(slot.groundId),
      'p_venue_name': null,
      'p_notes': blank(slot.notes),
    };
  }

  /// An `open_match_slots` row → a "Teams Looking for Opponents" entry. The
  /// server has no rating: "—".
  static MatchSeekerListing seeker(
    Map<String, dynamic> row, {
    String? Function(String id)? groundName,
  }) {
    final format = MatchRowMapper.format(row['format']);
    final city = MatchRowMapper.text(row, 'city');
    final groundId = MatchRowMapper.optText(row, 'ground_id');
    final venue =
        MatchRowMapper.optText(row, 'venue_name') ??
        (groundId == null ? null : groundName?.call(groundId)) ??
        'Any ground in $city';
    return MatchSeekerListing(
      slotId: MatchRowMapper.text(row, 'slot_id'),
      clubId: MatchRowMapper.text(row, 'club_id'),
      rating: '—',
      format: format,
      customOvers: format == MatchFormat.custom
          ? MatchRowMapper.optInt(row, 'custom_overs')
          : null,
      startsAt: MatchRowMapper.time(row, 'starts_at'),
      venue: venue,
      clubName: MatchRowMapper.text(row, 'club_name'),
      clubShortName: MatchRowMapper.optText(row, 'club_short_name'),
      clubCity: MatchRowMapper.optText(row, 'club_city'),
      clubWins: _count(row, 'club_won'),
      clubLosses: _count(row, 'club_lost'),
      notes: MatchRowMapper.optText(row, 'notes') ?? '',
    );
  }

  // ---- Rankings and applicant statistics ----

  static SquadCategory _category(Object? code) => switch (code) {
    'bowler' => SquadCategory.bowler,
    'all_rounder' => SquadCategory.allRounder,
    _ => SquadCategory.batsman,
  };

  /// A `player_rankings` row → [RankingInput]; the club is the short name
  /// (else the name). The server has no rating (`null`).
  static RankingInput rankingInput(Map<String, dynamic> row) => RankingInput(
    playerId: MatchRowMapper.text(row, 'user_id'),
    name: MatchRowMapper.text(row, 'full_name'),
    club:
        MatchRowMapper.optText(row, 'club_short_name') ??
        MatchRowMapper.optText(row, 'club_name') ??
        'No club',
    role: _category(row['player_role']),
    completedMatches: _count(row, 'matches'),
    runs: _count(row, 'runs'),
    battingAverage: _num(row, 'batting_average'),
    strikeRate: _num(row, 'strike_rate'),
    wickets: _count(row, 'wickets'),
    economy: _num(row, 'economy'),
    bowlingAverage: _num(row, 'bowling_average'),
    recentWins: _count(row, 'recent_wins'),
    recentPlayed: _count(row, 'recent_played'),
    isMe: row['is_me'] == true,
  );

  /// A `club_applicant_stats` row → the Join Request profile's figures;
  /// `null` when the applicant doesn't share their stats or never played.
  static JoinRequestPerformance? applicantPerformance(
    Map<String, dynamic> row,
  ) {
    if (row['stats_visible'] != true) return null;
    final matches = _count(row, 'matches');
    if (matches == 0) return null;
    final avg = _num(row, 'batting_average');
    return JoinRequestPerformance(
      matches: matches,
      runs: _count(row, 'runs'),
      average: avg == null ? '—' : avg.toStringAsFixed(2),
      wickets: _count(row, 'wickets'),
    );
  }

  /// Pakistan's "today" at [now] — slots start from the next day.
  static DateTime firstSlotDate(DateTime now) {
    final today = PakistanTime.dateOf(now);
    return DateTime(today.year, today.month, today.day + 1);
  }
}
