// M10 (migration 35, the CRICECO_TOURNAMENTS switch): tournaments on the
// server — hosting, browse, entries (exactly 11 + 4), the organizer's
// decisions and removals, the draw, the points table and the awards (official
// results only) — through the real repository, controllers and screens on
// FakeTournamentDb. No network, no database. Switch OFF: today's behaviour,
// no call made. The demo (memory mode) is covered by tournaments_test.dart.
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/match_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_tournament_repository.dart';
import 'package:criceco/data/supabase/tournament_row_mapper.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/matches/lineup_controller.dart';
import 'package:criceco/features/tournaments/registration_draft.dart';
import 'package:criceco/features/tournaments/screens/browse_screens.dart';
import 'package:criceco/features/tournaments/screens/hosted_screens.dart';
import 'package:criceco/features/tournaments/screens/registration_screens.dart';
import 'package:criceco/features/tournaments/tournament_demo_actions.dart';
import 'package:criceco/features/tournaments/tournaments_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'match_fakes.dart';
import 'membership_fakes.dart';
import 'supabase_fakes.dart';
import 'tournament_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

final _now = DateTime.utc(2026, 11, 20, 6);
final _today = DateTime(2026, 11, 20);

class _World {
  _World._(
    this.auth,
    this.clubDb,
    this.mdb,
    this.tdb,
    this.a,
    this.b,
    this.clubA,
    this.clubB,
  );

  final FakeAuth auth;
  final FakeClubDb clubDb;
  final FakeMatchDb mdb;
  final FakeTournamentDb tdb;
  final AuthUser a, b;
  final String clubA, clubB;

  static const clubC = 'club-c', clubD = 'club-d';

  static _World create() {
    final db = FakeDb();
    final auth = FakeAuth(db);
    final clubDb = FakeClubDb(db);
    final mdb = FakeMatchDb(auth, clubDb);
    final a = auth.addUser('a@example.com', 'Cricket@123');
    final b = auth.addUser('b@example.com', 'Cricket@123');
    final clubA = mdb.addClub(a.id, 'Lahore Lions', shortName: 'LL');
    final clubB = mdb.addClub(b.id, 'Karachi Kings', city: 'Karachi');
    final tdb = FakeTournamentDb(
      auth,
      owners: {
        clubA: a.id,
        clubB: b.id,
        clubC: 'owner-c',
        clubD: 'owner-d',
        'club-e': 'owner-e',
        'club-f': 'owner-f',
      },
      clubNames: {
        clubA: 'Lahore Lions',
        clubB: 'Karachi Kings',
        clubC: 'Multan Sultans',
        clubD: 'Quetta Gladiators',
        'club-e': 'Peshawar Zalmi',
        'club-f': 'Islamabad United',
      },
      today: _today,
    );
    auth.current = a;
    return _World._(auth, clubDb, mdb, tdb, a, b, clubA, clubB);
  }

  Club club({bool asB = false}) => Club(
    id: asB ? clubB : clubA,
    name: asB ? 'Karachi Kings' : 'Lahore Lions',
    city: asB ? 'Karachi' : 'Lahore',
    type: ClubType.corporate,
    code: asB ? 'ABC002' : 'ABC001',
  );

  Future<List<Override>> overrides({
    bool tournaments = true,
    bool memberships = true,
    bool asB = false,
    bool demo = false,
    List<Override> extra = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    auth.current = asB ? b : a;
    final me = asB ? b : a;
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(_supabase),
      membershipsEnabledProvider.overrideWithValue(memberships),
      matchesEnabledProvider.overrideWithValue(true),
      tournamentsEnabledProvider.overrideWithValue(tournaments),
      demoBuildProvider.overrideWithValue(demo),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      authGatewayProvider.overrideWithValue(auth),
      clubGatewayProvider.overrideWithValue(clubDb),
      membershipGatewayProvider.overrideWithValue(
        FakeMembershipDb(clubDb.db, clubDb),
      ),
      matchGatewayProvider.overrideWithValue(mdb),
      tournamentGatewayProvider.overrideWithValue(tdb),
      currentAccountProvider.overrideWithValue(
        UserAccount(
          id: me.id,
          fullName: asB ? 'Babar Azam' : 'Ali Raza',
          contactMethod: ContactMethod.email,
          city: asB ? 'Karachi' : 'Lahore',
        ),
      ),
      currentClubProvider.overrideWithValue(club(asB: asB)),
      ...extra,
    ];
  }

  Future<ProviderContainer> container({
    bool tournaments = true,
    bool memberships = true,
    bool asB = false,
    bool demo = false,
    List<Override> extra = const [],
  }) async {
    final c = ProviderContainer(
      overrides: await overrides(
        tournaments: tournaments,
        memberships: memberships,
        asB: asB,
        demo: demo,
        extra: extra,
      ),
    );
    addTearDown(c.dispose);
    return c;
  }
}

/// A squad of [xi] playing + [subs] substitutes, members m1… in pick order
/// (substitutes picked in between, as the Team Builder allows).
Lineup _squad({
  int xi = 11,
  int subs = 4,
  String? teamId,
  String? captain,
  String? vice,
}) => Lineup(
  name: teamId == null ? Lineup.newMatchDaySquadName : 'Kings XI',
  sourceTeamId: teamId,
  captainId: captain,
  viceCaptainId: vice,
  members: [
    for (var i = 1; i <= xi + subs; i++)
      TeamMember(
        playerId: 'm$i',
        selection: i == 2 || i > xi + 1
            ? SelectionRole.sub
            : SelectionRole.playing,
      ),
  ],
);

TournamentInput _input({
  String name = 'Lahore Super Cup',
  TournamentType type = TournamentType.knockout,
}) => TournamentInput(
  name: name,
  city: 'Lahore',
  ground: '  Gaddafi   Stadium ',
  format: MatchFormat.t20,
  type: type,
  startDate: DateTime(2026, 12, 10),
  endDate: DateTime(2026, 12, 13),
  registrationDeadline: DateTime(2026, 12, 5),
  entryFee: 5000,
  prize: 100000,
  maxTeams: 8,
  description: '   ',
);

Future<void> _settled(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, dynamic> _fixtureRow(
  int round,
  String name,
  int no, {
  String? home,
  String? away,
  bool homeBye = false,
  bool awayBye = false,
  String? winner,
  bool winnerBye = false,
}) => {
  'fixture_id': 'f-$round-$no',
  'round_no': round,
  'round_name': name,
  'match_no': no,
  'home_registration_id': home,
  'home_club_id': null,
  'home_name': home,
  'home_bye': homeBye,
  'away_registration_id': away,
  'away_club_id': null,
  'away_name': away,
  'away_bye': awayBye,
  'winner_registration_id': winner,
  'winner_bye': winnerBye,
  'state': 'ready',
  'next_fixture_id': null,
  'next_slot': null,
  'match_id': null,
  'decided_at': null,
};

void main() {
  // ---------------------------------------------------------------------------
  group('rows', () {
    test('a tournament row: codes, the effective status, the server counts, none for unset', () {
      final w = _World.create();
      final id = w.tdb.addTournament(
        w.clubB,
        'Karachi Cup',
        city: 'Karachi',
        type: 'league',
        maxTeams: 4,
      );
      w.tdb.addEntry(id, w.clubA, status: 'approved');
      final t = TournamentRowMapper.tournament(
        w.tdb.tRow(w.tdb.tournaments[id]!),
      );
      expect(
        (t.id, t.name, t.organizerClubId, t.organizerName),
        (id, 'Karachi Cup', w.clubB, 'Karachi Kings'),
      );
      expect(
        (t.city, t.ground, t.format, t.customOvers, t.type),
        (
          'Karachi',
          'Gaddafi Stadium',
          MatchFormat.t20,
          null,
          TournamentType.league,
        ),
      );
      expect(
        (t.startDate, t.endDate, t.registrationDeadline),
        (DateTime(2026, 12, 10), DateTime(2026, 12, 13), DateTime(2026, 12, 5)),
      );
      expect(
        (t.entryFee, t.prize, t.maxTeams, t.description),
        (5000, 50000, 4, 'Weekend cup'),
      );
      expect(t.rules, ['Standard T20 rules']);
      expect(
        (t.status, t.approvedCount, t.pendingCount, t.fixturesGenerated),
        (TournamentStatus.registrationOpen, 1, null, false),
      );
      expect(
        (
          t.joinedCount,
          t.availableSlots,
          t.isFull,
          t.hasFixtures,
          t.joined.length,
        ),
        (1, 3, false, false, 0),
      );
      expect(t.acceptsRegistrationsAt(_now), isTrue);

      final row = w.tdb.tRow(w.tdb.tournaments[id]!);
      final closed = TournamentRowMapper.tournament({
        ...row,
        'status': 'registration_closed',
        'entry_fee': null,
        'prize': null,
        'description': null,
        'rules': null,
        'format': 'custom',
        'custom_overs': 12,
        'fixtures_generated': true,
        'winner_registration_id': 'r1',
        'winner_name': 'Lahore Lions',
      });
      expect(
        (
          closed.status,
          closed.entryFee,
          closed.prize,
          closed.description,
          closed.rules.length,
        ),
        (TournamentStatus.registrationClosed, null, null, '', 0),
      );
      expect(
        (
          closed.customOvers,
          closed.hasFixtures,
          closed.acceptsRegistrationsAt(_now),
        ),
        (12, true, false),
      );
      expect(
        entrantLabel(closed, 'r1'),
        'Lahore Lions',
        reason: 'the champion by the server name',
      );
      for (final bad in [
        {...row, 'status': 'draft'},
        {...row, 'tournament_type': 'groups'},
        {...row, 'start_date': null},
        {...row, 'approved_count': null},
      ]) {
        expect(
          () => TournamentRowMapper.tournament(bad),
          throwsA(isA<MatchRowFormatException>()),
        );
      }
    });

    test('an entry: "removed" is listed as Rejected, flagged; its entrant is the club', () {
      final w = _World.create();
      final id = w.tdb.addTournament(w.clubA, 'Cup');
      final reg = w.tdb.addEntry(id, w.clubB, status: 'removed');
      final r = TournamentRowMapper.entry(w.tdb.entries.single);
      expect(
        (r.id, r.tournamentId, r.clubId, r.clubName, r.clubCity),
        (reg, id, w.clubB, 'Karachi Kings', 'Lahore'),
      );
      expect(
        (r.status, r.removed, r.teamName, r.decidedAt != null, r.isPending),
        (RegistrationStatus.rejected, true, 'Karachi Kings XI', true, false),
      );
      expect(TournamentRowMapper.registrationStatus('approved'), (
        RegistrationStatus.approved,
        false,
      ));
      expect(TournamentRowMapper.registrationStatus('rejected'), (
        RegistrationStatus.rejected,
        false,
      ));
      expect(
        () => TournamentRowMapper.registrationStatus('withdrawn'),
        throwsA(isA<MatchRowFormatException>()),
      );
      final e = TournamentRowMapper.entrant(r);
      expect(
        (e.id, e.displayName, e.clubId, e.city),
        (reg, 'Karachi Kings', w.clubB, 'Lahore'),
      );
      final mine = TournamentRowMapper.myRegistration({
        'registration_id': 'x',
        'tournament_id': id,
        'team_id': 't1',
        'team_name': 'Lions XI',
        'status': 'pending',
        'submitted_at': '2026-11-20T05:00:00+00:00',
        'decided_at': null,
      }, w.clubA);
      expect(
        (mine.clubId, mine.teamId, mine.status, mine.removed),
        (w.clubA, 't1', RegistrationStatus.pending, false),
      );
    });

    test('fixtures: rounds in draw order, BYE and TBD sides; decided BYEs are not listed', () {
      final rounds = TournamentRowMapper.fixtures([
        _fixtureRow(1, 'Semifinal', 1, home: 'r1', away: 'r2'),
        _fixtureRow(1, 'Semifinal', 2, home: 'r3', awayBye: true, winner: 'r3'),
        _fixtureRow(2, 'Final', 1, away: 'r3'),
      ])!;
      expect([for (final r in rounds) r.name], ['Semifinal', 'Final']);
      final walkover = rounds[0].matches[1];
      expect(
        (walkover.away, walkover.isBye, walkover.winnerId),
        (FixtureMatch.bye, true, 'r3'),
      );
      final last = rounds[1].matches.single;
      expect(
        (last.home, last.away, last.ready, last.completed),
        (null, 'r3', false, false),
      );
      final t = Tournament(
        id: 't',
        name: 'Cup',
        organizerClubId: 'c',
        city: 'Lahore',
        ground: 'G',
        format: MatchFormat.t20,
        type: TournamentType.knockout,
        startDate: _today,
        endDate: _today,
        registrationDeadline: _today,
        maxTeams: 4,
        status: TournamentStatus.registrationClosed,
        fixtures: rounds,
      );
      expect(
        [for (final f in flattenFixtures(t)) f.roundName],
        ['Semifinal', 'Final'],
      );
      expect(
        TournamentRowMapper.fixtures(const []),
        isNull,
        reason: 'no draw yet',
      );
      final byes = TournamentRowMapper.fixtures([
        _fixtureRow(
          1,
          'Final',
          1,
          homeBye: true,
          awayBye: true,
          winnerBye: true,
        ),
      ])!;
      expect(byes.single.matches.single.winnerId, FixtureMatch.bye);
    });

    test('points in table order; awards only from rows (none → null); the squad; the hub counts', () {
      final points = TournamentRowMapper.points([
        {
          'position': 1,
          'registration_id': 'r2',
          'club_id': 'c2',
          'club_name': 'B',
          'team_name': 'B',
          'played': 2,
          'won': 2,
          'lost': 0,
          'points': 4,
        },
        {
          'position': 2,
          'registration_id': 'r1',
          'club_id': 'c1',
          'club_name': 'A',
          'team_name': 'A',
          'played': 2,
          'won': 0,
          'lost': 2,
          'points': 0,
        },
      ]);
      expect(points.keys, ['r2', 'r1']);
      expect(
        (points['r2']!.played, points['r2']!.won, points['r2']!.points),
        (2, 2, 4),
      );

      expect(TournamentRowMapper.awards(const []), isNull);
      expect(
        TournamentRowMapper.awards([
          {
            'award': 'mvp',
            'registration_id': 'r1',
            'player_name': 'X',
            'value': 1,
            'matches_counted': 1,
          },
        ]),
        isNull,
        reason: 'an award this version does not know',
      );
      final awards = TournamentRowMapper.awards([
        {
          'award': 'top_run_scorer',
          'registration_id': 'r1',
          'club_id': 'c1',
          'club_name': 'A',
          'member_id': 'm1',
          'player_name': 'Babar',
          'value': 87,
          'matches_counted': 1,
        },
        {
          'award': 'best_fielder',
          'registration_id': 'r2',
          'club_id': 'c2',
          'club_name': 'B',
          'member_id': 'm2',
          'player_name': 'Shan',
          'value': 3,
          'matches_counted': 1,
        },
      ])!;
      expect(
        (
          awards.topScorer!.playerName,
          awards.topScorer!.value,
          awards.topScorer!.entrantId,
        ),
        ('Babar', 87, 'r1'),
      );
      expect(
        (awards.topWicketTaker, awards.bestKeeper, awards.bestFielder!.value),
        (null, null, 3),
      );

      final squad = TournamentRowMapper.squad([
        {
          'member_id': 'm1',
          'selection': 'playing',
          'is_captain': true,
          'is_vice_captain': false,
        },
        {
          'member_id': 'm2',
          'selection': 'playing',
          'is_captain': false,
          'is_vice_captain': true,
        },
        {
          'member_id': 'm3',
          'selection': 'sub',
          'is_captain': false,
          'is_vice_captain': false,
        },
      ], teamName: 'Lions XI');
      expect(
        (squad.name, squad.captainId, squad.viceCaptainId),
        ('Lions XI', 'm1', 'm2'),
      );
      expect(
        [for (final m in squad.members) (m.playerId, m.selection)],
        [
          ('m1', SelectionRole.playing),
          ('m2', SelectionRole.playing),
          ('m3', SelectionRole.sub),
        ],
      );

      expect(
        TournamentRowMapper.hubStats({
          'hosted': 1,
          'open': 2,
          'registered': 3,
          'approved': 4,
          'pending': 5,
        }),
        (hosted: 1, open: 2, registered: 3, approved: 4, pending: 5),
      );
    });

    test('parameters: create trims and codes the form (blank optional text is none); submit sends the XI first', () {
      final create = TournamentRowMapper.createParams(
        Tournament(
          id: '',
          name: ' Lahore Cup ',
          organizerClubId: 'club-1',
          city: 'Lahore',
          ground: ' Gaddafi ',
          format: MatchFormat.odi,
          customOvers: 30,
          type: TournamentType.league,
          startDate: DateTime(2026, 12, 1),
          endDate: DateTime(2026, 12, 2),
          registrationDeadline: DateTime(2026, 11, 28),
          maxTeams: 6,
          description: '  ',
          rules: const ['  ', ' No sledging '],
          status: TournamentStatus.registrationOpen,
        ),
      );
      expect(create, {
        'p_club_id': 'club-1',
        'p_name': 'Lahore Cup',
        'p_city': 'Lahore',
        'p_ground': 'Gaddafi',
        'p_format': 'odi',
        'p_custom_overs': null,
        'p_tournament_type': 'league',
        'p_start_date': '2026-12-01',
        'p_end_date': '2026-12-02',
        'p_registration_deadline': '2026-11-28',
        'p_max_teams': 6,
        'p_entry_fee': null,
        'p_prize': null,
        'p_description': null,
        'p_rules': ['No sledging'],
      });

      final submit = TournamentRowMapper.submitParams(
        tournamentId: 't1',
        clubId: 'club-2',
        lineup: _squad(teamId: 'team-1', captain: 'm1', vice: 'm3'),
        agreedToRules: true,
      );
      final players = (submit['p_players']! as List)
          .cast<Map<String, Object?>>();
      expect(players, hasLength(15));
      expect([
        for (final p in players.take(11)) p['selection'],
      ], everyElement('playing'));
      expect([
        for (final p in players.skip(11)) p['selection'],
      ], everyElement('sub'));
      expect(players.first, {'member_id': 'm1', 'selection': 'playing'});
      expect(players[11], {
        'member_id': 'm2',
        'selection': 'sub',
      }, reason: 'the first substitute picked');
      expect(
        {
          for (final k in [
            'p_tournament_id',
            'p_club_id',
            'p_team_name',
            'p_team_id',
            'p_captain_member_id',
            'p_vice_member_id',
            'p_keeper_member_id',
            'p_agree_rules',
          ])
            k: submit[k],
        },
        {
          'p_tournament_id': 't1',
          'p_club_id': 'club-2',
          'p_team_name': 'Kings XI',
          'p_team_id': 'team-1',
          'p_captain_member_id': 'm1',
          'p_vice_member_id': 'm3',
          'p_keeper_member_id': null,
          'p_agree_rules': true,
        },
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('errors', () {
    Exception map(String state, String message) => SupabaseErrorMapper.map(
      GatewayConstraintException(sqlState: state, message: message),
    );

    test('every refusal says what to do next, with its reason', () {
      for (final (state, message, text, reason) in [
        (
          '22023',
          'tournament: invalid name',
          TournamentTexts.name,
          'invalid name',
        ),
        (
          '22023',
          'tournament: start date too far ahead',
          TournamentTexts.startTooFar,
          'start date too far ahead',
        ),
        (
          '22023',
          'tournament: tournament too long',
          TournamentTexts.tooLong,
          'tournament too long',
        ),
        (
          '22023',
          'tournament: deadline after start date',
          TournamentTexts.deadlineAfterStart,
          'deadline after start date',
        ),
        (
          'P0001',
          'tournament: too many tournaments, try later',
          TournamentTexts.tooManyToday,
          'too many tournaments, try later',
        ),
        (
          'P0001',
          'tournament: too many tournaments',
          TournamentTexts.tooManyOpen,
          'too many tournaments',
        ),
        (
          '22023',
          'tournament: invalid team name',
          TournamentTexts.teamName,
          'invalid team name',
        ),
        (
          '22023',
          'tournament: invalid team',
          TournamentTexts.team,
          'invalid team',
        ),
        (
          '22023',
          'tournament: rules not agreed',
          TournamentTexts.rulesNotAgreed,
          'rules not agreed',
        ),
        (
          '23514',
          'tournament: squad must be 11 + 4',
          TournamentTexts.squadSize,
          'squad must be 11 + 4',
        ),
        (
          '23514',
          'tournament: player not in club',
          TournamentTexts.playerNotInClub,
          'player not in club',
        ),
        (
          'P0001',
          'tournament: player unavailable',
          TournamentTexts.playerUnavailable,
          'player unavailable',
        ),
        (
          'P0001',
          'tournament: player already registered',
          TournamentTexts.playerElsewhere,
          'player already registered',
        ),
        (
          'P0001',
          'tournament: registration full',
          TournamentTexts.full,
          'registration full',
        ),
        (
          'P0001',
          'tournament: registration closed',
          TournamentTexts.closed,
          'registration closed',
        ),
        (
          'P0001',
          'tournament: already registered',
          TournamentTexts.alreadyRegistered,
          'already registered',
        ),
        (
          'P0001',
          'tournament: too many registrations, try later',
          TournamentTexts.tooManyRegistrations,
          'too many registrations, try later',
        ),
        (
          'P0001',
          'tournament: not pending',
          TournamentTexts.notPending,
          'not pending',
        ),
        (
          'P0001',
          'tournament: fixtures generated',
          TournamentTexts.fixturesGenerated,
          'fixtures generated',
        ),
        (
          'P0001',
          'tournament: not enough teams',
          TournamentTexts.notEnoughTeams,
          'not enough teams',
        ),
        (
          'P0002',
          'tournament: registration not found',
          TournamentTexts.registrationGone,
          'registration not found',
        ),
        (
          'P0002',
          'tournament: not found',
          TournamentTexts.tournamentGone,
          'not found',
        ),
      ]) {
        final e = map(state, message);
        expect(e, isA<TournamentRuleException>(), reason: message);
        expect(
          ((e as TournamentRuleException).message, e.reason),
          (text, reason),
          reason: message,
        );
      }
      final unknown =
          map('P0001', 'tournament: something new') as TournamentRuleException;
      expect(
        (unknown.message, unknown.reason),
        (TournamentTexts.generic, null),
      );
      expect(
        map('42501', 'tournament: not allowed'),
        isA<PermissionDeniedException>(),
      );
      expect(
        map('42501', 'tournament: not authenticated'),
        isA<NotSignedInException>(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('switch', () {
    test('OFF: an empty in-memory repository, the module unavailable, nothing invented, no call', () async {
      final w = _World.create();
      final id = w.tdb.addTournament(w.clubB, 'Karachi Cup');
      final c = await w.container(tournaments: false);
      expect(
        c.read(tournamentRepositoryProvider),
        isA<InMemoryTournamentRepository>(),
      );
      expect(
        (c.read(tournamentBackendProvider), c.read(tournamentsLiveProvider)),
        (null, false),
      );
      expect(
        c.read(backendModulesProvider).has(BackendModule.tournaments),
        isFalse,
      );
      expect(await c.read(tournamentsProvider.future), isEmpty);
      expect(await c.read(tournamentRegistrationsProvider.future), isEmpty);
      expect(await c.read(tournamentServerStatsProvider.future), isNull);
      final keep = c.listen(tournamentsSyncProvider('hub'), (_, _) {});
      await c.read(tournamentsSyncProvider('hub').future);
      keep.close();
      expect(c.read(tournamentHubStatsProvider).hosted, 0);
      expect(c.read(tournamentAwardsProvider(id)), isNull);
      expect(w.tdb.calls, isEmpty);
    });

    test('ON: the server repository, its functions and the module', () async {
      final w = _World.create();
      final c = await w.container();
      expect(
        c.read(tournamentRepositoryProvider),
        isA<SupabaseTournamentRepository>(),
      );
      expect(
        c.read(tournamentBackendProvider),
        isA<SupabaseTournamentRepository>(),
      );
      expect(c.read(tournamentsLiveProvider), isTrue);
      expect(
        c.read(backendModulesProvider).has(BackendModule.tournaments),
        isTrue,
      );
      expect(
        () => c
            .read(tournamentRepositoryProvider)
            .save(
              TournamentRowMapper.tournament(
                w.tdb.tRow(
                  w.tdb.tournaments[w.tdb.addTournament(w.clubB, 'X')]!,
                ),
              ),
            ),
        throwsUnsupportedError,
      );
    });

    test('ON without the memberships switch: not available, no call', () async {
      final w = _World.create();
      final c = await w.container(memberships: false);
      expect(
        c.read(tournamentRepositoryProvider),
        isA<InMemoryTournamentRepository>(),
      );
      expect(
        c.read(backendModulesProvider).has(BackendModule.tournaments),
        isFalse,
      );
      expect(await c.read(tournamentsProvider.future), isEmpty);
      expect(w.tdb.calls, isEmpty);
    });

    test('module matrix: memory mode always; Supabase needs memberships AND tournaments', () {
      final memory = BackendConfig.parse();
      expect(
        BackendModules.of(
          memory,
          memberships: false,
          tournaments: false,
        ).has(BackendModule.tournaments),
        isTrue,
      );
      for (final (memberships, tournaments, expected) in [
        (false, false, false),
        (true, false, false),
        (false, true, false),
        (true, true, true),
      ]) {
        expect(
          BackendModules.of(
            _supabase,
            memberships: memberships,
            tournaments: tournaments,
          ).has(BackendModule.tournaments),
          expected,
          reason: 'memberships $memberships, tournaments $tournaments',
        );
        expect(
          BackendModules.tournamentsLive(
            _supabase,
            memberships: memberships,
            tournaments: tournaments,
          ),
          expected,
        );
      }
      expect(
        BackendModules.tournamentsLive(
          memory,
          memberships: true,
          tournaments: true,
        ),
        isFalse,
      );
      expect(kTournamentsBuild, isFalse, reason: 'OFF by default');
    });
  });

  // ---------------------------------------------------------------------------
  group('flows (server)', () {
    test('create: the form is checked first, then published on the server (its id and row)', () async {
      final w = _World.create();
      final c = await w.container();
      await c.read(tournamentsProvider.future);
      final ctrl = c.read(tournamentsProvider.notifier);

      await expectLater(
        ctrl.create(const TournamentInput(name: 'X')),
        throwsArgumentError,
      );
      expect(
        w.tdb.count('create_tournament'),
        0,
        reason: 'the form check runs first',
      );

      final t = await ctrl.create(_input());
      expect(t.id, startsWith('trn-'));
      expect(
        (t.ground, t.status, t.organizerName),
        ('Gaddafi Stadium', TournamentStatus.registrationOpen, 'Lahore Lions'),
      );
      final params = w.tdb.paramsOf('create_tournament').single;
      expect(
        (params['p_club_id'], params['p_format'], params['p_tournament_type']),
        (w.clubA, 't20', 'knockout'),
      );
      expect(
        (
          params['p_start_date'],
          params['p_registration_deadline'],
          params['p_description'],
        ),
        ('2026-12-10', '2026-12-05', null),
      );
      expect(c.read(hostedTournamentsProvider).map((x) => x.id), [t.id]);
      expect(
        c.read(browseTournamentsProvider),
        isEmpty,
        reason: 'never my own',
      );

      // The server's own limits: a name over 60 characters.
      await expectLater(
        ctrl.create(_input(name: 'N' * 61)),
        throwsA(
          isA<TournamentRuleException>().having(
            (e) => e.message,
            'message',
            TournamentTexts.name,
          ),
        ),
      );
    });

    test('hub stats and browse: the server counts; other clubs only; cities from the rows', () async {
      final w = _World.create();
      w.tdb
        ..addTournament(w.clubA, 'Mine')
        ..addTournament(w.clubB, 'Karachi Cup', city: 'Karachi')
        ..addTournament(
          _World.clubC,
          'Multan Cup',
          city: 'Multan',
          startIn: 21,
        );
      final t3 = w.tdb.addTournament(
        _World.clubD,
        'Quetta Cup',
        city: 'Quetta',
        startIn: 22,
      );
      w.tdb.addEntry(t3, w.clubA, status: 'approved');
      final c = await w.container();
      await c.read(tournamentsProvider.future);
      await c.read(tournamentServerStatsProvider.future);
      final s = c.read(tournamentHubStatsProvider);
      expect(
        (s.hosted, s.open, s.registered, s.approved, s.pendingRegistrations),
        (1, 3, 1, 1, 0),
      );
      expect(c.read(browseTournamentsProvider).map((t) => t.name), [
        'Karachi Cup',
        'Multan Cup',
        'Quetta Cup',
      ]);
      expect(c.read(browseCitiesProvider), ['Karachi', 'Multan', 'Quetta']);

      final byCity = await (c.read(tournamentBackendProvider)!)
          .browse(city: ' multan ');
      expect(byCity.map((t) => t.name), ['Multan Cup']);
      expect(w.tdb.paramsOf('browse_tournaments').last, {'p_city': 'multan'});
    });

    test('a list screen reads the list again: a tournament published since appears', () async {
      final w = _World.create();
      final c = await w.container();
      await c.read(tournamentsProvider.future);
      await c.read(tournamentRegistrationsProvider.future);
      expect(c.read(browseTournamentsProvider), isEmpty);
      w.tdb.addTournament(w.clubB, 'New Cup');
      final sub = c.listen(tournamentsSyncProvider('browse'), (_, _) {});
      await c.read(tournamentsSyncProvider('browse').future);
      sub.close();
      expect(c.read(browseTournamentsProvider).map((t) => t.name), ['New Cup']);
    });

    test('registration: 11 + 4 sent in pick order; pending; listed; the server refusals say why', () async {
      final w = _World.create();
      final tid = w.tdb.addTournament(w.clubA, 'Lahore Cup');
      final c = await w.container(asB: true);
      await c.read(tournamentsProvider.future);
      await c.read(tournamentRegistrationsProvider.future);
      final regs = c.read(tournamentRegistrationsProvider.notifier);
      final draft = c.read(registrationDraftProvider(tid).notifier);

      // Too small a squad (set directly; the line-up flow wouldn't allow it).
      draft
        ..setLineup(_squad(xi: 10))
        ..setAgreed(true);
      var result = await regs.submit(tid);
      expect(
        (result.registration, result.error),
        (null, TournamentTexts.squadSize),
      );

      draft
        ..setLineup(_squad(teamId: 'team-b', captain: 'm1'))
        ..setAgreed(true);
      result = await regs.submit(tid);
      final reg = result.registration!;
      expect(
        (reg.status, reg.clubId, reg.teamName, reg.lineup?.members.length),
        (RegistrationStatus.pending, w.clubB, 'Kings XI', 15),
      );
      final sent = w.tdb.paramsOf('submit_tournament_registration').last;
      expect(
        (sent['p_team_id'], sent['p_captain_member_id'], sent['p_agree_rules']),
        ('team-b', 'm1', true),
      );
      expect(
        c.read(registrationDraftProvider(tid)).lineup,
        isNull,
        reason: 'the draft is cleared',
      );
      expect(
        c
            .read(myRegistrationsByStatusProvider(RegistrationStatus.pending))
            .map((r) => r.id),
        [reg.id],
      );
      expect(c.read(activeRegistrationProvider(tid))?.id, reg.id);
      expect(c.read(tournamentProvider(tid))?.joinedCount, 0);

      // Again: the app already knows.
      draft
        ..setLineup(_squad())
        ..setAgreed(true);
      final calls = w.tdb.count('submit_tournament_registration');
      result = await regs.submit(tid);
      expect(
        result.error,
        'Your club has already registered for this tournament',
      );
      expect(w.tdb.count('submit_tournament_registration'), calls);

      // The squad as the server keeps it.
      final keep = c.listen(registrationSquadProvider(reg.id), (_, _) {});
      final squad = await c.read(registrationSquadProvider(reg.id).future);
      keep.close();
      expect((squad?.members.length, squad?.captainId), (15, 'm1'));
    });

    test('organizer: requests oldest first; approve, fill the last slot, refused when full; reject; decided', () async {
      final w = _World.create();
      final tid = w.tdb.addTournament(w.clubA, 'Lahore Cup', maxTeams: 2);
      final r1 = w.tdb.addEntry(tid, w.clubB);
      final r2 = w.tdb.addEntry(tid, _World.clubC);
      final r3 = w.tdb.addEntry(tid, _World.clubD);
      final c = await w.container();
      await c.read(tournamentsProvider.future);
      await c.read(tournamentsProvider.notifier).refreshDetail(tid);
      expect(c.read(pendingRequestsProvider(tid)).map((r) => r.id), [
        r1,
        r2,
        r3,
      ]);
      expect(c.read(tournamentProvider(tid))!.pendingCount, 3);

      final regs = c.read(tournamentRegistrationsProvider.notifier);
      expect(
        await regs.decide(r1, approve: true),
        RegistrationDecision.approved,
      );
      expect(
        await regs.decide(r2, approve: true),
        RegistrationDecision.approved,
      );
      final full = c.read(tournamentProvider(tid))!;
      expect(full.status, TournamentStatus.registrationFull);
      expect(full.joined.map((e) => e.displayName), [
        'Karachi Kings',
        'Multan Sultans',
      ]);
      expect(
        await regs.decide(r3, approve: true),
        RegistrationDecision.full,
        reason: 'the server refused',
      );
      expect(
        await regs.decide(r3, approve: false),
        RegistrationDecision.rejected,
      );
      expect(
        await regs.decide(r1, approve: false),
        RegistrationDecision.notPending,
      );
      expect(c.read(pendingRequestsProvider(tid)), isEmpty);
      expect(
        w.tdb
            .paramsOf('decide_tournament_registration')
            .map((p) => (p['p_registration_id'], p['p_approve'])),
        [(r1, true), (r2, true), (r3, true), (r3, false)],
      );
    });

    test('remove: a confirmed team becomes "removed" (Rejected) and a full tournament opens again', () async {
      final w = _World.create();
      final tid = w.tdb.addTournament(
        w.clubA,
        'Lahore Cup',
        maxTeams: 2,
        status: 'registration_full',
      );
      final r1 = w.tdb.addEntry(tid, w.clubB, status: 'approved');
      w.tdb.addEntry(tid, _World.clubC, status: 'approved');
      final c = await w.container();
      await c.read(tournamentsProvider.future);
      await c.read(tournamentsProvider.notifier).refreshDetail(tid);
      expect(
        await c.read(tournamentsProvider.notifier).removeTeam(tid, r1),
        isTrue,
      );
      final t = c.read(tournamentProvider(tid))!;
      expect(
        (t.status, t.joinedCount, t.joined.map((e) => e.id).contains(r1)),
        (TournamentStatus.registrationOpen, 1, false),
      );
      final removed = c.read(registrationProvider(r1))!;
      expect(
        (removed.status, removed.removed),
        (RegistrationStatus.rejected, true),
      );

      // As the removed club: shown under Rejected.
      final cb = await w.container(asB: true);
      await cb.read(tournamentRegistrationsProvider.future);
      final mine = cb
          .read(myRegistrationsByStatusProvider(RegistrationStatus.rejected))
          .single;
      expect((mine.id, mine.removed), (r1, true));
      expect(
        cb.read(activeRegistrationProvider(tid)),
        isNull,
        reason: 'it may enter again',
      );
    });

    test('the draw: made on the server, read back by round; requests waiting rejected; the table and awards', () async {
      final w = _World.create();
      final tid = w.tdb.addTournament(w.clubA, 'Lahore Cup', maxTeams: 8);
      final reg = [
        for (final club in [w.clubB, _World.clubC, _World.clubD, 'club-e'])
          w.tdb.addEntry(tid, club, status: 'approved'),
      ];
      final waiting = w.tdb.addEntry(tid, 'club-f');
      final c = await w.container();
      await c.read(tournamentsProvider.future);
      await c.read(tournamentsProvider.notifier).refreshDetail(tid);
      expect(
        c.read(tournamentAwardsProvider(tid)),
        isNull,
        reason: 'no official scorecard: never invented',
      );
      await c.read(tournamentServerAwardsProvider(tid).future);
      expect(c.read(tournamentAwardsProvider(tid)), isNull);

      final ctrl = c.read(tournamentsProvider.notifier);
      expect(await ctrl.generateFixtures(tid), FixturesOutcome.generated);
      final t = c.read(tournamentProvider(tid))!;
      expect([for (final r in t.fixtures!) r.name], ['Semifinal', 'Final']);
      expect(
        (t.status, t.hasFixtures, t.acceptsRegistrationsAt(_now)),
        (TournamentStatus.registrationClosed, true, false),
      );
      final first = t.fixtures!.first.matches.first;
      expect(
        (first.home, first.away),
        (reg[0], reg[1]),
        reason: 'seeded in approval order',
      );
      expect(entrantLabel(t, first.home), 'Karachi Kings');
      expect(
        c.read(registrationProvider(waiting))!.status,
        RegistrationStatus.rejected,
      );
      expect([for (final e in standingsTable(t)) e.$2.points], [0, 0, 0, 0]);

      // Already made: no second call.
      final calls = w.tdb.count('generate_tournament_fixtures');
      expect(
        await ctrl.generateFixtures(tid),
        FixturesOutcome.alreadyGenerated,
      );
      expect(w.tdb.count('generate_tournament_fixtures'), calls);
      expect(
        await ctrl.removeTeam(tid, reg[0]),
        isFalse,
        reason: 'teams are locked',
      );
      expect(
        await ctrl.recordResult(tid, 0, 0, reg[0]),
        isNull,
        reason: 'results are read-only',
      );

      // The trusted scorer records a result and an official scorecard.
      w.tdb.fixtureRows[tid]!.first['winner_registration_id'] = reg[1];
      w.tdb.awardRows[tid] = [
        {
          'award': 'top_run_scorer',
          'registration_id': reg[1],
          'club_id': _World.clubC,
          'club_name': 'Multan Sultans',
          'member_id': 'm9',
          'player_name': 'Rizwan',
          'value': 74,
          'matches_counted': 1,
        },
      ];
      await ctrl.refreshDetail(tid);
      final after = c.read(tournamentProvider(tid))!;
      expect(standingsTable(after).first.$1.displayName, 'Multan Sultans');
      expect(standingsTable(after).first.$2.points, 2);
      final awards = await c.read(tournamentServerAwardsProvider(tid).future);
      expect(
        (awards!.topScorer!.playerName, awards.topWicketTaker),
        ('Rizwan', null),
      );
      expect(c.read(tournamentAwardsProvider(tid))?.topScorer?.value, 74);
    });

    test('the draw needs two confirmed teams (asked first); awards for a club taking no part are not shown', () async {
      final w = _World.create();
      final tid = w.tdb.addTournament(w.clubA, 'Lahore Cup');
      w.tdb.addEntry(tid, w.clubB, status: 'approved');
      final c = await w.container();
      await c.read(tournamentsProvider.future);
      await c.read(tournamentsProvider.notifier).refreshDetail(tid);
      expect(
        await c.read(tournamentsProvider.notifier).generateFixtures(tid),
        FixturesOutcome.notEnoughTeams,
      );
      expect(w.tdb.count('generate_tournament_fixtures'), 0);

      final other = w.tdb.addTournament(_World.clubC, 'Multan Cup');
      w.tdb.awardRows[other] = [
        {
          'award': 'top_run_scorer',
          'registration_id': 'x',
          'player_name': 'Y',
          'value': 9,
          'matches_counted': 1,
        },
      ];
      expect(
        await c.read(tournamentServerAwardsProvider(other).future),
        isNull,
        reason: '42501 not allowed',
      );
    });

    test('Select Existing Team: exactly 11 + 4 available, the captain and vice-captain go with it', () async {
      final w = _World.create();
      final tid = w.tdb.addTournament(w.clubA, 'Lahore Cup');
      final pool = [
        for (var i = 1; i <= 16; i++)
          SquadPlayer(
            id: 'm$i',
            name: 'Player $i',
            position: 'Batsman',
            availability: i == 16
                ? PlayerAvailability.injured
                : PlayerAvailability.available,
          ),
      ];
      final c = await w.container(
        asB: true,
        extra: [clubPlayerPoolProvider.overrideWith((ref) async => pool)],
      );
      final ctrl = c.read(
        lineupDraftProvider(TournamentEntryTarget(tid)).notifier,
      );
      Team team(
        List<String> xi,
        List<String> subs, {
        String? captain,
        String? vice,
      }) => Team(
        id: 'team-b',
        clubId: w.clubB,
        name: 'Kings XI',
        format: MatchFormat.t20,
        createdAt: _today,
        captainId: captain,
        viceCaptainId: vice,
        members: [
          for (final id in xi)
            TeamMember(playerId: id, selection: SelectionRole.playing),
          for (final id in subs)
            TeamMember(playerId: id, selection: SelectionRole.sub),
        ],
      );
      final xi = [for (var i = 1; i <= 11; i++) 'm$i'];
      await expectLater(
        ctrl.useTeam(
          team([...xi.take(10), 'm16'], ['m12', 'm13', 'm14', 'm15']),
        ),
        throwsA(
          isA<TournamentRuleException>().having(
            (e) => e.message,
            'message',
            contains(
              '10 + 4 available players (1 injured or unavailable left out)',
            ),
          ),
        ),
      );
      expect(c.read(registrationDraftProvider(tid)).lineup, isNull);

      expect(
        await ctrl.useTeam(
          team(xi, ['m12', 'm13', 'm14', 'm15'], captain: 'm1', vice: 'm12'),
        ),
        0,
      );
      final lineup = c.read(registrationDraftProvider(tid)).lineup!;
      expect(
        (
          lineup.sourceTeamId,
          lineup.captainId,
          lineup.viceCaptainId,
          lineup.members.length,
        ),
        ('team-b', 'm1', null, 15),
        reason: 'a substitute is never vice-captain',
      );
    });

    test('demo controls never act on the server: no organizer simulator, no simulated result', () async {
      final w = _World.create();
      final tid = w.tdb.addTournament(w.clubB, 'Karachi Cup');
      final reg = w.tdb.addEntry(tid, w.clubA);
      final c = await w.container(demo: true);
      expect(c.read(demoModeProvider), isTrue);
      await c.read(tournamentsProvider.future);
      await c.read(tournamentRegistrationsProvider.future);
      final calls = w.tdb.calls.length;
      expect(
        await c
            .read(tournamentDemoActionsProvider)
            .organizerDecides(reg, approve: true),
        isNull,
      );
      expect(
        await c
            .read(tournamentDemoActionsProvider)
            .simulateResult(
              tid,
              const FixtureRef(
                roundIdx: 0,
                matchIdx: 0,
                roundName: 'Final',
                match: FixtureMatch(home: 'a', away: 'b'),
              ),
            ),
        isNull,
      );
      expect(
        await c
            .read(tournamentRegistrationsProvider.notifier)
            .receive(tid, clubId: _World.clubC, teamName: 'X'),
        isNull,
      );
      expect(w.tdb.calls.length, calls);
    });
  });

  // ---------------------------------------------------------------------------
  group('screens (tournaments on)', () {
    Future<_World> pump(
      WidgetTester tester,
      String location, {
      bool asB = false,
      bool demo = false,
      void Function(_World w)? before,
    }) async {
      tester.view.physicalSize = const Size(1000, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final w = _World.create();
      before?.call(w);
      final overrides = await w.overrides(asB: asB, demo: demo);
      String tid(GoRouterState s) => s.pathParameters['tid']!;
      String rid(GoRouterState s) => s.pathParameters['rid']!;
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: '/club/tournaments/hosted/:tid',
            builder: (_, s) => TournamentDetailsScreen(
              tournamentId: tid(s),
              tab: TournamentTab.parse(s.uri.queryParameters['tab']),
            ),
          ),
          GoRoute(
            path: '/club/tournaments/hosted/:tid/teams/requests/:rid',
            builder: (_, s) => TeamRequestDetailScreen(
              tournamentId: tid(s),
              registrationId: rid(s),
            ),
          ),
          GoRoute(
            path: Routes.browseTournaments,
            builder: (_, s) =>
                BrowseTournamentsScreen(city: s.uri.queryParameters['city']),
          ),
          GoRoute(
            path: '/club/tournaments/browse/:tid',
            builder: (_, s) => TournamentRegisterScreen(tournamentId: tid(s)),
          ),
          GoRoute(
            path: '/club/tournaments/browse/:tid/team/summary',
            builder: (_, s) => RegistrationSummaryScreen(tournamentId: tid(s)),
          ),
          GoRoute(
            path: Routes.myRegistrations,
            builder: (_, s) => MyRegistrationsScreen(
              tab: MyRegistrationsScreen.parseTab(s.uri.queryParameters['tab']),
            ),
          ),
          GoRoute(
            path: '/club/tournaments/registrations/:rid',
            builder: (_, s) =>
                RegistrationDetailsScreen(registrationId: rid(s)),
          ),
          GoRoute(
            path: '/club/tournaments/registrations/:rid/success',
            builder: (_, s) =>
                RegistrationSuccessScreen(registrationId: rid(s)),
          ),
          GoRoute(
            path: Routes.tournamentHub,
            builder: (_, _) => const Scaffold(body: Text('hub')),
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
          child: MaterialApp.router(
            theme: AppTheme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return w;
    }

    late String tid;
    late String request;

    testWidgets(
      'host workspace: the server counts, the awards empty state, a request accepted',
      (tester) async {
        final w = await pump(
          tester,
          '/club/tournaments/hosted/trn-1',
          before: (w) {
            tid = w.tdb.addTournament(w.clubA, 'Lahore Cup', maxTeams: 4);
            w.tdb
              ..addEntry(tid, w.clubB, status: 'approved')
              ..addEntry(tid, _World.clubC, status: 'approved');
            request = w.tdb.addEntry(tid, _World.clubD);
          },
        );
        expect(find.text('Lahore Cup'), findsWidgets);
        expect(find.text('Manage Teams (1 pending)'), findsOneWidget);
        expect(
          find.text('Awards will appear once results are official'),
          findsOneWidget,
        );
        expect(
          find.text('Awards will appear once teams are registered'),
          findsNothing,
        );
        expect(find.text('2/4'), findsWidgets);
        expect(w.tdb.count('tournament_teams'), greaterThan(0));

        await tester.tap(find.text('Manage Teams (1 pending)'));
        await tester.pumpAndSettle();
        expect(find.text('Clubs Requesting Registration · 1'), findsOneWidget);
        expect(
          find.text('Quetta Gladiators'),
          findsOneWidget,
          reason: 'the club name from the server',
        );
        expect(find.text('Confirmed Teams · 2'), findsOneWidget);

        await tester.tap(find.text('Quetta Gladiators'));
        await tester.pumpAndSettle();
        expect(find.text('Registration Request'), findsOneWidget);
        await tester.tap(find.text('Accept'));
        await tester.pumpAndSettle();
        expect(find.text('Quetta Gladiators accepted'), findsOneWidget);
        expect(w.tdb.paramsOf('decide_tournament_registration').single, {
          'p_registration_id': request,
          'p_approve': true,
        });
        expect(find.text('Confirmed Teams · 3'), findsOneWidget);
      },
    );

    testWidgets(
      'fixtures: generated on the server, by round; no result simulator even with demo controls',
      (tester) async {
        final w = await pump(
          tester,
          '/club/tournaments/hosted/trn-1?tab=fixtures',
          demo: true,
          before: (w) {
            tid = w.tdb.addTournament(
              w.clubA,
              'Lahore Cup',
              type: 'league',
              maxTeams: 4,
            );
            for (final club in [w.clubB, _World.clubC, _World.clubD]) {
              w.tdb.addEntry(tid, club, status: 'approved');
            }
          },
        );
        expect(find.text('Ready to generate'), findsOneWidget);
        await tester.tap(find.text('Generate Fixtures'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Generate Fixtures').last);
        await tester.pumpAndSettle();
        expect(w.tdb.count('generate_tournament_fixtures'), 1);
        expect(find.text('League Stage'), findsOneWidget);
        expect(find.text('Karachi Kings vs Multan Sultans'), findsOneWidget);
        expect(find.text('Tap to simulate result'), findsNothing);
      },
    );

    testWidgets('browse by city: another club\'s tournament, Register Team', (
      tester,
    ) async {
      await pump(
        tester,
        Routes.browseTournamentsIn('Lahore'),
        asB: true,
        before: (w) {
          tid = w.tdb.addTournament(w.clubA, 'Lahore Cup');
          w.tdb.addEntry(tid, _World.clubC, status: 'approved');
        },
      );
      expect(find.text('Open Tournaments in Lahore · 1'), findsOneWidget);
      expect(find.text('Lahore Cup'), findsOneWidget);
      expect(find.text('1 / 8 Teams'), findsOneWidget);
      expect(
        find.text('Lahore Lions · Lahore'),
        findsOneWidget,
        reason: 'the organizer name from the server',
      );
      expect(find.text('Register Team'), findsOneWidget);
    });

    testWidgets(
      'registration summary → submit → success; the server error is shown when refused',
      (tester) async {
        final w = await pump(
          tester,
          '/club/tournaments/browse/trn-1/team/summary',
          asB: true,
          before: (w) => tid = w.tdb.addTournament(w.clubA, 'Lahore Cup'),
        );
        expect(find.text('Pick your team first'), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(RegistrationSummaryScreen)),
        );
        container
            .read(registrationDraftProvider(tid).notifier)
            .setLineup(_squad(xi: 10));
        await tester.pumpAndSettle();
        await tester.tap(find.text('I agree to the tournament rules.'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Submit Registration'));
        await tester.pumpAndSettle();
        expect(find.text(TournamentTexts.squadSize), findsOneWidget);

        container.read(registrationDraftProvider(tid).notifier)
          ..setLineup(_squad())
          ..setAgreed(true);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Submit Registration'));
        await tester.pumpAndSettle();
        await _settled(
          () => find
              .text('Registration Submitted Successfully!')
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Registration Submitted Successfully!'),
          findsOneWidget,
        );
        expect(w.tdb.count('submit_tournament_registration'), 2);
      },
    );

    testWidgets(
      'a removed team: under Rejected, says it was removed; no organizer simulator',
      (tester) async {
        await pump(
          tester,
          '/club/tournaments/registrations/reg-2',
          asB: true,
          demo: true,
          before: (w) {
            tid = w.tdb.addTournament(w.clubA, 'Lahore Cup');
            request = w.tdb.addEntry(tid, w.clubB, status: 'removed');
            expect(request, 'reg-2');
          },
        );
        expect(find.text('Registration Rejected'), findsOneWidget);
        expect(
          find.textContaining(
            'The organizer removed your team from this tournament.',
          ),
          findsOneWidget,
        );
        expect(find.text('Simulate Organizer Decision'), findsNothing);
      },
    );
  });
}
