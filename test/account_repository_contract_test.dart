import 'package:clock/clock.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/validators.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 2, Step 2: the explicit `saveProfileSetup` / `savePlayerProfile`
/// repository contract (in-memory implementation + session wiring).
void main() {
  final today = DateTime(2026, 10, 29, 15, 30);

  late InMemoryAccountRepository repo;
  late UserAccount fresh;

  setUp(() async {
    repo = InMemoryAccountRepository(SeedData(today));
    fresh = await repo.signUp(
      fullName: 'Test User',
      method: ContactMethod.email,
      identifier: 'test@example.com',
      password: 'Cricket@2026',
    );
  });

  UserAccount setup({
    String fullName = 'Test User',
    String? phone = '0300 1234567',
    DateTime? dateOfBirth,
    String? currentCity = 'Lahore',
    String? currentArea = 'Gulberg',
    String? currentAddress = 'House 1, Street 2',
    bool same = true,
    String? permanentCity,
    String? permanentArea,
    String? permanentAddress,
  }) => UserAccount(
    id: fresh.id,
    fullName: fullName,
    contactMethod: fresh.contactMethod,
    email: fresh.email,
    phone: phone,
    dateOfBirth: dateOfBirth ?? DateTime(2000, 5, 1),
    currentCity: currentCity,
    currentArea: currentArea,
    currentAddress: currentAddress,
    isPermanentSameAsCurrent: same,
    permanentCity: same ? currentCity : permanentCity,
    permanentArea: same ? currentArea : permanentArea,
    permanentAddress: same ? currentAddress : permanentAddress,
  );

  Matcher rejected(String message) => throwsA(
    isA<ProfileValidationException>().having(
      (e) => e.message,
      'message',
      message,
    ),
  );

  group('saveProfileSetup', () {
    test(
      'saves the details and both addresses and marks the profile complete',
      () async {
        final saved = await repo.saveProfileSetup(
          setup(
            same: false,
            permanentCity: 'Multan',
            permanentArea: 'Cantt',
            permanentAddress: 'Street 9',
          ),
          at: today,
        );
        expect(saved.profileComplete, isTrue);
        expect(saved.fullName, 'Test User');
        expect(saved.phone, '0300 1234567');
        expect(saved.dateOfBirth, DateTime(2000, 5, 1));
        expect(
          [saved.currentCity, saved.currentArea, saved.currentAddress],
          ['Lahore', 'Gulberg', 'House 1, Street 2'],
        );
        expect(
          [saved.permanentCity, saved.permanentArea, saved.permanentAddress],
          ['Multan', 'Cantt', 'Street 9'],
        );
        final stored = await repo.byId(fresh.id);
        expect(stored!.profileComplete, isTrue);
        expect(stored.permanentCity, 'Multan');
      },
    );

    test('same as current: no separate permanent address is needed', () async {
      final saved = await repo.saveProfileSetup(setup(same: true), at: today);
      expect(saved.isPermanentSameAsCurrent, isTrue);
      expect(saved.profileComplete, isTrue);
    });

    test(
      'a date of birth today is fine; tomorrow is not (as of `at`)',
      () async {
        await repo.saveProfileSetup(
          setup(dateOfBirth: DateTime(2026, 10, 29)),
          at: today,
        );
        expect(
          () => repo.saveProfileSetup(
            setup(dateOfBirth: DateTime(2026, 10, 30)),
            at: today,
          ),
          rejected("Date of birth can't be in the future"),
        );
      },
    );

    test('date of birth: 1900-01-01 is the earliest accepted day', () async {
      final saved = await repo.saveProfileSetup(
        setup(dateOfBirth: DateTime(1900, 1, 1)),
        at: today,
      );
      expect(saved.dateOfBirth, DateTime(1900, 1, 1));
      expect(
        () => repo.saveProfileSetup(
          setup(dateOfBirth: DateTime(1899, 12, 31)),
          at: today,
        ),
        rejected('Date of birth must be in 1900 or later'),
      );
    });

    test('length limits: exactly at the database limit is accepted', () async {
      final saved = await repo.saveProfileSetup(
        setup(
          fullName: 'a' * ProfileRules.nameMaxLength,
          currentArea: 'b' * ProfileRules.areaMaxLength,
          currentAddress: 'c' * ProfileRules.addressMaxLength,
          same: false,
          permanentCity: 'Multan',
          permanentArea: 'd' * ProfileRules.areaMaxLength,
          permanentAddress: 'e' * ProfileRules.addressMaxLength,
        ),
        at: today,
      );
      expect(saved.fullName.length, 100);
      expect(saved.currentArea!.length, 150);
      expect(saved.permanentAddress!.length, 500);
    });

    test('length limits: one character over is refused', () {
      final cases = <UserAccount, String>{
        setup(fullName: 'a' * 101): 'Full name must be at most 100 characters',
        setup(currentArea: 'b' * 151): 'Area must be at most 150 characters',
        setup(currentAddress: 'c' * 501):
            'Address must be at most 500 characters',
        setup(
          same: false,
          permanentCity: 'Multan',
          permanentArea: 'd' * 151,
          permanentAddress: 'Street 9',
        ): 'Area must be at most 150 characters',
        setup(
          same: false,
          permanentCity: 'Multan',
          permanentArea: 'Cantt',
          permanentAddress: 'e' * 501,
        ): 'Address must be at most 500 characters',
      };
      for (final MapEntry(key: account, value: message) in cases.entries) {
        expect(
          () => repo.saveProfileSetup(account, at: today),
          rejected(message),
          reason: message,
        );
      }
    });

    test(
      'length limits count like the database: trimmed, per character',
      () async {
        // Surrounding spaces don't count …
        await repo.saveProfileSetup(
          setup(fullName: '  ${'a' * 100}  '),
          at: today,
        );
        // … and each Urdu letter is one character.
        await repo.saveProfileSetup(
          setup(fullName: 'ع' * 100, currentArea: 'گ' * 150),
          at: today,
        );
        expect(
          () => repo.saveProfileSetup(setup(fullName: 'ع' * 101), at: today),
          rejected('Full name must be at most 100 characters'),
        );
      },
    );

    test('the form limits stay below the database limits', () {
      expect(CeValidators.nameMaxLength, lessThan(ProfileRules.nameMaxLength));
      expect(CeValidators.areaMaxLength, lessThan(ProfileRules.areaMaxLength));
      expect(
        CeValidators.addressMaxLength,
        lessThan(ProfileRules.addressMaxLength),
      );
    });

    test('a save refused for length or date keeps nothing', () async {
      for (final bad in [
        setup(fullName: 'a' * 101),
        setup(currentAddress: 'c' * 501),
        setup(dateOfBirth: DateTime(1899, 12, 31)),
      ]) {
        await expectLater(
          repo.saveProfileSetup(bad, at: today),
          throwsA(isA<ProfileValidationException>()),
        );
      }
      final stored = await repo.byId(fresh.id);
      expect(stored!.profileComplete, isFalse);
      expect(stored.dateOfBirth, isNull);
      expect(stored.currentAddress, isNull);
      expect(stored.fullName, 'Test User'); // the sign-up name, unchanged
    });

    test('each broken rule is refused with the form message', () {
      final cases = <UserAccount, String>{
        setup(fullName: ''): 'Full name is required',
        setup(fullName: 'A'): 'Enter your full name',
        setup(fullName: '123'): 'Enter a valid name',
        setup(phone: null): 'Phone number is required',
        setup(phone: '+1 555 1234567'):
            'Enter a valid mobile number (03XX-XXXXXXX)',
        setup(currentCity: null): 'City is required',
        setup(currentArea: '  '): 'Area is required',
        setup(currentArea: '123'): 'Enter a valid area',
        setup(currentAddress: null): 'Address is required',
        setup(same: false, permanentArea: 'Cantt', permanentAddress: 'St 9'):
            'City is required',
        setup(same: false, permanentCity: 'Multan', permanentAddress: 'St 9'):
            'Area is required',
        setup(same: false, permanentCity: 'Multan', permanentArea: 'Cantt'):
            'Address is required',
      };
      for (final MapEntry(key: account, value: message) in cases.entries) {
        expect(
          () => repo.saveProfileSetup(account, at: today),
          rejected(message),
          reason: message,
        );
      }
    });

    test('a refused save keeps nothing', () async {
      await expectLater(
        repo.saveProfileSetup(setup(phone: 'not a phone'), at: today),
        throwsA(isA<ProfileValidationException>()),
      );
      final stored = await repo.byId(fresh.id);
      expect(stored!.profileComplete, isFalse);
      expect(stored.phone, isNull);
      expect(stored.currentCity, isNull);
    });
  });

  group('savePlayerProfile', () {
    test('saves the player profile on the account', () async {
      const profile = PlayerProfile(
        role: PlayerRole.batsman,
        battingStyle: BattingStyle.rightHanded,
        isWicketkeeper: true,
      );
      final saved = await repo.savePlayerProfile(fresh.id, profile);
      expect(saved.playerProfile.role, PlayerRole.batsman);
      expect(saved.playerProfile.isWicketkeeper, isTrue);
      expect((await repo.byId(fresh.id))!.playerProfile.isComplete, isTrue);
    });

    test('accepts every role with exactly its styles', () async {
      for (final profile in const [
        PlayerProfile(
          role: PlayerRole.batsman,
          battingStyle: BattingStyle.leftHanded,
        ),
        PlayerProfile(
          role: PlayerRole.bowler,
          bowlingStyle: BowlingStyle.leftArmChinaman,
        ),
        PlayerProfile(
          role: PlayerRole.allRounder,
          battingStyle: BattingStyle.rightHanded,
          bowlingStyle: BowlingStyle.rightArmOffSpin,
        ),
      ]) {
        final saved = await repo.savePlayerProfile(fresh.id, profile);
        expect(saved.playerProfile.role, profile.role);
      }
    });

    test('each broken role rule is refused', () {
      final cases = <PlayerProfile, String>{
        const PlayerProfile(): 'Choose your playing role',
        const PlayerProfile(role: PlayerRole.batsman): 'Choose a batting style',
        const PlayerProfile(role: PlayerRole.bowler): 'Choose a bowling style',
        const PlayerProfile(
          role: PlayerRole.allRounder,
          battingStyle: BattingStyle.rightHanded,
        ): 'Choose a bowling style',
        const PlayerProfile(
          role: PlayerRole.bowler,
          battingStyle: BattingStyle.leftHanded,
          bowlingStyle: BowlingStyle.leftArmFast,
        ): "A Bowler doesn't have a batting style",
        const PlayerProfile(
          role: PlayerRole.batsman,
          battingStyle: BattingStyle.rightHanded,
          bowlingStyle: BowlingStyle.rightArmFast,
        ): "A Batsman doesn't have a bowling style",
        const PlayerProfile(
          role: PlayerRole.bowler,
          bowlingStyle: BowlingStyle.rightArmFast,
          isWicketkeeper: true,
        ): 'Only a Batsman can be the wicket keeper',
      };
      for (final MapEntry(key: profile, value: message) in cases.entries) {
        expect(
          () => repo.savePlayerProfile(fresh.id, profile),
          rejected(message),
          reason: message,
        );
      }
    });

    test(
      'a refused save keeps nothing; an unknown account is an error',
      () async {
        await expectLater(
          repo.savePlayerProfile(
            fresh.id,
            const PlayerProfile(role: PlayerRole.bowler),
          ),
          throwsA(isA<ProfileValidationException>()),
        );
        expect((await repo.byId(fresh.id))!.playerProfile.role, isNull);
        expect(
          () => repo.savePlayerProfile(
            'no-such-account',
            const PlayerProfile(
              role: PlayerRole.batsman,
              battingStyle: BattingStyle.rightHanded,
            ),
          ),
          throwsStateError,
        );
      },
    );
  });

  group('session uses the explicit methods', () {
    late _SpyAccounts spy;
    late ProviderContainer c;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      spy = _SpyAccounts(InMemoryAccountRepository(SeedData(today)));
      c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          clockProvider.overrideWith((ref) => Clock(() => today)),
          accountRepositoryProvider.overrideWithValue(spy),
        ],
      );
      addTearDown(c.dispose);
      await c
          .read(sessionProvider.notifier)
          .signUp(
            fullName: 'Hamza Sheikh',
            method: ContactMethod.email,
            identifier: 'hamza@example.com',
            password: 'Cricket@2026',
          );
      spy.calls.clear();
    });

    test(
      'completeProfile saves through saveProfileSetup with the clock date',
      () async {
        await c
            .read(sessionProvider.notifier)
            .completeProfile(
              fullName: 'Hamza Sheikh',
              phone: '0333 9876543',
              dateOfBirth: DateTime(2000, 5, 1),
              currentCity: 'Karachi',
              currentArea: 'Clifton',
              currentAddress: 'Street 1',
              permanentCity: 'Karachi',
              permanentArea: 'Clifton',
              permanentAddress: 'Street 1',
              isPermanentSameAsCurrent: true,
            );
        expect(spy.calls, ['saveProfileSetup']);
        expect(spy.lastAt, today);
        final s = c.read(sessionProvider);
        expect(s.status, SessionStatus.signedIn);
        expect(s.account!.profileComplete, isTrue);
        expect(s.account!.city, 'Karachi'); // syncProfileCity still applies
      },
    );

    test('a refused Profile Setup leaves the session onboarding', () async {
      await expectLater(
        c
            .read(sessionProvider.notifier)
            .completeProfile(
              fullName: 'Hamza Sheikh',
              phone: 'not a phone',
              dateOfBirth: DateTime(2000, 5, 1),
              currentCity: 'Karachi',
              currentArea: 'Clifton',
              currentAddress: 'Street 1',
              permanentCity: 'Karachi',
              permanentArea: 'Clifton',
              permanentAddress: 'Street 1',
              isPermanentSameAsCurrent: true,
            ),
        throwsA(isA<ProfileValidationException>()),
      );
      final s = c.read(sessionProvider);
      expect(s.status, SessionStatus.onboarding);
      expect(s.account!.profileComplete, isFalse);
    });

    test('savePlayerProfile saves through savePlayerProfile', () async {
      await c
          .read(sessionProvider.notifier)
          .savePlayerProfile(
            const PlayerProfile(
              role: PlayerRole.bowler,
              bowlingStyle: BowlingStyle.rightArmMedium,
            ),
          );
      expect(spy.calls, ['savePlayerProfile']);
      expect(
        c.read(sessionProvider).account!.playerProfile.bowlingStyle,
        BowlingStyle.rightArmMedium,
      );
    });
  });
}

/// Records which write methods the session uses; delegates everything.
class _SpyAccounts implements AccountRepository {
  _SpyAccounts(this.inner);
  final AccountRepository inner;
  final calls = <String>[];
  DateTime? lastAt;

  @override
  Future<UserAccount?> signIn({
    required String identifier,
    required String password,
  }) => inner.signIn(identifier: identifier, password: password);
  @override
  Future<UserAccount> signUp({
    required String fullName,
    required ContactMethod method,
    required String identifier,
    required String password,
  }) => inner.signUp(
    fullName: fullName,
    method: method,
    identifier: identifier,
    password: password,
  );
  @override
  Future<UserAccount?> byId(String accountId) => inner.byId(accountId);
  @override
  Future<UserAccount> update(UserAccount account) {
    calls.add('update');
    return inner.update(account);
  }

  @override
  Future<UserAccount> saveProfileSetup(
    UserAccount account, {
    required DateTime at,
  }) {
    calls.add('saveProfileSetup');
    lastAt = at;
    return inner.saveProfileSetup(account, at: at);
  }

  @override
  Future<UserAccount> savePlayerProfile(
    String accountId,
    PlayerProfile profile,
  ) {
    calls.add('savePlayerProfile');
    return inner.savePlayerProfile(accountId, profile);
  }

  @override
  Future<void> signOut() {
    calls.add('signOut');
    return inner.signOut();
  }

  @override
  Future<bool> changePassword(
    String accountId, {
    required String current,
    required String next,
  }) => inner.changePassword(accountId, current: current, next: next);
  @override
  Future<PasswordResetTicket?> requestPasswordReset(
    String identifier, {
    required DateTime at,
  }) => inner.requestPasswordReset(identifier, at: at);
  @override
  Future<ResetCodeCheck> verifyResetCode(
    String identifier,
    String code, {
    required DateTime at,
  }) => inner.verifyResetCode(identifier, code, at: at);
  @override
  Future<ResetCodeCheck> resetPassword(
    String identifier,
    String code,
    String newPassword, {
    required DateTime at,
  }) => inner.resetPassword(identifier, code, newPassword, at: at);
}
