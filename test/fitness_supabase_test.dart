// M9 (app half): logged workouts and the owner's squad fitness on the server
// (migration 34, the CRICECO_FITNESS switch) — repository mapping and
// errors, the SDK gateway's requests, the module matrix, Add Workout /
// delete, the Fitness Meter from server data and the owner's views with
// members who don't share their stats. Fake gateways only: no network.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/fitness_meter.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_fitness_repository.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/screens/member_profile_screen.dart';
import 'package:criceco/features/club/screens/members_screen.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/fitness/fitness_providers.dart';
import 'package:criceco/features/fitness/workout_sheet.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'fitness_fakes.dart';
import 'helpers.dart';
import 'match_fakes.dart';
import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// 2026-11-26 01:00 in Pakistan (still the 25th in UTC and further west).
final _lateNight = DateTime.utc(2026, 11, 25, 20);

/// 2026-11-26 12:00 in Pakistan: the same calendar day on any device.
final _midday = DateTime.utc(2026, 11, 26, 7);

GatewayConstraintException _refusal(String state, String message) =>
    GatewayConstraintException(sqlState: state, message: message);

Future<Object?> _errorOf(Future<Object?> call) =>
    call.then<Object?>((_) => null, onError: (Object e) => e);

void main() {
  group('SupabaseFitnessRepository: mapping', () {
    late FakeFitnessDb db;
    late SupabaseFitnessRepository repo;
    setUp(() {
      db = FakeFitnessDb();
      repo = SupabaseFitnessRepository(db: db, clock: Clock.fixed(_lateNight));
    });

    test(
      'my_workouts: the last 30 days up to today in Pakistan, rows mapped',
      () async {
        db.many['my_workouts'] = [
          workoutRow(
            'w1',
            '2026-11-20',
            type: 'nets',
            minutes: 45,
            intensity: 'light',
          ),
          workoutRow(
            'w2',
            '2026-11-26',
            type: 'gym',
            minutes: 90,
            intensity: 'high',
            notes: 'Leg day',
          ),
        ];
        final list = await repo.myWorkouts();
        expect(db.calls.single.params, {
          'p_from': '2026-10-28',
          'p_to': '2026-11-26',
        });
        expect(
          [
            for (final w in list)
              (w.id, w.date, w.type, w.minutes, w.intensity, w.notes),
          ],
          [
            (
              'w1',
              DateTime(2026, 11, 20),
              WorkoutType.nets,
              45,
              WorkoutIntensity.light,
              '',
            ),
            (
              'w2',
              DateTime(2026, 11, 26),
              WorkoutType.gym,
              90,
              WorkoutIntensity.high,
              'Leg day',
            ),
          ],
        );
      },
    );

    test('an unreadable row is a generic error, never a guess', () async {
      for (final bad in [
        workoutRow('w1', '2026-11-20', type: 'Training'),
        workoutRow('w1', '2026-11-20', intensity: 'extreme'),
        workoutRow('w1', '26/11/2026'),
        {...workoutRow('w1', '2026-11-20'), 'minutes': 'sixty'},
        {...workoutRow('w1', '2026-11-20'), 'id': null},
      ]) {
        db.many['my_workouts'] = [bad];
        expect(
          await _errorOf(repo.myWorkouts()),
          isA<BackendOperationException>(),
          reason: '$bad',
        );
      }
    });

    test('log_workout: date, codes and trimmed notes (blank → null); the stored row back', () async {
      final w = await repo.logWorkout(
        date: DateTime(2026, 11, 26, 9, 30),
        type: WorkoutType.running,
        minutes: 600,
        intensity: WorkoutIntensity.high,
        notes: '  Hill sprints  ',
      );
      expect(db.calls.single.fn, 'log_workout');
      expect(db.calls.single.params, {
        'p_workout_date': '2026-11-26',
        'p_workout_type': 'running',
        'p_minutes': 600,
        'p_intensity': 'high',
        'p_notes': 'Hill sprints',
      });
      expect(
        (w.id, w.date, w.notes),
        ('wk-server-1', DateTime(2026, 11, 26), 'Hill sprints'),
      );

      await repo.logWorkout(
        date: DateTime(2026, 11, 1),
        type: WorkoutType.other,
        minutes: 1,
        intensity: WorkoutIntensity.light,
        notes: '   ',
      );
      expect(db.calls.last.params['p_notes'], isNull);
      expect(db.calls.last.params['p_workout_type'], 'other');
    });

    test("log_workout: the server's own rules first — nothing is sent when one fails", () async {
      Future<Object?> log(DateTime d, {int minutes = 60, String notes = ''}) =>
          _errorOf(
            repo.logWorkout(
              date: d,
              type: WorkoutType.gym,
              minutes: minutes,
              intensity: WorkoutIntensity.moderate,
              notes: notes,
            ),
          );
      // Today in Pakistan is the 26th even though it is still the 25th in UTC.
      expect(await log(DateTime(2026, 11, 27)), isA<FitnessRuleException>());
      expect(
        await log(DateTime(2025, 11, 25)),
        isA<FitnessRuleException>(),
        reason: '366 days back',
      );
      expect(
        await log(DateTime(2026, 11, 26), minutes: 0),
        isA<FitnessRuleException>(),
      );
      expect(
        await log(DateTime(2026, 11, 26), minutes: WorkoutEntry.maxMinutes + 1),
        isA<FitnessRuleException>(),
      );
      expect(
        await log(
          DateTime(2026, 11, 26),
          notes: 'x' * (WorkoutEntry.notesMaxLength + 1),
        ),
        isA<FitnessRuleException>(),
      );
      expect(db.calls, isEmpty);
      // The limits themselves are accepted.
      expect(
        await log(
          DateTime(2026, 11, 26),
          notes: ' ${'x' * WorkoutEntry.notesMaxLength} ',
        ),
        isNull,
      );
      expect(
        await log(DateTime(2025, 11, 26)),
        isNull,
        reason: '365 days back',
      );
      expect(db.calls.length, 2);
    });

    test('delete_workout by id', () async {
      await repo.deleteWorkout('w9');
      expect(
        (db.calls.single.fn, db.calls.single.params['p_id']),
        ('delete_workout', 'w9'),
      );
    });

    test(
      'owner views: the meter window (today − 6 … today in Pakistan)',
      () async {
        await repo.clubMemberFitness('club-a');
        await repo.clubMemberWorkouts('club-a');
        await repo.clubMemberMatchActivity('club-a');
        for (final c in db.calls) {
          expect(c.params, {
            'p_club_id': 'club-a',
            'p_from': '2026-11-20',
            'p_to': '2026-11-26',
          }, reason: c.fn);
        }
        expect(db.fns, [
          'club_member_fitness',
          'club_member_workouts',
          'club_member_match_activity',
        ]);
      },
    );

    test('club_member_fitness: visible figures; a hidden member has none (never 0)', () async {
      db.many['club_member_fitness'] = [
        fitnessRow('m-owner', role: 'owner'),
        fitnessRow(
          'm-1',
          sessions: 2,
          minutes: 150,
          load: '2.25',
          lastWorkout: '2026-11-25',
          matches: 1,
          lastMatch: '2026-11-24',
        ),
        fitnessRow('m-2', visible: false),
        // A hidden row is shown hidden whatever else it holds.
        {...fitnessRow('m-3', visible: false), 'workout_sessions': 4},
      ];
      final s = {
        for (final r in await repo.clubMemberFitness('club-a')) r.memberId: r,
      };
      expect(
        (
          s['m-owner']!.visible,
          s['m-owner']!.workoutSessions,
          s['m-owner']!.trainingLoad,
        ),
        (true, 0, 0.0),
      );
      final m1 = s['m-1']!;
      expect(
        (
          m1.workoutSessions,
          m1.workoutMinutes,
          m1.trainingLoad,
          m1.lastWorkoutDate,
          m1.matches,
          m1.lastMatchDate,
        ),
        (2, 150, 2.25, DateTime(2026, 11, 25), 1, DateTime(2026, 11, 24)),
      );
      for (final id in ['m-2', 'm-3']) {
        final h = s[id]!;
        expect(h.visible, isFalse);
        expect([
          h.workoutSessions,
          h.workoutMinutes,
          h.trainingLoad,
          h.matches,
          h.lastWorkoutDate,
          h.lastMatchDate,
        ], everyElement(isNull));
      }
    });

    test('club_member_workouts: by member, no notes', () async {
      db.many['club_member_workouts'] = [
        memberWorkoutRow(
          'm-1',
          'w1',
          '2026-11-21',
          type: 'training',
          minutes: 30,
          intensity: 'light',
        ),
        memberWorkoutRow('m-1', 'w2', '2026-11-25'),
        memberWorkoutRow('m-4', 'w3', '2026-11-26', type: 'nets'),
      ];
      final w = await repo.clubMemberWorkouts('club-a');
      expect(w.keys, unorderedEquals(['m-1', 'm-4']));
      expect(
        [
          for (final e in w['m-1']!)
            (e.id, e.date, e.type, e.minutes, e.intensity, e.notes),
        ],
        [
          (
            'w1',
            DateTime(2026, 11, 21),
            WorkoutType.training,
            30,
            WorkoutIntensity.light,
            '',
          ),
          (
            'w2',
            DateTime(2026, 11, 25),
            WorkoutType.running,
            60,
            WorkoutIntensity.high,
            '',
          ),
        ],
      );
    });

    test('club_member_match_activity → MatchLogEntry (overs from balls), newest first', () async {
      db.many['club_member_match_activity'] = [
        activityRow(
          'm-1',
          'x1',
          '2026-11-21T10:00:00+00:00',
          result: 'lost',
          batRuns: 12,
          batBalls: 20,
        ),
        activityRow(
          'm-1',
          'x2',
          '2026-11-25T10:00:00+00:00',
          result: 'no_result',
          bowlBalls: 22,
          bowlWickets: 3,
          opponent: 'Quetta Gladiators',
        ),
      ];
      final a = await repo.clubMemberMatchActivity('club-a');
      final log = a['m-1']!;
      expect(
        [for (final e in log) e.opponentName],
        ['Quetta Gladiators', 'Karachi Kings'],
      );
      expect(
        (
          log[0].result,
          log[0].overs,
          log[0].wickets,
          log[0].opponentAbbr,
          log[0].date,
        ),
        (
          MatchResult.noResult,
          '3.4',
          3,
          'QG',
          DateTime.utc(2026, 11, 25, 10).toLocal(),
        ),
      );
      expect(
        (log[1].result, log[1].runs, log[1].balls, log[1].overs),
        (MatchResult.lost, 12, 20, '0.0'),
      );
    });
  });

  group('SupabaseFitnessRepository: errors', () {
    late FakeFitnessDb db;
    late SupabaseFitnessRepository repo;
    setUp(() {
      db = FakeFitnessDb();
      repo = SupabaseFitnessRepository(db: db, clock: Clock.fixed(_midday));
    });

    Future<Object?> log() => _errorOf(
      repo.logWorkout(
        date: DateTime(2026, 11, 26),
        type: WorkoutType.gym,
        minutes: 60,
        intensity: WorkoutIntensity.moderate,
      ),
    );

    test(
      'every log_workout refusal of the contract → what the player can do next',
      () async {
        for (final (state, message, text) in [
          ('22023', 'fitness: invalid date', FitnessTexts.date),
          ('22023', 'fitness: future date', FitnessTexts.futureDate),
          ('22023', 'fitness: date too old', FitnessTexts.tooOld),
          ('22023', 'fitness: invalid type', FitnessTexts.type),
          ('22023', 'fitness: invalid minutes', FitnessTexts.minutes),
          ('22023', 'fitness: invalid intensity', FitnessTexts.intensity),
          ('22023', 'fitness: notes too long', FitnessTexts.notes),
          (
            'P0001',
            'fitness: too many workouts on that day',
            FitnessTexts.perDay,
          ),
          (
            'P0001',
            'fitness: too many workouts logged, try later',
            FitnessTexts.perWindow,
          ),
          ('P0001', 'fitness: something new', FitnessTexts.generic),
        ]) {
          db.failOn['log_workout'] = _refusal(state, message);
          final e = await log();
          expect(e, isA<FitnessRuleException>(), reason: message);
          expect((e! as FitnessRuleException).message, text, reason: message);
          expect(
            (e as FitnessRuleException).message,
            isNot(contains('fitness:')),
            reason: 'never the raw database text',
          );
        }
      },
    );

    test('not signed in / no profile / not the owner / range', () async {
      db.failOn['log_workout'] = _refusal(
        '42501',
        'fitness: not authenticated',
      );
      expect(await log(), isA<NotSignedInException>());
      db.failOn['log_workout'] = _refusal(
        'P0002',
        'fitness: profile not found',
      );
      expect(await log(), isA<ProfileNotFoundException>());
      db.failOn['club_member_fitness'] = _refusal(
        '42501',
        'fitness: not allowed',
      );
      expect(
        await _errorOf(repo.clubMemberFitness('club-x')),
        isA<PermissionDeniedException>(),
      );
      db.failOn['club_member_workouts'] = _refusal(
        '42501',
        'permission denied for function club_member_workouts',
      );
      expect(
        await _errorOf(repo.clubMemberWorkouts('club-x')),
        isA<PermissionDeniedException>(),
      );
      db.failOn['my_workouts'] = _refusal('22023', 'fitness: invalid range');
      expect(await _errorOf(repo.myWorkouts()), isA<FitnessRuleException>());
      db.failOn['delete_workout'] = _refusal(
        'P0002',
        'fitness: workout not found',
      );
      final e = await _errorOf(repo.deleteWorkout('w1'));
      expect((e! as FitnessRuleException).message, FitnessTexts.notFound);
      db.failOn['my_workouts'] = const GatewayNetworkException();
      expect(
        await _errorOf(repo.myWorkouts()),
        isA<BackendUnavailableException>(),
      );
    });
  });

  group('SupabaseFitnessGateway on the SDK client', () {
    final requests = <http.Request>[];
    late http.Response Function(http.Request) respond;
    late sb.SupabaseClient client;
    late SupabaseFitnessGateway gateway;

    http.Response json(Object? body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

    setUp(() {
      requests.clear();
      respond = (_) => json([]);
      client = sb.SupabaseClient(
        'https://abcdefghijklmnop.supabase.co',
        'sb_publishable_test_0000000000000000',
        httpClient: MockClient((r) async {
          requests.add(r);
          final res = respond(r);
          return http.Response.bytes(
            res.bodyBytes,
            res.statusCode,
            headers: res.headers,
            request: r,
          );
        }),
        authOptions: const sb.AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: sb.AuthFlowType.implicit,
        ),
      );
      gateway = SupabaseFitnessGateway(client);
    });
    tearDown(() => client.dispose());

    void expectRpc(String fn, Map<String, Object?> params) {
      final r = requests.single;
      expect((r.method, r.url.path), ('POST', '/rest/v1/rpc/$fn'));
      expect(jsonDecode(r.body), params);
      requests.clear();
    }

    test('every function by name, with its parameters', () async {
      respond = (_) => json([workoutRow('w1', '2026-11-26')]);
      final params = FitnessRowMapperParams.sample;
      expect((await gateway.logWorkout(params))['id'], 'w1');
      expectRpc('log_workout', params);
      respond = (_) => json([]);
      await gateway.myWorkouts(from: '2026-10-28', to: '2026-11-26');
      expectRpc('my_workouts', {'p_from': '2026-10-28', 'p_to': '2026-11-26'});
      respond = (_) => json(null);
      await gateway.deleteWorkout('w1');
      expectRpc('delete_workout', {'p_id': 'w1'});
      respond = (_) => json([]);
      const range = {
        'p_club_id': 'c1',
        'p_from': '2026-11-20',
        'p_to': '2026-11-26',
      };
      await gateway.clubMemberFitness(
        'c1',
        from: '2026-11-20',
        to: '2026-11-26',
      );
      expectRpc('club_member_fitness', range);
      await gateway.clubMemberWorkouts(
        'c1',
        from: '2026-11-20',
        to: '2026-11-26',
      );
      expectRpc('club_member_workouts', range);
      await gateway.clubMemberMatchActivity(
        'c1',
        from: '2026-11-20',
        to: '2026-11-26',
      );
      expectRpc('club_member_match_activity', range);
    });

    test('log_workout without a row is unexpected; a refusal keeps its code and message', () async {
      respond = (_) => json([]);
      expect(
        await _errorOf(gateway.logWorkout(FitnessRowMapperParams.sample)),
        isA<GatewayUnexpectedException>(),
      );
      respond = (_) => json({
        'code': 'P0001',
        'message': 'fitness: too many workouts on that day',
      }, 400);
      final e = await _errorOf(
        gateway.logWorkout(FitnessRowMapperParams.sample),
      );
      expect((e! as GatewayConstraintException).sqlState, 'P0001');
      expect(
        (e as GatewayConstraintException).message,
        'fitness: too many workouts on that day',
      );
    });
  });

  group('the fitness switch: modules and repositories', () {
    test('playerStats needs Supabase + memberships, matches, results AND fitness; the demo has it', () {
      for (final m in [false, true]) {
        for (final mt in [false, true]) {
          for (final r in [false, true]) {
            for (final f in [false, true]) {
              final modules = BackendModules.of(
                _supabase,
                memberships: m,
                matches: mt,
                results: r,
                fitness: f,
              );
              expect(
                modules.has(BackendModule.playerStats),
                m && mt && r && f,
                reason: '$m $mt $r $f',
              );
              expect(
                BackendModules.fitnessLive(
                  _supabase,
                  memberships: m,
                  matches: mt,
                  results: r,
                  fitness: f,
                ),
                m && mt && r && f,
              );
              // The other modules don't depend on it.
              expect(modules.has(BackendModule.matchStats), m && mt && r);
            }
          }
        }
      }
      expect(
        BackendModules.of(
          const BackendConfig.memory(),
          fitness: false,
        ).has(BackendModule.playerStats),
        isTrue,
      );
      expect(
        BackendModules.fitnessLive(
          const BackendConfig.memory(),
          memberships: true,
          matches: true,
          results: true,
          fitness: true,
        ),
        isFalse,
      );
    });

    test('OFF by default', () {
      expect(kFitnessBuild, isFalse);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(fitnessEnabledProvider), isFalse);
    });

    ProviderContainer container({
      required BackendConfig config,
      required bool fitness,
    }) {
      final c = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(config),
          membershipsEnabledProvider.overrideWithValue(true),
          matchesEnabledProvider.overrideWithValue(true),
          resultsEnabledProvider.overrideWithValue(true),
          fitnessEnabledProvider.overrideWithValue(fitness),
          fitnessGatewayProvider.overrideWith(
            (ref) => fitness && config.isSupabase
                ? FakeFitnessDb()
                : throw StateError('fitness gateway used with the switch off'),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('Supabase with every switch → the Supabase repository', () {
      final c = container(config: _supabase, fitness: true);
      expect(c.read(fitnessBackendLiveProvider), isTrue);
      expect(
        c.read(fitnessRepositoryProvider),
        isA<SupabaseFitnessRepository>(),
      );
      expect(
        c.read(backendModulesProvider).has(BackendModule.playerStats),
        isTrue,
      );
    });

    for (final (name, config) in [
      ('Supabase without the fitness switch', _supabase),
      ('the demo', const BackendConfig.memory()),
    ]) {
      test(
        '$name → unavailable: nothing listed, writes refused, the gateway never read',
        () async {
          final c = container(config: config, fitness: name == 'the demo');
          expect(c.read(fitnessBackendLiveProvider), isFalse);
          final r = c.read(fitnessRepositoryProvider);
          expect(r, isA<UnavailableFitnessRepository>());
          expect(await r.myWorkouts(), isEmpty);
          expect(await r.clubMemberFitness('c1'), isEmpty);
          expect(await r.clubMemberWorkouts('c1'), isEmpty);
          expect(await r.clubMemberMatchActivity('c1'), isEmpty);
          expect(
            await _errorOf(r.deleteWorkout('w1')),
            isA<ModuleUnavailableException>(),
          );
        },
      );
    }
  });

  group('the demo keeps its session workouts', () {
    test('save / delete stay in memory, by the device date; the fitness gateway is never read', () async {
      final c = await makeContainer(
        clock: TestClock(DateTime(2026, 9, 23, 10)),
      );
      addTearDown(c.dispose);
      await c
          .read(sessionProvider.notifier)
          .signIn(identifier: 'x', password: 'y');
      final ctrl = c.read(playerWorkoutsProvider.notifier);
      expect(c.read(fitnessBackendLiveProvider), isFalse);
      expect(c.read(workoutTodayProvider)(), DateTime(2026, 9, 23));
      final w = await ctrl.save(
        date: DateTime(2026, 9, 23),
        type: WorkoutType.gym,
        minutes: 30,
        intensity: WorkoutIntensity.light,
        notes: ' a ',
      );
      expect((w.notes, c.read(playerWorkoutsProvider).single.id), ('a', w.id));
      expect(
        await _errorOf(
          ctrl.save(
            date: DateTime(2026, 9, 24),
            type: WorkoutType.gym,
            minutes: 30,
            intensity: WorkoutIntensity.light,
          ),
        ),
        isA<ArgumentError>(),
      );
      await ctrl.delete(w.id);
      expect(c.read(playerWorkoutsProvider), isEmpty);
      // The demo's own Fitness Meter and member activity are unchanged.
      expect(c.read(fitnessRecordedProvider), isTrue);
      expect(c.read(memberFitnessHiddenProvider('any')), isFalse);
    });
  });

  group('the app on server data (switch ON)', () {
    const ownClub = Club(
      id: 'club-a',
      name: 'Lahore Lions',
      city: 'Lahore',
      type: ClubType.corporate,
      code: 'ABC001',
    );
    const owner = ClubMember(
      id: 'm-owner',
      name: 'Omar Owner',
      role: MemberRole.owner,
      playingRole: PlayerRole.batsman,
      poolPlayerId: 'm-owner',
    );
    const ali = ClubMember(
      id: 'm-1',
      name: 'Ali Khan',
      role: MemberRole.player,
      playingRole: PlayerRole.bowler,
      poolPlayerId: 'm-1',
    );
    const bilal = ClubMember(
      id: 'm-2',
      name: 'Bilal Hidden',
      role: MemberRole.player,
      playingRole: PlayerRole.batsman,
      poolPlayerId: 'm-2',
    );
    const coach = ClubMember(
      id: 'm-3',
      name: 'Coach Zia',
      role: MemberRole.coach,
    );
    const account = UserAccount(
      id: 'u-owner',
      fullName: 'Omar Owner',
      contactMethod: ContactMethod.email,
    );
    final ownLog = [
      MatchLogEntry(
        opponentAbbr: 'KK',
        opponentName: 'Karachi Kings',
        date: DateTime(2026, 11, 24, 15),
        result: MatchResult.won,
        runs: 40,
        balls: 30,
        wickets: 0,
        overs: '0',
      ),
    ];

    late FakeFitnessDb fdb;
    late FakeDb db;

    Future<ProviderContainer> make({bool fitness = true}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      db = FakeDb();
      final auth = FakeAuth(db);
      final clubs = FakeClubDb(db);
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          backendConfigProvider.overrideWithValue(_supabase),
          membershipsEnabledProvider.overrideWithValue(true),
          matchesEnabledProvider.overrideWithValue(true),
          resultsEnabledProvider.overrideWithValue(true),
          fitnessEnabledProvider.overrideWithValue(fitness),
          clockProvider.overrideWithValue(Clock.fixed(_midday)),
          authGatewayProvider.overrideWithValue(auth),
          clubGatewayProvider.overrideWithValue(clubs),
          membershipGatewayProvider.overrideWithValue(
            FakeMembershipDb(db, clubs),
          ),
          matchGatewayProvider.overrideWithValue(FakeMatchDb(auth, clubs)),
          fitnessGatewayProvider.overrideWith(
            (ref) => fitness
                ? fdb
                : throw StateError('fitness gateway used with the switch off'),
          ),
          currentAccountProvider.overrideWithValue(account),
          currentClubProvider.overrideWithValue(ownClub),
          performanceProvider.overrideWith(
            (ref) async => PerformanceSummary(
              matches: 1,
              runs: 40,
              wickets: 0,
              rating: '—',
              snapshot: const [],
              batting: const [],
              bowling: const [],
              fielding: const [],
              recentForm: const [],
              matchLog: ownLog,
            ),
          ),
          playerAvailabilityRepositoryProvider.overrideWithValue(
            const UnavailablePlayerAvailabilityRepository(),
          ),
          clubMembersProvider.overrideWith(
            (ref) async => const [owner, ali, bilal, coach],
          ),
          clubPlayerPoolProvider.overrideWith(
            (ref) async => const [
              SquadPlayer(
                id: 'm-owner',
                name: 'Omar Owner',
                position: 'Batsman',
                availability: PlayerAvailability.available,
              ),
              SquadPlayer(
                id: 'm-1',
                name: 'Ali Khan',
                position: 'Bowler',
                availability: PlayerAvailability.available,
              ),
              SquadPlayer(
                id: 'm-2',
                name: 'Bilal Hidden',
                position: 'Batsman',
                availability: PlayerAvailability.available,
              ),
            ],
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      fdb = FakeFitnessDb()
        ..many['my_workouts'] = [
          workoutRow('w-own', '2026-11-25', minutes: 120, intensity: 'high'),
        ]
        ..many['club_member_fitness'] = [
          fitnessRow('m-owner', role: 'owner'),
          fitnessRow('m-1', sessions: 1, minutes: 60, load: 1.5, matches: 2),
          fitnessRow('m-2', visible: false),
          fitnessRow('m-3', role: 'coach'),
        ]
        ..many['club_member_workouts'] = [
          memberWorkoutRow('m-1', 'w-ali', '2026-11-25'),
        ]
        ..many['club_member_match_activity'] = [
          activityRow(
            'm-1',
            'x1',
            '2026-11-24T10:00:00+00:00',
            bowlBalls: 24,
            bowlWickets: 2,
          ),
          activityRow(
            'm-1',
            'x2',
            '2026-11-25T10:00:00+00:00',
            bowlBalls: 24,
            bowlWickets: 1,
          ),
        ];
    });

    Future<void> load(ProviderContainer c) async {
      await c.read(performanceProvider.future);
      await c.read(serverWorkoutsProvider.future);
      await c.read(clubMembersProvider.future);
      await c.read(clubPlayerPoolProvider.future);
      await c.read(ownerFitnessDataProvider.future);
      await c.read(memberActivityProvider.future);
      c.read(playerAvailabilityProvider);
    }

    test("the player's meter: own match log, availability and the server's workouts", () async {
      final c = await make();
      c.listen(playerWorkoutsProvider, (_, _) {});
      await load(c);
      expect(c.read(fitnessRecordedProvider), isTrue);
      expect([for (final w in c.read(playerWorkoutsProvider)) w.id], ['w-own']);
      final f = c.read(playerFitnessProvider)!;
      final expected = FitnessMeter.evaluate(
        ownLog,
        now: _midday,
        workouts: c.read(playerWorkoutsProvider),
      );
      expect(
        (f.score, f.matches, f.trainingSessions, f.trainingLoad),
        (expected.score, 1, 1, 3.0),
      );
    });

    test('Add Workout saves on the server and the meter counts it; a refusal changes nothing', () async {
      final c = await make();
      c.listen(playerWorkoutsProvider, (_, _) {});
      await load(c);
      final ctrl = c.read(playerWorkoutsProvider.notifier);
      final saved = await ctrl.save(
        date: DateTime(2026, 11, 26),
        type: WorkoutType.nets,
        minutes: 30,
        intensity: WorkoutIntensity.light,
        notes: ' Throwdowns ',
      );
      expect(
        fdb.calls.where((x) => x.fn == 'log_workout').single.params['p_notes'],
        'Throwdowns',
      );
      expect(
        [for (final w in c.read(playerWorkoutsProvider)) w.id],
        ['w-own', saved.id],
      );
      expect(c.read(playerFitnessProvider)!.trainingSessions, 2);

      fdb.failOn['log_workout'] = _refusal(
        'P0001',
        'fitness: too many workouts on that day',
      );
      final e = await _errorOf(
        ctrl.save(
          date: DateTime(2026, 11, 26),
          type: WorkoutType.gym,
          minutes: 30,
          intensity: WorkoutIntensity.light,
        ),
      );
      expect((e! as FitnessRuleException).message, FitnessTexts.perDay);
      expect(c.read(playerWorkoutsProvider).length, 2);

      // The app's own checks: tomorrow in Pakistan, minutes, notes — nothing sent.
      final before = fdb.calls.length;
      for (final call in [
        () => ctrl.save(
          date: DateTime(2026, 11, 27),
          type: WorkoutType.gym,
          minutes: 30,
          intensity: WorkoutIntensity.light,
        ),
        () => ctrl.save(
          date: DateTime(2026, 11, 26),
          type: WorkoutType.gym,
          minutes: 0,
          intensity: WorkoutIntensity.light,
        ),
        () => ctrl.save(
          date: DateTime(2026, 11, 26),
          type: WorkoutType.gym,
          minutes: 601,
          intensity: WorkoutIntensity.light,
        ),
        () => ctrl.save(
          date: DateTime(2026, 11, 26),
          type: WorkoutType.gym,
          minutes: 30,
          intensity: WorkoutIntensity.light,
          notes: 'x' * 121,
        ),
      ]) {
        expect(await _errorOf(call()), isA<ArgumentError>());
      }
      expect(fdb.calls.length, before);
    });

    test(
      'delete: on the server first; refused → the list is unchanged',
      () async {
        final c = await make();
        c.listen(playerWorkoutsProvider, (_, _) {});
        await load(c);
        final ctrl = c.read(playerWorkoutsProvider.notifier);
        fdb.failOn['delete_workout'] = _refusal(
          'P0002',
          'fitness: workout not found',
        );
        expect(
          await _errorOf(ctrl.delete('w-own')),
          isA<FitnessRuleException>(),
        );
        expect(c.read(playerWorkoutsProvider), hasLength(1));
        fdb.failOn.clear();
        await ctrl.delete('w-own');
        expect(
          (fdb.calls.last.fn, fdb.calls.last.params['p_id']),
          ('delete_workout', 'w-own'),
        );
        expect(c.read(playerWorkoutsProvider), isEmpty);
        expect(c.read(playerFitnessProvider)!.trainingSessions, 0);
      },
    );

    test("owner: members' meters from the server; a hidden member is not shared, never 0/10", () async {
      final c = await make();
      await load(c);
      final activity = c.read(memberActivityProvider).value!;
      expect(activity['m-1'], hasLength(2));
      expect(activity.containsKey('m-2'), isFalse);

      final f = c.read(memberFitnessProvider('m-1'))!;
      final expected = FitnessMeter.evaluate(
        activity['m-1']!,
        now: _midday,
        workouts: c.read(memberWorkoutsProvider('m-1')),
      );
      expect(
        (f.score, f.matches, f.trainingSessions, f.oversBowled),
        (expected.score, 2, 1, '8'),
      );

      expect(c.read(memberFitnessProvider('m-2')), isNull);
      expect(c.read(memberFitnessHiddenProvider('m-2')), isTrue);
      expect(c.read(memberFitnessHiddenProvider('m-1')), isFalse);
      expect(
        c.read(memberFitnessHiddenProvider('m-owner')),
        isFalse,
        reason: "the owner's own row",
      );
      expect(c.read(memberFitnessProvider('m-3')), isNull, reason: 'staff');
      expect(
        c.read(memberFitnessProvider('m-owner'))!.score,
        c.read(playerFitnessProvider)!.score,
      );

      // Suggest Team: the hidden member has no fitness entry (counts nothing).
      final pool = c.read(poolFitnessProvider);
      expect(pool.keys, unorderedEquals(['m-owner', 'm-1']));
      expect(pool['m-1']!.score, f.score);
      // Every owner view used the meter window.
      expect(
        {
          for (final x in fdb.calls.where(
            (x) => x.fn.startsWith('club_member'),
          ))
            x.params['p_from'],
        },
        {'2026-11-20'},
      );
    });

    test(
      'owner views refused (not the owner any more): no member fitness at all',
      () async {
        fdb.failOn['club_member_fitness'] = _refusal(
          '42501',
          'fitness: not allowed',
        );
        final c = await make();
        await load(c);
        expect(c.read(memberFitnessProvider('m-1')), isNull);
        expect(c.read(poolFitnessProvider), isEmpty);
        expect(
          c.read(memberFitnessHiddenProvider('m-1')),
          isFalse,
          reason: 'unknown, not "not shared"',
        );
      },
    );

    test("switch OFF: today's behaviour — not recorded, no member activity, the gateway never read", () async {
      final c = await make(fitness: false);
      await c.read(clubMembersProvider.future);
      expect(c.read(fitnessRecordedProvider), isFalse);
      expect(
        c.read(backendModulesProvider).has(BackendModule.playerStats),
        isFalse,
      );
      expect(await c.read(memberActivityProvider.future), isEmpty);
      expect(await c.read(serverWorkoutsProvider.future), isEmpty);
      expect(c.read(playerFitnessProvider), isNull);
      expect(c.read(memberFitnessProvider('m-1')), isNull);
      expect(c.read(poolFitnessProvider), isEmpty);
      expect(c.read(memberFitnessHiddenProvider('m-2')), isFalse);
      expect(c.read(clubRepositoryProvider), isA<SupabaseClubRepository>());
    });

    Future<ProviderContainer> pump(
      WidgetTester tester,
      Widget Function(WidgetRef ref) body,
    ) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = await make();
      await tester.runAsync(() async {
        c.listen(playerWorkoutsProvider, (_, _) {});
        await load(c);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: Consumer(builder: (_, ref, _) => body(ref))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets(
      'Members list: the hidden member shows "Not shared"; sorting puts them last',
      (tester) async {
        final c = await pump(
          tester,
          (ref) => Builder(
            builder: (context) => ListView(
              children: memberListChildren(context, ref, onOpen: (_) {}),
            ),
          ),
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is CeStatusChip && w.label == 'Not shared',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('/10'),
          findsNWidgets(2),
          reason: 'owner and Ali, never a 0/10 for Bilal',
        );
        for (final sort in [MemberSort.fitnessLow, MemberSort.fitnessHigh]) {
          c
              .read(memberFilterProvider.notifier)
              .select(MemberFilter(sort: sort));
          await tester.pumpAndSettle();
          final names = [
            for (final t in tester.widgetList<Text>(find.byType(Text)))
              if (['Omar Owner', 'Ali Khan', 'Bilal Hidden'].contains(t.data))
                t.data,
          ];
          expect(names.last, 'Bilal Hidden', reason: '$sort');
        }
      },
    );

    testWidgets(
      'Member Profile: not shared → a note, no Fitness Meter; shared → the meter',
      (tester) async {
        final c = await pump(
          tester,
          (ref) => Builder(
            builder: (context) =>
                ListView(children: memberProfileChildren(context, ref, bilal)),
          ),
        );
        expect(
          find.byKey(const Key('member.fitnessNotShared')),
          findsOneWidget,
        );
        expect(find.textContaining('/10'), findsNothing);
        expect(c.read(memberFitnessProvider('m-2')), isNull);
      },
    );

    testWidgets(
      'Add Workout sheet: saved on the server, or the refusal shown and the sheet kept',
      (tester) async {
        await pump(
          tester,
          (ref) => Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showAddWorkoutSheet(context),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        Finder save() =>
            find.widgetWithText(InkWell, 'Save Workout').hitTestable();

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('workout.minutes')), '45');
        await tester.pumpAndSettle();
        fdb.failOn['log_workout'] = _refusal(
          'P0001',
          'fitness: too many workouts logged, try later',
        );
        await tester.tap(find.text('Save Workout'));
        await tester.pumpAndSettle();
        expect(find.text(FitnessTexts.perWindow), findsOneWidget);
        expect(
          find.text('Save Workout'),
          findsOneWidget,
          reason: 'the sheet stays open',
        );

        fdb.failOn.clear();
        await tester.tap(find.text('Save Workout'));
        await tester.pumpAndSettle();
        expect(find.text('Workout added'), findsOneWidget);
        final logged = fdb.calls.where((x) => x.fn == 'log_workout').toList();
        expect(logged, hasLength(2));
        expect(logged.last.params, {
          'p_workout_date': '2026-11-26',
          'p_workout_type': 'training',
          'p_minutes': 45,
          'p_intensity': 'moderate',
          'p_notes': null,
        });
        expect(save(), findsNothing);
      },
    );
  });
}

/// `log_workout` parameters for the gateway tests.
abstract final class FitnessRowMapperParams {
  static final sample = FitnessRowMapper.logParams(
    date: DateTime(2026, 11, 26),
    type: WorkoutType.gym,
    minutes: 60,
    intensity: WorkoutIntensity.moderate,
    notes: 'Leg day',
  );
}
