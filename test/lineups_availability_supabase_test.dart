// M1 P6: line-ups on server matches (migration 18) and player availability
// (migration 19) through the real controllers and repositories, on fakes
// (FakeMatchDb for the match functions, FakeMembershipDb for the squad pool,
// sharing member ids). No network, no database. The demo's line-up and
// availability flows keep their own tests (lineup_test.dart,
// player_core_test.dart).
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/features/matches/lineup_controller.dart';
import 'package:criceco/features/matches/screens/match_management_screen.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'match_fakes.dart';
import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// 2026-11-20 11:00 in Pakistan. The match is on the 23rd.
final _now = DateTime.utc(2026, 11, 20, 6);
const _start = '2026-11-23T05:00:00.000Z';

class _World {
  _World._(
    this.db,
    this.auth,
    this.clubDb,
    this.members,
    this.mdb,
    this.ownerA,
    this.clubA,
    this.clubB,
  );

  final FakeDb db;
  final FakeAuth auth;
  final FakeClubDb clubDb;
  final FakeMembershipDb members;
  final FakeMatchDb mdb;
  final AuthUser ownerA;
  final String clubA, clubB;

  /// Player users and their member ids in club A, in pick order.
  final players = <({AuthUser user, String member})>[];

  static _World create({int players = 17}) {
    final db = FakeDb();
    final auth = FakeAuth(db);
    final clubDb = FakeClubDb(db);
    final members = FakeMembershipDb(db, clubDb);
    final mdb = FakeMatchDb(auth, clubDb)..now = _now;
    final a = auth.addUser('a@example.com', 'Cricket@123');
    final b = auth.addUser('b@example.com', 'Cricket@123');
    final w = _World._(
      db,
      auth,
      clubDb,
      members,
      mdb,
      a,
      mdb.addClub(a.id, 'Lahore Lions'),
      mdb.addClub(b.id, 'Karachi Kings', city: 'Karachi'),
    );
    for (var i = 1; i <= players; i++) {
      w.addPlayer('Player ${i.toString().padLeft(2, '0')}');
    }
    auth.current = a;
    return w;
  }

  /// A playing member of club A, known to both fakes under one member id.
  ({AuthUser user, String member}) addPlayer(String name) {
    final u = auth.addUser(
      '${name.toLowerCase().replaceAll(' ', '')}@example.com',
      'Cricket@123',
    );
    db.profiles[u.id] = {...?db.profiles[u.id], 'full_name': name};
    db.players[u.id] = {
      'user_id': u.id,
      'player_role': 'all_rounder',
      'batting_style': 'right_handed',
      'bowling_style': 'right_arm_fast',
      'is_wicketkeeper': false,
    };
    final id = mdb.addMember(clubA, u.id, name);
    members.members.add({
      'id': id,
      'club_id': clubA,
      'user_id': u.id,
      'member_role': 'player',
      'status': 'active',
      'joined_at': _now.toIso8601String(),
    });
    final p = (user: u, member: id);
    players.add(p);
    return p;
  }

  /// A confirmed match A (challenged) vs B on the 23rd.
  String confirmedMatch({String startsAt = _start}) {
    final id = 'match-${mdb.matches.length + 1}';
    mdb.matches.add({
      'id': id,
      'challenge_id': null,
      'club_a_id': clubB,
      'club_b_id': clubA,
      'format': 't20',
      'custom_overs': null,
      'status': 'confirmed',
      'starts_at': startsAt,
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
    return id;
  }

  /// [who] sets their availability (directly in the fake, as they would).
  void setAvailability(AuthUser who, String status, {String? until}) {
    mdb.availability[who.id] = {
      'user_id': who.id,
      'status': status,
      'reason': null,
      'until_date': until,
      'notes': null,
      'updated_at': _now.toIso8601String(),
    };
  }

  Future<List<Override>> overrides({AuthUser? as}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final signedIn = as ?? ownerA;
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(_supabase),
      membershipsEnabledProvider.overrideWithValue(true),
      matchesEnabledProvider.overrideWithValue(true),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      authGatewayProvider.overrideWithValue(auth),
      profileGatewayProvider.overrideWithValue(db),
      clubGatewayProvider.overrideWithValue(clubDb),
      membershipGatewayProvider.overrideWithValue(members),
      matchGatewayProvider.overrideWithValue(mdb),
      currentAccountProvider.overrideWithValue(null),
      currentClubProvider.overrideWithValue(
        signedIn == ownerA
            ? Club(
                id: clubA,
                name: 'Lahore Lions',
                city: 'Lahore',
                type: ClubType.corporate,
                code: 'ABC001',
              )
            : null,
      ),
    ];
  }

  Future<ProviderContainer> container({AuthUser? as}) async {
    auth.current = as ?? ownerA;
    final c = ProviderContainer(overrides: await overrides(as: as));
    addTearDown(c.dispose);
    return c;
  }

  int calls(String fn) => mdb.calls.where((x) => x.fn == fn).length;

  /// The first 15 players: 11 playing + 4 subs, in pick order.
  List<TeamMember> squad({int from = 0}) => [
    for (var i = from; i < from + 15; i++)
      TeamMember(
        playerId: players[i].member,
        selection: i - from < 11 ? SelectionRole.playing : SelectionRole.sub,
      ),
  ];

  Team team({int from = 0, String? captain, String? vice}) => Team(
    id: 'team-1',
    clubId: clubA,
    name: 'Lions XI',
    format: MatchFormat.t20,
    createdAt: _now,
    captainId: captain,
    viceCaptainId: vice,
    members: squad(from: from),
  );
}

void main() {
  group('line-ups on server matches', () {
    test(
      'a confirmed match carries its saved line-up (own club only)',
      () async {
        final w = _World.create();
        final id = w.confirmedMatch();
        w.mdb.lineups.add({
          'match_id': id,
          'club_id': w.clubA,
          'name': 'Lions XI',
          'source_team_id': null,
          'captain_member_id': null,
          'vice_captain_member_id': null,
          'saved_at': _now.toIso8601String(),
          'saved_by': w.ownerA.id,
        });
        for (final (i, m) in w.squad().indexed) {
          w.mdb.lineupPlayers.add({
            'match_id': id,
            'club_id': w.clubA,
            'member_id': m.playerId,
            'selection': m.selection == SelectionRole.playing
                ? 'playing'
                : 'sub',
            'position': i + 1,
          });
        }
        final c = await w.container();
        final m = (await c.read(clubMatchesProvider.future)).single;
        expect(m.lineup!.name, 'Lions XI');
        expect(
          m.lineup!.members.map((x) => x.playerId),
          w.squad().map((x) => x.playerId),
        );
        expect(w.calls('match_lineup'), 1);
        expect(c.read(lineupEditableProvider(id)), isTrue);
      },
    );

    test('build a line-up: 11 + 4 saved on the server in pick order; the match shows it', () async {
      final w = _World.create();
      final id = w.confirmedMatch();
      final c = await w.container();
      await c.read(clubMatchesProvider.future);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final draft = c.read(lineupDraftProvider(MatchLineupTarget(id)).notifier)
        ..startNew();
      for (final p in pool.take(15)) {
        draft.cycle(p); // → playing (the first 11), then → sub
      }
      expect(
        c.read(lineupDraftProvider(MatchLineupTarget(id))).isComplete,
        isTrue,
      );
      expect(await draft.confirmBuilt(), isNull);
      final params = w.mdb.calls
          .singleWhere((x) => x.fn == 'save_match_lineup')
          .params;
      expect((params['p_players'] as List).length, 15);
      expect((params['p_players'] as List).first, {
        'member_id': pool.first.id,
        'selection': 'playing',
      });
      expect(params['p_name'], Lineup.newMatchDaySquadName);
      expect(c.read(clubMatchProvider(id))!.lineup!.members, hasLength(15));
      expect(w.calls('save_match_lineup'), 1);
    });

    test('the server refuses a player unavailable on the match day: the reason, picks kept', () async {
      final w = _World.create();
      final id = w.confirmedMatch();
      final c = await w.container();
      await c.read(clubMatchesProvider.future);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final draft = c.read(lineupDraftProvider(MatchLineupTarget(id)).notifier)
        ..startNew();
      for (final p in pool.take(15)) {
        draft.cycle(p);
      }
      // Marked unavailable after the pool was read (another device).
      w.setAvailability(w.players[2].user, 'unavailable');
      expect(
        await draft.confirmBuilt(),
        contains('injured or unavailable on the match day'),
      );
      expect(c.read(lineupDraftProvider(MatchLineupTarget(id))).dirty, isTrue);
      expect(c.read(clubMatchProvider(id))!.lineup, isNull);
    });

    test(
      'use a team: a complete 11 + 4 with its captain and vice-captain',
      () async {
        final w = _World.create();
        final id = w.confirmedMatch();
        final c = await w.container();
        await c.read(clubMatchesProvider.future);
        final t = w.team(
          captain: w.players[0].member,
          vice: w.players[1].member,
        );
        expect(
          await c
              .read(lineupDraftProvider(MatchLineupTarget(id)).notifier)
              .useTeam(t),
          0,
        );
        final params = w.mdb.calls
            .singleWhere((x) => x.fn == 'save_match_lineup')
            .params;
        expect(params['p_source_team_id'], 'team-1');
        expect(params['p_captain_member_id'], w.players[0].member);
        expect(params['p_vice_member_id'], w.players[1].member);
        expect(c.read(clubMatchProvider(id))!.lineup!.sourceTeamId, 'team-1');
      },
    );

    test(
      'use a team with an injured player: refused readably, nothing saved',
      () async {
        final w = _World.create();
        final id = w.confirmedMatch();
        w.setAvailability(w.players[3].user, 'injured');
        final c = await w.container();
        await c.read(clubMatchesProvider.future);
        await expectLater(
          c
              .read(lineupDraftProvider(MatchLineupTarget(id)).notifier)
              .useTeam(w.team()),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('10 + 4'),
                contains('1 injured or unavailable left out'),
              ),
            ),
          ),
        );
        expect(w.calls('save_match_lineup'), 0);
      },
    );

    test('a pending match or one that has started: line-ups closed', () async {
      final w = _World.create();
      final started = w.confirmedMatch(startsAt: '2026-11-20T05:00:00.000Z');
      final c = await w.container();
      await c.read(clubMatchesProvider.future);
      expect(c.read(lineupEditableProvider(started)), isFalse);
    });
  });

  group('availability in the squad pool (owner)', () {
    test('injured / unavailable today are locked; an injury that ended, or limited, is not', () async {
      final w = _World.create();
      w.setAvailability(w.players[0].user, 'injured');
      w.setAvailability(w.players[1].user, 'unavailable', until: '2026-11-25');
      w.setAvailability(
        w.players[2].user,
        'injured',
        until: '2026-11-19',
      ); // ended yesterday
      w.setAvailability(w.players[3].user, 'limited');
      final c = await w.container();
      final pool = {
        for (final p in await c.read(clubPlayerPoolProvider.future)) p.id: p,
      };
      expect(pool[w.players[0].member]!.locked, isTrue);
      expect(
        pool[w.players[1].member]!.availability,
        PlayerAvailability.unavailable,
      );
      expect(
        pool[w.players[2].member]!.availability,
        PlayerAvailability.available,
      );
      expect(
        pool[w.players[3].member]!.availability,
        PlayerAvailability.limited,
      );
      expect(pool[w.players[3].member]!.locked, isFalse);
      expect(
        pool[w.players[4].member]!.availability,
        PlayerAvailability.available,
        reason: 'no record',
      );
      expect(w.calls('club_player_availability'), 1);
    });

    test('availability not readable: the pool still loads (the server checks on save)', () async {
      final w = _World.create();
      w.setAvailability(w.players[0].user, 'injured');
      w.mdb.failOn['club_player_availability'] =
          const GatewayNetworkException();
      final c = await w.container();
      final pool = await c.read(clubPlayerPoolProvider.future);
      expect(pool, hasLength(17));
      expect(pool.every((p) => !p.locked), isTrue);
    });
  });

  group('player availability on the server', () {
    test('the saved record is read at start', () async {
      final w = _World.create();
      final me = w.players.first.user;
      w.setAvailability(me, 'injured', until: '2026-11-30');
      final c = await w.container(as: me);
      c.read(playerAvailabilityProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final r = c.read(playerAvailabilityProvider);
      expect(r.status, PlayerAvailability.injured);
      expect(r.untilDate, DateTime(2026, 11, 30));
      expect(w.calls('my_availability'), 1);
    });

    test(
      'update: saved for the signed-in player only, shown once stored',
      () async {
        final w = _World.create();
        final me = w.players.first.user;
        final c = await w.container(as: me);
        final ctrl = c.read(playerAvailabilityProvider.notifier);
        final error = await ctrl.update(
          status: PlayerAvailability.unavailable,
          reason: AvailabilityReason.travel,
          until: AvailabilityUntil.weekend,
          untilDate: DateTime(2026, 11, 22),
          notes: ' Away ',
        );
        expect(error, isNull);
        expect(
          w.mdb.calls.lastWhere((x) => x.fn == 'set_my_availability').params,
          {
            'p_status': 'unavailable',
            'p_reason': 'travel',
            'p_until_date': '2026-11-22',
            'p_notes': 'Away',
          },
        );
        expect(w.mdb.availability[me.id]!['status'], 'unavailable');
        final r = c.read(playerAvailabilityProvider);
        expect(r.status, PlayerAvailability.unavailable);
        expect(
          r.until,
          AvailabilityUntil.weekend,
          reason: 'the shortcut kept on this device',
        );
        expect(await ctrl.toggleQuick(), isNull);
        expect(
          c.read(playerAvailabilityProvider).status,
          PlayerAvailability.available,
        );
        expect(w.mdb.availability[me.id]!['reason'], isNull);
      },
    );

    test('a refusal: the reason comes back and the record stays', () async {
      final w = _World.create();
      final me = w.players.first.user;
      final c = await w.container(as: me);
      final ctrl = c.read(playerAvailabilityProvider.notifier);
      final error = await ctrl.update(
        status: PlayerAvailability.limited,
        notes: 'n' * 201,
      );
      expect(error, contains('200'));
      expect(
        c.read(playerAvailabilityProvider).status,
        PlayerAvailability.available,
      );
      w.mdb.failNext = const GatewayNetworkException();
      expect(await ctrl.update(status: PlayerAvailability.injured), isNotNull);
      expect(
        c.read(playerAvailabilityProvider).status,
        PlayerAvailability.available,
      );
    });

    test('a second save while one is on its way does nothing', () async {
      final w = _World.create();
      final me = w.players.first.user;
      final c = await w.container(as: me);
      final ctrl = c.read(playerAvailabilityProvider.notifier);
      final first = ctrl.update(status: PlayerAvailability.injured);
      expect(await ctrl.update(status: PlayerAvailability.limited), isNull);
      await first;
      expect(w.calls('set_my_availability'), 1);
      expect(
        c.read(playerAvailabilityProvider).status,
        PlayerAvailability.injured,
      );
    });

    test('the demo keeps saving at once, in memory', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ctrl = c.read(playerAvailabilityProvider.notifier);
      final saving = ctrl.update(status: PlayerAvailability.injured);
      expect(
        c.read(playerAvailabilityProvider).status,
        PlayerAvailability.injured,
        reason: 'set before any await',
      );
      expect(await saving, isNull);
    });
  });

  group('Match Management line-up entry (server)', () {
    testWidgets('a confirmed match: "Line-up needed" → the line-up sheet', (
      tester,
    ) async {
      final w = _World.create();
      final id = w.confirmedMatch();
      final overrides = await w.overrides();
      final router = GoRouter(
        initialLocation: Routes.matchManagement(MatchTab.scheduled),
        routes: [
          GoRoute(
            path: Routes.matchManagementPath,
            builder: (_, s) => MatchManagementScreen(
              tab: MatchManagementScreen.parseTab(s.uri.queryParameters['tab']),
            ),
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
      expect(find.text('vs Karachi Kings'), findsOneWidget);
      expect(find.text('Line-up needed'), findsOneWidget);
      expect(find.text('Select Your Playing XI'), findsOneWidget);
      await tester.tap(find.byKey(Key('match.lineup.$id')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lineupSheet.select')), findsOneWidget);
    });
  });
}
