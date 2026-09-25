import '../enums/enums.dart';
import '../models/tournament.dart';

/// Fixture generation and result recording (prototype `generateKnockoutRounds`
/// / `generateLeagueRounds` / `completeMatch`), with the BYE deadlock fixed:
/// a team drawn against a BYE advances automatically.
abstract final class FixtureEngine {
  static const _named = ['Final', 'Semifinal', 'Quarterfinal', 'Round of 16', 'Round of 32'];

  static List<String> knockoutRoundNames(int totalRounds) => [
        for (var r = 0; r < totalRounds; r++)
          (totalRounds - 1 - r) < _named.length ? _named[totalRounds - 1 - r] : 'Round ${r + 1}',
      ];

  static List<FixtureRound> generate(TournamentType type, List<String> entrantIds) =>
      type == TournamentType.knockout ? knockout(entrantIds) : league(entrantIds);

  static List<FixtureRound> league(List<String> ids) => [
        FixtureRound(name: 'League Stage', matches: [
          for (var i = 0; i < ids.length; i++)
            for (var j = i + 1; j < ids.length; j++) FixtureMatch(home: ids[i], away: ids[j]),
        ]),
      ];

  static List<FixtureRound> knockout(List<String> ids) {
    var size = 1;
    while (size < ids.length) {
      size *= 2;
    }
    if (size < 2) size = 2;
    final padded = [...ids, for (var i = ids.length; i < size; i++) FixtureMatch.bye];
    var totalRounds = 0;
    for (var s = size; s > 1; s ~/= 2) {
      totalRounds++;
    }
    final names = knockoutRoundNames(totalRounds);
    final rounds = <FixtureRound>[
      FixtureRound(name: names[0], matches: [
        for (var i = 0; i < padded.length; i += 2) FixtureMatch(home: padded[i], away: padded[i + 1]),
      ]),
    ];
    var count = size ~/ 4;
    for (var r = 1; r < totalRounds; r++) {
      rounds.add(FixtureRound(
        name: names[r],
        matches: List.generate(count, (_) => const FixtureMatch(home: null, away: null)),
      ));
      count ~/= 2;
    }
    return _autoAdvanceByes(rounds);
  }

  /// Resolves every match that has a BYE on one side (no points awarded).
  static List<FixtureRound> _autoAdvanceByes(List<FixtureRound> rounds) {
    var result = rounds;
    var changed = true;
    while (changed) {
      changed = false;
      for (var r = 0; r < result.length; r++) {
        for (var m = 0; m < result[r].matches.length; m++) {
          final match = result[r].matches[m];
          if (match.completed || !match.isBye) continue;
          if (match.home == null || match.away == null) continue;
          final winner = match.home == FixtureMatch.bye ? match.away! : match.home!;
          result = _setWinner(result, r, m, winner);
          changed = true;
        }
      }
    }
    return result;
  }

  static List<FixtureRound> _setWinner(List<FixtureRound> rounds, int r, int m, String winner) {
    final out = [
      for (final round in rounds) FixtureRound(name: round.name, matches: [...round.matches]),
    ];
    out[r].matches[m] = out[r].matches[m].copyWith(winnerId: winner);
    if (r + 1 < out.length) {
      final next = m ~/ 2;
      final nm = out[r + 1].matches[next];
      out[r + 1].matches[next] =
          m.isEven ? FixtureMatch(home: winner, away: nm.away) : FixtureMatch(home: nm.home, away: winner);
    }
    return out;
  }

  /// Records a result and returns the updated tournament (standings, next
  /// knockout round, winner and completion).
  static Tournament recordResult(Tournament t, int roundIdx, int matchIdx, String winnerId) {
    final fixtures = t.fixtures;
    if (fixtures == null) return t;
    final match = fixtures[roundIdx].matches[matchIdx];
    if (!match.ready || match.completed) return t;
    final loserId = winnerId == match.home ? match.away! : match.home!;

    final standings = Map<String, Standing>.of(t.standings);
    Standing s(String id) => standings[id] ?? const Standing();
    final w = s(winnerId);
    final l = s(loserId);
    standings[winnerId] = Standing(
        played: w.played + 1, won: w.won + 1, lost: w.lost, points: w.points + Standing.pointsPerWin);
    standings[loserId] = Standing(played: l.played + 1, won: l.won, lost: l.lost + 1, points: l.points);

    var rounds = _setWinner(fixtures, roundIdx, matchIdx, winnerId);
    if (t.type == TournamentType.knockout) rounds = _autoAdvanceByes(rounds);

    String? champion;
    if (t.type == TournamentType.knockout) {
      final finalMatch = rounds.last.matches.single;
      champion = finalMatch.winnerId;
    } else if (rounds.expand((r) => r.matches).every((m) => m.completed)) {
      champion = (standings.entries.toList()..sort((a, b) => b.value.points - a.value.points)).first.key;
    }
    return t.copyWith(
      fixtures: rounds,
      standings: standings,
      winnerId: champion,
      status: champion != null ? TournamentStatus.completed : t.status,
    );
  }

  static Map<String, Standing> emptyStandings(Iterable<String> ids) => {for (final id in ids) id: const Standing()};
}
