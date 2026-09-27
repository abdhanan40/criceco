import '../../../core/models/models.dart';

/// Suggest Team (New Team sheet): a starting selection the owner reviews and
/// adjusts before creating the team. Rule-based ranking from existing player
/// data and the Fitness Meter:
///
/// * Left out (with a reason): injured / unavailable players and players
///   whose Fitness Meter says Overloaded.
/// * Ranking: scouting rating, recent form (wins in the last 5) and fitness
///   score.
/// * 11 Playing XI + 2 substitutes; one wicket keeper when available and at
///   least 4 bowling options (bowlers + all-rounders).
class TeamSuggestion {
  const TeamSuggestion({required this.picks, required this.leftOut});

  static const xi = SquadRules.maxPlaying; // 11
  static const subs = 2;
  static const minBowlingOptions = 4;

  /// Playing XI first, then substitutes (insertion-ordered).
  final Map<String, SelectionRole> picks;

  /// Players not suggested, with the reason ("Injured", "Overloaded (2/10)").
  final List<(SquadPlayer, String)> leftOut;

  static bool isKeeper(SquadPlayer p) => p.position.toLowerCase().contains('keeper');

  static TeamSuggestion build(
    List<SquadPlayer> pool, {
    required Map<String, PlayerStats> stats,
    required Map<String, FitnessReport> fitness,
  }) {
    final leftOut = <(SquadPlayer, String)>[];
    final eligible = <SquadPlayer>[];
    for (final p in pool) {
      final f = fitness[p.id];
      if (p.locked) {
        leftOut.add((p, p.availability.label));
      } else if (f != null && f.level == FitnessLevel.overloaded) {
        leftOut.add((p, 'Overloaded (${f.score}/10)'));
      } else {
        eligible.add(p);
      }
    }
    double score(SquadPlayer p) {
      final s = stats[p.id];
      final rating = double.tryParse(s?.rating ?? '') ?? 0;
      return rating * 10 + (s?.wins ?? 0) * 2 + (fitness[p.id]?.score ?? FitnessReport.max) * 3;
    }

    eligible.sort((a, b) => score(b).compareTo(score(a)));

    final xiList = <SquadPlayer>[];
    void add(SquadPlayer p) {
      if (xiList.length < xi && !xiList.contains(p)) xiList.add(p);
    }

    final keeper = eligible.where(isKeeper).firstOrNull;
    if (keeper != null) add(keeper);
    bool bowls(SquadPlayer p) => p.category != SquadCategory.batsman;
    for (final p in eligible.where(bowls)) {
      if (xiList.where(bowls).length >= minBowlingOptions) break;
      add(p);
    }
    for (final p in eligible) {
      add(p);
    }
    final subList = eligible.where((p) => !xiList.contains(p)).take(subs);

    return TeamSuggestion(
      picks: {
        for (final p in xiList) p.id: SelectionRole.playing,
        for (final p in subList) p.id: SelectionRole.sub,
      },
      leftOut: leftOut,
    );
  }
}
