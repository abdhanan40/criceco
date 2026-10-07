import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/domain/fixture_engine.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/validators.dart';
import 'package:criceco/features/booking/booking_controller.dart';
import 'package:criceco/features/challenges/challenges_controller.dart';
import 'package:criceco/features/club/hunt/player_hunt_controller.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/fitness/fitness_providers.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/features/membership/join_club_controller.dart';
import 'package:criceco/shared/widgets/ce_inputs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 23, 10);

Future<ProviderContainer> _owner({bool waitForTeams = true}) async {
  final c = await makeContainer(clock: TestClock(_now));
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  if (waitForTeams) await c.read(teamsProvider.future);
  return c;
}

void main() {
  group('Required fields and names', () {
    test('blank and whitespace-only values are rejected', () {
      for (final v in [null, '', '   ', '\t\n']) {
        expect(CeValidators.required(v, 'Address'), 'Address is required', reason: '"$v"');
        expect(CeValidators.entityName(v, 'Club name'), 'Club name is required', reason: '"$v"');
        expect(CeValidators.personName(v, 'Owner name'), 'Owner name is required', reason: '"$v"');
      }
    });

    test('club / team names need a letter; real names pass', () {
      expect(CeValidators.entityName('123', 'Club name'), 'Enter a valid club name');
      expect(CeValidators.entityName('--', 'Club name'), 'Enter a valid club name');
      for (final n in ['Lahore Lions CC', '1st XI', 'Karachi Kings', 'لاہور کلب']) {
        expect(CeValidators.entityName(n, 'Club name'), isNull, reason: n);
      }
      expect(CeValidators.personName('42', 'Owner name'), 'Enter a valid name');
      expect(CeValidators.personName('Hamza Sheikh', 'Owner name'), isNull);
    });

    test('date of birth: required, never in the future', () {
      expect(CeValidators.dateOfBirth(null, _now), 'Date of birth is required');
      expect(CeValidators.dateOfBirth(DateTime(2026, 9, 24), _now), "Date of birth can't be in the future");
      expect(CeValidators.dateOfBirth(DateTime(2026, 9, 23), _now), isNull, reason: 'today is not the future');
      expect(CeValidators.dateOfBirth(DateTime(2000, 5, 1), _now), isNull);
    });

    test('phone input keeps only supported characters (digits, spaces, + and -)', () {
      TextEditingValue apply(String text) => kPhoneInputFormatters.fold(
            TextEditingValue(text: text),
            (value, f) => f.formatEditUpdate(TextEditingValue.empty, value),
          );
      expect(apply('03ab33-98x76543').text, '0333-9876543');
      expect(apply('+92 333 9876543').text, '+92 333 9876543');
      expect(apply('0333\$%^&9876543').text, '03339876543');
    });

    test('custom overs: 1–50 only', () {
      expect(CeValidators.customOvers(null), 'Please enter the number of overs');
      expect(CeValidators.customOvers(0), 'Enter between 1 and 50 overs');
      expect(CeValidators.customOvers(51), 'Enter between 1 and 50 overs');
      expect(CeValidators.customOvers(1), isNull);
      expect(CeValidators.customOvers(50), isNull);
    });
  });

  group('Teams and squads', () {
    test('duplicate team names are refused ignoring case and repeated spaces', () async {
      final c = await _owner();
      final teams = c.read(teamsProvider.notifier);
      expect(await teams.create(name: '  bs   cs XI ', format: MatchFormat.t20), CreateTeamError.duplicateName);
      expect(await teams.create(name: 'Team  A', format: MatchFormat.t20), isNull);
      expect(c.read(teamsProvider).value!.last.name, 'Team A', reason: 'saved trimmed, one space');
      expect(await teams.create(name: 'team a', format: MatchFormat.odi), CreateTeamError.duplicateName);
    });

    test('the duplicate check waits for the teams to load', () async {
      final c = await _owner(waitForTeams: false);
      // Created before anything awaited teamsProvider: still compared to the real list.
      expect(await c.read(teamsProvider.notifier).create(name: 'BS IT XI', format: MatchFormat.t20),
          CreateTeamError.duplicateName);
    });

    test('name length and custom overs range are enforced in the logic', () async {
      final c = await _owner();
      final teams = c.read(teamsProvider.notifier);
      expect(await teams.create(name: 'X' * 41, format: MatchFormat.t20), CreateTeamError.nameTooLong);
      expect(await teams.create(name: 'Overs Team', format: MatchFormat.custom, customOvers: 0),
          CreateTeamError.oversOutOfRange);
      expect(await teams.create(name: 'Overs Team', format: MatchFormat.custom, customOvers: 51),
          CreateTeamError.oversOutOfRange);
      expect(await teams.create(name: 'Overs Team', format: MatchFormat.custom, customOvers: 50), isNull);
    });

    test('limits, no duplicates, injured players locked — but a picked player who got injured can be removed', () async {
      final c = await _owner();
      final teamId = c.read(teamsProvider).value!.first.id;
      final editor = c.read(squadEditorProvider(teamId).notifier);
      const fit = SquadPlayer(id: 'p_x', name: 'Ali Raza', position: 'Batsman', availability: PlayerAvailability.available);
      expect(editor.assign(fit, SelectionRole.playing), PickOutcome.changed);
      expect(editor.assign(fit, SelectionRole.playing), PickOutcome.changed, reason: 'same player, same slot: no duplicate');
      expect(c.read(squadEditorProvider(teamId)).picks.length, 1);

      // The same player, now injured: can't be (re)added, can be taken out.
      const injured = SquadPlayer(id: 'p_x', name: 'Ali Raza', position: 'Batsman', availability: PlayerAvailability.injured);
      expect(editor.assign(injured, SelectionRole.sub), PickOutcome.locked);
      expect(editor.assign(injured, null), PickOutcome.changed);
      expect(c.read(squadEditorProvider(teamId)).picks.containsKey('p_x'), isFalse);

      // Playing XI limit.
      for (var i = 0; i < SquadRules.maxPlaying; i++) {
        editor.assign(
            SquadPlayer(id: 'p$i', name: 'P$i', position: 'Batsman', availability: PlayerAvailability.available),
            SelectionRole.playing);
      }
      const extra = SquadPlayer(id: 'p_extra', name: 'Extra', position: 'Bowler', availability: PlayerAvailability.available);
      expect(editor.assign(extra, SelectionRole.playing), PickOutcome.full);
    });
  });

  group('Join a club', () {
    test('unknown code, already a member, own club and a pending request are all refused', () async {
      final c = await makeContainer(clock: TestClock(_now));
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      final join = c.read(joinClubProvider.notifier);
      expect(await join.blockReason('NOPE99'), startsWith('No club found with code NOPE99'));
      await c.read(sessionProvider.notifier).addMembership(const ClubMembership(
          clubId: 'club_krc001', clubName: 'Riverside CC', clubCode: 'KRC001', role: MemberRole.player));
      expect(await join.blockReason('krc001'), startsWith('You’re already a member of'));
      await expectLater(join.send('NOPE99'), throwsA(isA<JoinBlockedException>()));
      expect(c.read(joinClubProvider), isNull, reason: 'nothing sent');

      expect(await join.blockReason('35HLWZ'), isNull);
      await join.send('35HLWZ');
      expect(await join.blockReason('35HLWZ'), startsWith('You already have a pending request'));
      await expectLater(join.send('35HLWZ'), throwsA(isA<JoinBlockedException>()), reason: 'no duplicate request');
    });

    test("an owner can't request to join their own club", () async {
      final c = await _owner();
      final code = c.read(currentClubProvider)!.code;
      expect(await c.read(joinClubProvider.notifier).blockReason(code), startsWith('You own'));
    });
  });

  group('Challenges', () {
    test('your own club, a second pending challenge and today / past dates are refused', () async {
      final c = await _owner();
      c.read(demoModeProvider.notifier).set(false); // challenges stay pending
      final ch = c.read(challengesProvider.notifier);
      await c.read(challengesProvider.future);
      final own = c.read(currentClubProvider)!.id;
      await expectLater(ch.send(own), throwsA(isA<ChallengeBlockedException>()));
      expect(ch.blockReason(own), "You can't challenge your own club");

      expect(ch.blockReason('club_kk', proposedAt: DateTime(2026, 9, 23)), CeValidators.matchDateMessage, reason: 'today');
      expect(ch.blockReason('club_kk', proposedAt: DateTime(2026, 9, 20)), CeValidators.matchDateMessage, reason: 'past');
      expect(ch.blockReason('club_kk', proposedAt: DateTime(2026, 9, 24)), isNull, reason: 'tomorrow');

      await ch.send('club_kk', proposedAt: DateTime(2026, 9, 30));
      await expectLater(ch.send('club_kk'), throwsA(isA<ChallengeBlockedException>()), reason: 'already pending');
      expect(ch.blockReason('club_iu'), isNull, reason: 'other clubs are fine');
    });
  });

  group('Booking safety', () {
    Future<(ProviderContainer, BookingsController)> booking() async {
      final c = await _owner();
      await c.read(clubMatchesProvider.future);
      final b = c.read(bookingsProvider.notifier)..start(c.read(clubMatchProvider('m_3'))!);
      b.updateDraft('m_3', (d) => d.copyWith(groundId: 'g_pindi', date: DateTime(2026, 10, 15), slot: TimeSlot.standard[1]));
      return (c, b);
    }

    test('time slots must end after they start', () {
      for (final s in TimeSlot.standard) {
        expect(s.isValid, isTrue, reason: s.label);
      }
      expect(() => TimeSlot(startHour: 10, endHour: 8), throwsA(isA<AssertionError>()));
    });

    test('a paid booking is never re-reserved (no wiped payment) and is never charged twice', () async {
      final (c, b) = await booking();
      await b.reserve('m_3');
      expect(await b.pay('m_3', PaymentMethodType.card), PaymentOutcome.success);
      final paid = c.read(bookingsProvider)['m_3']!.myPayment;
      expect(await b.pay('m_3', PaymentMethodType.card), PaymentOutcome.success, reason: 'idempotent');
      expect(c.read(bookingsProvider)['m_3']!.myPayment!.at, paid!.at, reason: 'not charged again');
      await expectLater(b.reserve('m_3'), throwsA(isA<BookingLockedException>()));
      expect(c.read(bookingsProvider)['m_3']!.myShareSettled, isTrue, reason: 'payment kept');
    });

    test("the club can't hold two matches at the same time (any ground)", () async {
      final (_, b) = await booking();
      await b.reserve('m_3');
      final start = TimeSlot.standard[1].startOn(DateTime(2026, 10, 15));
      expect(b.clubBusyAt('m_other', start), isTrue);
      expect(b.clubBusyAt('m_3', start), isFalse, reason: 'its own booking is not a clash');
      expect(b.clubBusyAt('m_other', TimeSlot.standard[2].startOn(DateTime(2026, 10, 15))), isFalse);
    });
  });

  group('Workouts', () {
    test('no future dates, and minutes between 1 and the maximum', () async {
      final c = await makeContainer(clock: TestClock(_now));
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      final w = c.read(playerWorkoutsProvider.notifier);
      void add(DateTime date, int minutes) =>
          w.add(date: date, type: WorkoutType.training, minutes: minutes, intensity: WorkoutIntensity.moderate);
      expect(() => add(DateTime(2026, 9, 24), 60), throwsArgumentError, reason: 'tomorrow');
      expect(() => add(DateTime(2026, 9, 23), 0), throwsArgumentError);
      expect(() => add(DateTime(2026, 9, 23), WorkoutEntry.maxMinutes + 1), throwsArgumentError);
      expect(c.read(playerWorkoutsProvider), isEmpty);
      add(DateTime(2026, 9, 23), 60);
      add(DateTime(2026, 9, 20), WorkoutEntry.maxMinutes);
      expect(c.read(playerWorkoutsProvider).length, 2);
    });
  });

  group('Player Hunt', () {
    test('the same open requirement is not posted twice', () async {
      final c = await _owner();
      final hunt = c.read(playerHuntProvider.notifier);
      const draft = HuntDraft(role: HuntRole.bowler, playersNeeded: 2);
      expect(await hunt.publish(const HuntDraft()), 'Please select the role you need');
      expect(await hunt.publish(draft), isNull);
      expect(await hunt.publish(draft), 'You already have this requirement posted');
      expect(await hunt.publish(const HuntDraft(role: HuntRole.bowler, playersNeeded: 3)), isNull,
          reason: 'a different requirement is fine');
    });
  });

  group('Tournaments', () {
    test('fixtures never pair a team with itself, and only a team in the fixture can win it', () {
      final rounds = FixtureEngine.generate(TournamentType.league, ['a', 'b', 'c', 'd']);
      final pairs = <String>{};
      for (final r in rounds) {
        for (final m in r.matches) {
          expect(m.home, isNot(m.away));
          expect(pairs.add(([m.home, m.away]..sort()).join('-')), isTrue, reason: 'no duplicate fixture');
        }
      }
      final t = Tournament(
        id: 't',
        name: 'Cup',
        organizerClubId: 'club_sc',
        city: 'Lahore',
        ground: 'Gaddafi',
        format: MatchFormat.t20,
        type: TournamentType.league,
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 9),
        registrationDeadline: DateTime(2026, 9, 28),
        maxTeams: 4,
        status: TournamentStatus.registrationClosed,
        fixtures: rounds,
        standings: FixtureEngine.emptyStandings(['a', 'b', 'c', 'd']),
      );
      expect(identical(FixtureEngine.recordResult(t, 0, 0, 'zz'), t), isTrue, reason: 'unknown winner ignored');
      final first = rounds[0].matches[0];
      expect(FixtureEngine.recordResult(t, 0, 0, first.home!).fixtures![0].matches[0].winnerId, first.home);
    });
  });
}
