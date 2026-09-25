import 'dart:math';

import '../core/models/models.dart';

/// Demo Mode only (revised architecture §11). These stand in for the other
/// side of a tournament — other clubs applying, another club's organizer
/// deciding, match results — and call the same controller APIs a backend
/// event would. Production screens reach them only through
/// `TournamentDemoActions` from inside a DemoPanel / demo-only fixture tap.

/// Other clubs apply to a newly published tournament (prototype
/// `submitTournament`: the first three other clubs become pending requests).
/// With Demo Mode OFF nothing is seeded; requests arrive from real clubs.
class DemoTournamentEntries {
  const DemoTournamentEntries();

  static const requestCount = 3;

  Future<void> seedRequests(
    Tournament t,
    List<ClubSummary> otherClubs,
    Future<Object?> Function(String tournamentId, String clubId, String teamName) receive,
  ) async {
    final applicants = otherClubs.where((c) => c.id != t.organizerClubId).take(requestCount);
    for (final c in applicants) {
      await receive(t.id, c.id, c.name);
    }
  }
}

/// "Tap to simulate result": picks a winner for a ready fixture (prototype
/// `completeMatch`, which also chose at random). With Demo Mode OFF fixtures
/// are read-only (P10).
class DemoMatchResults {
  DemoMatchResults([Random? random]) : _random = random ?? Random();
  final Random _random;

  String? pickWinner(FixtureMatch m) {
    if (!m.ready || m.completed) return null;
    return _random.nextBool() ? m.home : m.away;
  }
}

/// Deterministic award figures derived from the entrants' players (port of
/// the prototype's `tournamentAwardStats` ranges). Demo data only; real
/// awards come from recorded scorecards.
abstract final class DemoTournamentAwards {
  static int _hash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7FFFFFFF;
    }
    return h;
  }

  static int _range(String seed, int a, int b) => a + _hash(seed) % (b - a + 1);

  /// [players]: (player name, position, entrant id). `null` when there are
  /// no players to rank yet.
  static TournamentAwards? compute(String tournamentId, List<(String, String, String)> players) {
    if (players.isEmpty) return null;
    TournamentAward best(String kind, int a, int b, Iterable<(String, String, String)> pool) {
      TournamentAward? top;
      for (final (name, _, entrantId) in pool) {
        final v = _range('$tournamentId|$kind|$entrantId|$name', a, b);
        if (top == null || v > top.value) top = TournamentAward(playerName: name, entrantId: entrantId, value: v);
      }
      return top!;
    }

    final keepers = players.where((p) => RegExp('keeper', caseSensitive: false).hasMatch(p.$2));
    return TournamentAwards(
      topScorer: best('runs', 60, 399, players),
      topWicketTaker: best('wkts', 2, 19, players),
      bestKeeper: best('dis', 2, 15, keepers.isEmpty ? players : keepers),
      bestFielder: best('ct', 0, 11, players),
    );
  }
}
