import 'package:criceco/core/domain/fixture_engine.dart';
import 'package:criceco/core/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Tournament _t(TournamentType type, List<String> ids) => Tournament(
      id: 't',
      name: 'Cup',
      organizerClubId: 'own',
      city: 'Lahore',
      ground: 'G',
      format: MatchFormat.t20,
      type: type,
      startDate: DateTime(2026, 10, 1),
      endDate: DateTime(2026, 10, 5),
      registrationDeadline: DateTime(2026, 9, 28),
      maxTeams: 8,
      status: TournamentStatus.registrationOpen,
      joined: [for (final id in ids) TournamentEntrant(id: id, displayName: id)],
      fixtures: FixtureEngine.generate(type, ids),
      standings: FixtureEngine.emptyStandings(ids),
    );

void main() {
  test('knockout round names and sizes match the prototype', () {
    final r = FixtureEngine.knockout(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']);
    expect([for (final x in r) x.name], ['Quarterfinal', 'Semifinal', 'Final']);
    expect([for (final x in r) x.matches.length], [4, 2, 1]);
  });

  test('BYE auto-advances so a 3-team knockout can finish (fixes prototype deadlock)', () {
    var t = _t(TournamentType.knockout, ['a', 'b', 'c']);
    // c drew a BYE → already in the final.
    expect(t.fixtures![0].matches[1].winnerId, 'c');
    expect(t.fixtures![1].matches[0].away, 'c');

    t = FixtureEngine.recordResult(t, 0, 0, 'a');
    expect(t.fixtures![1].matches[0].home, 'a');
    t = FixtureEngine.recordResult(t, 1, 0, 'c');
    expect(t.winnerId, 'c');
    expect(t.status, TournamentStatus.completed);
    expect(t.standings['c']!.points, 2);
  });

  test('league: every pair plays once; champion by points when all complete', () {
    var t = _t(TournamentType.league, ['a', 'b', 'c']);
    expect(t.fixtures!.single.matches.length, 3);
    t = FixtureEngine.recordResult(t, 0, 0, 'a'); // a v b
    t = FixtureEngine.recordResult(t, 0, 1, 'a'); // a v c
    expect(t.winnerId, isNull);
    t = FixtureEngine.recordResult(t, 0, 2, 'b'); // b v c
    expect(t.winnerId, 'a');
    expect(t.standings['a']!.points, 4);
  });
}
