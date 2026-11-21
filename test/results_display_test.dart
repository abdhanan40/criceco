// M2 P4: official match results and statistics, DISPLAY ONLY — the server's
// results (migrations 20–23, the CRICECO_RESULTS switch) shown through the
// existing screens: My Matches, the Match workspace and scorecard,
// Performance, Club History, the club match result screen and the squad's
// stats by membership id. Nothing can be entered, edited, confirmed or
// disputed. Fake gateways only: no network, no database.
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/result_display_adapter.dart';
import 'package:criceco/data/supabase/result_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_match_repository.dart';
import 'package:criceco/data/supabase/supabase_results_repository.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/matches/screens/club_match_result_screen.dart';
import 'package:criceco/features/matches/screens/match_management_screen.dart';
import 'package:criceco/features/player/screens/my_matches_screen.dart';
import 'package:criceco/features/player/screens/performance_workspace.dart';
import 'package:criceco/features/player/screens/player_match_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'match_fakes.dart';
import 'membership_fakes.dart';
import 'results_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// 2026-11-21 15:00 in Pakistan.
final _now = DateTime.utc(2026, 11, 21, 10);

// ---- Rows shaped like the database functions' (migrations 20–23) ----

Map<String, dynamic> myMatchRow(
  String id,
  String status,
  DateTime startsAt, {
  String? selection,
  bool captain = false,
  String? result,
  String? summary,
  int? version,
  String? cancelReason,
  bool lineupSaved = true,
}) => {
  'match_id': id,
  'club_id': 'club-a',
  'club_name': 'Lahore Lions',
  'opponent_club_id': 'club-b',
  'opponent_name': 'Karachi Kings',
  'format': 't20',
  'custom_overs': null,
  'status': status,
  'starts_at': startsAt.toIso8601String(),
  'venue_name': 'Gaddafi Stadium',
  'city': 'Lahore',
  'cancel_reason': cancelReason,
  'lineup_saved': lineupSaved,
  'selection': selection,
  'is_captain': captain,
  'is_vice_captain': false,
  'result': result,
  'summary': summary,
  'result_version': version,
};

Map<String, dynamic> inningsJson(
  int no,
  String bat,
  String bowl,
  int runs,
  int wkts,
  int balls, {
  int byes = 0,
  int legByes = 0,
  int wides = 0,
  int noBalls = 0,
}) => {
  'innings_no': no,
  'batting_club_id': bat,
  'bowling_club_id': bowl,
  'runs': runs,
  'wickets': wkts,
  'balls': balls,
  'byes': byes,
  'leg_byes': legByes,
  'wides': wides,
  'no_balls': noBalls,
  'penalty': 0,
  'declared': false,
};

Map<String, dynamic> versionRow(
  int version,
  String status,
  String outcome,
  String summary, {
  List<Map<String, dynamic>> innings = const [],
  String? pom = 'Ali Khan',
  bool pomDeleted = false,
}) => {
  'version': version,
  'status': status,
  'outcome': outcome,
  'margin_runs': null,
  'margin_wickets': null,
  'innings_victory': false,
  'summary': summary,
  'player_of_match_member_id': pom == null ? null : 'mem-a1',
  'player_of_match_name': pom,
  'player_of_match_deleted': pomDeleted,
  'submitted_by_me': false,
  'submitted_at': '2026-11-18T12:00:00+00:00',
  'decided_at': status == 'submitted' ? null : '2026-11-18T13:00:00+00:00',
  'dispute_reason': null,
  'club_a_id': 'club-a',
  'club_b_id': 'club-b',
  'innings': innings,
};

Map<String, dynamic> bat(
  int pos,
  String? name,
  String how,
  int runs,
  int balls,
  String text, {
  int fours = 0,
  int sixes = 0,
}) => {
  'position': pos,
  'member_id': name == null ? null : 'mem-$pos',
  'name': name,
  'deleted': name == null,
  'runs': runs,
  'balls': balls,
  'fours': fours,
  'sixes': sixes,
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

Map<String, dynamic> bowl(
  int no,
  String name,
  int balls,
  int runs,
  int wkts, {
  int maidens = 0,
}) => {
  'bowler_no': no,
  'member_id': 'bowler-$no',
  'name': name,
  'deleted': false,
  'balls': balls,
  'maidens': maidens,
  'runs': runs,
  'wickets': wkts,
  'wides': 0,
  'no_balls': 0,
};

Map<String, dynamic> statsRow({int matches = 3}) => {
  'matches': matches,
  'bat_innings': matches,
  'not_outs': 1,
  'runs': matches == 0 ? 0 : 120,
  'balls_faced': 100,
  'batting_average': matches == 0 ? null : 60.0,
  'strike_rate': matches == 0 ? null : 120.0,
  'highest': matches == 0 ? null : 64,
  'highest_not_out': matches == 0 ? null : true,
  'fifties': 1,
  'hundreds': 0,
  'ducks': 0,
  'fours': 10,
  'sixes': 3,
  'bowl_innings': 2,
  'balls_bowled': 48,
  'maidens': 1,
  'runs_conceded': 60,
  'wickets': 4,
  'bowling_average': 15.0,
  'economy': 7.5,
  'bowling_strike_rate': 12.0,
  'best_wickets': 2,
  'best_runs': 30,
  'five_wickets': 0,
  'catches': 2,
  'run_outs': 1,
  'direct_hits': 1,
  'stumpings': 0,
  'player_of_match': 1,
};

Map<String, dynamic> logRow(String id, String result, int runs, DateTime at) =>
    {
      'match_id': id,
      'starts_at': at.toIso8601String(),
      'format': 't20',
      'custom_overs': null,
      'club_id': 'club-a',
      'club_name': 'Lahore Lions',
      'opponent_club_id': 'club-b',
      'opponent_name': 'Karachi Kings',
      'result': result,
      'summary': 'Summary of $id',
      'bat_innings': 1,
      'bat_runs': runs,
      'bat_balls': 40,
      'bat_fours': 2,
      'bat_sixes': 1,
      'bat_outs': 1,
      'bowl_balls': 24,
      'bowl_maidens': 0,
      'bowl_runs': 30,
      'bowl_wickets': 2,
      'catches': 1,
      'run_outs': 0,
      'stumpings': 0,
      'player_of_match': false,
    };

/// The official data for club A ("Lahore Lions") v club B ("Karachi Kings").
FakeResultsDb officialData() {
  final r = FakeResultsDb();
  r.many['my_matches'] = [
    myMatchRow(
      'm-up',
      'confirmed',
      DateTime.utc(2026, 11, 25, 10),
      selection: 'playing',
      captain: true,
    ),
    myMatchRow(
      'm-pend',
      'confirmed',
      DateTime.utc(2026, 11, 20, 10),
      selection: 'playing',
    ),
    myMatchRow(
      'm-won',
      'completed',
      DateTime.utc(2026, 11, 18, 10),
      selection: 'playing',
      result: 'won',
      summary: 'Lahore Lions won by 30 runs',
      version: 2,
    ),
    myMatchRow(
      'm-tie',
      'completed',
      DateTime.utc(2026, 11, 15, 10),
      selection: 'sub',
      result: 'tied',
      summary: 'Match tied',
      version: 1,
    ),
    myMatchRow(
      'm-tot',
      'completed',
      DateTime.utc(2026, 11, 12, 10),
      result: 'lost',
      summary: 'Karachi Kings won by 4 wickets',
      version: 1,
    ),
    myMatchRow(
      'm-nr',
      'completed',
      DateTime.utc(2026, 11, 11, 10),
      result: 'no_result',
      summary: 'No result',
      version: 1,
    ),
    myMatchRow(
      'm-ab',
      'completed',
      DateTime.utc(2026, 11, 10, 10),
      result: 'abandoned',
      summary: 'Match abandoned',
      version: 1,
    ),
    myMatchRow(
      'm-cx',
      'cancelled',
      DateTime.utc(2026, 11, 8, 10),
      cancelReason: 'Rain',
      lineupSaved: false,
    ),
  ];
  final wonInnings = [
    inningsJson(
      1,
      'club-a',
      'club-b',
      150,
      3,
      120,
      byes: 1,
      legByes: 2,
      wides: 3,
      noBalls: 1,
    ),
    inningsJson(2, 'club-b', 'club-a', 120, 10, 110),
  ];
  r.byMatch['match_result'] = {
    'm-won': [
      versionRow(
        2,
        'confirmed',
        'club_a_won',
        'Lahore Lions won by 30 runs',
        innings: wonInnings,
      ),
      versionRow(
        1,
        'superseded',
        'club_a_won',
        'Lahore Lions won by 24 runs',
        innings: wonInnings,
      ),
    ],
    'm-tot': [
      versionRow(
        1,
        'confirmed',
        'club_b_won',
        'Karachi Kings won by 4 wickets',
        pom: null,
        innings: [
          inningsJson(1, 'club-a', 'club-b', 140, 8, 120),
          inningsJson(2, 'club-b', 'club-a', 141, 6, 115),
        ],
      ),
    ],
    'm-pend': const [],
  };
  r.byMatch['match_scorecard'] = {
    'm-won': [
      {
        'version': 2,
        'innings_no': 1,
        'batting_club_id': 'club-a',
        'bowling_club_id': 'club-b',
        'batting': [
          bat(
            1,
            'Ali Khan',
            'caught',
            60,
            40,
            'c Bilal b Saad',
            fours: 6,
            sixes: 2,
          ),
          bat(2, null, 'bowled', 45, 35, 'b Saad'),
          bat(3, 'Umar Gul', 'did_not_bat', 0, 0, 'did not bat'),
        ],
        'bowling': [
          bowl(1, 'Saad Ali', 24, 35, 2),
          bowl(2, 'Bilal Raza', 22, 30, 0),
        ],
      },
      {
        'version': 2,
        'innings_no': 2,
        'batting_club_id': 'club-b',
        'bowling_club_id': 'club-a',
        'batting': [bat(1, 'Bilal Raza', 'not_out', 40, 30, 'not out')],
        'bowling': [bowl(1, 'Ali Khan', 24, 30, 2, maidens: 1)],
      },
    ],
    'm-tot': const [],
  };
  r.one['player_stats'] = statsRow();
  r.many['player_match_log'] = [
    logRow('m-won', 'won', 60, DateTime.utc(2026, 11, 18, 10)),
    logRow('m-tie', 'tied', 12, DateTime.utc(2026, 11, 15, 10)),
    logRow('m-tot', 'lost', 48, DateTime.utc(2026, 11, 12, 10)),
  ];
  r.many['club_results'] = [
    {
      'match_id': 'cm-won',
      'opponent_club_id': 'club-b',
      'opponent_name': 'Karachi Kings',
      'starts_at': '2026-11-18T10:00:00+00:00',
      'format': 't20',
      'custom_overs': null,
      'result': 'won',
      'margin_runs': 30,
      'margin_wickets': null,
      'innings_victory': false,
      'summary': 'Lahore Lions won by 30 runs',
      'version': 2,
    },
  ];
  return r;
}

/// Write functions must never be called from a display screen.
const _writes = {
  'submit_match_result_with_scorecard',
  'confirm_match_result',
  'dispute_match_result',
};

class _World {
  _World._(
    this.auth,
    this.clubDb,
    this.mdb,
    this.results,
    this.clubA,
    this.clubB,
  );

  final FakeAuth auth;
  final FakeClubDb clubDb;
  final FakeMatchDb mdb;
  final FakeResultsDb results;
  final String clubA;
  final String clubB;
  bool resultsOn = true;

  static _World create() {
    final db = FakeDb();
    final auth = FakeAuth(db);
    final clubDb = FakeClubDb(db);
    final mdb = FakeMatchDb(auth, clubDb)..now = _now;
    final a = auth.addUser('a@example.com', 'Cricket@123');
    final b = auth.addUser('b@example.com', 'Cricket@123');
    final w = _World._(
      auth,
      clubDb,
      mdb,
      officialData(),
      mdb.addClub(a.id, 'Lahore Lions', shortName: 'LL'),
      mdb.addClub(b.id, 'Karachi Kings', city: 'Karachi', shortName: 'KK'),
    );
    auth.current = a;
    return w;
  }

  /// A server match of club A v club B.
  void addMatch(String id, String status, DateTime startsAt) =>
      mdb.matches.add({
        'id': id,
        'challenge_id': null,
        'club_a_id': clubA,
        'club_b_id': clubB,
        'format': 't20',
        'custom_overs': null,
        'status': status,
        'starts_at': startsAt.toIso8601String(),
        'venue_name': 'Gaddafi Stadium',
        'city': 'Lahore',
        'proposed_starts_at': null,
        'proposed_venue_name': null,
        'proposed_city': null,
        'proposed_by_club_id': null,
        'proposal_version': 1,
        'cancelled_at': null,
        'cancelled_by_club_id': null,
        'cancel_reason': null,
        'created_at': _now.toIso8601String(),
        'last_updated_at': _now.toIso8601String(),
      });

  Club get ownClub => Club(
    id: clubA,
    name: 'Lahore Lions',
    city: 'Lahore',
    type: ClubType.corporate,
    code: 'ABC001',
  );

  Future<List<Override>> overrides() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(_supabase),
      membershipsEnabledProvider.overrideWithValue(true),
      matchesEnabledProvider.overrideWithValue(true),
      resultsEnabledProvider.overrideWithValue(resultsOn),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      authGatewayProvider.overrideWithValue(auth),
      clubGatewayProvider.overrideWithValue(clubDb),
      membershipGatewayProvider.overrideWithValue(
        FakeMembershipDb(clubDb.db, clubDb),
      ),
      matchGatewayProvider.overrideWithValue(mdb),
      resultsGatewayProvider.overrideWith(
        (ref) => resultsOn
            ? results
            : throw StateError('results gateway used with the switch off'),
      ),
      currentAccountProvider.overrideWithValue(null),
      currentClubProvider.overrideWithValue(ownClub),
    ];
  }

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: await overrides());
    addTearDown(c.dispose);
    return c;
  }

  Iterable<String> get writeCalls =>
      results.calls.map((c) => c.fn).where(_writes.contains);
}

Future<_World> _pump(
  WidgetTester tester,
  String location, {
  void Function(_World w)? before,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final w = _World.create();
  before?.call(w);
  final overrides = await w.overrides();
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: Routes.myMatches,
        builder: (_, s) => MyMatchesScreen(
          tab: MyMatchesScreen.parseTab(s.uri.queryParameters['tab']),
        ),
        routes: [
          GoRoute(
            path: ':matchId',
            builder: (_, s) => PlayerMatchWorkspace(
              matchId: s.pathParameters['matchId']!,
              tab: PlayerMatchView.parse(s.uri.queryParameters['tab']),
            ),
          ),
        ],
      ),
      GoRoute(
        path: Routes.myPerformance,
        builder: (_, s) => PerformanceWorkspace(
          tab: PerformanceView.parse(s.uri.queryParameters['tab']),
        ),
      ),
      GoRoute(
        path: Routes.matchManagementPath,
        builder: (_, s) => MatchManagementScreen(
          tab: MatchManagementScreen.parseTab(s.uri.queryParameters['tab']),
        ),
        routes: [
          GoRoute(
            path: ':matchId/result',
            builder: (_, s) =>
                ClubMatchResultScreen(matchId: s.pathParameters['matchId']!),
          ),
        ],
      ),
      GoRoute(
        path: Routes.playerHome,
        builder: (_, _) => const Scaffold(body: Text('player home')),
      ),
      GoRoute(
        path: Routes.clubHome,
        builder: (_, _) => const Scaffold(body: Text('club home')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return w;
}

/// No input field and no way to submit, edit, confirm or dispute anything.
void _expectReadOnly(WidgetTester tester, _World w) {
  expect(find.byType(TextField), findsNothing);
  for (final label in [
    'Submit',
    'Submit Result',
    'Edit',
    'Confirm Result',
    'Dispute',
    'Enter Result',
  ]) {
    expect(
      find.text(label),
      findsNothing,
      reason: 'no "$label" on a display screen',
    );
  }
  expect(
    w.writeCalls,
    isEmpty,
    reason: 'display screens only read official results',
  );
}

void main() {
  // ---------------------------------------------------------------------------
  // The adapter: official rows → the existing display models
  // ---------------------------------------------------------------------------
  group('display adapter', () {
    ClubResultRow row(
      ClubResultKind k, {
      int? runs,
      int? wkts,
      bool innings = false,
    }) => ClubResultRow(
      matchId: 'm',
      opponentClubId: 'b',
      opponentName: 'B',
      startsAt: _now,
      format: MatchFormat.t20,
      result: k,
      summary: 's',
      version: 1,
      marginRuns: runs,
      marginWickets: wkts,
      inningsVictory: innings,
    );

    test('every outcome, from the club side', () {
      expect(
        ResultDisplayAdapter.sideText(row(ClubResultKind.won, runs: 30)),
        'Won by 30 runs',
      );
      expect(
        ResultDisplayAdapter.sideText(row(ClubResultKind.lost, wkts: 1)),
        'Lost by 1 wicket',
      );
      expect(
        ResultDisplayAdapter.sideText(
          row(ClubResultKind.won, runs: 1, innings: true),
        ),
        'Won by an innings and 1 run',
      );
      expect(
        ResultDisplayAdapter.sideText(row(ClubResultKind.tied)),
        'Match tied',
      );
      expect(
        ResultDisplayAdapter.sideText(row(ClubResultKind.noResult)),
        'No result',
      );
      expect(
        ResultDisplayAdapter.sideText(row(ClubResultKind.abandoned)),
        'Match abandoned',
      );
      expect(ClubResultKind.values.map(ResultDisplayAdapter.result), [
        MatchResult.won,
        MatchResult.lost,
        MatchResult.tied,
        MatchResult.noResult,
        MatchResult.abandoned,
      ]);
    });

    test('my_matches → player matches: upcoming, pending, played, cancelled; own selection', () async {
      final db = officialData();
      final rows = await SupabaseResultsRepository(db: db).myMatches();
      final byId = {
        for (final m in rows)
          m.matchId: ResultDisplayAdapter.playerMatch(m, _now),
      };
      expect(byId['m-up']!.status, PlayerMatchStatus.upcoming);
      expect(byId['m-up']!.playingTeamName, 'Playing XI (Captain)');
      final pending = byId['m-pend']!;
      expect(
        (pending.status, pending.resultPending, pending.hasScorecard),
        (PlayerMatchStatus.past, true, false),
      );
      final won = byId['m-won']!;
      expect(
        (won.result, won.resultText, won.scorecardId, won.resultPending),
        (MatchResult.won, 'Lahore Lions won by 30 runs', 'm-won', false),
      );
      expect(
        (won.ownTeamAbbr, won.opponentAbbr, won.ground),
        ('LL', 'KK', 'Gaddafi Stadium, Lahore'),
      );
      expect(
        (byId['m-tie']!.result, byId['m-tie']!.playingTeamName),
        (MatchResult.tied, 'Substitute'),
      );
      expect(byId['m-nr']!.result, MatchResult.noResult);
      expect(byId['m-tot']!.playingTeamName, 'Not selected');
      expect(
        (byId['m-ab']!.result, byId['m-ab']!.hasScorecard),
        (MatchResult.abandoned, false),
      );
      final cx = byId['m-cx']!;
      expect(
        (cx.status, cx.cancelReason, cx.playingTeamName),
        (PlayerMatchStatus.cancelled, 'Rain', 'Line-up not announced'),
      );
    });

    test('a confirmed result with cards: strike rate, economy, extras, did not bat, deleted player', () async {
      final repo = SupabaseResultsRepository(db: officialData());
      final v = (await repo.matchResult('m-won')).first;
      final sc = ResultDisplayAdapter.scorecard(
        v,
        await repo.scorecard('m-won', version: 2),
        {'club-a': 'Lahore Lions', 'club-b': 'Karachi Kings'},
      );
      expect(
        (sc.result, sc.playerOfMatch, sc.innings.length),
        ('Lahore Lions won by 30 runs', 'Ali Khan', 2),
      );
      final first = sc.innings.first;
      expect(
        (first.team, first.abbr, first.total, first.wickets, first.overs),
        ('Lahore Lions', 'LL', 150, 3, '20.0'),
      );
      expect(
        (first.extras, first.extrasDetail, first.cardRecorded),
        (7, 'b 1, lb 2, w 3, nb 1', true),
      );
      expect(first.batting.map((b) => (b.name, b.didNotBat, b.strikeRate)), [
        ('Ali Khan', false, '150.00'),
        ('Deleted player', false, '128.57'),
        ('Umar Gul', true, '—'),
      ]);
      expect(first.bowling.map((b) => (b.name, b.overs, b.economy)), [
        ('Saad Ali', 4, '8.75'),
        ('Bilal Raza', 3.4, '8.18'),
      ]);
    });

    test(
      'totals only: innings without a card; no Player of the Match → "—"',
      () async {
        final repo = SupabaseResultsRepository(db: officialData());
        final v = (await repo.matchResult('m-tot')).first;
        final sc = ResultDisplayAdapter.scorecard(v, const [], const {
          'club-a': 'Lahore Lions',
        });
        expect(sc.playerOfMatch, '—');
        expect(
          sc.innings.map((i) => (i.team, i.cardRecorded, i.batting.length)),
          [('Lahore Lions', false, 0), ('Unknown club', false, 0)],
        );
        expect(sc.topScorer, isNull);
      },
    );

    test('a deleted Player of the Match is "Deleted player"', () {
      final v = ResultRowMapperShim.version(
        versionRow(
          1,
          'confirmed',
          'tie',
          'Match tied',
          pom: null,
          pomDeleted: true,
        ),
      );
      expect(
        ResultDisplayAdapter.scorecard(v, const [], const {}).playerOfMatch,
        'Deleted player',
      );
    });

    test('statistics → Performance tiles; none → the empty summary; rating never computed', () async {
      final repo = SupabaseResultsRepository(db: officialData());
      final p = ResultDisplayAdapter.performance(
        await repo.playerStats(),
        await repo.matchLog(),
      );
      expect(
        (p.matches, p.runs, p.wickets, p.rating, p.battingAverage),
        (3, 120, 4, '—', '60.00'),
      );
      String tile(List<StatTile> t, String label) =>
          t.firstWhere((x) => x.label == label).value;
      expect(tile(p.batting, 'Best Score'), '64*');
      expect(tile(p.batting, 'Boundaries (4s/6s)'), '10 / 3');
      expect(tile(p.bowling, 'Best Bowling'), '2/30');
      expect(tile(p.bowling, 'Economy Rate'), '7.50');
      expect(tile(p.bowling, 'Overs Bowled'), '8.0');
      expect(tile(p.fielding, 'Direct Hits'), '1');
      expect(p.recentForm.map((f) => f.result), [
        MatchResult.won,
        MatchResult.tied,
        MatchResult.lost,
      ]);
      expect(
        (p.recentWins, p.recentLosses),
        (1, 1),
        reason: 'a tie is neither a win nor a loss',
      );
      expect(p.matchLog.first.overs, '4.0');
      final none = ResultDisplayAdapter.performance(
        CricketStats.empty,
        const [],
      );
      expect(identical(none, PerformanceSummary.empty), isTrue);
    });

    test('squad stats: official figures, or unrecorded with none; rating, skill and verified never computed', () {
      final s = ResultDisplayAdapter.squadStats(
        ClubMemberStats(
          memberId: 'mem-1',
          stats: ResultRowMapperShim.stats(statsRow()),
        ),
        position: 'Opening Bat',
        category: SquadCategory.batsman,
        availability: PlayerAvailability.available,
      );
      expect(
        (
          s.matches,
          s.batting.runs,
          s.batting.average,
          s.batting.best,
          s.bowling.best,
        ),
        (3, 120, '60.00', '64*', '2/30'),
      );
      expect(
        (s.rating, s.skill, s.verified, s.form.isEmpty),
        ('—', null, false, true),
      );
      final none = ResultDisplayAdapter.squadStats(
        const ClubMemberStats(memberId: 'mem-2', stats: CricketStats.empty),
        position: 'Bowler',
        category: SquadCategory.bowler,
        availability: PlayerAvailability.available,
      );
      expect(none.hasRecord, isFalse);
    });

    test(
      'display models: results other than won / lost are not counted as losses',
      () {
        const form = [
          MatchResult.won,
          MatchResult.tied,
          MatchResult.noResult,
          MatchResult.lost,
          MatchResult.abandoned,
        ];
        final s = PlayerStats.unrecorded(
          position: 'x',
          category: SquadCategory.batsman,
        );
        final withForm = PlayerStats(
          matches: 5,
          batting: s.batting,
          bowling: s.bowling,
          form: form,
          rating: '—',
          category: s.category,
          position: s.position,
          availability: s.availability,
          skill: null,
          verified: false,
          lastMatch: s.lastMatch,
        );
        expect((withForm.wins, withForm.losses), (1, 1));
        expect(MatchResult.values.map((r) => r.short), [
          'W',
          'L',
          'T',
          'NR',
          'A',
        ]);
        expect(
          const BowlingEntry(
            name: 'x',
            overs: 3.4,
            maidens: 0,
            runs: 22,
            wickets: 1,
          ).balls,
          22,
        );
        expect(
          const BattingEntry(
            name: 'x',
            runs: 0,
            balls: 0,
            fours: 0,
            sixes: 0,
            dismissal: '',
          ).strikeRate,
          '—',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Repositories and the switch
  // ---------------------------------------------------------------------------
  group('repositories and the CRICECO_RESULTS switch', () {
    test('matchStats is a module only with Supabase + memberships + matches + results; the demo has it', () {
      for (final (m, mt, r) in [
        (true, true, true),
        (true, true, false),
        (true, false, true),
        (false, true, true),
      ]) {
        expect(
          BackendModules.of(
            _supabase,
            memberships: m,
            matches: mt,
            results: r,
          ).has(BackendModule.matchStats),
          m && mt && r,
        );
      }
      final on = BackendModules.of(
        _supabase,
        memberships: true,
        matches: true,
        results: true,
      );
      expect(
        on.has(BackendModule.playerStats),
        isFalse,
        reason: 'fitness keeps its own gate: no backend yet',
      );
      expect(
        BackendModules.of(const BackendConfig.memory())
            .has(BackendModule.matchStats),
        isTrue,
      );
    });

    test('results on: matches, scorecard and performance come from the official results — reads only', () async {
      final w = _World.create();
      final c = await w.container();
      final repo = c.read(matchRepositoryProvider) as SupabaseMatchRepository;
      expect(repo.results, isA<SupabaseResultsRepository>());
      expect((await repo.playerMatches()).length, 8);
      final sc = await repo.scorecard('m-won');
      expect(sc?.innings.first.team, 'Lahore Lions');
      expect(sc?.innings.last.team, 'Karachi Kings');
      final cardCall = w.results.calls.lastWhere(
        (x) => x.fn == 'match_scorecard',
      );
      expect(cardCall.params, {
        'p_match_id': 'm-won',
        'p_version': 2,
      }, reason: 'the CONFIRMED version');
      expect(
        await repo.scorecard('m-pend'),
        isNull,
        reason: 'no confirmed result → result pending',
      );
      expect((await repo.performance()).matches, 3);
      expect(w.writeCalls, isEmpty);
    });

    test('a waiting (unconfirmed) version is never shown', () async {
      final w = _World.create();
      w.results.byMatch['match_result']!['m-pend'] = [
        versionRow(1, 'submitted', 'tie', 'Match tied'),
      ];
      final c = await w.container();
      expect(await c.read(matchRepositoryProvider).scorecard('m-pend'), isNull);
    });

    test('club History: completed server matches carry the official result from the club side', () async {
      final w = _World.create()
        ..addMatch('cm-won', 'completed', DateTime.utc(2026, 11, 18, 10))
        ..addMatch('cm-play', 'confirmed', DateTime.utc(2026, 11, 20, 10));
      final c = await w.container();
      final matches = await c.read(matchRepositoryProvider).clubMatches();
      expect(
        matches.firstWhere((m) => m.id == 'cm-won').resultText,
        'Won by 30 runs',
      );
      expect(matches.firstWhere((m) => m.id == 'cm-play').resultText, isNull);
    });

    test(
      'results off: no official data, the results gateway never read',
      () async {
        final w = _World.create()..resultsOn = false;
        final c = await w.container();
        final repo = c.read(matchRepositoryProvider) as SupabaseMatchRepository;
        expect(repo.results, isNull);
        expect(await repo.playerMatches(), isEmpty);
        expect(await repo.scorecard('m-won'), isNull);
        expect(
          identical(await repo.performance(), PerformanceSummary.empty),
          isTrue,
        );
        expect(
          c.read(resultsRepositoryProvider),
          isA<UnavailableResultsRepository>(),
        );
      },
    );

    test('squad stats by MEMBERSHIP ID — never by name; nothing without the switch', () async {
      final w = _World.create();
      w.results.many['club_member_stats'] = [
        {
          'member_id': 'mem-ali',
          'full_name': 'Ali Khan',
          'member_role': 'player',
          ...statsRow(),
        },
      ];
      final c = await w.container();
      await c.read(clubMemberStatsProvider.future);
      final byId = c.read(
        squadPlayerStatsProvider((
          'mem-ali',
          'Somebody Else',
          'Opening Bat',
          PlayerAvailability.available,
        )),
      );
      expect(byId.matches, 3, reason: 'found by id, whatever the name');
      final byName = c.read(
        squadPlayerStatsProvider((
          'mem-other',
          'Ali Khan',
          'Opening Bat',
          PlayerAvailability.available,
        )),
      );
      expect(
        byName.hasRecord,
        isFalse,
        reason: 'the same name with another id is another person',
      );
      expect(
        c
            .read(
              squadPlayerStatsProvider((
                '',
                'Ali Khan',
                'Bowler',
                PlayerAvailability.available,
              )),
            )
            .hasRecord,
        isFalse,
      );
      expect(w.results.calls.single.params, {'p_club_id': w.clubA});

      final off = _World.create()..resultsOn = false;
      final c2 = await off.container();
      expect(await c2.read(clubMemberStatsProvider.future), isEmpty);
      expect(
        c2
            .read(
              squadPlayerStatsProvider((
                'mem-ali',
                'Ali Khan',
                'Bowler',
                PlayerAvailability.available,
              )),
            )
            .hasRecord,
        isFalse,
      );
    });

    test('demo: unchanged sample data, never the official results', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          resultsEnabledProvider.overrideWithValue(true),
          resultsGatewayProvider.overrideWith(
            (ref) => throw StateError('the demo never reads official results'),
          ),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(matchRepositoryProvider), isA<InMemoryMatchRepository>());
      expect(
        c.read(resultsRepositoryProvider),
        isA<UnavailableResultsRepository>(),
      );
      final perf = await c.read(matchRepositoryProvider).performance();
      expect(
        (perf.matches, perf.rating),
        (8, '8.2'),
        reason: 'the demo season, as before',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Screens (server, results on) — read-only
  // ---------------------------------------------------------------------------
  group('screens (official results, read-only)', () {
    testWidgets(
      'My Matches: upcoming, played with results, result pending, cancelled',
      (tester) async {
        final w = await _pump(tester, '${Routes.myMatches}?tab=past');
        expect(find.text('Lahore Lions won by 30 runs'), findsOneWidget);
        expect(find.text('Match tied'), findsOneWidget);
        expect(find.text('No result'), findsOneWidget);
        expect(find.text('Match abandoned'), findsOneWidget);
        expect(
          find.byKey(const Key('playerMatch.pending.m-pend')),
          findsOneWidget,
        );
        expect(find.text('Playing XI'), findsWidgets);
        _expectReadOnly(tester, w);

        await tester.tap(find.text('Upcoming'));
        await tester.pumpAndSettle();
        expect(find.text('Playing XI (Captain)'), findsOneWidget);
        await tester.tap(find.text('Cancelled'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Rain'), findsOneWidget);
      },
    );

    testWidgets('workspace: result pending → a notice, no scorecard tab', (
      tester,
    ) async {
      final w = await _pump(tester, '${Routes.myMatches}/m-pend');
      expect(
        find.byKey(const Key('playerMatch.resultPending')),
        findsOneWidget,
      );
      expect(find.text('Scorecard'), findsNothing);
      _expectReadOnly(tester, w);
    });

    testWidgets(
      'workspace: the official scorecard — SR, Econ, extras, did not bat, deleted player',
      (tester) async {
        final w = await _pump(
          tester,
          '${Routes.myMatches}/m-won?tab=scorecard',
        );
        expect(find.text('Lahore Lions won by 30 runs'), findsWidgets);
        for (final h in ['SR', 'ECON']) {
          expect(find.text(h), findsNWidgets(2), reason: 'both innings');
        }
        expect(find.text('150.00'), findsOneWidget);
        expect(find.text('Deleted player'), findsOneWidget);
        expect(find.text('Did not bat: Umar Gul'), findsOneWidget);
        expect(find.text('Extras 7 (b 1, lb 2, w 3, nb 1)'), findsOneWidget);
        expect(find.text('8.75'), findsOneWidget);
        expect(find.text('Ali Khan'), findsWidgets);
        _expectReadOnly(tester, w);
      },
    );

    testWidgets('workspace: a totals-only result shows the totals, no card', (
      tester,
    ) async {
      final w = await _pump(tester, '${Routes.myMatches}/m-tot?tab=scorecard');
      expect(find.byKey(const Key('scorecard.totalsOnly')), findsNWidgets(2));
      expect(find.text('SR'), findsNothing);
      expect(find.textContaining('140/8'), findsOneWidget);
      _expectReadOnly(tester, w);
    });

    testWidgets('workspace: an abandoned match — the result, no scorecard', (
      tester,
    ) async {
      final w = await _pump(tester, '${Routes.myMatches}/m-ab');
      expect(find.text('Match abandoned'), findsOneWidget);
      expect(find.text('Scorecard'), findsNothing);
      _expectReadOnly(tester, w);
    });

    testWidgets('Performance: official figures; a tie in the form', (
      tester,
    ) async {
      final w = await _pump(tester, Routes.myPerformance);
      expect(find.text('60.00'), findsWidgets);
      expect(find.text('T'), findsOneWidget);
      expect(find.byKey(const Key('performance.notAvailable')), findsNothing);
      _expectReadOnly(tester, w);
    });

    testWidgets(
      'Performance: no official matches → "Statistics not available yet"',
      (tester) async {
        final w = await _pump(
          tester,
          Routes.myPerformance,
          before: (w) {
            w.results.one['player_stats'] = statsRow(matches: 0);
            w.results.many['player_match_log'] = const [];
          },
        );
        expect(
          find.byKey(const Key('performance.notAvailable')),
          findsOneWidget,
        );
        expect(find.text('60.00'), findsNothing);
        _expectReadOnly(tester, w);
      },
    );

    testWidgets('Performance: a failed load says so, with Try again', (
      tester,
    ) async {
      await _pump(
        tester,
        Routes.myPerformance,
        before: (w) {
          w.results.failOn['player_stats'] = const GatewayNetworkException();
        },
      );
      expect(find.text('Performance unavailable'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets(
      'Club History: the official result and View Result; a played match is "Result pending"',
      (tester) async {
        final w = await _pump(
          tester,
          Routes.matchManagement(MatchTab.history),
          before: (w) {
            w
              ..addMatch('cm-won', 'completed', DateTime.utc(2026, 11, 18, 10))
              ..addMatch(
                'cm-play',
                'confirmed',
                DateTime.utc(2026, 11, 20, 10),
              );
            w.results.byMatch['match_result']!['cm-won'] =
                w.results.byMatch['match_result']!['m-won']!;
            w.results.byMatch['match_scorecard']!['cm-won'] =
                w.results.byMatch['match_scorecard']!['m-won']!;
            w.results.many['my_matches'] = [
              myMatchRow(
                'cm-won',
                'completed',
                DateTime.utc(2026, 11, 18, 10),
                result: 'won',
                summary: 'Lahore Lions won by 30 runs',
                version: 2,
              ),
            ];
          },
        );
        expect(find.byKey(const Key('match.result.cm-won')), findsOneWidget);
        expect(find.text('Won by 30 runs'), findsOneWidget);
        _expectReadOnly(tester, w);

        await tester.tap(find.byKey(const Key('match.viewResult.cm-won')));
        await tester.pumpAndSettle();
        expect(find.text('Match Result'), findsOneWidget);
        expect(find.text('Lahore Lions won by 30 runs'), findsWidgets);
        expect(find.text('ECON'), findsNWidgets(2));
        _expectReadOnly(tester, w);
      },
    );

    testWidgets(
      'Club Scheduled tab: a played match without an official result is "Result pending"',
      (tester) async {
        final w = await _pump(
          tester,
          Routes.matchManagement(MatchTab.scheduled),
          before: (w) {
            w
              ..addMatch('cm-play', 'confirmed', DateTime.utc(2026, 11, 20, 10))
              ..addMatch(
                'cm-next',
                'confirmed',
                DateTime.utc(2026, 11, 26, 10),
              );
          },
        );
        expect(
          find.text('RESULT PENDING'),
          findsOneWidget,
          reason: 'status chips are uppercase; only the played match',
        );
        expect(find.text('CONFIRMED'), findsOneWidget);
        _expectReadOnly(tester, w);
      },
    );

    testWidgets(
      'results off: a played match stays "Confirmed", no View Result',
      (tester) async {
        await _pump(
          tester,
          Routes.matchManagement(MatchTab.scheduled),
          before: (w) {
            w
              ..resultsOn = false
              ..addMatch(
                'cm-play',
                'confirmed',
                DateTime.utc(2026, 11, 20, 10),
              );
          },
        );
        expect(find.text('RESULT PENDING'), findsNothing);
        expect(find.text('CONFIRMED'), findsOneWidget);
      },
    );

    testWidgets('Club match result: nothing confirmed yet → "Result pending"', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        '${Routes.matchManagementPath}/m-pend/result',
      );
      expect(find.byKey(const Key('clubResult.pending')), findsOneWidget);
      _expectReadOnly(tester, w);
    });
  });
}

/// Rows → models through the real mapper (for the few direct checks above).
abstract final class ResultRowMapperShim {
  static ResultVersion version(Map<String, dynamic> row) =>
      ResultRowMapper.version('m', row);
  static CricketStats stats(Map<String, dynamic> row) =>
      ResultRowMapper.stats(row);
}
