import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/validators.dart';
import 'package:criceco/features/auth/onboarding_controller.dart';
import 'package:criceco/features/booking/booking_controller.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('Match Setup date (from tomorrow on)', () {
    final now = DateTime(2026, 10, 7, 21, 30); // 7 Oct, late evening

    test('today is rejected (any time of day)', () {
      expect(CeValidators.matchDate(DateTime(2026, 10, 7), now), CeValidators.matchDateMessage);
      expect(CeValidators.matchDate(DateTime(2026, 10, 7, 23, 59), now), CeValidators.matchDateMessage);
    });

    test('past dates are rejected', () {
      expect(CeValidators.matchDate(DateTime(2026, 10, 6), now), CeValidators.matchDateMessage);
      expect(CeValidators.matchDate(DateTime(2025, 12, 31), now), CeValidators.matchDateMessage);
    });

    test('tomorrow is the first date accepted', () {
      expect(CeValidators.firstMatchDate(now), DateTime(2026, 10, 8));
      expect(CeValidators.matchDate(DateTime(2026, 10, 8), now), isNull);
      expect(CeValidators.matchDate(DateTime(2026, 10, 8, 6), now), isNull, reason: 'early tomorrow');
    });

    test('future dates are accepted (across month and year ends)', () {
      expect(CeValidators.matchDate(DateTime(2026, 11, 3), now), isNull);
      expect(CeValidators.firstMatchDate(DateTime(2026, 10, 31, 9)), DateTime(2026, 11, 1));
      expect(CeValidators.firstMatchDate(DateTime(2026, 12, 31, 9)), DateTime(2027, 1, 1));
    });

    test('no date is asked for', () => expect(CeValidators.matchDate(null, now), 'Please pick a date'));

    test('logic guard: a draft carrying today cannot be reserved; tomorrow can', () async {
      final clock = TestClock(DateTime(2026, 9, 23, 10));
      final c = await makeContainer(clock: clock);
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      await c.read(clubMatchesProvider.future);
      final bookings = c.read(bookingsProvider.notifier)..start(c.read(clubMatchProvider('m_3'))!);
      bookings.updateDraft(
          'm_3', (d) => d.copyWith(groundId: 'g_pindi', date: DateTime(2026, 9, 23), slot: TimeSlot.standard.last));
      await expectLater(bookings.reserve('m_3'), throwsA(isA<InvalidMatchDateException>()));
      expect(c.read(clubMatchProvider('m_3'))!.status, isNot(MatchStatus.reserved), reason: 'nothing held');

      bookings.updateDraft('m_3', (d) => d.copyWith(date: DateTime(2026, 9, 24), slot: TimeSlot.standard[1]));
      final hold = await bookings.reserve('m_3');
      expect(hold.slotStart, DateTime(2026, 9, 24, 8));
    });
  });

  group('Strong password', () {
    test('too short is rejected', () {
      expect(CeValidators.password('Ab@1xyz'), 'Password must be at least 8 characters');
    });
    test('missing uppercase is rejected', () {
      expect(CeValidators.password('cricket@123'), 'Add an uppercase letter (A–Z)');
    });
    test('missing lowercase is rejected', () {
      expect(CeValidators.password('CRICKET@123'), 'Add a lowercase letter (a–z)');
    });
    test('missing number is rejected', () {
      expect(CeValidators.password('Cricket@abc'), 'Add a number (0–9)');
    });
    test('missing special character is rejected', () {
      expect(CeValidators.password('Cricket123'), r'Add a special character (e.g. @ # ! $)');
      expect(CeValidators.password('Cricket 123'), isNotNull, reason: 'a space is not a special character');
    });
    test('valid mixed passwords are accepted', () {
      for (final p in ['Cricket@123', 'Lahore#2026', 'aB3!efgh', 'Pass-word9', 'Ünïcode_1x']) {
        expect(CeValidators.password(p), isNull, reason: p);
        expect(CeValidators.isStrongPassword(p), isTrue, reason: p);
      }
    });
    test('empty is required', () => expect(CeValidators.password(''), 'Password is required'));
    test('the checklist rules are the same rules, in display order', () {
      expect([for (final r in CeValidators.passwordRules) r.$1],
          ['8+ characters', 'Uppercase letter', 'Lowercase letter', 'Number', 'Special character']);
      final met = [for (final r in CeValidators.passwordRules) r.$3('cricket1')];
      expect(met, [true, false, true, true, false]);
    });
  });

  group('Strong password at the session layer (not only the screens)', () {
    const seedPhone = '0312-9020000';

    test('Sign Up: a weak password is rejected with the validator message; nothing is created', () async {
      final c = await makeContainer(clock: TestClock(DateTime(2026, 9, 23, 10)));
      final s = c.read(sessionProvider.notifier);
      await expectLater(
        s.signUp(fullName: '', method: ContactMethod.phone, identifier: '03331234567', password: 'cricket123'),
        throwsA(isA<WeakPasswordException>()
            .having((e) => e.message, 'message', r'Add an uppercase letter (A–Z)')),
      );
      expect(c.read(sessionProvider).isAuthenticated, isFalse, reason: 'no session started');
      // No account was saved under that number (the demo login accepts any
      // identifier, so look the account up instead).
      expect(await s.requestPasswordReset('03331234567'), isNull, reason: 'no account saved');
    });

    test('Sign Up: a valid strong password is accepted', () async {
      final c = await makeContainer(clock: TestClock(DateTime(2026, 9, 23, 10)));
      final s = c.read(sessionProvider.notifier);
      await s.signUp(fullName: '', method: ContactMethod.phone, identifier: '03331234567', password: 'Cricket@123');
      expect(c.read(sessionProvider).isAuthenticated, isTrue);
      s.logout();
      expect(await s.signIn(identifier: '03331234567', password: 'Cricket@123'), isTrue);
    });

    test('Settings change: a weak new password is rejected and the old one still works', () async {
      final c = await makeContainer(clock: TestClock(DateTime(2026, 9, 23, 10)));
      final s = c.read(sessionProvider.notifier);
      await s.signIn(identifier: 'x', password: 'secret1');
      for (final weak in ['short1!', 'nouppercase1!', 'NOLOWERCASE1!', 'NoNumber!!', 'NoSpecial123']) {
        await expectLater(s.changePassword(current: 'secret1', next: weak), throwsA(isA<WeakPasswordException>()),
            reason: weak);
      }
      expect(c.read(currentAccountProvider)!.settings.passwordChangedAt, isNull, reason: 'nothing changed');
      expect(await s.changePassword(current: 'secret1', next: 'Cricket@123'), isTrue, reason: 'strong is accepted');
      s.logout();
      expect(await s.signIn(identifier: 'x', password: 'Cricket@123'), isTrue);
    });

    test('Forgot / reset: a weak new password is rejected before the code is used', () async {
      final c = await makeContainer(clock: TestClock(DateTime(2026, 9, 23, 10)));
      final s = c.read(sessionProvider.notifier);
      final code = (await s.requestPasswordReset(seedPhone))!.demoCode!;
      await expectLater(s.resetPassword(seedPhone, code, 'weakpass'), throwsA(isA<WeakPasswordException>()));
      // The code is still valid: a strong password then succeeds.
      expect(await s.resetPassword(seedPhone, code, 'Fresh-Start1'), ResetCodeCheck.ok);
      expect(await s.signIn(identifier: seedPhone, password: 'Fresh-Start1'), isTrue);
    });

    test('login is unchanged: an existing non-empty password signs in without strength rules', () async {
      final c = await makeContainer(clock: TestClock(DateTime(2026, 9, 23, 10)));
      final s = c.read(sessionProvider.notifier);
      expect(CeValidators.isStrongPassword('secret1'), isFalse, reason: 'the seed password is not "strong"');
      expect(await s.signIn(identifier: seedPhone, password: 'secret1'), isTrue);
      s.logout();
      expect(await s.signIn(identifier: 'x', password: 'secret1'), isTrue);
    });
  });

  group('Common fields', () {
    test('names: whitespace-only and letterless values are rejected; real names (any script) accepted', () {
      expect(CeValidators.personName('   '), 'Full name is required');
      expect(CeValidators.personName('A'), 'Enter your full name');
      expect(CeValidators.personName('123 45'), 'Enter a valid name');
      for (final n in ['Aman Ali', "Shah O'Neil", 'Muhammad Al-Hassan', 'علی رضا', 'Jo']) {
        expect(CeValidators.personName(n), isNull, reason: n);
      }
    });

    test('phone and email keep their formats', () {
      expect(CeValidators.pkPhone(''), 'Phone number is required');
      expect(CeValidators.pkPhone('0333-98'), 'Enter a valid mobile number (03XX-XXXXXXX)');
      expect(CeValidators.pkPhone('+92 333 9876543'), isNull);
      expect(CeValidators.email('not-an-email'), 'Enter a valid email address');
      expect(CeValidators.email('aman@criceco.pk'), isNull);
    });
  });

  group('Player details follow the playing role', () {
    test('role → shown fields', () {
      expect((PlayerRole.batsman.bats, PlayerRole.batsman.bowls, PlayerRole.batsman.canKeepWicket), (true, false, true));
      expect((PlayerRole.bowler.bats, PlayerRole.bowler.bowls, PlayerRole.bowler.canKeepWicket), (false, true, false));
      expect((PlayerRole.allRounder.bats, PlayerRole.allRounder.bowls, PlayerRole.allRounder.canKeepWicket),
          (true, true, false));
    });

    test('completeness only counts the fields of the role (hidden fields never block)', () {
      expect(const PlayerProfile(role: PlayerRole.batsman, battingStyle: BattingStyle.rightHanded).isComplete, isTrue);
      expect(const PlayerProfile(role: PlayerRole.batsman).isComplete, isFalse);
      expect(const PlayerProfile(role: PlayerRole.bowler, bowlingStyle: BowlingStyle.rightArmFast).isComplete, isTrue);
      expect(const PlayerProfile(role: PlayerRole.bowler, battingStyle: BattingStyle.rightHanded).isComplete, isFalse);
      expect(const PlayerProfile(role: PlayerRole.allRounder, battingStyle: BattingStyle.leftHanded).isComplete, isFalse);
      expect(
          const PlayerProfile(
                  role: PlayerRole.allRounder, battingStyle: BattingStyle.leftHanded, bowlingStyle: BowlingStyle.rightArmOffSpin)
              .isComplete,
          isTrue);
      expect(const PlayerProfile().isComplete, isFalse);
    });

    test('switching roles clears answers that no longer apply; only relevant ones are saved', () async {
      final c = await makeContainer();
      final n = c.read(onboardingProvider.notifier);
      OnboardingDraft d() => c.read(onboardingProvider);

      n.setRole(PlayerRole.batsman);
      n.setBattingStyle(BattingStyle.leftHanded);
      n.setWicketkeeper(true);
      expect((d().missingPlayerDetail, d().isWicketkeeper), (null, true));

      n.setRole(PlayerRole.bowler); // Batsman → Bowler
      expect((d().battingStyle, d().isWicketkeeper, d().missingPlayerDetail), (null, false, 'bowling'));
      n.setWicketkeeper(true);
      expect(d().isWicketkeeper, isFalse, reason: 'wicket keeper is for Batsmen only');
      n.setBowlingStyle(BowlingStyle.rightArmLegSpin);
      expect(d().missingPlayerDetail, isNull);

      n.setRole(PlayerRole.batsman); // Bowler → Batsman
      expect((d().bowlingStyle, d().missingPlayerDetail), (null, 'batting'));
      n.setBattingStyle(BattingStyle.rightHanded);

      n.setRole(PlayerRole.allRounder); // Batsman → All-Rounder keeps batting, needs bowling
      expect((d().battingStyle, d().missingPlayerDetail), (BattingStyle.rightHanded, 'bowling'));
      n.setBowlingStyle(BowlingStyle.rightArmOffSpin);
      final p = d().playerProfile;
      expect((p.role, p.battingStyle, p.bowlingStyle, p.isWicketkeeper, p.isComplete),
          (PlayerRole.allRounder, BattingStyle.rightHanded, BowlingStyle.rightArmOffSpin, false, true));
    });
  });
}
