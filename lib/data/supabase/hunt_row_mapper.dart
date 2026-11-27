import '../../core/models/models.dart';
import '../../core/utils/media_ref.dart';
import 'match_row_mapper.dart';

/// Rows of migration 33 (Player Hunt / Playing Opportunities) ↔ the app's
/// models (docs/M8_PLAYER_HUNT.md). A required field missing or of the wrong
/// type is a [MatchRowFormatException] — never a guessed value.
abstract final class HuntRowMapper {
  static const _roles = {
    'batsman': HuntRole.batsman,
    'bowler': HuntRole.bowler,
    'all_rounder': HuntRole.allRounder,
    'wicket_keeper': HuntRole.wicketKeeper,
  };
  static const _budgets = {
    'any': HuntBudget.any,
    'under_2000': HuntBudget.under2000,
    'from_2000_to_5000': HuntBudget.from2000to5000,
    'over_5000': HuntBudget.over5000,
  };
  static const _invites = {
    'pending': HuntInviteStatus.pending,
    'accepted': HuntInviteStatus.accepted,
    'declined': HuntInviteStatus.declined,
    'expired': HuntInviteStatus.expired,
  };

  static String roleCode(HuntRole r) =>
      _roles.entries.firstWhere((e) => e.value == r).key;
  static String budgetCode(HuntBudget b) =>
      _budgets.entries.firstWhere((e) => e.value == b).key;

  /// `null` for none or a role this version doesn't know.
  static HuntRole? optRole(Object? code) => _roles[code];
  static HuntRole role(Object? code) =>
      _roles[code] ?? (throw const MatchRowFormatException('role'));
  static HuntInviteStatus? optInvite(Object? code) => _invites[code];
  static HuntInviteStatus invite(Object? code) =>
      _invites[code] ?? (throw const MatchRowFormatException('status'));

  static double? _num(Map<String, dynamic> row, String key) =>
      switch (row[key]) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };

  static String _initials(String name) => name
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase())
      .take(2)
      .join();

  static String? _avatar(Map<String, dynamic> row) => MediaRef.of(
    MediaRef.avatarsBucket,
    MatchRowMapper.optText(row, 'avatar_path'),
  );

  /// The figures of a row, only when the player shares their stats.
  static HuntPlayerFigures? figures(Map<String, dynamic> row) =>
      row['stats_visible'] != true
      ? null
      : HuntPlayerFigures(
          matches: MatchRowMapper.optInt(row, 'matches') ?? 0,
          runs: MatchRowMapper.optInt(row, 'runs') ?? 0,
          wickets: MatchRowMapper.optInt(row, 'wickets') ?? 0,
          battingAverage: _num(row, 'batting_average'),
          strikeRate: _num(row, 'strike_rate'),
          economy: _num(row, 'economy'),
        );

  /// A post row (`publish_hunt_post`, `club_hunt_posts`, `hunt_open_posts`).
  static PlayerHuntPost post(Map<String, dynamic> row) {
    final clubName = MatchRowMapper.text(row, 'club_name');
    final display = MatchRowMapper.optText(row, 'club_short_name') ?? clubName;
    final time = MatchRowMapper.optText(row, 'match_time');
    return PlayerHuntPost(
      id: MatchRowMapper.text(row, 'post_id'),
      clubId: MatchRowMapper.text(row, 'club_id'),
      clubName: display,
      clubAbbr: _initials(display),
      clubCity: MatchRowMapper.optText(row, 'club_city'),
      role: role(row['role']),
      format: MatchRowMapper.format(row['format']),
      playersNeeded: MatchRowMapper.integer(row, 'players_needed'),
      location: MatchRowMapper.optText(row, 'city'),
      date: MatchRowMapper.optDate(row, 'match_date'),
      time: time != null && RegExp(r'^\d{2}:\d{2}').hasMatch(time)
          ? time.substring(0, 5)
          : null,
      budget: _budgets[row['budget']] ?? HuntBudget.any,
      notes: MatchRowMapper.optText(row, 'notes') ?? '',
      isMyClub: row['is_my_club'] == true,
      interested: row['interested'] == true,
      interestCount: MatchRowMapper.optInt(row, 'interest_count'),
      isOpen: row['status'] == 'open',
    );
  }

  /// `publish_hunt_post` parameters.
  static Map<String, Object?> publishParams(String clubId, PlayerHuntPost p) {
    final notes = p.notes.trim();
    return {
      'p_club_id': clubId,
      'p_role': roleCode(p.role),
      'p_format': MatchRowMapper.formatCode(p.format),
      'p_players_needed': p.playersNeeded,
      'p_city': p.location,
      'p_match_date': p.date == null ? null : MatchRowMapper.dateCode(p.date!),
      'p_match_time': p.time,
      'p_budget': budgetCode(p.budget),
      'p_notes': notes.isEmpty ? null : notes,
    };
  }

  /// A `hunt_open_players` row → an Available Players entry.
  static OpenPlayer openPlayer(Map<String, dynamic> row) => OpenPlayer(
    id: MatchRowMapper.text(row, 'user_id'),
    name: MatchRowMapper.text(row, 'full_name'),
    role: optRole(row['role']) ?? HuntRole.batsman,
    availabilityLabel: 'Available Now',
    city: MatchRowMapper.optText(row, 'city') ?? '',
    isMe: row['is_me'] == true,
    isMember: row['is_member'] == true,
    inviteStatus: optInvite(row['invite_status']),
    figures: figures(row),
    photoPath: _avatar(row),
  );

  /// A `my_hunt_listing` / `set_my_hunt_listing` row.
  static HuntListing listing(Map<String, dynamic> row) => HuntListing(
    listed: MatchRowMapper.flag(row, 'listed'),
    visible: row['visible'] == true,
    role: optRole(row['role']),
    city: MatchRowMapper.optText(row, 'city'),
  );

  /// A `club_hunt_interests` row.
  static HuntInterest interest(Map<String, dynamic> row) => HuntInterest(
    id: MatchRowMapper.text(row, 'interest_id'),
    postId: MatchRowMapper.text(row, 'post_id'),
    playerId: MatchRowMapper.text(row, 'user_id'),
    name: MatchRowMapper.optText(row, 'full_name') ?? 'A player',
    createdAt: MatchRowMapper.time(row, 'created_at'),
    role: optRole(row['role']),
    city: MatchRowMapper.optText(row, 'city'),
    phone: MatchRowMapper.optText(row, 'phone'),
    figures: figures(row),
    photoPath: _avatar(row),
  );

  /// A `club_hunt_invites` row.
  static ClubHuntInvite clubInvite(Map<String, dynamic> row) => ClubHuntInvite(
    id: MatchRowMapper.text(row, 'invite_id'),
    playerId: MatchRowMapper.text(row, 'user_id'),
    name: MatchRowMapper.optText(row, 'full_name') ?? 'A player',
    status: invite(row['status']),
    createdAt: MatchRowMapper.time(row, 'created_at'),
    role: optRole(row['role']),
    city: MatchRowMapper.optText(row, 'city'),
    postId: MatchRowMapper.optText(row, 'post_id'),
    expiresAt: MatchRowMapper.optTime(row, 'expires_at'),
    respondedAt: MatchRowMapper.optTime(row, 'responded_at'),
    phone: MatchRowMapper.optText(row, 'phone'),
  );

  /// A `my_hunt_invites` row.
  static PlayerHuntInvite playerInvite(Map<String, dynamic> row) {
    final format = row['post_format'];
    return PlayerHuntInvite(
      id: MatchRowMapper.text(row, 'invite_id'),
      clubId: MatchRowMapper.text(row, 'club_id'),
      clubName: MatchRowMapper.text(row, 'club_name'),
      clubShortName: MatchRowMapper.optText(row, 'club_short_name'),
      clubCity: MatchRowMapper.optText(row, 'club_city'),
      postRole: optRole(row['post_role']),
      postFormat: format == null ? null : MatchRowMapper.format(format),
      postDate: MatchRowMapper.optDate(row, 'post_match_date'),
      status: invite(row['status']),
      createdAt: MatchRowMapper.time(row, 'created_at'),
      expiresAt: MatchRowMapper.optTime(row, 'expires_at'),
      respondedAt: MatchRowMapper.optTime(row, 'responded_at'),
    );
  }
}
