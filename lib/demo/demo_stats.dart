import '../core/models/models.dart';

/// Deterministic scouting stats hashed from a player's name — a faithful port
/// of the prototype's `ceStats` (criceco-app.js :7706). Demo data only; real
/// stats come from a repository in production.
abstract final class DemoStats {
  static final Map<String, PlayerStats> _cache = {};

  static int _seed(String name) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0xFFFFFFFF;
    }
    return h;
  }

  static PlayerStats forPlayer(String name,
      {String position = 'Batsman', PlayerAvailability availability = PlayerAvailability.available}) {
    return _cache.putIfAbsent(name, () => _build(name, position, availability));
  }

  static PlayerStats _build(String name, String position, PlayerAvailability availability) {
    final h = _seed(name);
    int r(int n, int a, int b) => a + (((h >> (n % 24)) ^ (h * (n + 7))) & 0xFFFFFFFF) % (b - a + 1);
    String fixed(int v, int digits) => (v / 10).toStringAsFixed(digits);

    final cat = SquadCategory.fromPosition(position);
    final matches = r(2, 14, 62);
    final batting = cat == SquadCategory.bowler
        ? BattingStats(
            runs: r(3, 60, 340),
            average: fixed(r(4, 80, 190), 1),
            strikeRate: fixed(r(5, 780, 1180), 1),
            fifties: r(6, 0, 1),
            best: '${r(7, 14, 44)}')
        : BattingStats(
            runs: r(3, 420, 2150),
            average: fixed(r(4, 220, 480), 1),
            strikeRate: fixed(r(5, 1050, 1610), 1),
            fifties: r(6, 2, 14),
            best: '${r(7, 54, 128)}${h % 2 == 1 ? '*' : ''}');
    final bowling = cat == SquadCategory.batsman
        ? BowlingStats(
            wickets: r(8, 0, 9),
            economy: fixed(r(9, 62, 96), 2),
            average: fixed(r(10, 240, 420), 1),
            best: '1/${r(11, 9, 26)}')
        : BowlingStats(
            wickets: r(8, 24, 96),
            economy: fixed(r(9, 48, 78), 2),
            average: fixed(r(10, 140, 260), 1),
            best: '${r(11, 3, 6)}/${r(12, 11, 34)}');

    const pattern = [
      MatchResult.won, MatchResult.won, MatchResult.lost,
      MatchResult.won, MatchResult.lost, MatchResult.won,
    ];
    final form = [
      for (var i = 0; i < 5; i++)
        pattern[(((h >> (i * 3)) ^ (i * 2654435761)) & 0xFFFFFFFF) != 0 ? (((h >> (i * 3)) + i * 7) % 6) : 0],
    ];
    const opponents = ['Falcons CC', 'Shaheen XI', 'Gulberg Tigers', 'Riverside CC'];
    final line = cat == SquadCategory.bowler ? '${r(13, 1, 4)}/${r(14, 12, 38)}' : '${r(13, 12, 86)} (${r(14, 10, 58)})';

    return PlayerStats(
      matches: matches,
      batting: batting,
      bowling: bowling,
      form: form,
      rating: (6.2 + ((h >> 13) % 36) / 10).toStringAsFixed(1),
      category: cat,
      position: position,
      availability: availability,
      skill: SkillLevel.values[(h >> 17) % 4],
      verified: (h >> 19) % 3 != 0,
      lastMatch: LastMatchLine(opponent: opponents[(h >> 21) % 4], line: line),
    );
  }
}
