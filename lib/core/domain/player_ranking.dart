import '../enums/enums.dart';

/// Basic, explainable player rankings (frontend stage).
///
/// Everything here is pure and deterministic: the same inputs always give
/// the same scores and the same order. Rankings are derived from the stats
/// the app already has — nothing is stored, nothing is random.
///
/// **Eligibility.** A player is ranked only after [minCompletedMatches]
/// completed matches (a match with a result). Fewer → "Not yet ranked".
///
/// **Score (0–100).** Each stat is turned into a 0–1 value against a fixed
/// cricket benchmark, then combined with fixed weights:
///
/// * Batting  — runs per match (÷50) 30 % · batting average (÷50) 25 % ·
///   strike rate (÷150) 15 % · existing rating (÷10) 20 % · last-5 form 10 %
/// * Bowling  — wickets per match (÷2.5) 35 % · economy ((10 − econ) ÷ 6)
///   20 % · bowling average ((40 − avg) ÷ 25) 15 % · rating 20 % · form 10 %
/// * All-Rounder — half batting, half bowling
///
/// A player's Ranking Score is the score for their own role (Batsman →
/// batting, Bowler → bowling, All-Rounder → both), so the Overall table
/// compares everyone on their role's score. A stat that isn't available is
/// left out and the remaining weights are re-balanced — it never counts as 0.
abstract final class PlayerRankingMath {
  static const minCompletedMatches = 7;

  static bool isEligible(int completedMatches) => completedMatches >= minCompletedMatches;

  /// 0–1 values (`null` = stat not available).
  static double? _ratio(num? value, num benchmark) => value == null ? null : (value / benchmark).clamp(0, 1).toDouble();
  static double? _lowerIsBetter(num? value, num worst, num range) =>
      value == null ? null : ((worst - value) / range).clamp(0, 1).toDouble();

  /// Weighted mean of the available parts (weights re-balanced over them).
  static double _blend(List<(double? value, double weight)> parts) {
    var sum = 0.0;
    var weights = 0.0;
    for (final (v, w) in parts) {
      if (v == null) continue;
      sum += v * w;
      weights += w;
    }
    return weights == 0 ? 0 : sum / weights;
  }

  static double? _perMatch(int total, int matches) => matches <= 0 ? null : total / matches;
  static double? _rating(RankingInput p) => _ratio(p.rating, 10);
  static double? _form(RankingInput p) =>
      p.recentPlayed <= 0 ? null : (p.recentWins / p.recentPlayed).clamp(0, 1).toDouble();

  static double battingScore(RankingInput p) => _blend([
        (_ratio(_perMatch(p.runs, p.completedMatches), 50), 0.30),
        (_ratio(p.battingAverage, 50), 0.25),
        (_ratio(p.strikeRate, 150), 0.15),
        (_rating(p), 0.20),
        (_form(p), 0.10),
      ]);

  static double bowlingScore(RankingInput p) => _blend([
        (_ratio(_perMatch(p.wickets, p.completedMatches), 2.5), 0.35),
        (_lowerIsBetter(p.economy, 10, 6), 0.20),
        (_lowerIsBetter(p.bowlingAverage, 40, 25), 0.15),
        (_rating(p), 0.20),
        (_form(p), 0.10),
      ]);

  /// The player's Ranking Score for their own role, 0–100 (whole number).
  static int score(RankingInput p) {
    final s = switch (p.role) {
      SquadCategory.batsman => battingScore(p),
      SquadCategory.bowler => bowlingScore(p),
      SquadCategory.allRounder => (battingScore(p) + bowlingScore(p)) / 2,
    };
    return (s * 100).round().clamp(0, 100);
  }

  /// Ranking order: Score ↓, then completed matches ↓, rating ↓, recent
  /// form ↓, and finally name A–Z. Never random.
  static int compare(PlayerRanking a, PlayerRanking b) {
    int desc(num x, num y) => y.compareTo(x);
    var c = desc(a.score, b.score);
    if (c != 0) return c;
    c = desc(a.input.completedMatches, b.input.completedMatches);
    if (c != 0) return c;
    c = desc(a.input.rating ?? -1, b.input.rating ?? -1);
    if (c != 0) return c;
    c = desc(a.input.recentWins, b.input.recentWins);
    if (c != 0) return c;
    return a.input.name.toLowerCase().compareTo(b.input.name.toLowerCase());
  }

  /// Ranks every input: Overall across all eligible players, and within each
  /// role. Ineligible players get no rank (but keep their score inputs).
  static RankingBoard rank(List<RankingInput> inputs) {
    final scored = [for (final p in inputs) PlayerRanking._(p, score(p))];
    final eligible = scored.where((r) => r.eligible).toList()..sort(compare);
    final overall = <String, int>{for (final (i, r) in eligible.indexed) r.input.playerId: i + 1};
    final byRole = <String, int>{};
    for (final role in SquadCategory.values) {
      final list = eligible.where((r) => r.input.role == role);
      for (final (i, r) in list.indexed) {
        byRole[r.input.playerId] = i + 1;
      }
    }
    final all = [
      for (final r in scored)
        r._ranked(overallRank: overall[r.input.playerId], roleRank: byRole[r.input.playerId]),
    ];
    return RankingBoard(all);
  }
}

/// What a player is ranked on — only stats the app really has. Optional
/// stats are `null` when unknown.
class RankingInput {
  const RankingInput({
    required this.playerId,
    required this.name,
    required this.club,
    required this.role,
    required this.completedMatches,
    this.runs = 0,
    this.battingAverage,
    this.strikeRate,
    this.wickets = 0,
    this.economy,
    this.bowlingAverage,
    this.rating,
    this.recentWins = 0,
    this.recentPlayed = 0,
    this.isMe = false,
  });

  final String playerId;
  final String name;
  final String club;
  final SquadCategory role;

  /// Matches with a result only — scheduled or cancelled matches never count.
  final int completedMatches;
  final int runs;
  final double? battingAverage;
  final double? strikeRate;
  final int wickets;
  final double? economy;
  final double? bowlingAverage;

  /// The existing 0–10 performance rating.
  final double? rating;

  /// Wins in the last [recentPlayed] (up to 5) completed matches.
  final int recentWins;
  final int recentPlayed;
  final bool isMe;
}

/// One player's place in the rankings (derived, never stored).
class PlayerRanking {
  const PlayerRanking._(this.input, this.score, {this.overallRank, this.roleRank});

  final RankingInput input;

  /// Ranking Score, 0–100.
  final int score;

  /// `null` until the player is eligible.
  final int? overallRank;
  final int? roleRank;

  String get playerId => input.playerId;
  int get completedMatches => input.completedMatches;
  bool get eligible => PlayerRankingMath.isEligible(input.completedMatches);

  /// "5/7" towards eligibility.
  String get progress => '${input.completedMatches.clamp(0, PlayerRankingMath.minCompletedMatches)}/'
      '${PlayerRankingMath.minCompletedMatches}';

  PlayerRanking _ranked({int? overallRank, int? roleRank}) =>
      PlayerRanking._(input, score, overallRank: overallRank, roleRank: roleRank);
}

/// Leaderboard tabs.
enum RankingCategory {
  overall('Overall'),
  batsmen('Batsmen'),
  bowlers('Bowlers'),
  allRounders('All-Rounders');

  const RankingCategory(this.label);
  final String label;

  SquadCategory? get role => switch (this) {
        RankingCategory.overall => null,
        RankingCategory.batsmen => SquadCategory.batsman,
        RankingCategory.bowlers => SquadCategory.bowler,
        RankingCategory.allRounders => SquadCategory.allRounder,
      };

  static RankingCategory forRole(SquadCategory role) => switch (role) {
        SquadCategory.batsman => RankingCategory.batsmen,
        SquadCategory.bowler => RankingCategory.bowlers,
        SquadCategory.allRounder => RankingCategory.allRounders,
      };
}

/// All rankings, with lookups by player and leaderboards by category.
class RankingBoard {
  RankingBoard(this.all) : _byId = {for (final r in all) r.playerId: r};

  final List<PlayerRanking> all;
  final Map<String, PlayerRanking> _byId;

  PlayerRanking? byId(String playerId) => _byId[playerId];
  PlayerRanking? get me => all.where((r) => r.input.isMe).firstOrNull;

  /// Eligible players of [category], best first (the official order).
  List<PlayerRanking> leaderboard(RankingCategory category) {
    final role = category.role;
    final list = [
      for (final r in all)
        if (r.eligible && (role == null || r.input.role == role)) r,
    ]..sort(PlayerRankingMath.compare);
    return list;
  }

  /// The rank shown in [category]: overall rank, or the role rank.
  static int? rankIn(PlayerRanking r, RankingCategory category) =>
      category == RankingCategory.overall ? r.overallRank : r.roleRank;
}
