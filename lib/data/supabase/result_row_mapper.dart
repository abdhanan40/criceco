import '../../core/models/models.dart';
import 'match_row_mapper.dart';

/// Rows of migrations 20–23 ↔ the app's models. Same rules as
/// [MatchRowMapper]: a required field missing or of the wrong type, or a
/// code this version doesn't know, is a [MatchRowFormatException] — never a
/// guessed value. Timestamps are instants, shown in local time.
abstract final class ResultRowMapper {
  // ---- Codes ----

  static const _outcomes = {
    'club_a_won': ResultOutcome.clubAWon,
    'club_b_won': ResultOutcome.clubBWon,
    'tie': ResultOutcome.tie,
    'no_result': ResultOutcome.noResult,
    'abandoned': ResultOutcome.abandoned,
  };
  static const _statuses = {
    'submitted': ResultStatus.submitted,
    'confirmed': ResultStatus.confirmed,
    'rejected': ResultStatus.rejected,
    'superseded': ResultStatus.superseded,
  };
  static const _kinds = {
    'won': ClubResultKind.won,
    'lost': ClubResultKind.lost,
    'tied': ClubResultKind.tied,
    'no_result': ClubResultKind.noResult,
    'abandoned': ClubResultKind.abandoned,
  };
  static const _dismissals = {
    'not_out': DismissalKind.notOut,
    'did_not_bat': DismissalKind.didNotBat,
    'retired_hurt': DismissalKind.retiredHurt,
    'retired_out': DismissalKind.retiredOut,
    'bowled': DismissalKind.bowled,
    'caught': DismissalKind.caught,
    'lbw': DismissalKind.lbw,
    'run_out': DismissalKind.runOut,
    'stumped': DismissalKind.stumped,
    'hit_wicket': DismissalKind.hitWicket,
    'obstructing_field': DismissalKind.obstructingField,
    'hit_ball_twice': DismissalKind.hitBallTwice,
    'timed_out': DismissalKind.timedOut,
  };

  static T _code<T>(
    Map<String, T> codes,
    Map<String, dynamic> row,
    String key,
  ) => codes[row[key]] ?? (throw MatchRowFormatException(key));

  // ---- Field readers (on top of MatchRowMapper's) ----

  static String _text(Map<String, dynamic> r, String k) =>
      MatchRowMapper.text(r, k);
  static String? _optText(Map<String, dynamic> r, String k) =>
      MatchRowMapper.optText(r, k);
  static int _int(Map<String, dynamic> r, String k) =>
      MatchRowMapper.integer(r, k);
  static int? _optInt(Map<String, dynamic> r, String k) {
    if (r[k] == null) return null;
    return MatchRowMapper.optInt(r, k) ?? (throw MatchRowFormatException(k));
  }

  static bool _flag(Map<String, dynamic> r, String k) =>
      MatchRowMapper.flag(r, k);

  static bool? _optFlag(Map<String, dynamic> r, String k) =>
      r[k] == null ? null : _flag(r, k);

  /// A `numeric` (averages, rates): a JSON number, or — as PostgREST may
  /// send it — its text; `null` stays `null`.
  static double? _optNum(Map<String, dynamic> r, String k) => switch (r[k]) {
    null => null,
    final num v => v.toDouble(),
    final String s when double.tryParse(s) != null => double.parse(s),
    _ => throw MatchRowFormatException(k),
  };

  static List<Map<String, dynamic>> _maps(Map<String, dynamic> r, String k) {
    final v = r[k];
    if (v is! List) throw MatchRowFormatException(k);
    return [
      for (final e in v)
        if (e is Map)
          Map<String, dynamic>.from(e)
        else
          throw MatchRowFormatException(k),
    ];
  }

  // ---- Results (migration 20) ----

  static InningsTotals innings(Map<String, dynamic> r) => InningsTotals(
    inningsNo: _int(r, 'innings_no'),
    battingClubId: _text(r, 'batting_club_id'),
    bowlingClubId: _text(r, 'bowling_club_id'),
    runs: _int(r, 'runs'),
    wickets: _int(r, 'wickets'),
    balls: _int(r, 'balls'),
    byes: _int(r, 'byes'),
    legByes: _int(r, 'leg_byes'),
    wides: _int(r, 'wides'),
    noBalls: _int(r, 'no_balls'),
    penalty: _int(r, 'penalty'),
    declared: _flag(r, 'declared'),
  );

  /// A `match_result()` row of [matchId].
  static ResultVersion version(String matchId, Map<String, dynamic> r) {
    final pomId = _optText(r, 'player_of_match_member_id');
    final pomName = _optText(r, 'player_of_match_name');
    final pomDeleted = _flag(r, 'player_of_match_deleted');
    return ResultVersion(
      matchId: matchId,
      version: _int(r, 'version'),
      status: _code(_statuses, r, 'status'),
      outcome: _code(_outcomes, r, 'outcome'),
      marginRuns: _optInt(r, 'margin_runs'),
      marginWickets: _optInt(r, 'margin_wickets'),
      inningsVictory: _flag(r, 'innings_victory'),
      summary: _text(r, 'summary'),
      playerOfMatch: pomId == null && pomName == null && !pomDeleted
          ? null
          : PlayerOfMatch(memberId: pomId, name: pomName, deleted: pomDeleted),
      submittedAt: MatchRowMapper.time(r, 'submitted_at'),
      decidedAt: MatchRowMapper.optTime(r, 'decided_at'),
      clubAId: _text(r, 'club_a_id'),
      clubBId: _text(r, 'club_b_id'),
      innings: [for (final i in _maps(r, 'innings')) innings(i)]
        ..sort((a, b) => a.inningsNo - b.inningsNo),
    );
  }

  static ClubResultRow clubResult(Map<String, dynamic> r) => ClubResultRow(
    matchId: _text(r, 'match_id'),
    opponentClubId: _text(r, 'opponent_club_id'),
    opponentName: _text(r, 'opponent_name'),
    startsAt: MatchRowMapper.time(r, 'starts_at'),
    format: MatchRowMapper.format(r['format']),
    customOvers: _optInt(r, 'custom_overs'),
    result: _code(_kinds, r, 'result'),
    marginRuns: _optInt(r, 'margin_runs'),
    marginWickets: _optInt(r, 'margin_wickets'),
    inningsVictory: _flag(r, 'innings_victory'),
    summary: _text(r, 'summary'),
    version: _int(r, 'version'),
  );

  static ClubRecord record(Map<String, dynamic> r) => ClubRecord(
    played: _int(r, 'played'),
    won: _int(r, 'won'),
    lost: _int(r, 'lost'),
    tied: _int(r, 'tied'),
    noResult: _int(r, 'no_result'),
    abandoned: _int(r, 'abandoned'),
  );

  // ---- Scorecards (migration 21) ----

  static CardBattingRow batting(Map<String, dynamic> r) => CardBattingRow(
    position: _int(r, 'position'),
    memberId: _optText(r, 'member_id'),
    name: _optText(r, 'name'),
    deleted: _flag(r, 'deleted'),
    runs: _int(r, 'runs'),
    balls: _int(r, 'balls'),
    fours: _int(r, 'fours'),
    sixes: _int(r, 'sixes'),
    dismissal: _code(_dismissals, r, 'dismissal'),
    dismissalText: _text(r, 'dismissal_text'),
    bowlerMemberId: _optText(r, 'bowler_member_id'),
    bowlerName: _optText(r, 'bowler_name'),
    fielderMemberId: _optText(r, 'fielder_member_id'),
    fielderName: _optText(r, 'fielder_name'),
    fielderDeleted: _flag(r, 'fielder_deleted'),
    fielderSubstitute: _flag(r, 'fielder_substitute'),
    directHit: _flag(r, 'direct_hit'),
  );

  static CardBowlingRow bowling(Map<String, dynamic> r) => CardBowlingRow(
    bowlerNo: _int(r, 'bowler_no'),
    memberId: _optText(r, 'member_id'),
    name: _optText(r, 'name'),
    deleted: _flag(r, 'deleted'),
    balls: _int(r, 'balls'),
    maidens: _int(r, 'maidens'),
    runs: _int(r, 'runs'),
    wickets: _int(r, 'wickets'),
    wides: _int(r, 'wides'),
    noBalls: _int(r, 'no_balls'),
  );

  static InningsCard inningsCard(Map<String, dynamic> r) => InningsCard(
    version: _int(r, 'version'),
    inningsNo: _int(r, 'innings_no'),
    battingClubId: _text(r, 'batting_club_id'),
    bowlingClubId: _text(r, 'bowling_club_id'),
    batting: [for (final b in _maps(r, 'batting')) batting(b)]
      ..sort((a, b) => a.position - b.position),
    bowling: [for (final w in _maps(r, 'bowling')) bowling(w)]
      ..sort((a, b) => a.bowlerNo - b.bowlerNo),
  );

  // ---- Statistics (migration 22) ----

  static CricketStats stats(Map<String, dynamic> r) => CricketStats(
    matches: _int(r, 'matches'),
    batInnings: _int(r, 'bat_innings'),
    notOuts: _int(r, 'not_outs'),
    runs: _int(r, 'runs'),
    ballsFaced: _int(r, 'balls_faced'),
    battingAverage: _optNum(r, 'batting_average'),
    strikeRate: _optNum(r, 'strike_rate'),
    highest: _optInt(r, 'highest'),
    highestNotOut: _optFlag(r, 'highest_not_out'),
    fifties: _int(r, 'fifties'),
    hundreds: _int(r, 'hundreds'),
    ducks: _int(r, 'ducks'),
    fours: _int(r, 'fours'),
    sixes: _int(r, 'sixes'),
    bowlInnings: _int(r, 'bowl_innings'),
    ballsBowled: _int(r, 'balls_bowled'),
    maidens: _int(r, 'maidens'),
    runsConceded: _int(r, 'runs_conceded'),
    wickets: _int(r, 'wickets'),
    bowlingAverage: _optNum(r, 'bowling_average'),
    economy: _optNum(r, 'economy'),
    bowlingStrikeRate: _optNum(r, 'bowling_strike_rate'),
    bestWickets: _optInt(r, 'best_wickets'),
    bestRuns: _optInt(r, 'best_runs'),
    fiveWickets: _int(r, 'five_wickets'),
    catches: _int(r, 'catches'),
    runOuts: _int(r, 'run_outs'),
    directHits: _int(r, 'direct_hits'),
    stumpings: _int(r, 'stumpings'),
    playerOfMatch: _int(r, 'player_of_match'),
  );

  static ClubMemberStats memberStats(Map<String, dynamic> r) => ClubMemberStats(
    memberId: _text(r, 'member_id'),
    name: _optText(r, 'full_name'),
    memberRole: MatchRowMapper.memberRole(r['member_role']),
    stats: stats(r),
  );

  static PlayerMatchLogRow logRow(Map<String, dynamic> r) => PlayerMatchLogRow(
    matchId: _text(r, 'match_id'),
    startsAt: MatchRowMapper.time(r, 'starts_at'),
    format: MatchRowMapper.format(r['format']),
    customOvers: _optInt(r, 'custom_overs'),
    clubId: _text(r, 'club_id'),
    clubName: _text(r, 'club_name'),
    opponentClubId: _text(r, 'opponent_club_id'),
    opponentName: _text(r, 'opponent_name'),
    result: _code(_kinds, r, 'result'),
    summary: _text(r, 'summary'),
    batInnings: _int(r, 'bat_innings'),
    batRuns: _int(r, 'bat_runs'),
    batBalls: _int(r, 'bat_balls'),
    batFours: _int(r, 'bat_fours'),
    batSixes: _int(r, 'bat_sixes'),
    batOuts: _int(r, 'bat_outs'),
    bowlBalls: _int(r, 'bowl_balls'),
    bowlMaidens: _int(r, 'bowl_maidens'),
    bowlRuns: _int(r, 'bowl_runs'),
    bowlWickets: _int(r, 'bowl_wickets'),
    catches: _int(r, 'catches'),
    runOuts: _int(r, 'run_outs'),
    stumpings: _int(r, 'stumpings'),
    playerOfMatch: _flag(r, 'player_of_match'),
  );

  // ---- The player's match list (migration 23) ----

  static MyMatch myMatch(Map<String, dynamic> r) => MyMatch(
    matchId: _text(r, 'match_id'),
    clubId: _text(r, 'club_id'),
    clubName: _text(r, 'club_name'),
    opponentClubId: _text(r, 'opponent_club_id'),
    opponentName: _text(r, 'opponent_name'),
    format: MatchRowMapper.format(r['format']),
    customOvers: _optInt(r, 'custom_overs'),
    status: MatchRowMapper.matchStatus(r['status']),
    startsAt: MatchRowMapper.time(r, 'starts_at'),
    venueName: _optText(r, 'venue_name'),
    city: _optText(r, 'city'),
    cancelReason: _optText(r, 'cancel_reason'),
    lineupSaved: _flag(r, 'lineup_saved'),
    selection: r['selection'] == null
        ? null
        : MatchRowMapper.selection(r['selection']),
    isCaptain: _flag(r, 'is_captain'),
    isViceCaptain: _flag(r, 'is_vice_captain'),
    result: r['result'] == null ? null : _code(_kinds, r, 'result'),
    summary: _optText(r, 'summary'),
    resultVersion: _optInt(r, 'result_version'),
  );
}
