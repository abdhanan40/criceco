import '../enums/enums.dart';

/// A player in the owner's club pool (prototype `clubSquad`). Source for Add
/// Players and the match-day Team Builder.
class SquadPlayer {
  const SquadPlayer({
    required this.id,
    required this.name,
    required this.position,
    required this.availability,
  });

  final String id;
  final String name;
  final String position; // free text, e.g. "Opening Bat"
  final PlayerAvailability availability;

  SquadCategory get category => SquadCategory.fromPosition(position);
  bool get locked => availability.locksSelection;
}

class BattingStats {
  const BattingStats({
    required this.runs,
    required this.average,
    required this.strikeRate,
    required this.best,
    required this.fifties,
  });
  final int runs;
  final String average;
  final String strikeRate;
  final String best;
  final int fifties;
}

class BowlingStats {
  const BowlingStats({
    required this.wickets,
    required this.economy,
    required this.average,
    required this.best,
  });
  final int wickets;
  final String economy;
  final String average;
  final String best;
}

class LastMatchLine {
  const LastMatchLine({required this.opponent, required this.line});
  final String opponent;
  final String line;
}

/// Scouting stats shown in Add Players and the Player Stats sheet.
class PlayerStats {
  const PlayerStats({
    required this.matches,
    required this.batting,
    required this.bowling,
    required this.form,
    required this.rating,
    required this.category,
    required this.position,
    required this.availability,
    required this.skill,
    required this.verified,
    required this.lastMatch,
  });

  final int matches;
  final BattingStats batting;
  final BowlingStats bowling;
  final List<MatchResult> form; // last 5
  final String rating;
  final SquadCategory category;
  final String position;
  final PlayerAvailability availability;
  final SkillLevel skill;
  final bool verified;
  final LastMatchLine lastMatch;

  int get wins => form.where((f) => f == MatchResult.won).length;
  int get losses => form.length - wins;
}

/// A match from the Player's point of view (My Matches / Match Details).
class PlayerMatch {
  const PlayerMatch({
    required this.id,
    required this.status,
    required this.ownTeamName,
    required this.ownTeamAbbr,
    required this.opponentName,
    required this.opponentAbbr,
    required this.startsAt,
    required this.format,
    required this.ground,
    required this.playingTeamName,
    this.matchType,
    this.result,
    this.resultText,
    this.cancelReason,
    this.scorecardId,
  });

  final String id;
  final PlayerMatchStatus status;
  final String ownTeamName;
  final String ownTeamAbbr;
  final String opponentName;
  final String opponentAbbr;
  final DateTime startsAt;
  final MatchFormat format;
  final String ground;
  final String playingTeamName;
  final String? matchType; // "League Match"
  final MatchResult? result;
  final String? resultText; // "Won by 24 runs"
  final String? cancelReason;
  final String? scorecardId;

  bool get hasScorecard => scorecardId != null;
}

class BattingEntry {
  const BattingEntry({
    required this.name,
    required this.runs,
    required this.balls,
    required this.fours,
    required this.sixes,
    required this.dismissal,
  });
  final String name;
  final int runs;
  final int balls;
  final int fours;
  final int sixes;
  final String dismissal;
}

class BowlingEntry {
  const BowlingEntry({
    required this.name,
    required this.overs,
    required this.maidens,
    required this.runs,
    required this.wickets,
  });
  final String name;
  final num overs;
  final int maidens;
  final int runs;
  final int wickets;
}

class Innings {
  const Innings({
    required this.team,
    required this.abbr,
    required this.total,
    required this.wickets,
    required this.overs,
    required this.batting,
    required this.bowling,
  });
  final String team;
  final String abbr;
  final int total;
  final int wickets;
  final String overs;
  final List<BattingEntry> batting;
  final List<BowlingEntry> bowling;
}

class Scorecard {
  const Scorecard({
    required this.id,
    required this.matchId,
    required this.result,
    required this.playerOfMatch,
    required this.innings,
  });
  final String id;
  final String matchId;
  final String result;
  final String playerOfMatch;
  final List<Innings> innings;

  BattingEntry get topScorer => innings
      .expand((i) => i.batting)
      .reduce((a, b) => b.runs > a.runs ? b : a);
  BowlingEntry get topWicketTaker => innings
      .expand((i) => i.bowling)
      .reduce((a, b) => b.wickets > a.wickets ? b : a);
}

class StatTile {
  const StatTile({required this.label, required this.value});
  final String label;
  final String value;
}

class FormEntry {
  const FormEntry({
    required this.opponentAbbr,
    required this.result,
    required this.runs,
    required this.wickets,
  });
  final String opponentAbbr;
  final MatchResult result;
  final int runs;
  final int wickets;
}

class MatchLogEntry {
  const MatchLogEntry({
    required this.opponentAbbr,
    required this.opponentName,
    required this.date,
    required this.result,
    required this.runs,
    required this.balls,
    required this.wickets,
    required this.overs,
  });
  final String opponentAbbr;
  final String opponentName;
  final DateTime date;
  final MatchResult result;
  final int runs;
  final int balls;
  final int wickets;
  final String overs;
}

class PerformanceSummary {
  const PerformanceSummary({
    required this.matches,
    required this.runs,
    required this.wickets,
    required this.rating,
    required this.snapshot,
    required this.batting,
    required this.bowling,
    required this.fielding,
    required this.recentForm,
    required this.matchLog,
  });

  final int matches;
  final int runs;
  final int wickets;
  final String rating;
  final List<StatTile> snapshot;
  final List<StatTile> batting;
  final List<StatTile> bowling;
  final List<StatTile> fielding;
  final List<FormEntry> recentForm;
  final List<MatchLogEntry> matchLog;

  /// Batting average as shown in the snapshot ("32.00"); `—` if absent.
  String get battingAverage =>
      snapshot.where((t) => t.label == 'Average').firstOrNull?.value ?? '—';

  int get recentWins =>
      recentForm.where((f) => f.result == MatchResult.won).length;
  int get recentLosses => recentForm.length - recentWins;
}
