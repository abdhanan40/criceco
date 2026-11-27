// M7 (migration 32, the CRICECO_DISCOVERY switch): club directory and public
// profiles, availability slots, the shared player rankings, applicant
// statistics and the club dashboard's official record — through the real
// repositories, controllers and screens on FakeDiscoveryDb. No network, no
// database. Switch OFF: today's behaviour, no call made.
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/discovery_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/challenges/challenges_controller.dart';
import 'package:criceco/features/challenges/screens/challenges_hub_screen.dart';
import 'package:criceco/features/challenges/screens/club_profile_screen.dart';
import 'package:criceco/features/challenges/screens/create_slot_screen.dart';
import 'package:criceco/features/challenges/widgets/challenge_widgets.dart'
    show ChallengesSection;
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/requests/join_requests_controller.dart';
import 'package:criceco/features/club/screens/club_dashboard_screen.dart'
    show ownClubRecordProvider;
import 'package:criceco/features/rankings/rankings_providers.dart';
import 'package:criceco/shared/widgets/ce_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'discovery_hunt_fakes.dart';
import 'match_fakes.dart';
import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// 2026-11-20 11:00 in Pakistan: "tomorrow" is the 21st.
final _now = DateTime.utc(2026, 11, 20, 6);

class _World {
  _World._(
    this.auth,
    this.clubDb,
    this.mdb,
    this.ddb,
    this.ownerA,
    this.ownerB,
    this.clubA,
    this.clubB,
  );

  final FakeAuth auth;
  final FakeClubDb clubDb;
  final FakeMatchDb mdb;
  final FakeDiscoveryDb ddb;
  final AuthUser ownerA, ownerB;
  final String clubA, clubB;

  static _World create() {
    final db = FakeDb();
    final auth = FakeAuth(db);
    final clubDb = FakeClubDb(db);
    final mdb = FakeMatchDb(auth, clubDb);
    final a = auth.addUser('a@example.com', 'Cricket@123');
    final b = auth.addUser('b@example.com', 'Cricket@123');
    final clubA = mdb.addClub(a.id, 'Lahore Lions', shortName: 'LL');
    final clubB = mdb.addClub(
      b.id,
      'Karachi Kings',
      city: 'Karachi',
      shortName: 'KK',
    );
    final ddb = FakeDiscoveryDb(auth, owners: {clubA: a.id, clubB: b.id});
    ddb.clubs[clubA] = publicClubRow(
      clubA,
      'Lahore Lions',
      shortName: 'LL',
      played: 6,
      won: 4,
      lost: 1,
      tied: 1,
    );
    ddb.clubs[clubB] = publicClubRow(
      clubB,
      'Karachi Kings',
      city: 'Karachi',
      shortName: 'KK',
      established: 2019,
      members: 18,
      played: 4,
      won: 3,
      lost: 1,
      form: ['won', 'lost', 'won', 'won'],
      formats: ['t20', 'odi'],
    );
    auth.current = a;
    return _World._(auth, clubDb, mdb, ddb, a, b, clubA, clubB);
  }

  Club get ownClub => Club(
    id: clubA,
    name: 'Lahore Lions',
    city: 'Lahore',
    type: ClubType.corporate,
    code: 'ABC001',
  );

  UserAccount get account => UserAccount(
    id: ownerA.id,
    fullName: 'Ali Raza',
    contactMethod: ContactMethod.email,
  );

  Future<List<Override>> overrides({bool discovery = true}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(_supabase),
      membershipsEnabledProvider.overrideWithValue(true),
      matchesEnabledProvider.overrideWithValue(true),
      discoveryEnabledProvider.overrideWithValue(discovery),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      authGatewayProvider.overrideWithValue(auth),
      clubGatewayProvider.overrideWithValue(clubDb),
      membershipGatewayProvider.overrideWithValue(
        FakeMembershipDb(clubDb.db, clubDb),
      ),
      matchGatewayProvider.overrideWithValue(mdb),
      discoveryGatewayProvider.overrideWithValue(ddb),
      currentAccountProvider.overrideWithValue(account),
      currentClubProvider.overrideWithValue(ownClub),
    ];
  }

  Future<ProviderContainer> container({bool discovery = true}) async {
    final c = ProviderContainer(
      overrides: await overrides(discovery: discovery),
    );
    addTearDown(c.dispose);
    return c;
  }
}

Future<Object?> _errorOf(Future<Object?> f) =>
    f.then<Object?>((_) => null, onError: (Object e) => e);

AvailabilitySlot _slot(
  DateTime date, {
  TimeSlot slot = const TimeSlot(startHour: 14, endHour: 16),
  String notes = '',
}) => AvailabilitySlot(
  id: 'tmp',
  format: MatchFormat.t20,
  city: ' Lahore ',
  date: date,
  slot: slot,
  notes: notes,
);

void main() {
  group('switches', () {
    test('Player Hunt is a module only with memberships + the hunt switch; the demo has all', () {
      expect(
        BackendModules.of(
          _supabase,
          memberships: true,
          playerHunt: true,
        ).has(BackendModule.playerHunt),
        isTrue,
      );
      expect(
        BackendModules.of(
          _supabase,
          memberships: false,
          playerHunt: true,
        ).has(BackendModule.playerHunt),
        isFalse,
      );
      expect(
        BackendModules.of(
          _supabase,
          memberships: true,
          playerHunt: false,
        ).has(BackendModule.playerHunt),
        isFalse,
      );
      expect(
        BackendModules.of(
          _supabase,
          memberships: true,
        ).has(BackendModule.playerHunt),
        isFalse,
        reason: 'OFF by default',
      );
      expect(
        BackendModules.of(const BackendConfig.memory())
            .has(BackendModule.playerHunt),
        isTrue,
      );
    });

    test('discovery is live only with memberships, matches and the switch, on Supabase', () {
      bool live(bool m, bool x, bool d, {BackendConfig? config}) =>
          BackendModules.discoveryLive(
            config ?? _supabase,
            memberships: m,
            matches: x,
            discovery: d,
          );
      expect(live(true, true, true), isTrue);
      expect(live(false, true, true), isFalse);
      expect(live(true, false, true), isFalse);
      expect(live(true, true, false), isFalse);
      expect(
        live(true, true, true, config: const BackendConfig.memory()),
        isFalse,
      );
      expect(kDiscoveryBuild, isFalse);
      expect(kPlayerHuntBuild, isFalse);
    });

    test(
      'switch OFF: no other clubs, no slots, no rankings — and no call',
      () async {
        final w = _World.create();
        final c = await w.container(discovery: false);
        expect(await c.read(clubRepositoryProvider).otherClubs(), isEmpty);
        expect(
          await c.read(clubRepositoryProvider).clubSummary(w.clubB),
          isNull,
        );
        expect(
          await c.read(challengeRepositoryProvider).availabilitySlots(),
          isEmpty,
        );
        expect(
          await c.read(challengeRepositoryProvider).matchSeekers(),
          isEmpty,
        );
        expect(
          await _errorOf(
            c
                .read(challengeRepositoryProvider)
                .postAvailabilitySlot(_slot(DateTime(2026, 11, 22))),
          ),
          isA<ModuleUnavailableException>(),
        );
        expect(
          c.read(discoveryRepositoryProvider),
          isA<UnavailableDiscoveryRepository>(),
        );
        expect(
          await c.read(joinRequestPerformanceProvider('req-x').future),
          isNull,
        );
        expect(w.ddb.calls, isEmpty);
      },
    );
  });

  group('club directory and profiles', () {
    test('the public row → ClubSummary: names, record, form, formats; no owner, coach, captain or players', () {
      final w = _World.create();
      final s = DiscoveryRowMapper.clubSummary(w.ddb.clubs[w.clubB]!);
      expect(s.id, w.clubB);
      expect(s.abbr, 'KK');
      expect(s.meta, 'Karachi · Corporate Club');
      expect(s.level, 'Corporate Club');
      expect(s.established, 2019);
      expect(s.squadSize, 18);
      expect(s.formats, 'T20 / ODI');
      expect(s.preferredFormat, MatchFormat.t20);
      expect(s.recentForm, [
        MatchResult.won,
        MatchResult.lost,
        MatchResult.won,
        MatchResult.won,
      ]);
      expect((s.played, s.wins, s.losses, s.winRate), (4, 3, 1, 75));
      expect(s.homeGround, 'Not listed');
      expect(s.ownerName, isNull);
      expect(s.coachName, isNull);
      expect(s.captain, isNull);
      expect(s.keyPlayers, isEmpty);
      final bare = DiscoveryRowMapper.clubSummary(
        publicClubRow('c9', 'Ravi Riders'),
      );
      expect(
        (bare.abbr, bare.established, bare.formats, bare.winRate),
        ('RR', 0, '', 0),
      );
    });

    test(
      'otherClubs reads the directory page by page; the own club never listed',
      () async {
        final w = _World.create();
        for (var i = 0; i < 120; i++) {
          final id = 'c-$i';
          w.ddb.clubs[id] = publicClubRow(
            id,
            'Club ${i.toString().padLeft(3, '0')}',
          );
        }
        final c = await w.container();
        final clubs = await c.read(clubRepositoryProvider).otherClubs();
        expect(clubs, hasLength(121));
        expect(clubs.any((x) => x.id == w.clubA), isFalse);
        expect(
          [
            for (final x in w.ddb.calls)
              if (x.fn == 'club_directory') x.params['p_offset'],
          ],
          [0, 100],
        );
        expect(w.ddb.calls.first.params['p_limit'], 100);
      },
    );

    test('clubSummary: the public profile; an unknown club is null; offline is an error', () async {
      final w = _World.create();
      final c = await w.container();
      final repo = c.read(clubRepositoryProvider);
      expect((await repo.clubSummary(w.clubB))!.name, 'Karachi Kings');
      expect(await repo.clubSummary('nope'), isNull);
      w.ddb.failOn['club_public_profile'] = const GatewayNetworkException();
      expect(
        await _errorOf(repo.clubSummary(w.clubB)),
        isA<BackendUnavailableException>(),
      );
    });

    test('a club beyond the directory is still found (clubSummaryProvider), and its profile opens', () async {
      final w = _World.create();
      final c = await w.container();
      w.ddb.clubs['c-late'] = publicClubRow('c-late', 'Late Club');
      // The directory is read first (cached); the club appears afterwards.
      await c.read(clubDirectoryProvider.future);
      w.ddb.clubs.remove('c-late');
      expect(
        await c.read(clubSummaryProvider('c-late').future),
        isNotNull,
        reason: 'cached directory',
      );
      w.ddb.clubs['c-new'] = publicClubRow('c-new', 'New Club');
      expect(
        (await c.read(clubSummaryProvider('c-new').future))!.name,
        'New Club',
      );
    });

    test('the opponent directory now carries the profile (record, View Club Profile)', () async {
      final w = _World.create();
      final c = await w.container();
      final clubs = await c.read(
        opponentDirectoryProvider((search: '', city: '')).future,
      );
      final kings = clubs.singleWhere((x) => x.id == w.clubB);
      expect(kings.summary, isNotNull);
      expect(kings.meta, 'Karachi · W3, L1');
    });

    test('the dashboard record: the own club\'s official one', () async {
      final w = _World.create();
      final c = await w.container();
      final own = await c.read(ownClubRecordProvider.future);
      expect((own!.played, own.wins, own.losses), (6, 4, 1));
    });
  });

  group('availability slots', () {
    test('post: the server\'s parameters, then Your Open Slot; withdraw removes it', () async {
      final w = _World.create();
      final c = await w.container();
      final ctrl = c.read(availabilitySlotsProvider.notifier);
      await c.read(availabilitySlotsProvider.future);
      final saved = await ctrl.post(
        _slot(DateTime(2026, 11, 22), notes: ' Friendly '),
      );
      expect(
        w.ddb.calls.where((x) => x.fn == 'post_match_slot').single.params,
        {
          'p_club_id': w.clubA,
          'p_format': 't20',
          'p_custom_overs': null,
          'p_city': 'Lahore',
          'p_slot_date': '2026-11-22',
          'p_start_time': '14:00',
          'p_end_time': '16:00',
          'p_ground_id': null,
          'p_venue_name': null,
          'p_notes': 'Friendly',
        },
      );
      expect(saved.id, startsWith('slot-'));
      expect(saved.slot, const TimeSlot(startHour: 14, endHour: 16));
      expect(saved.date, DateTime(2026, 11, 22));
      expect(saved.notes, 'Friendly');
      c.invalidate(availabilitySlotsProvider);
      expect(
        (await c.read(availabilitySlotsProvider.future)).single.id,
        saved.id,
      );
      await c.read(availabilitySlotsProvider.notifier).remove(saved.id);
      expect(w.ddb.count('withdraw_match_slot'), 1);
      expect(c.read(availabilitySlotsProvider).value, isEmpty);
      c.invalidate(availabilitySlotsProvider);
      expect(await c.read(availabilitySlotsProvider.future), isEmpty);
    });

    test(
      'refusals: today, an overlap, not the owner — friendly texts',
      () async {
        final w = _World.create();
        final c = await w.container();
        final repo = c.read(challengeRepositoryProvider);
        final today = await _errorOf(
          repo.postAvailabilitySlot(_slot(DateTime(2026, 11, 20))),
        );
        expect(today, isA<MatchRuleException>());
        expect(
          (today! as MatchRuleException).message,
          contains('from tomorrow'),
        );
        await repo.postAvailabilitySlot(_slot(DateTime(2026, 11, 22)));
        final overlap = await _errorOf(
          repo.postAvailabilitySlot(
            _slot(
              DateTime(2026, 11, 22),
              slot: const TimeSlot(startHour: 15, endHour: 18),
            ),
          ),
        );
        expect(
          (overlap! as MatchRuleException).message,
          contains('already have an open slot'),
        );
        // Back to back is fine.
        await repo.postAvailabilitySlot(
          _slot(
            DateTime(2026, 11, 22),
            slot: const TimeSlot(startHour: 16, endHour: 18),
          ),
        );
        w.ddb.owners = {w.clubA: 'someone-else', w.clubB: w.ownerB.id};
        expect(
          await _errorOf(
            repo.postAvailabilitySlot(_slot(DateTime(2026, 11, 23))),
          ),
          isA<PermissionDeniedException>(),
        );
      },
    );

    test('every slot refusal has its own text, never the raw message', () {
      Exception map(String state, String m) => SupabaseErrorMapper.map(
        GatewayConstraintException(sqlState: state, message: m),
      );
      for (final (state, reason, text) in [
        ('22023', 'invalid date', 'from tomorrow'),
        ('22023', 'invalid time', 'ends after it starts'),
        ('22023', 'invalid notes', '200 characters'),
        ('22023', 'invalid', 'Custom needs 1–50 overs'),
        ('23P01', 'overlaps', 'open slot at that time'),
        ('P0001', 'too many open', '10 open slots'),
        ('P0001', 'not open', 'already started'),
        ('P0002', 'not found', 'no longer exists'),
        ('P0002', 'club not found', 'Your club'),
      ]) {
        final e = map(state, 'slot: $reason');
        expect(e, isA<MatchRuleException>(), reason: reason);
        expect(
          (e as MatchRuleException).message,
          contains(text),
          reason: reason,
        );
      }
      expect(
        map('42501', 'slot: not allowed'),
        isA<PermissionDeniedException>(),
      );
      expect(
        map('42501', 'slot: not authenticated'),
        isA<NotSignedInException>(),
      );
      expect(
        map('42501', 'ranking: not authenticated'),
        isA<NotSignedInException>(),
      );
      expect(map('22023', 'ranking: invalid'), isA<MatchRuleException>());
      expect(
        (map('P0002', 'club: not found') as MatchRuleException).message,
        'This club is no longer available.',
      );
    });

    test('Teams Looking for Opponents: other clubs\' open slots, no rating; none for a player', () async {
      final w = _World.create();
      w.ddb.openSlots
        ..add(
          openSlotRow(
            's1',
            w.clubB,
            'Karachi Kings',
            venue: 'National Stadium',
          ),
        )
        ..add(openSlotRow('s2', w.clubB, 'Karachi Kings', date: '2026-11-23'))
        ..add(openSlotRow('s3', w.clubA, 'Lahore Lions'));
      final c = await w.container();
      final seekers = await c.read(matchSeekersProvider.future);
      expect(seekers.map((s) => s.slotId), [
        's1',
        's2',
      ], reason: 'the own club never listed');
      final s = seekers.first;
      expect(
        (s.clubId, s.clubName, s.clubCity, s.clubWins, s.clubLosses),
        (w.clubB, 'Karachi Kings', 'Karachi', 3, 1),
      );
      expect(s.rating, '—');
      expect(s.venue, 'National Stadium');
      expect(seekers.last.venue, 'Any ground in Karachi');
      expect(
        s.startsAt.isAtSameMomentAs(DateTime.utc(2026, 11, 22, 9)),
        isTrue,
      );
      expect(s.format, MatchFormat.t20);

      // A signed-in person without a club: no call, nothing listed.
      final p = w.auth.addUser('p@example.com', 'Cricket@123');
      w.auth.current = p;
      final before = w.ddb.count('open_match_slots');
      expect(await c.read(challengeRepositoryProvider).matchSeekers(), isEmpty);
      expect(w.ddb.count('open_match_slots'), before);
    });
  });

  group('rankings and applicants', () {
    test('the shared leaderboard from player_rankings; ranked by the app, rating none', () async {
      final w = _World.create();
      w.ddb.rankings
        ..add(rankingRow('u-1', 'Babar', runs: 400, average: 50))
        ..add(
          rankingRow(
            'u-2',
            'Shaheen',
            role: 'bowler',
            runs: 20,
            wickets: 15,
            average: null,
          ),
        )
        ..add(
          rankingRow(
            w.ownerA.id,
            'Ali Raza',
            role: 'all_rounder',
            runs: 100,
            wickets: 3,
          ),
        );
      final c = await w.container();
      final inputs = await c.read(rankingInputsProvider.future);
      expect(inputs.map((i) => i.name), ['Babar', 'Shaheen', 'Ali Raza']);
      expect(inputs.first.club, 'Karachi Kings');
      expect(inputs.first.battingAverage, 50);
      expect(inputs[1].role, SquadCategory.bowler);
      expect(inputs[1].battingAverage, isNull);
      expect(inputs.every((i) => i.rating == null), isTrue);
      expect(inputs.last.isMe, isTrue);
      expect(
        w.ddb.calls
            .where((x) => x.fn == 'player_rankings')
            .single
            .params['p_limit'],
        200,
      );
      final board = await c.read(rankingBoardProvider.future);
      expect(board.all, hasLength(3));
      expect(board.me?.input.name, 'Ali Raza');
    });

    test(
      'switch OFF: the own club only (today), no player_rankings call',
      () async {
        final w = _World.create();
        final c = await w.container(discovery: false);
        await c.read(rankingInputsProvider.future);
        expect(w.ddb.count('player_rankings'), 0);
      },
    );

    test(
      'applicant statistics: shown when shared and played; none otherwise',
      () async {
        final w = _World.create();
        Map<String, dynamic> row(bool visible, int matches) => {
          'request_id': 'r',
          'stats_visible': visible,
          'matches': visible ? matches : null,
          'runs': visible ? 321 : null,
          'batting_average': visible && matches > 0 ? 35.666 : null,
          'wickets': visible ? 4 : null,
        };
        expect(DiscoveryRowMapper.applicantPerformance(row(false, 0)), isNull);
        expect(
          DiscoveryRowMapper.applicantPerformance(row(true, 0)),
          isNull,
          reason: 'never played',
        );
        final p = DiscoveryRowMapper.applicantPerformance(row(true, 9))!;
        expect((p.matches, p.runs, p.average, p.wickets), (9, 321, '35.67', 4));
        w.ddb.applicants['req-1'] = row(true, 9);
        final c = await w.container();
        expect(
          (await c
                  .read(discoveryRepositoryProvider)
                  .applicantPerformance('req-1'))!
              .runs,
          321,
        );
        expect(
          await _errorOf(
            c
                .read(discoveryRepositoryProvider)
                .applicantPerformance('req-gone'),
          ),
          isA<ClubMembershipException>(),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Screens
  // ---------------------------------------------------------------------------
  group('screens (discovery on)', () {
    Future<_World> pump(
      WidgetTester tester,
      String location, {
      void Function(_World w)? before,
      bool discovery = true,
    }) async {
      tester.view.physicalSize = const Size(1000, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final w = _World.create();
      before?.call(w);
      final overrides = await w.overrides(discovery: discovery);
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: Routes.challenges,
            builder: (_, s) => ChallengesWorkspace(
              tab: ChallengesSection.parse(s.uri.queryParameters['tab']),
            ),
          ),
          GoRoute(
            path: Routes.createAvailabilitySlot,
            builder: (_, _) => const CreateSlotScreen(),
          ),
          GoRoute(
            path: '/club/clubs/:clubId',
            builder: (_, s) => ClubProfileScreen(
              clubId: s.pathParameters['clubId']!,
              fromFind: s.uri.queryParameters['from'] == 'find',
            ),
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

    testWidgets(
      'Find Opponent: slot CTA, Your Open Slot, teams looking (W/L, no rating), the directory',
      (tester) async {
        await pump(
          tester,
          Routes.findMatch,
          before: (w) {
            w.ddb.openSlots.add(openSlotRow('s1', w.clubB, 'Karachi Kings'));
            w.ddb.slots.add({
              ...openSlotRow(
                'mine',
                w.clubA,
                'Lahore Lions',
                date: '2026-11-24',
              ),
              'status': 'open',
              'closed_at': null,
            });
          },
        );
        expect(find.textContaining('Create Availability Slot'), findsOneWidget);
        expect(find.text('Your Open Slot'), findsOneWidget);
        expect(
          find.text('Teams Looking for Opponents · 1 Team'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('seeker.s1')), findsOneWidget);
        expect(find.textContaining('W3 L1'), findsOneWidget);
        expect(find.text('—'), findsOneWidget);
        expect(find.text('Any ground in Karachi'), findsOneWidget);
        expect(find.text('Send Match Request'), findsOneWidget);
      },
    );

    testWidgets('switch OFF: Find Opponent is the directory only (today)', (
      tester,
    ) async {
      final w = await pump(tester, Routes.findMatch, discovery: false);
      expect(find.textContaining('Create Availability Slot'), findsNothing);
      expect(find.textContaining('Teams Looking for Opponents'), findsNothing);
      expect(find.text('Karachi Kings'), findsOneWidget);
      expect(w.ddb.calls, isEmpty);
    });

    testWidgets(
      'Opponent Club Profile opens from the directory with server data',
      (tester) async {
        final w = await pump(tester, Routes.findMatch);
        await tester.tap(find.byKey(Key('opponent.${w.clubB}')));
        await tester.pumpAndSettle();
        expect(find.text('Club Profile'), findsOneWidget);
        expect(find.text('Karachi Kings'), findsWidgets);
        expect(find.text('Est. 2019 · Squad of 18'), findsOneWidget);
        expect(find.text('75%'), findsOneWidget);
        expect(
          find.text('Not listed'),
          findsNWidgets(3),
          reason: 'owner, coach, home ground',
        );
        expect(find.text('T20 / ODI'), findsOneWidget);
        expect(find.text('Club Captain'), findsNothing);
        expect(find.textContaining('Key Players'), findsNothing);
        expect(find.text('Send Match Request'), findsOneWidget);
      },
    );

    testWidgets(
      'Create Slot: today is disabled (server: from tomorrow); a refusal is shown',
      (tester) async {
        final w = await pump(tester, Routes.createAvailabilitySlot);
        await tester.tap(find.byType(CeDateRow));
        await tester.pumpAndSettle();
        GestureDetector dayCell(String d) => tester.widget<GestureDetector>(
          find
              .ancestor(
                of: find.text(d),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        expect(dayCell('20').onTap, isNull, reason: 'today');
        expect(dayCell('21').onTap, isNotNull, reason: 'tomorrow');
        await tester.tap(find.text('21'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('T20'));
        await tester.tap(find.byKey(const Key('slot.city')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lahore').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('2pm – 4pm'));
        w.ddb.failOn['post_match_slot'] = const GatewayConstraintException(
          sqlState: 'P0001',
          message: 'slot: too many open',
        );
        await tester.ensureVisible(find.text('Post Availability Slot'));
        await tester.tap(find.text('Post Availability Slot'));
        await tester.pumpAndSettle();
        expect(find.textContaining('10 open slots'), findsOneWidget);
        expect(w.ddb.calls.last.params['p_slot_date'], '2026-11-21');
      },
    );
  });
}
