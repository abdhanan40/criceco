// M2 P3: the results data layer (migrations 20–23) — row mapping, request
// building, error translation and the CRICECO_RESULTS switch, on a fake
// gateway that returns rows shaped like the real database functions'. The
// SQL itself is verified by supabase/tests/local/17–18 on a disposable
// Postgres.
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/result_row_mapper.dart';
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
      expect(v.submittedByMe, isTrue);
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

    test('a totals-only submission sends no card keys; outcome and innings as the server expects', () async {
      db.one['submit_match_result_with_scorecard'] = resultsRow();
      final receipt = await repo.submit(
        const ResultSubmission(
          matchId: 'm1',
          outcome: ResultOutcome.tie,
          innings: [
            InningsInput(
              battingClubId: 'club-a',
              runs: 150,
              wickets: 7,
              balls: 120,
              wides: 4,
            ),
            InningsInput(
              battingClubId: 'club-b',
              runs: 150,
              wickets: 9,
              balls: 120,
            ),
          ],
        ),
      );
      expect(
        (receipt.matchId, receipt.version, receipt.status, receipt.outcome),
        ('m1', 1, ResultStatus.submitted, ResultOutcome.tie),
      );
      final p = db.calls.single.params;
      expect(p['p_match_id'], 'm1');
      expect(p['p_outcome'], 'tie');
      expect(p['p_player_of_match_member_id'], isNull);
      expect(p['p_innings'], [
        {
          'batting_club_id': 'club-a',
          'runs': 150,
          'wickets': 7,
          'balls': 120,
          'byes': 0,
          'leg_byes': 0,
          'wides': 4,
          'no_balls': 0,
          'penalty': 0,
          'declared': false,
        },
        {
          'batting_club_id': 'club-b',
          'runs': 150,
          'wickets': 9,
          'balls': 120,
          'byes': 0,
          'leg_byes': 0,
          'wides': 0,
          'no_balls': 0,
          'penalty': 0,
          'declared': false,
        },
      ]);
    });

    test('a submission with cards: dismissal codes; bowler, fielder and direct hit only when set', () async {
      db.one['submit_match_result_with_scorecard'] = resultsRow();
      await repo.submit(
        const ResultSubmission(
          matchId: 'm1',
          outcome: ResultOutcome.clubBWon,
          playerOfMatchMemberId: 'mem-9',
          innings: [
            InningsInput(
              battingClubId: 'club-a',
              runs: 20,
              wickets: 1,
              balls: 12,
              batting: [
                BattingInput(
                  memberId: 'a1',
                  dismissal: DismissalKind.caught,
                  runs: 15,
                  balls: 8,
                  fours: 2,
                  bowlerMemberId: 'b2',
                  fielderMemberId: 'b1',
                ),
                BattingInput(
                  memberId: 'a2',
                  dismissal: DismissalKind.runOut,
                  fielderMemberId: 'b3',
                  directHit: true,
                ),
                BattingInput(
                  memberId: 'a3',
                  dismissal: DismissalKind.didNotBat,
                ),
              ],
              bowling: [
                BowlingInput(
                  memberId: 'b2',
                  balls: 12,
                  runs: 20,
                  maidens: 1,
                  wides: 1,
                ),
              ],
            ),
          ],
        ),
      );
      final p = db.calls.single.params;
      expect(p['p_outcome'], 'club_b_won');
      expect(p['p_player_of_match_member_id'], 'mem-9');
      final innings = (p['p_innings']! as List).single as Map;
      expect(innings['batting'], [
        {
          'member_id': 'a1',
          'runs': 15,
          'balls': 8,
          'fours': 2,
          'sixes': 0,
          'dismissal': 'caught',
          'bowler_member_id': 'b2',
          'fielder_member_id': 'b1',
        },
        {
          'member_id': 'a2',
          'runs': 0,
          'balls': 0,
          'fours': 0,
          'sixes': 0,
          'dismissal': 'run_out',
          'fielder_member_id': 'b3',
          'direct_hit': true,
        },
        {
          'member_id': 'a3',
          'runs': 0,
          'balls': 0,
          'fours': 0,
          'sixes': 0,
          'dismissal': 'did_not_bat',
        },
      ]);
      expect(innings['bowling'], [
        {
          'member_id': 'b2',
          'balls': 12,
          'maidens': 1,
          'runs': 20,
          'wides': 1,
          'no_balls': 0,
        },
      ]);
    });

    test('every outcome and dismissal has its server code', () {
      expect(ResultOutcome.values.map(ResultRowMapper.outcomeCode), [
        'club_a_won',
        'club_b_won',
        'tie',
        'no_result',
        'abandoned',
      ]);
      expect(DismissalKind.values.map(ResultRowMapper.dismissalCode), [
        'not_out',
        'did_not_bat',
        'retired_hurt',
        'retired_out',
        'bowled',
        'caught',
        'lbw',
        'run_out', //
        'stumped',
        'hit_wicket',
        'obstructing_field',
        'hit_ball_twice',
        'timed_out',
      ]);
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

    test(
      'confirm and dispute name the version; the dispute reason is tidied',
      () async {
        db.one['confirm_match_result'] = resultsRow(
          status: 'confirmed',
          version: 3,
        );
        db.one['dispute_match_result'] = resultsRow(
          status: 'disputed',
          version: 3,
        );
        expect((await repo.confirm('m1', 3)).status, ResultStatus.confirmed);
        expect(
          (await repo.dispute('m1', 3, '  We   scored 121 ')).status,
          ResultStatus.disputed,
        );
        expect(db.calls.map((c) => c.params), [
          {'p_match_id': 'm1', 'p_version': 3},
          {'p_match_id': 'm1', 'p_version': 3, 'p_reason': 'We scored 121'},
        ]);
      },
    );

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
    test(
      'the player pool: line-up order, substitutes may only field',
      () async {
        db.many['match_player_pool'] = [
          {
            'club_id': 'club-a',
            'member_id': 'a1',
            'full_name': 'Ali',
            'selection': 'playing',
            'pick_order': 1,
          },
          {
            'club_id': 'club-a',
            'member_id': 'a12',
            'full_name': 'Sub',
            'selection': 'sub',
            'pick_order': 12,
          },
          {
            'club_id': 'club-b',
            'member_id': 'b1',
            'full_name': 'Bilal',
            'selection': 'member',
            'pick_order': null,
          },
        ];
        final pool = await repo.playerPool('m1');
        expect(pool.map((p) => (p.selection, p.pickOrder, p.canBatOrBowl)), [
          (PoolSelection.playing, 1, true),
          (PoolSelection.sub, 12, false),
          (PoolSelection.member, null, true),
        ]);
      },
    );

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
      db.many['match_player_pool'] = [
        {
          'club_id': 'c',
          'member_id': 'm',
          'full_name': 'X',
          'selection': 'captain',
          'pick_order': null,
        },
      ];
      expect(
        await errorOf(repo.playerPool('m1')),
        isA<BackendOperationException>(),
      );
    });

    test(
      'result refusals → what to do next (never the database text)',
      () async {
        final expected = {
          'result: match not played':
              'A result can be entered only once the match has started.',
          'result: invalid innings': 'Check the innings: runs, wickets, balls (within the overs) and extras.',
          'result: inconsistent result': 'The result doesn’t match the scores — check the winner and the totals.',
          'result: invalid scorecard': 'The scorecard doesn’t add up — check every batter, bowler and dismissal against the innings totals.',
          'result: invalid player':
              'Choose the Player of the Match from the two clubs’ players.',
          'result: invalid reason':
              'Give a reason for the dispute (up to 300 characters).',
          'result: not pending': 'This result has already been answered.',
          'result: version changed':
              'The result was changed — check the new version and try again.',
          'result: invalid': 'Choose a valid result.',
          'result: not found': 'This match no longer exists.',
          'result: invalid transition':
              "Some result details aren't valid — please check and try again",
        };
        for (final MapEntry(key: message, value: text) in expected.entries) {
          db.failOn['submit_match_result_with_scorecard'] = refusal(
            '22023',
            message,
          );
          final e = await errorOf(
            repo.submit(
              const ResultSubmission(
                matchId: 'm1',
                outcome: ResultOutcome.abandoned,
                innings: [],
              ),
            ),
          );
          expect(
            e,
            isA<MatchRuleException>().having((e) => e.message, 'message', text),
            reason: message,
          );
        }
      },
    );

    test('"not allowed" is a refusal, "not authenticated" a lost session; network stays network', () async {
      db.failOn['confirm_match_result'] = refusal(
        '42501',
        'result: not allowed',
      );
      expect(
        await errorOf(repo.confirm('m1', 1)),
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
        '$name → unavailable: nothing listed, changes refused, the gateway never read',
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
          expect(
            await errorOf(r.confirm('m1', 1)),
            isA<ModuleUnavailableException>(),
          );
          expect(
            await errorOf(
              r.submit(
                const ResultSubmission(
                  matchId: 'm1',
                  outcome: ResultOutcome.abandoned,
                  innings: [],
                ),
              ),
            ),
            isA<ModuleUnavailableException>(),
          );
        },
      );
    }
  });
}
