import '../enums/enums.dart';

// OFFICIAL match results, scorecards and statistics from the server
// (migrations 20–24, M2) — read only: they come from a trusted Scorer/Umpire
// integration, never from the app. Members and players are referenced by
// club membership id; a deleted account has no id and no name ("Deleted
// player").

/// The outcome of a match, from the match's side (club A = the challenger).
enum ResultOutcome { clubAWon, clubBWon, tie, noResult, abandoned }

/// Where an official result version stands (migration 24): provisional,
/// official, rejected by a verifier, or replaced. The app is only ever shown
/// the official (confirmed) one.
enum ResultStatus { submitted, confirmed, rejected, superseded }

/// A confirmed result from one club's side.
enum ClubResultKind { won, lost, tied, noResult, abandoned }

/// How a batter's innings ended (or didn't).
enum DismissalKind {
  notOut,
  didNotBat,
  retiredHurt,
  retiredOut,
  bowled,
  caught,
  lbw,
  runOut,
  stumped,
  hitWicket,
  obstructingField,
  hitBallTwice,
  timedOut;

  /// A wicket the bowler is credited with.
  bool get creditsBowler => switch (this) {
    bowled || caught || lbw || stumped || hitWicket => true,
    _ => false,
  };

  /// Counts as a wicket of the innings.
  bool get isOut =>
      !(this == notOut || this == didNotBat || this == retiredHurt);
}

/// `balls` legal balls as overs: 116 → "19.2".
String oversOf(int balls) => '${balls ~/ 6}.${balls % 6}';

/// One innings' totals.
class InningsTotals {
  const InningsTotals({
    required this.inningsNo,
    required this.battingClubId,
    required this.bowlingClubId,
    required this.runs,
    required this.wickets,
    required this.balls,
    this.byes = 0,
    this.legByes = 0,
    this.wides = 0,
    this.noBalls = 0,
    this.penalty = 0,
    this.declared = false,
  });

  final int inningsNo;
  final String battingClubId;
  final String bowlingClubId;
  final int runs;
  final int wickets;
  final int balls;
  final int byes;
  final int legByes;
  final int wides;
  final int noBalls;
  final int penalty;
  final bool declared;

  int get extras => byes + legByes + wides + noBalls + penalty;
  String get overs => oversOf(balls);
}

/// The Player of the Match of a result version.
class PlayerOfMatch {
  const PlayerOfMatch({this.memberId, this.name, this.deleted = false});

  /// `null` once [deleted].
  final String? memberId;

  /// The name when the result was submitted; `null` once [deleted].
  final String? name;

  /// The player deleted their account: show "Deleted player".
  final bool deleted;
}

/// A match's official result (`match_result()`: at most one, confirmed).
class ResultVersion {
  const ResultVersion({
    required this.matchId,
    required this.version,
    required this.status,
    required this.outcome,
    required this.summary,
    required this.submittedAt,
    required this.clubAId,
    required this.clubBId,
    this.marginRuns,
    this.marginWickets,
    this.inningsVictory = false,
    this.playerOfMatch,
    this.decidedAt,
    this.innings = const [],
  });

  final String matchId;
  final int version;
  final ResultStatus status;
  final ResultOutcome outcome;

  /// Computed by the server: "Lahore Lions won by 24 runs", "Match tied", …
  final String summary;
  final int? marginRuns;
  final int? marginWickets;
  final bool inningsVictory;
  final PlayerOfMatch? playerOfMatch;

  /// When the official scorer submitted it.
  final DateTime submittedAt;

  /// When it was verified (became the official result).
  final DateTime? decidedAt;
  final String clubAId;
  final String clubBId;
  final List<InningsTotals> innings;
}

/// A club's confirmed result (`club_results()`), from its side.
class ClubResultRow {
  const ClubResultRow({
    required this.matchId,
    required this.opponentClubId,
    required this.opponentName,
    required this.startsAt,
    required this.format,
    required this.result,
    required this.summary,
    required this.version,
    this.customOvers,
    this.marginRuns,
    this.marginWickets,
    this.inningsVictory = false,
  });

  final String matchId;
  final String opponentClubId;
  final String opponentName;
  final DateTime startsAt;
  final MatchFormat format;
  final int? customOvers;
  final ClubResultKind result;
  final int? marginRuns;
  final int? marginWickets;
  final bool inningsVictory;
  final String summary;
  final int version;
}

/// A club's record from its confirmed results (`club_record()`).
class ClubRecord {
  const ClubRecord({
    this.played = 0,
    this.won = 0,
    this.lost = 0,
    this.tied = 0,
    this.noResult = 0,
    this.abandoned = 0,
  });

  static const empty = ClubRecord();

  final int played;
  final int won;
  final int lost;
  final int tied;
  final int noResult;
  final int abandoned;
}

/// One batting-card row (`match_scorecard()`).
class CardBattingRow {
  const CardBattingRow({
    required this.position,
    required this.runs,
    required this.balls,
    required this.fours,
    required this.sixes,
    required this.dismissal,
    required this.dismissalText,
    this.memberId,
    this.name,
    this.deleted = false,
    this.bowlerMemberId,
    this.bowlerName,
    this.fielderMemberId,
    this.fielderName,
    this.fielderDeleted = false,
    this.fielderSubstitute = false,
    this.directHit = false,
  });

  final int position;
  final String? memberId;
  final String? name;
  final bool deleted;
  final int runs;
  final int balls;
  final int fours;
  final int sixes;
  final DismissalKind dismissal;

  /// Written by the server: "c Ali b Khan", "not out", "Deleted player" …
  final String dismissalText;
  final String? bowlerMemberId;
  final String? bowlerName;
  final String? fielderMemberId;
  final String? fielderName;
  final bool fielderDeleted;
  final bool fielderSubstitute;
  final bool directHit;
}

/// One bowling-card row (`match_scorecard()`).
class CardBowlingRow {
  const CardBowlingRow({
    required this.bowlerNo,
    required this.balls,
    required this.maidens,
    required this.runs,
    required this.wickets,
    required this.wides,
    required this.noBalls,
    this.memberId,
    this.name,
    this.deleted = false,
  });

  final int bowlerNo;
  final String? memberId;
  final String? name;
  final bool deleted;
  final int balls;
  final int maidens;
  final int runs;

  /// Computed by the server from the dismissals.
  final int wickets;
  final int wides;
  final int noBalls;

  String get overs => oversOf(balls);
}

/// The cards of one innings of a result version.
class InningsCard {
  const InningsCard({
    required this.version,
    required this.inningsNo,
    required this.battingClubId,
    required this.bowlingClubId,
    required this.batting,
    required this.bowling,
  });

  final int version;
  final int inningsNo;
  final String battingClubId;
  final String bowlingClubId;
  final List<CardBattingRow> batting;
  final List<CardBowlingRow> bowling;
}

/// A player's figures from confirmed results (`player_stats()`,
/// `club_member_stats()`). Averages and rates are `null` when undefined.
/// No rating, skill or "verified" figure (approved M2 decision 10).
class CricketStats {
  const CricketStats({
    this.matches = 0,
    this.batInnings = 0,
    this.notOuts = 0,
    this.runs = 0,
    this.ballsFaced = 0,
    this.battingAverage,
    this.strikeRate,
    this.highest,
    this.highestNotOut,
    this.fifties = 0,
    this.hundreds = 0,
    this.ducks = 0,
    this.fours = 0,
    this.sixes = 0,
    this.bowlInnings = 0,
    this.ballsBowled = 0,
    this.maidens = 0,
    this.runsConceded = 0,
    this.wickets = 0,
    this.bowlingAverage,
    this.economy,
    this.bowlingStrikeRate,
    this.bestWickets,
    this.bestRuns,
    this.fiveWickets = 0,
    this.catches = 0,
    this.runOuts = 0,
    this.directHits = 0,
    this.stumpings = 0,
    this.playerOfMatch = 0,
  });

  static const empty = CricketStats();

  final int matches;
  final int batInnings;
  final int notOuts;
  final int runs;
  final int ballsFaced;
  final double? battingAverage;
  final double? strikeRate;
  final int? highest;
  final bool? highestNotOut;
  final int fifties;
  final int hundreds;
  final int ducks;
  final int fours;
  final int sixes;
  final int bowlInnings;
  final int ballsBowled;
  final int maidens;
  final int runsConceded;
  final int wickets;
  final double? bowlingAverage;
  final double? economy;
  final double? bowlingStrikeRate;
  final int? bestWickets;
  final int? bestRuns;
  final int fiveWickets;
  final int catches;
  final int runOuts;
  final int directHits;
  final int stumpings;
  final int playerOfMatch;

  /// "60*" / "60"; `null` before a first innings.
  String? get highestText =>
      highest == null ? null : '$highest${highestNotOut == true ? '*' : ''}';

  /// "2/30"; `null` before a first bowling innings.
  String? get bestBowlingText =>
      bestWickets == null || bestRuns == null ? null : '$bestWickets/$bestRuns';

  String get oversBowled => oversOf(ballsBowled);
}

/// A club member's figures in that club's matches (`club_member_stats()`).
class ClubMemberStats {
  const ClubMemberStats({
    required this.memberId,
    required this.stats,
    this.name,
    this.memberRole,
  });

  final String memberId;
  final String? name;
  final MemberRole? memberRole;
  final CricketStats stats;
}

/// One confirmed match of a player (`player_match_log()`): the result from
/// the side they played for, and their own figures in it.
class PlayerMatchLogRow {
  const PlayerMatchLogRow({
    required this.matchId,
    required this.startsAt,
    required this.format,
    required this.clubId,
    required this.clubName,
    required this.opponentClubId,
    required this.opponentName,
    required this.result,
    required this.summary,
    this.customOvers,
    this.batInnings = 0,
    this.batRuns = 0,
    this.batBalls = 0,
    this.batFours = 0,
    this.batSixes = 0,
    this.batOuts = 0,
    this.bowlBalls = 0,
    this.bowlMaidens = 0,
    this.bowlRuns = 0,
    this.bowlWickets = 0,
    this.catches = 0,
    this.runOuts = 0,
    this.stumpings = 0,
    this.playerOfMatch = false,
  });

  final String matchId;
  final DateTime startsAt;
  final MatchFormat format;
  final int? customOvers;
  final String clubId;
  final String clubName;
  final String opponentClubId;
  final String opponentName;
  final ClubResultKind result;
  final String summary;
  final int batInnings;
  final int batRuns;
  final int batBalls;
  final int batFours;
  final int batSixes;
  final int batOuts;
  final int bowlBalls;
  final int bowlMaidens;
  final int bowlRuns;
  final int bowlWickets;
  final int catches;
  final int runOuts;
  final int stumpings;
  final bool playerOfMatch;

  /// Unbeaten in every innings they batted.
  bool get notOut => batInnings > 0 && batOuts == 0;
}

/// One of the signed-in player's scheduled matches (`my_matches()`).
class MyMatch {
  const MyMatch({
    required this.matchId,
    required this.clubId,
    required this.clubName,
    required this.opponentClubId,
    required this.opponentName,
    required this.format,
    required this.status,
    required this.startsAt,
    required this.lineupSaved,
    this.customOvers,
    this.venueName,
    this.city,
    this.cancelReason,
    this.selection,
    this.isCaptain = false,
    this.isViceCaptain = false,
    this.result,
    this.summary,
    this.resultVersion,
  });

  final String matchId;
  final String clubId;
  final String clubName;
  final String opponentClubId;
  final String opponentName;
  final MatchFormat format;
  final int? customOvers;
  final MatchStatus status;
  final DateTime startsAt;
  final String? venueName;
  final String? city;
  final String? cancelReason;

  /// The player's club saved a line-up for this match.
  final bool lineupSaved;

  /// The player's own place in it; `null` when not picked (or no line-up).
  final SelectionRole? selection;
  final bool isCaptain;
  final bool isViceCaptain;

  /// The confirmed result from the player's club's side; `null` until then.
  final ClubResultKind? result;
  final String? summary;
  final int? resultVersion;
}
