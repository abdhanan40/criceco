import '../../core/models/models.dart';

/// Official results (migrations 20–23) → the display models the existing
/// screens use (My Matches, the match workspace, the scorecard, Performance
/// and the squad's stats). Only what the server returned is shown: nothing
/// is estimated or filled in, and a missing value is "—". Players keep their
/// server identity (membership id); a deleted account is "Deleted player".
abstract final class ResultDisplayAdapter {
  static const deletedPlayer = 'Deleted player';
  static const _none = '—';

  static MatchResult result(ClubResultKind k) => switch (k) {
    ClubResultKind.won => MatchResult.won,
    ClubResultKind.lost => MatchResult.lost,
    ClubResultKind.tied => MatchResult.tied,
    ClubResultKind.noResult => MatchResult.noResult,
    ClubResultKind.abandoned => MatchResult.abandoned,
  };

  static String _runs(int n) => n == 1 ? '1 run' : '$n runs';
  static String _wickets(int n) => n == 1 ? '1 wicket' : '$n wickets';

  /// A confirmed result from the club's side: "Won by 30 runs", "Lost by 6
  /// wickets", "Won by an innings and 12 runs", "Match tied", "No result",
  /// "Match abandoned".
  static String sideText(ClubResultRow r) {
    String margin() => r.marginWickets != null
        ? _wickets(r.marginWickets!)
        : r.inningsVictory
        ? 'an innings and ${_runs(r.marginRuns ?? 0)}'
        : _runs(r.marginRuns ?? 0);
    return switch (r.result) {
      ClubResultKind.won => 'Won by ${margin()}',
      ClubResultKind.lost => 'Lost by ${margin()}',
      ClubResultKind.tied => 'Match tied',
      ClubResultKind.noResult => 'No result',
      ClubResultKind.abandoned => 'Match abandoned',
    };
  }

  /// Badge initials for a club name ("Card Lions" → "CL").
  static String abbr(String name) {
    final words = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first
          .substring(0, words.first.length.clamp(0, 2))
          .toUpperCase();
    }
    return words.take(2).map((w) => w[0].toUpperCase()).join();
  }

  static String _place(String? venue, String? city) {
    final parts = [?venue, ?city].where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? 'Venue to be confirmed' : parts.join(', ');
  }

  /// The player's own part in the match.
  static String selectionLabel(MyMatch m) => switch (m.selection) {
    SelectionRole.playing =>
      m.isCaptain
          ? 'Playing XI (Captain)'
          : m.isViceCaptain
          ? 'Playing XI (Vice-captain)'
          : 'Playing XI',
    SelectionRole.sub => 'Substitute',
    null => m.lineupSaved ? 'Not selected' : 'Line-up not announced',
  };

  /// A `my_matches()` row → [PlayerMatch]. Upcoming = confirmed and still
  /// ahead; Past = completed, or started without a published result
  /// ([PlayerMatch.resultPending]); Cancelled = cancelled. The scorecard
  /// opens once an official result exists (not for an abandoned match).
  static PlayerMatch playerMatch(MyMatch m, DateTime now) {
    final status = switch (m.status) {
      MatchStatus.cancelled => PlayerMatchStatus.cancelled,
      MatchStatus.completed => PlayerMatchStatus.past,
      _ =>
        m.startsAt.isAfter(now)
            ? PlayerMatchStatus.upcoming
            : PlayerMatchStatus.past,
    };
    final r = m.result;
    return PlayerMatch(
      id: m.matchId,
      status: status,
      ownTeamName: m.clubName,
      ownTeamAbbr: abbr(m.clubName),
      opponentName: m.opponentName,
      opponentAbbr: abbr(m.opponentName),
      startsAt: m.startsAt,
      format: m.format,
      ground: _place(m.venueName, m.city),
      playingTeamName: selectionLabel(m),
      result: r == null ? null : result(r),
      resultText: r == null ? null : m.summary,
      cancelReason: m.cancelReason,
      scorecardId: r == null || r == ClubResultKind.abandoned
          ? null
          : m.matchId,
    );
  }

  static String? _extrasDetail(InningsTotals t) {
    final parts = [
      if (t.byes > 0) 'b ${t.byes}',
      if (t.legByes > 0) 'lb ${t.legByes}',
      if (t.wides > 0) 'w ${t.wides}',
      if (t.noBalls > 0) 'nb ${t.noBalls}',
      if (t.penalty > 0) 'pen ${t.penalty}',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// An official result version and its cards → [Scorecard]. [clubNames]
  /// maps club ids to names. An innings without a card is shown as totals
  /// only ([Innings.cardRecorded] false) — never an invented card.
  static Scorecard scorecard(
    ResultVersion v,
    List<InningsCard> cards,
    Map<String, String> clubNames,
  ) {
    final pom = v.playerOfMatch;
    return Scorecard(
      id: v.matchId,
      matchId: v.matchId,
      result: v.summary,
      playerOfMatch: pom == null
          ? _none
          : (pom.deleted ? deletedPlayer : pom.name ?? _none),
      innings: [
        for (final t in v.innings)
          () {
            final card = cards
                .where((c) => c.inningsNo == t.inningsNo)
                .firstOrNull;
            final team = clubNames[t.battingClubId] ?? 'Unknown club';
            return Innings(
              team: team,
              abbr: abbr(team),
              total: t.runs,
              wickets: t.wickets,
              overs: t.overs,
              extras: t.extras,
              extrasDetail: _extrasDetail(t),
              declared: t.declared,
              cardRecorded: card != null,
              batting: [
                for (final b in card?.batting ?? const <CardBattingRow>[])
                  BattingEntry(
                    name: b.deleted ? deletedPlayer : b.name ?? deletedPlayer,
                    runs: b.runs,
                    balls: b.balls,
                    fours: b.fours,
                    sixes: b.sixes,
                    dismissal: b.dismissalText,
                    didNotBat: b.dismissal == DismissalKind.didNotBat,
                  ),
              ],
              bowling: [
                for (final w in card?.bowling ?? const <CardBowlingRow>[])
                  BowlingEntry(
                    name: w.deleted ? deletedPlayer : w.name ?? deletedPlayer,
                    overs: num.parse(w.overs),
                    maidens: w.maidens,
                    runs: w.runs,
                    wickets: w.wickets,
                  ),
              ],
            );
          }(),
      ],
    );
  }

  static String _num(double? v) => v == null ? _none : v.toStringAsFixed(2);

  /// Career figures and the match log → [PerformanceSummary], with the tile
  /// labels the Performance screens use. No official matches → the empty
  /// summary ("Statistics not available"). Rating is not computed (M2
  /// decision 10).
  static PerformanceSummary performance(
    CricketStats s,
    List<PlayerMatchLogRow> log,
  ) {
    if (s.matches == 0 && log.isEmpty) return PerformanceSummary.empty;
    StatTile t(String label, String value) =>
        StatTile(label: label, value: value);
    final best = s.highestText ?? _none;
    return PerformanceSummary(
      matches: s.matches,
      runs: s.runs,
      wickets: s.wickets,
      rating: _none,
      snapshot: [
        t('Runs', '${s.runs}'),
        t('Average', _num(s.battingAverage)),
        t('Strike Rate', _num(s.strikeRate)),
        t('Wickets', '${s.wickets}'),
        t('Best Score', best),
      ],
      batting: [
        t('Matches Played', '${s.matches}'),
        t('Runs Scored', '${s.runs}'),
        t('Batting Average', _num(s.battingAverage)),
        t('Strike Rate', _num(s.strikeRate)),
        t('Best Score', best),
        t('Half Centuries', '${s.fifties}'),
        t('Centuries', '${s.hundreds}'),
        t('Not Outs', '${s.notOuts}'),
        t('Boundaries (4s/6s)', '${s.fours} / ${s.sixes}'),
      ],
      bowling: [
        t('Matches Played', '${s.matches}'),
        t('Wickets Taken', '${s.wickets}'),
        t('Bowling Average', _num(s.bowlingAverage)),
        t('Economy Rate', _num(s.economy)),
        t('Best Bowling', s.bestBowlingText ?? _none),
        t('Overs Bowled', s.oversBowled),
        t('Maiden Overs', '${s.maidens}'),
      ],
      fielding: [
        t('Matches Played', '${s.matches}'),
        t('Catches Taken', '${s.catches}'),
        t('Run Outs', '${s.runOuts}'),
        t('Stumpings', '${s.stumpings}'),
        t('Direct Hits', '${s.directHits}'),
      ],
      recentForm: [
        for (final r in log.take(5))
          FormEntry(
            opponentAbbr: abbr(r.opponentName),
            result: result(r.result),
            runs: r.batRuns,
            wickets: r.bowlWickets,
          ),
      ],
      matchLog: [
        for (final r in log)
          MatchLogEntry(
            opponentAbbr: abbr(r.opponentName),
            opponentName: r.opponentName,
            date: r.startsAt,
            result: result(r.result),
            runs: r.batRuns,
            balls: r.batBalls,
            wickets: r.bowlWickets,
            overs: oversOf(r.bowlBalls),
          ),
      ],
    );
  }

  /// A member's official figures in the club's matches → the squad's
  /// [PlayerStats]. Rating, skill and "verified" are not computed (decision
  /// 10); no per-match form comes with the squad list.
  static PlayerStats squadStats(
    ClubMemberStats m, {
    required String position,
    required SquadCategory category,
    required PlayerAvailability availability,
  }) {
    final s = m.stats;
    if (s.matches == 0) {
      return PlayerStats.unrecorded(
        position: position,
        category: category,
        availability: availability,
      );
    }
    return PlayerStats(
      matches: s.matches,
      batting: BattingStats(
        runs: s.runs,
        average: _num(s.battingAverage),
        strikeRate: _num(s.strikeRate),
        best: s.highestText ?? _none,
        fifties: s.fifties,
      ),
      bowling: BowlingStats(
        wickets: s.wickets,
        economy: _num(s.economy),
        average: _num(s.bowlingAverage),
        best: s.bestBowlingText ?? _none,
      ),
      form: const [],
      rating: _none,
      category: category,
      position: position,
      availability: availability,
      skill: null,
      verified: false,
      lastMatch: LastMatchLine(
        opponent: _none,
        line: s.matches == 1
            ? '1 official match recorded'
            : '${s.matches} official matches recorded',
      ),
    );
  }
}
