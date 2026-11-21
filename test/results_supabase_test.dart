// M2 P3: the results data layer (migrations 20–23) — row mapping, request
// building, error translation and the CRICECO_RESULTS switch, on a fake
// gateway that returns rows shaped like the real database functions'. The
// SQL itself is verified by supabase/tests/local/17–18 on a disposable
// Postgres.
import 'dart:io';

import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_results_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'results_fakes.dart';

GatewayConstraintException refusal(String sqlState, String message) =>
    GatewayConstraintException(sqlState: sqlState, message: message);

Future<Object?> errorOf(Future<Object?> call) =>
    call.then<Object?>((_) => null, onError: (Object e) => e);

// ---- Rows shaped like the database functions' (migrations 20–23) ----

Map<String, dynamic> inningsJson(
  int no,
  String bat,
  String bowl,
  int runs,
  int wkts,
  int balls,
) => {
  'innings_no': no,
  'batting_club_id': bat,
  'bowling_club_id': bowl,
  'runs': runs,
  'wickets': wkts,
  'balls': balls,
  'byes': 1,
  'leg_byes': 2,
  'wides': 3,
  'no_balls': 1,
  'penalty': 0,
  'declared': false,
};

Map<String, dynamic> versionRow({
  int version = 2,
  String status = 'confirmed',
}) => {
  'version': version,
  'status': status,
  'outcome': 'club_a_won',
  'margin_runs': 30,
  'margin_wickets': null,
  'innings_victory': false,
  'summary': 'Card Lions won by 30 runs',
  'player_of_match_member_id': 'mem-101',
  'player_of_match_name': 'Ali Khan',
  'player_of_match_deleted': false,
  'submitted_by_me': true,
  'submitted_at': '2026-11-21T10:00:00+00:00',
  'decided_at': '2026-11-21T11:30:00+00:00',
  'dispute_reason': null,
  'club_a_id': 'club-a',
  'club_b_id': 'club-b',
  // Out of order on purpose: the mapper sorts by innings number.
  'innings': [
    inningsJson(2, 'club-b', 'club-a', 120, 10, 110),
    inningsJson(1, 'club-a', 'club-b', 150, 3, 120),
  ],
};

Map<String, dynamic> resultsRow({
  String status = 'submitted',
  int version = 1,
}) => {
  'match_id': 'm1',
  'version': version,
  'status': status,
  'outcome': 'tie',
  'margin_runs': null,
  'margin_wickets': null,
  'innings_victory': false,
  'submitted_by_club_id': 'club-a',
  'decided_at': null,
};

Map<String, dynamic> statsRow({Object? average = 60.0}) => {
  'matches': 1,
  'bat_innings': 1,
  'not_outs': 0,
  'runs': 60,
  'balls_faced': 40,
  'batting_average': average,
  'strike_rate': 150.0,
  'highest': 60,
  'highest_not_out': true,
  'fifties': 1,
  'hundreds': 0,
  'ducks': 0,
  'fours': 6,
  'sixes': 2,
  'bowl_innings': 1,
  'balls_bowled': 23,
  'maidens': 0,
  'runs_conceded': 30,
  'wickets': 2,
  'bowling_average': 15.0,
  'economy': 7.5,
  'bowling_strike_rate': 12.0,
  'best_wickets': 2,
  'best_runs': 30,
  'five_wickets': 0,
  'catches': 1,
  'run_outs': 0,
  'direct_hits': 0,
  'stumpings': 0,
  'player_of_match': 1,
};

void main() {
  late FakeResultsDb db;
  late SupabaseResultsRepository repo;
  setUp(() {
    db = FakeResultsDb();
    repo = SupabaseResultsRepository(db: db);
  });

  group('results (migration 20)', () {
    test('match_result rows → versions, innings in batting order, Player of the Match', () async {
      db.many['match_result'] = [
        versionRow(),
        versionRow(version: 1, status: 'superseded'),
      ];
      final versions = await repo.matchResult('m1');
      expect(versions.map((v) => (v.version, v.status)), [
        (2, ResultStatus.confirmed),
        (1, ResultStatus.superseded),
      ]);
      final v = versions.first;
      expect(v.matchId, 'm1');
      expect(v.outcome, ResultOutcome.clubAWon);
      expect(v.marginRuns, 30);
      expect(v.marginWickets, isNull);
      expect(v.summary, 'Card Lions won by 30 runs');
      expect(v.submittedAt, DateTime.utc(2026, 11, 21, 10).toLocal());
      expect(v.decidedAt, DateTime.utc(2026, 11, 21, 11, 30).toLocal());
      expect(v.playerOfMatch?.memberId, 'mem-101');
      expect(v.playerOfMatch?.name, 'Ali Khan');
      expect(v.innings.map((i) => i.inningsNo), [1, 2]);
      final first = v.innings.first;
      expect(
        (first.runs, first.wickets, first.overs, first.extras),
        (150, 3, '20.0', 7),
      );
      expect(v.innings.last.overs, '18.2');
    });

    test('a deleted Player of the Match: no id, no name, "deleted"; none at all → null', () async {
      db.many['match_result'] = [
        versionRow()
          ..['player_of_match_member_id'] = null
          ..['player_of_match_name'] = null
          ..['player_of_match_deleted'] = true,
        versionRow(version: 1)
          ..['player_of_match_member_id'] = null
          ..['player_of_match_name'] = null,
      ];
      final [deleted, none] = await repo.matchResult('m1');
      expect(deleted.playerOfMatch?.deleted, isTrue);
      expect(deleted.playerOfMatch?.name, isNull);
      expect(none.playerOfMatch, isNull);
    });

    test('dismissals: which credit the bowler, which count as a wicket', () {
      expect(DismissalKind.values.where((d) => d.creditsBowler), [
        DismissalKind.bowled,
        DismissalKind.caught,
        DismissalKind.lbw,
        DismissalKind.stumped,
        DismissalKind.hitWicket,
      ]);
      expect(DismissalKind.values.where((d) => !d.isOut), [
        DismissalKind.notOut,
        DismissalKind.didNotBat,
        DismissalKind.retiredHurt,
      ]);
    });

    test('club results and record', () async {
      db.many['club_results'] = [
        {
          'match_id': 'm1',
          'opponent_club_id': 'club-b',
          'opponent_name': 'Card Kings',
          'starts_at': '2026-11-20T05:00:00+00:00',
          'format': 'custom',
          'custom_overs': 15,
          'result': 'won',
          'margin_runs': null,
          'margin_wickets': 6,
          'innings_victory': false,
          'summary': 'Card Lions won by 6 wickets',
          'version': 1,
        },
      ];
      db.one['club_record'] = {
        'played': 6,
        'won': 1,
        'lost': 2,
        'tied': 1,
        'no_result': 1,
        'abandoned': 1,
      };
      final [row] = await repo.clubResults('club-a');
      expect(
        (
          row.result,
          row.format,
          row.customOvers,
          row.marginWickets,
          row.opponentName,
        ),
        (ClubResultKind.won, MatchFormat.custom, 15, 6, 'Card Kings'),
      );
      final r = await repo.clubRecord('club-a');
      expect(
        (r.played, r.won, r.lost, r.tied, r.noResult, r.abandoned),
        (6, 1, 2, 1, 1, 1),
      );
    });
  });

  group('scorecards (migration 21)', () {
    test('innings cards in order, rows in batting / bowling order; deleted players have no name', () async {
      Map<String, dynamic> bat(
        int pos,
        String how, {
        String? member = 'x',
        String text = 'not out',
      }) => {
        'position': pos,
        'member_id': member,
        'name': member == null ? null : 'Player $pos',
        'deleted': member == null,
        'runs': 10,
        'balls': 8,
        'fours': 1,
        'sixes': 0,
        'dismissal': how,
        'dismissal_text': text,
        'bowler_member_id': null,
        'bowler_name': null,
        'fielder_member_id': null,
        'fielder_name': null,
        'fielder_deleted': false,
        'fielder_substitute': false,
        'direct_hit': false,
      };
      Map<String, dynamic> bowl(int no) => {
        'bowler_no': no,
        'member_id': 'w$no',
        'name': 'Bowler $no',
        'deleted': false,
        'balls': 22,
        'maidens': 1,
        'runs': 30,
        'wickets': 2,
        'wides': 1,
        'no_balls': 0,
      };
      db.many['match_scorecard'] = [
        {
          'version': 2,
          'innings_no': 2,
          'batting_club_id': 'club-b',
          'bowling_club_id': 'club-a',
          'batting': [
            bat(2, 'did_not_bat'),
            bat(1, 'caught', member: null, text: 'c Deleted player b Ali'),
          ],
          'bowling': [bowl(2), bowl(1)],
        },
        {
          'version': 2,
          'innings_no': 1,
          'batting_club_id': 'club-a',
          'bowling_club_id': 'club-b',
          'batting': [bat(1, 'not_out')],
          'bowling': [bowl(1)],
        },
      ];
      final cards = await repo.scorecard('m1', version: 2);
      expect(db.calls.single.params, {'p_match_id': 'm1', 'p_version': 2});
      expect(cards.map((c) => c.inningsNo), [1, 2]);
      final second = cards.last;
      expect(second.batting.map((b) => (b.position, b.dismissal)), [
        (1, DismissalKind.caught),
        (2, DismissalKind.didNotBat),
      ]);
      expect(
        (
          second.batting.first.deleted,
          second.batting.first.name,
          second.batting.first.dismissalText,
        ),
        (true, null, 'c Deleted player b Ali'),
      );
      expect(second.bowling.map((w) => (w.bowlerNo, w.overs, w.wickets)), [
        (1, '3.4', 2),
        (2, '3.4', 2),
      ]);
    });
  });

  group('statistics and my_matches (migrations 22–23)', () {
    test('player_stats: figures, texts; averages from a number or a numeric string; nulls kept', () async {
      db.one['player_stats'] = statsRow(average: '60.00');
      final s = await repo.playerStats(userId: 'u2');
      expect(db.calls.single.params, {'p_user_id': 'u2'});
      expect(
        (s.matches, s.runs, s.battingAverage, s.strikeRate, s.highestText),
        (1, 60, 60.0, 150.0, '60*'),
      );
      expect(
        (s.wickets, s.economy, s.bestBowlingText, s.oversBowled),
        (2, 7.5, '2/30', '3.5'),
      );
      expect((s.catches, s.playerOfMatch), (1, 1));
      db.one['player_stats'] = statsRow(average: null)
        ..['highest'] = null
        ..['highest_not_out'] = null
        ..['best_wickets'] = null
        ..['best_runs'] = null
        ..['economy'] = null;
      final none = await repo.playerStats();
      expect(
        (
          none.battingAverage,
          none.highestText,
          none.bestBowlingText,
          none.economy,
        ),
        (null, null, null, null),
      );
    });

    test('club_member_stats: one row per member with its role', () async {
      db.many['club_member_stats'] = [
        {
          'member_id': 'a1',
          'full_name': 'Ali',
          'member_role': 'player',
          ...statsRow(),
        },
        {
          'member_id': 'a0',
          'full_name': null,
          'member_role': 'owner',
          ...statsRow()..['matches'] = 0,
        },
      ];
      final rows = await repo.clubMemberStats('club-a');
      expect(
        rows.map((r) => (r.memberId, r.name, r.memberRole, r.stats.matches)),
        [
          ('a1', 'Ali', MemberRole.player, 1),
          ('a0', null, MemberRole.owner, 0),
        ],
      );
    });

    test(
      'player_match_log: the limit is kept within 1–200; not out when unbeaten',
      () async {
        db.many['player_match_log'] = [
          {
            'match_id': 'm1',
            'starts_at': '2026-11-20T05:00:00+00:00',
            'format': 't20',
            'custom_overs': null,
            'club_id': 'club-a',
            'club_name': 'Card Lions',
            'opponent_club_id': 'club-b',
            'opponent_name': 'Card Kings',
            'result': 'lost',
            'summary': 'Card Kings won by 4 wickets',
            'bat_innings': 1,
            'bat_runs': 15,
            'bat_balls': 15,
            'bat_fours': 1,
            'bat_sixes': 0,
            'bat_outs': 0,
            'bowl_balls': 24,
            'bowl_maidens': 0,
            'bowl_runs': 20,
            'bowl_wickets': 2,
            'catches': 0,
            'run_outs': 0,
            'stumpings': 1,
            'player_of_match': false,
          },
        ];
        final [row] = await repo.matchLog(limit: 500);
        await repo.matchLog(userId: 'u2', limit: 0);
        expect(db.calls.map((c) => c.params), [
          {'p_user_id': null, 'p_limit': 200},
          {'p_user_id': 'u2', 'p_limit': 1},
        ]);
        expect(
          (
            row.result,
            row.batRuns,
            row.notOut,
            row.bowlWickets,
            row.stumpings,
            row.playerOfMatch,
          ),
          (ClubResultKind.lost, 15, true, 2, 1, false),
        );
      },
    );

    test('my_matches: own selection, captaincy, the result from the club side; nulls for none', () async {
      Map<String, dynamic> row(
        String id,
        String status, {
        String? selection,
        String? result,
      }) => {
        'match_id': id,
        'club_id': 'club-a',
        'club_name': 'Card Lions',
        'opponent_club_id': 'club-b',
        'opponent_name': 'Card Kings',
        'format': 't20',
        'custom_overs': null,
        'status': status,
        'starts_at': '2026-11-20T05:00:00+00:00',
        'venue_name': 'Card Ground',
        'city': null,
        'cancel_reason': status == 'cancelled' ? 'Rain' : null,
        'lineup_saved': selection != null,
        'selection': selection,
        'is_captain': selection == 'playing',
        'is_vice_captain': false,
        'result': result,
        'summary': result == null ? null : 'Card Lions won by 30 runs',
        'result_version': result == null ? null : 2,
      };
      db.many['my_matches'] = [
        row('m2', 'confirmed'),
        row('m1', 'completed', selection: 'playing', result: 'won'),
        row('m3', 'cancelled', selection: 'sub'),
      ];
      final [upcoming, played, cancelled] = await repo.myMatches();
      expect(
        (
          upcoming.status,
          upcoming.selection,
          upcoming.lineupSaved,
          upcoming.result,
        ),
        (MatchStatus.confirmed, null, false, null),
      );
      expect(
        (
          played.selection,
          played.isCaptain,
          played.result,
          played.resultVersion,
        ),
        (SelectionRole.playing, true, ClubResultKind.won, 2),
      );
      expect(
        (cancelled.status, cancelled.selection, cancelled.cancelReason),
        (MatchStatus.cancelled, SelectionRole.sub, 'Rain'),
      );
    });
  });

  group('unreadable rows and refusals', () {
    test('an unknown code or a missing field is a generic error — never a guessed value', () async {
      db.many['match_result'] = [versionRow(status: 'draft')];
      expect(
        await errorOf(repo.matchResult('m1')),
        isA<BackendOperationException>(),
      );
      db.many['match_result'] = [versionRow()..remove('summary')];
      expect(
        await errorOf(repo.matchResult('m1')),
        isA<BackendOperationException>(),
      );
      db.many['match_result'] = [versionRow()..['innings'] = 'nope'];
      expect(
        await errorOf(repo.matchResult('m1')),
        isA<BackendOperationException>(),
      );
      db.one['player_stats'] = statsRow(average: 'n/a');
      expect(
        await errorOf(repo.playerStats()),
        isA<BackendOperationException>(),
      );
      db.many['my_matches'] = [
        {'match_id': 'm', 'status': 'live'},
      ];
      expect(await errorOf(repo.myMatches()), isA<BackendOperationException>());
    });

    test('read refusals → plain text (never the database text)', () async {
      db.failOn['match_result'] = refusal('P0002', 'result: not found');
      expect(
        await errorOf(repo.matchResult('m1')),
        isA<MatchRuleException>().having(
          (e) => e.message,
          'message',
          'This match no longer exists.',
        ),
      );
      db.failOn['match_scorecard'] = refusal('P0001', 'result: anything else');
      expect(
        await errorOf(repo.scorecard('m1')),
        isA<MatchRuleException>().having(
          (e) => e.message,
          'message',
          'This result isn’t available.',
        ),
      );
    });

    test('"not allowed" is a refusal, "not authenticated" a lost session; network stays network', () async {
      db.failOn['match_result'] = refusal('42501', 'result: not allowed');
      expect(
        await errorOf(repo.matchResult('m1')),
        isA<PermissionDeniedException>(),
      );
      db.failOn['player_stats'] = refusal('42501', 'stats: not allowed');
      expect(
        await errorOf(repo.playerStats(userId: 'u2')),
        isA<PermissionDeniedException>(),
      );
      db.failOn['my_matches'] = refusal('42501', 'match: not authenticated');
      expect(await errorOf(repo.myMatches()), isA<NotSignedInException>());
      db.failOn['club_results'] = const GatewayNetworkException();
      expect(
        await errorOf(repo.clubResults('c1')),
        isA<BackendUnavailableException>(),
      );
    });
  });

  group('CRICECO_RESULTS switch and providers', () {
    final supabase = BackendConfig.parse(
      backend: 'supabase',
      supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
      supabasePublishableKey: 'sb_publishable_test_0000000000000000',
    );

    test('the switch is off by default', () {
      expect(kResultsBuild, isFalse);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(resultsEnabledProvider), isFalse);
    });

    test(
      'results are live only with Supabase + memberships + matches + results',
      () {
        for (final memberships in [true, false]) {
          for (final matches in [true, false]) {
            for (final results in [true, false]) {
              expect(
                BackendModules.resultsLive(
                  supabase,
                  memberships: memberships,
                  matches: matches,
                  results: results,
                ),
                memberships && matches && results,
              );
              expect(
                BackendModules.resultsLive(
                  const BackendConfig.memory(),
                  memberships: memberships,
                  matches: matches,
                  results: results,
                ),
                isFalse,
              );
            }
          }
        }
      },
    );

    test('the results switch adds no screen module (P4–P5 do)', () {
      final without = BackendModules.of(
        supabase,
        memberships: true,
        matches: true,
      );
      expect(without.has(BackendModule.playerStats), isFalse);
    });

    ProviderContainer container({
      required BackendConfig config,
      required bool results,
      bool matches = true,
    }) {
      final c = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(config),
          membershipsEnabledProvider.overrideWithValue(true),
          matchesEnabledProvider.overrideWithValue(matches),
          resultsEnabledProvider.overrideWithValue(results),
          // Reading the results gateway while results aren't live is a failure.
          resultsGatewayProvider.overrideWith(
            (ref) => results && matches && config.isSupabase
                ? FakeResultsDb()
                : throw StateError('results gateway used with the switch off'),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('Supabase with every switch → the Supabase repository', () {
      final c = container(config: supabase, results: true);
      expect(c.read(resultsBackendLiveProvider), isTrue);
      expect(
        c.read(resultsRepositoryProvider),
        isA<SupabaseResultsRepository>(),
      );
    });

    for (final (name, config, results, matches) in [
      ('Supabase without the results switch', supabase, false, true),
      ('Supabase without the matches switch', supabase, true, false),
      ('the demo', const BackendConfig.memory(), true, true),
    ]) {
      test(
        '$name → unavailable: nothing listed, the gateway never read',
        () async {
          final c = container(
            config: config,
            results: results,
            matches: matches,
          );
          expect(c.read(resultsBackendLiveProvider), isFalse);
          final r = c.read(resultsRepositoryProvider);
          expect(r, isA<UnavailableResultsRepository>());
          expect(await r.matchResult('m1'), isEmpty);
          expect(await r.myMatches(), isEmpty);
          expect(await r.scorecard('m1'), isEmpty);
          expect((await r.playerStats()).matches, 0);
          expect((await r.clubRecord('c1')).played, 0);
        },
      );
    }
  });

  group('no write path in the app (migration 24, D8)', () {
    test('the app code calls no result write function — owner or scorer', () {
      const forbidden = [
        // Removed by migration 24 (owner writes).
        'submit_match_result',
        'confirm_match_result',
        'dispute_match_result',
        'match_player_pool',
        // The trusted scorer integration only (server-side, service_role).
        'ingest_official_result',
        'verify_official_result',
        'correct_official_result',
        'assign_match_official',
        'unassign_match_official',
        'official_match_roster',
      ];
      final offenders = <String>[];
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final name in forbidden) {
          if (src.contains(name)) offenders.add('${f.path}: $name');
        }
      }
      expect(offenders, isEmpty);
    });

    test(
      'the unavailable repository and the gateway are read-only by design',
      () {
        // A compile-time guarantee, checked here for the record: the read API
        // is all there is.
        const ResultsRepository r = UnavailableResultsRepository();
        expect(r, isA<ResultsRepository>());
        expect(FakeResultsDb(), isA<ResultsGateway>());
      },
    );
  });
}
