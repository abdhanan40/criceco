import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_account_overlay.dart';
import 'package:criceco/data/supabase/supabase_account_repository.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// Phase 2 Step 3: [SupabaseAccountRepository] against fake gateways — no
/// network, no supabase_flutter.
void main() {
  final today = DateTime(2026, 10, 29, 15, 30);
  const email = 'player@example.com';
  const password = 'Cricket@2026';

  late SharedPreferences prefs;
  late FakeDb db;
  late FakeAuth auth;
  late SupabaseAccountRepository repo;

  SupabaseAccountRepository newRepo() => SupabaseAccountRepository(
    auth: auth,
    db: db,
    overlay: LocalAccountOverlay(prefs),
    clock: Clock(() => today),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    repo = newRepo();
  });

  Future<UserAccount> signedUp({String name = 'Hamza Sheikh'}) => repo.signUp(
    fullName: name,
    method: ContactMethod.email,
    identifier: email,
    password: password,
  );

  UserAccount filledIn(
    UserAccount a, {
    String phone = '0300 1234567',
    bool same = true,
    String? photoPath,
  }) => a.copyWith(
    fullName: a.fullName,
    phone: phone,
    dateOfBirth: DateTime(2000, 5, 1),
    currentCity: 'Lahore',
    currentArea: 'Gulberg',
    currentAddress: 'House 1, Street 2',
    isPermanentSameAsCurrent: same,
    permanentCity: same ? 'Lahore' : 'Multan',
    permanentArea: same ? 'Gulberg' : 'Cantt',
    permanentAddress: same ? 'House 1, Street 2' : 'Street 9',
    hasPhoto: photoPath != null,
    photoPath: photoPath,
  );

  Matcher validation(String message) => throwsA(
    isA<ProfileValidationException>().having(
      (e) => e.message,
      'message',
      message,
    ),
  );

  group('sign-up and sign-in', () {
    test(
      'sign-up keeps the name in Auth metadata (D5) and starts onboarding',
      () async {
        final a = await signedUp();
        expect(auth.calls, ['signUp']);
        expect(auth.current!.metadata, {'full_name': 'Hamza Sheikh'});
        expect(a.fullName, 'Hamza Sheikh'); // from metadata
        expect(a.email, email);
        expect(a.contactMethod, ContactMethod.email);
        expect(a.profileComplete, isFalse);
        expect(
          db.profiles[a.id]!['full_name'],
          isNull,
        ); // saved at Profile Setup
      },
    );

    test(
      'email confirmation required → typed error, nothing signed in',
      () async {
        auth.requireConfirmation = true;
        await expectLater(
          signedUp(),
          throwsA(isA<EmailConfirmationRequiredException>()),
        );
        expect(auth.current, isNull);
      },
    );

    test(
      'phone sign-up / sign-in is refused before any Auth call (D1)',
      () async {
        await expectLater(
          repo.signUp(
            fullName: 'X Y',
            method: ContactMethod.phone,
            identifier: '03001234567',
            password: password,
          ),
          throwsA(isA<UnsupportedSignInMethodException>()),
        );
        await expectLater(
          repo.signIn(identifier: '03001234567', password: password),
          throwsA(isA<UnsupportedSignInMethodException>()),
        );
        expect(auth.calls, isEmpty);
      },
    );

    test(
      'sign-in: wrong password → null; right password → the account',
      () async {
        auth.addUser(email, password, metadata: {'full_name': 'Ali Raza'});
        expect(
          await repo.signIn(identifier: email, password: 'Wrong@2026'),
          isNull,
        );
        final a = await repo.signIn(
          identifier: ' Player@Example.com ',
          password: password,
        );
        expect(a!.fullName, 'Ali Raza');
      },
    );

    test(
      'network failure during sign-up → BackendUnavailableException',
      () async {
        auth.failNext = const GatewayNetworkException();
        await expectLater(
          signedUp(),
          throwsA(isA<BackendUnavailableException>()),
        );
      },
    );
  });

  group('byId', () {
    test('signed out → null, without a database read', () async {
      expect(await repo.byId('user-1'), isNull);
      expect(db.calls, isEmpty);
    });

    test("another user's id → null, without a database read", () async {
      await signedUp();
      db.calls.clear();
      expect(await repo.byId('someone-else'), isNull);
      expect(db.calls, isEmpty);
    });

    test('a legacy row maps as in Phase 1 (03 phone kept, completed without DOB = incomplete)', () async {
      final u = auth.addUser(email, password);
      db.profiles[u.id] = {
        ...FakeDb.freshProfile(u.id),
        'full_name': 'Owner Two',
        'phone': '0312 9020000',
        'role': 'club_owner',
        'profile_completed': true,
      };
      auth.current = u;
      final a = await repo.byId(u.id);
      expect(a!.fullName, 'Owner Two');
      expect(a.phone, '03129020000');
      expect(a.profileComplete, isFalse);
    });
  });

  group('saveProfileSetup', () {
    test(
      'saves through the function: +92 phone, name persisted to profiles (D5)',
      () async {
        final a = await signedUp();
        final saved = await repo.saveProfileSetup(filledIn(a), at: today);
        expect(db.lastSetupParams!['p_phone'], '+923001234567');
        expect(db.lastSetupParams!['p_full_name'], 'Hamza Sheikh');
        expect(db.profiles[a.id]!['full_name'], 'Hamza Sheikh');
        expect(saved.profileComplete, isTrue);
        expect(saved.phone, '03001234567');
        expect(saved.permanentCity, 'Lahore'); // same-as-current copy
      },
    );

    test('a broken profile rule is refused before any database call', () async {
      final a = await signedUp();
      db.calls.clear();
      await expectLater(
        repo.saveProfileSetup(filledIn(a, phone: 'not a phone'), at: today),
        throwsA(isA<ProfileValidationException>()),
      );
      expect(db.calls, isEmpty);
    });

    test('signed out → NotSignedInException; another id → AccountMismatchException; no call', () async {
      final a = await signedUp();
      auth.current = null;
      db.calls.clear();
      await expectLater(
        repo.saveProfileSetup(filledIn(a), at: today),
        throwsA(isA<NotSignedInException>()),
      );
      auth.current = const AuthUser(id: 'someone-else', email: 'x@example.com');
      await expectLater(
        repo.saveProfileSetup(filledIn(a), at: today),
        throwsA(isA<AccountMismatchException>()),
      );
      expect(db.calls, isEmpty);
    });

    test(
      'database refusals become user-facing messages (never the raw text)',
      () async {
        final a = await signedUp();
        final cases = <GatewayException, String>{
          const GatewayConstraintException(
            sqlState: '23514',
            message: 'phone must be a Pakistani mobile number',
          ): 'Enter a valid mobile number (03XX-XXXXXXX)',
          const GatewayConstraintException(
            sqlState: '23514',
            message: 'full_name must be 2–100 characters',
          ): 'Enter your full name (2–100 characters)',
          const GatewayConstraintException(
            sqlState: '23514',
            message: 'date_of_birth cannot be in the future',
          ): "Date of birth can't be in the future",
          const GatewayConstraintException(
            sqlState: '23514',
            message: 'new row for relation "current_addresses" violates check constraint "current_addresses_area_check"',
          ): 'Area is required (up to 150 characters)',
          const GatewayConstraintException(
            sqlState: '23502',
            message: 'null value in column "city"',
          ): 'Please complete all address fields',
          const GatewayConstraintException(
            sqlState: '23514',
            message: 'some new rule',
          ): "Some details aren't valid — please check and try again",
        };
        for (final MapEntry(key: error, value: message) in cases.entries) {
          db.failNext = error;
          await expectLater(
            repo.saveProfileSetup(filledIn(a), at: today),
            validation(message),
            reason: message,
          );
        }
      },
    );

    test(
      'not authenticated / unexpected errors become typed account errors',
      () async {
        final a = await signedUp();
        db.failNext = const GatewayConstraintException(
          sqlState: 'P0001',
          message: 'not authenticated',
        );
        await expectLater(
          repo.saveProfileSetup(filledIn(a), at: today),
          throwsA(isA<NotSignedInException>()),
        );
        db.failNext = const GatewayPermissionException();
        await expectLater(
          repo.saveProfileSetup(filledIn(a), at: today),
          throwsA(isA<NotSignedInException>()),
        );
        db.failNext = const GatewayUnexpectedException('boom');
        await expectLater(
          repo.saveProfileSetup(filledIn(a), at: today),
          throwsA(isA<BackendOperationException>()),
        );
      },
    );

    test('network failure: nothing saved remotely or on the device', () async {
      final a = await signedUp();
      db.failNext = const GatewayNetworkException();
      await expectLater(
        repo.saveProfileSetup(
          filledIn(a, photoPath: '/photos/me.jpg'),
          at: today,
        ),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(db.profiles[a.id]!['profile_completed'], isFalse);
      expect(db.currentAddresses, isEmpty);
      expect(prefs.getString(LocalAccountOverlay.keyFor(a.id)), isNull);
    });

    test('the photo stays on the device (D9)', () async {
      final a = await signedUp();
      final saved = await repo.saveProfileSetup(
        filledIn(a, photoPath: '/photos/me.jpg'),
        at: today,
      );
      expect(saved.photoPath, '/photos/me.jpg');
      expect(db.profiles[a.id]!.containsKey('photo_path'), isFalse);
      // A new repository on the same device (app restart) still has it.
      repo = newRepo();
      expect((await repo.byId(a.id))!.photoPath, '/photos/me.jpg');
    });
  });

  group('savePlayerProfile', () {
    const batsman = PlayerProfile(
      role: PlayerRole.batsman,
      battingStyle: BattingStyle.rightHanded,
    );

    test(
      'upserts the player row and sets profiles.role = player when NULL',
      () async {
        final a = await signedUp();
        final saved = await repo.savePlayerProfile(a.id, batsman);
        expect(db.players[a.id]!['player_role'], 'batsman');
        expect(db.profiles[a.id]!['role'], 'player');
        expect(saved.playerProfile.role, PlayerRole.batsman);
      },
    );

    test('never overwrites club_owner', () async {
      final a = await signedUp();
      db.profiles[a.id]!['role'] = 'club_owner';
      await repo.savePlayerProfile(a.id, batsman);
      expect(db.profiles[a.id]!['role'], 'club_owner');
    });

    test('rule failure / another id → no database call', () async {
      final a = await signedUp();
      db.calls.clear();
      await expectLater(
        repo.savePlayerProfile(
          a.id,
          const PlayerProfile(role: PlayerRole.bowler),
        ),
        validation('Choose a bowling style'),
      );
      await expectLater(
        repo.savePlayerProfile('someone-else', batsman),
        throwsA(isA<AccountMismatchException>()),
      );
      expect(db.calls, isEmpty);
    });

    test('a database role-rule refusal is mapped', () async {
      final a = await signedUp();
      db.failNext = const GatewayConstraintException(
        sqlState: '23514',
        message: 'violates check constraint "player_profiles_wicketkeeper_batsman_only"',
      );
      await expectLater(
        repo.savePlayerProfile(a.id, batsman),
        validation('Only a Batsman can be the wicket keeper'),
      );
    });
  });

  group('update', () {
    Future<UserAccount> completed() async {
      final a = await signedUp();
      return repo.saveProfileSetup(filledIn(a), at: today);
    }

    test('writes only the changed columns; phone stored as +92', () async {
      final a = await completed();
      db.calls.clear();
      await repo.update(a.copyWith(phone: '0333 1112223'));
      expect(db.calls, ['updateProfileColumns', 'fetchAccountRows']);
      expect(db.profiles[a.id]!['phone'], '+923331112223');
      expect(db.profiles[a.id]!['full_name'], 'Hamza Sheikh'); // unchanged
    });

    test('nothing changed remotely → no database call at all', () async {
      final a = await completed();
      db.calls.clear();
      await repo.update(
        a.copyWith(phone: '0300-1234567'),
      ); // same number, other spelling
      expect(db.calls, isEmpty);
    });

    test('City change updates the existing address rows (and the same-as-current copy)', () async {
      final a = await completed();
      final saved = await repo.update(
        a.copyWith(currentCity: 'Karachi', city: 'Karachi'),
      );
      expect(db.currentAddresses[a.id]!['city'], 'Karachi');
      expect(db.permanentAddresses[a.id]!['city'], 'Karachi');
      expect(saved.currentCity, 'Karachi');
    });

    test('no address rows yet → none are created by update', () async {
      final a = await signedUp();
      await repo.update(a.copyWith(currentCity: 'Karachi'));
      expect(db.currentAddresses, isEmpty);
      expect(db.calls.where((c) => c.startsWith('updateAddress')), isEmpty);
    });

    test(
      'a legacy profile without a date of birth can still change its name',
      () async {
        final a = await signedUp();
        final saved = await repo.update(a.copyWith(fullName: 'Hamza Ali'));
        expect(db.profiles[a.id]!['full_name'], 'Hamza Ali');
        expect(saved.fullName, 'Hamza Ali');
      },
    );

    test('an invalid changed value is refused before any write', () async {
      final a = await completed();
      db.calls.clear();
      await expectLater(
        repo.update(a.copyWith(phone: '12345')),
        throwsA(isA<ProfileValidationException>()),
      );
      await expectLater(
        repo.update(a.copyWith(dateOfBirth: DateTime(1899, 12, 31))),
        validation('Date of birth must be in 1900 or later'),
      );
      expect(db.calls, isEmpty);
    });

    test('settings stay on the device (D9); club flags only from the clubs row (3B)', () async {
      final a = await completed();
      // Claiming a Club Owner profile without a club row is not believed:
      // the account is read back from the database.
      final saved = await repo.update(
        a.copyWith(
          settings: a.settings.copyWith(showPhone: true, publicProfile: false),
          hasClubOwnerProfile: true,
          ownedClubId: 'club-1',
        ),
      );
      expect((saved.hasClubOwnerProfile, saved.ownedClubId), (false, null));
      final now = await repo.byId(a.id);
      expect(now!.settings.showPhone, isTrue);
      expect(now.hasClubOwnerProfile, isFalse);
      // Restart: settings survive.
      repo = newRepo();
      final restarted = await repo.byId(a.id);
      expect(restarted!.settings.showPhone, isTrue);
      expect(restarted.settings.publicProfile, isFalse);
      expect(restarted.hasClubOwnerProfile, isFalse);
      expect(restarted.ownedClubId, isNull);
    });

    test('network failure: the device copy is not changed either', () async {
      final a = await completed();
      db.failNext = const GatewayNetworkException();
      await expectLater(
        repo.update(
          a.copyWith(
            fullName: 'New Name',
            settings: a.settings.copyWith(showPhone: true),
          ),
        ),
        throwsA(isA<BackendUnavailableException>()),
      );
      expect(db.profiles[a.id]!['full_name'], 'Hamza Sheikh');
      expect((await repo.byId(a.id))!.settings.showPhone, isFalse);
    });

    test('another id → AccountMismatchException', () async {
      final a = await completed();
      await expectLater(
        repo.update(
          UserAccount(
            id: 'someone-else',
            fullName: a.fullName,
            contactMethod: ContactMethod.email,
          ),
        ),
        throwsA(isA<AccountMismatchException>()),
      );
    });
  });

  group('Club Owner profile from the clubs row (Stage 3B)', () {
    const batsman = PlayerProfile(
      role: PlayerRole.batsman,
      battingStyle: BattingStyle.rightHanded,
    );
    late FakeClubDb clubs;

    setUp(() => clubs = FakeClubDb(db));

    /// User Profile Setup done, then a club through the fake create_club.
    Future<String> clubFor(UserAccount a) async {
      db.completeProfile(a.id);
      final row = await clubs.createClub({
        'p_name': 'Lahore Lions CC',
        'p_city': 'Lahore',
        'p_club_type': 'corporate',
      });
      return row['id'] as String;
    }

    int accountReads() => db.calls.where((c) => c == 'fetchAccountRows').length;

    test('no club → no Club Owner profile', () async {
      final a = await signedUp();
      final read = await repo.byId(a.id);
      expect((read!.hasClubOwnerProfile, read.ownedClubId), (false, null));
    });

    test(
      'a club row → the flags, on sign-in, byId and after a restart',
      () async {
        final a = await signedUp();
        final clubId = await clubFor(a);
        expect(
          (
            (await repo.byId(a.id))!.hasClubOwnerProfile,
            (await repo.byId(a.id))!.ownedClubId,
          ),
          (true, clubId),
        );
        repo = newRepo(); // a new app run
        expect((await repo.byId(a.id))!.ownedClubId, clubId);
        auth.current = null;
        final again = await repo.signIn(identifier: email, password: password);
        expect((again!.hasClubOwnerProfile, again.ownedClubId), (true, clubId));
      },
    );

    test(
      'club creation, then update(flags) re-reads them from the database',
      () async {
        final a = await signedUp();
        final clubId = await clubFor(a);
        final readsBefore = accountReads();
        final saved = await repo.update(
          a.copyWith(hasClubOwnerProfile: true, ownedClubId: clubId),
        );
        expect((saved.hasClubOwnerProfile, saved.ownedClubId), (true, clubId));
        expect(
          accountReads(),
          readsBefore + 1,
          reason: 'read back, not trusted',
        );
      },
    );

    test('unchanged club flags: no extra account read', () async {
      final a = await signedUp();
      final clubId = await clubFor(a);
      final owner = await repo.update(
        a.copyWith(hasClubOwnerProfile: true, ownedClubId: clubId),
      );
      final readsBefore = accountReads();
      await repo.update(
        owner.copyWith(settings: owner.settings.copyWith(loginAlerts: false)),
      );
      expect(accountReads(), readsBefore);
    });

    test('the app writes no role: create_club (its trigger) does — NULL / player / club_owner', () async {
      for (final (start, label) in [
        (null, 'NULL'),
        ('player', 'player'),
        ('club_owner', 'club_owner'),
      ]) {
        db = FakeDb();
        auth = FakeAuth(db);
        clubs = FakeClubDb(db);
        repo = newRepo();
        final a = await signedUp();
        db.profiles[a.id] = {...db.profiles[a.id]!, 'role': start};
        final clubId = await clubFor(a);
        await repo.update(
          a.copyWith(hasClubOwnerProfile: true, ownedClubId: clubId),
        );
        expect(db.profiles[a.id]!['role'], 'club_owner', reason: label);
        expect(
          db.calls.where((c) => c.toLowerCase().contains('role')),
          isEmpty,
          reason: 'no role write from the app ($label)',
        );
      }
    });

    test('a later Player save keeps club_owner and the club', () async {
      final a = await signedUp();
      final clubId = await clubFor(a);
      final saved = await repo.savePlayerProfile(a.id, batsman);
      expect(db.profiles[a.id]!['role'], 'club_owner');
      expect((saved.hasClubOwnerProfile, saved.ownedClubId), (true, clubId));
    });

    test(
      'memberships stay this run\'s; the club flags come from the database',
      () async {
        final a = await signedUp();
        final clubId = await clubFor(a);
        const membership = ClubMembership(
          clubId: 'club_krc',
          clubName: 'Karachi Ravians CC',
          clubCode: 'KRC001',
          role: MemberRole.player,
        );
        await repo.update(
          a.copyWith(
            hasClubOwnerProfile: true,
            ownedClubId: clubId,
            memberships: const [membership],
          ),
        );
        final now = (await repo.byId(a.id))!;
        expect(now.memberships.single.clubCode, 'KRC001');
        expect(now.ownedClubId, clubId);
        repo = newRepo(); // restart: memberships are this run's only (D6)
        final restarted = (await repo.byId(a.id))!;
        expect(restarted.memberships, isEmpty);
        expect(
          (restarted.hasClubOwnerProfile, restarted.ownedClubId),
          (true, clubId),
        );
      },
    );
  });

  test('signOut ends the Auth session; device data survives', () async {
    final a = await signedUp();
    await repo.update(
      a.copyWith(settings: a.settings.copyWith(showStats: false)),
    );
    await repo.signOut();
    expect(auth.current, isNull);
    expect(prefs.getString(LocalAccountOverlay.keyFor(a.id)), isNotNull);
  });

  test('password flows are not supported yet (D13)', () async {
    expect(
      () => repo.changePassword('x', current: 'a', next: 'b'),
      throwsUnsupportedError,
    );
    expect(
      () => repo.requestPasswordReset(email, at: today),
      throwsUnsupportedError,
    );
  });

  group('session in Supabase mode', () {
    late ProviderContainer c;
    late FakeClubDb clubs;

    /// A (re)started app. [db] / [auth] / the clubs table model the server
    /// and the SDK's stored session, so they outlive a restart.
    Future<void> start({Map<String, Object> saved = const {}}) async {
      SharedPreferences.setMockInitialValues(saved);
      prefs = await SharedPreferences.getInstance();
      clubs = db.clubDb ?? FakeClubDb(db);
      c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          clockProvider.overrideWith((ref) => Clock(() => today)),
          backendConfigProvider.overrideWithValue(
            BackendConfig.parse(
              backend: 'supabase',
              supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
              supabasePublishableKey: 'sb_publishable_test_0000000000000000',
            ),
          ),
          authGatewayProvider.overrideWithValue(auth),
          profileGatewayProvider.overrideWithValue(db),
          clubGatewayProvider.overrideWithValue(clubs),
        ],
      );
      addTearDown(c.dispose);
    }

    SessionController session() => c.read(sessionProvider.notifier);

    Future<void> completeProfile() => session().completeProfile(
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

    test('sign-up → onboarding → Profile Setup → signed in', () async {
      await start();
      expect(
        c.read(accountRepositoryProvider),
        isA<SupabaseAccountRepository>(),
      );
      await session().signUp(
        fullName: 'Hamza Sheikh',
        method: ContactMethod.email,
        identifier: email,
        password: password,
      );
      expect(c.read(sessionProvider).status, SessionStatus.onboarding);
      await completeProfile();
      final s = c.read(sessionProvider);
      expect(s.status, SessionStatus.signedIn);
      expect(s.account!.profileComplete, isTrue);
      expect(db.profiles[s.account!.id]!['phone'], '+923339876543');
    });

    test(
      'a network failure during Profile Setup leaves the session onboarding',
      () async {
        await start();
        await session().signUp(
          fullName: 'Hamza Sheikh',
          method: ContactMethod.email,
          identifier: email,
          password: password,
        );
        final before = c.read(sessionProvider).account;
        db.failNext = const GatewayNetworkException();
        await expectLater(
          completeProfile(),
          throwsA(isA<BackendUnavailableException>()),
        );
        final s = c.read(sessionProvider);
        expect(s.status, SessionStatus.onboarding);
        expect(identical(s.account, before), isTrue);
      },
    );

    test('restore: a saved id without an Auth session → signed out', () async {
      final u = auth.addUser(email, password);
      await start(saved: {'criceco.session.accountId': u.id});
      await session().restore();
      expect(c.read(sessionProvider).status, SessionStatus.signedOut);
    });

    test('restore: offline → signed out, nothing cleared, no crash', () async {
      final u = auth.addUser(email, password);
      auth.current = u;
      await start(saved: {'criceco.session.accountId': u.id});
      db.failNext = const GatewayNetworkException();
      await session().restore();
      expect(c.read(sessionProvider).status, SessionStatus.signedOut);
      expect(prefs.getString('criceco.session.accountId'), u.id);
    });

    test('restore: with the Auth session → back into the account', () async {
      final u = auth.addUser(
        email,
        password,
        metadata: {'full_name': 'Ali Raza'},
      );
      auth.current = u;
      await start(saved: {'criceco.session.accountId': u.id});
      await session().restore();
      expect(c.read(sessionProvider).account!.fullName, 'Ali Raza');
    });

    group('restore never stops startup (H1)', () {
      const savedKey = 'criceco.session.accountId';

      /// A saved id with the Auth session of [u] still present.
      Future<AuthUser> savedSession() async {
        final u = auth.addUser(email, password);
        auth.current = u;
        await start(saved: {savedKey: u.id});
        return u;
      }

      /// Signed out, the saved id forgotten, the Auth session ended.
      void expectCleanSignedOut() {
        expect(c.read(sessionProvider).status, SessionStatus.signedOut);
        expect(c.read(sessionProvider).account, isNull);
        expect(prefs.getString(savedKey), isNull);
        expect(auth.calls.last, 'signOut');
        expect(auth.current, isNull);
      }

      test('missing profile row → signed out, id cleared', () async {
        final u = await savedSession();
        db.profiles.remove(u.id);
        await session().restore(); // completes: no exception escapes
        expectCleanSignedOut();
      });

      test('expired / invalid session (401, PGRST301) → signed out', () async {
        await savedSession();
        db.failNext = const GatewayPermissionException();
        await session().restore();
        expectCleanSignedOut();
      });

      test(
        'refresh token refused (unexpected Auth error) → signed out',
        () async {
          await savedSession();
          db.failNext = const GatewayUnexpectedException('auth:400');
          await session().restore();
          expectCleanSignedOut();
        },
      );

      test('malformed profile data → signed out', () async {
        final u = await savedSession();
        db.players[u.id] = {'user_id': u.id, 'player_role': 'captain'};
        await session().restore();
        expectCleanSignedOut();
      });

      test('an RLS refusal (42501) → signed out at start too', () async {
        await savedSession();
        db.failNext = const GatewayConstraintException(
          sqlState: '42501',
          message: 'permission denied for table profiles',
        );
        await session().restore();
        expectCleanSignedOut();
      });

      test('the clean-up sign-out failing too still completes', () async {
        final u = await savedSession();
        db.profiles.remove(u.id);
        // The Auth sign-out after the failed read fails as well (the read
        // itself makes no Auth call, so this hits the sign-out).
        auth.failNext = const GatewayNetworkException();
        await session().restore();
        expect(auth.calls.last, 'signOut');
        expect(c.read(sessionProvider).status, SessionStatus.signedOut);
        expect(prefs.getString(savedKey), isNull);
      });

      test(
        'offline is unchanged: id and Auth session kept for retry',
        () async {
          final u = await savedSession();
          db.failNext = const GatewayNetworkException();
          await session().restore();
          expect(c.read(sessionProvider).status, SessionStatus.signedOut);
          expect(prefs.getString(savedKey), u.id);
          expect(auth.current, isNotNull);
          expect(auth.calls, isNot(contains('signOut')));

          await session().restore(); // back online: the next start restores
          expect(c.read(sessionProvider).account!.id, u.id);
        },
      );
    });

    test('logout offline still signs out locally, no error escapes', () async {
      await start();
      await session().signUp(
        fullName: 'Hamza Sheikh',
        method: ContactMethod.email,
        identifier: email,
        password: password,
      );
      auth.failNext = const GatewayNetworkException();
      session().logout();
      await pumpEventQueue();
      expect(auth.calls.last, 'signOut');
      expect(c.read(sessionProvider).status, SessionStatus.signedOut);
      expect(prefs.getString('criceco.session.accountId'), isNull);
    });

    test('logout ends the Auth session too', () async {
      await start();
      await session().signUp(
        fullName: 'Hamza Sheikh',
        method: ContactMethod.email,
        identifier: email,
        password: password,
      );
      session().logout();
      await pumpEventQueue();
      expect(auth.calls.last, 'signOut');
      expect(auth.current, isNull);
      expect(c.read(sessionProvider).status, SessionStatus.signedOut);
    });

    group('Create Club: the club in Supabase, kept across restarts (3B)', () {
      Future<String> profiled() async {
        await start();
        await session().signUp(
          fullName: 'Hamza Sheikh',
          method: ContactMethod.email,
          identifier: email,
          password: password,
        );
        await completeProfile();
        return c.read(currentAccountProvider)!.id;
      }

      Future<Club> createClub() => session().createClub(
        name: 'Lahore Lions CC',
        city: 'Lahore',
        type: ClubType.corporate,
      );

      test(
        'club created → a clubs row, Club Owner, role saved by create_club',
        () async {
          final uid = await profiled();
          final club = await createClub();
          expect(clubs.clubs[uid]!['id'], club.id);
          expect(club.code, hasLength(6));
          expect(db.profiles[uid]!['role'], 'club_owner');
          final s = c.read(sessionProvider);
          expect(
            (s.hasClubOwnerProfile, s.account!.ownedClubId),
            (true, club.id),
          );
          expect(c.read(currentClubProvider)!.name, 'Lahore Lions CC');
        },
      );

      test('a restart restores the club; so does logout + login', () async {
        final uid = await profiled();
        final club = await createClub();
        final kept = {for (final k in prefs.getKeys()) k: prefs.get(k)!};

        await start(saved: kept); // a new app run, same server + stored session
        await session().restore();
        expect(c.read(sessionProvider).account!.id, uid);
        expect(c.read(sessionProvider).hasClubOwnerProfile, isTrue);
        expect(
          (c.read(currentClubProvider)!.id, c.read(currentClubProvider)!.code),
          (club.id, club.code),
        );

        session().logout();
        await pumpEventQueue();
        expect(c.read(currentClubProvider), isNull);
        await session().signIn(identifier: email, password: password);
        expect(c.read(currentClubProvider)!.name, 'Lahore Lions CC');
      });

      test('offline: not a Club Owner, then a retry succeeds', () async {
        final uid = await profiled();
        clubs.failNext = const GatewayNetworkException();
        await expectLater(
          createClub(),
          throwsA(isA<BackendUnavailableException>()),
        );
        expect(clubs.clubs, isEmpty);
        expect(db.profiles[uid]!['role'], isNull);
        expect(c.read(sessionProvider).hasClubOwnerProfile, isFalse);
        expect(c.read(currentClubProvider), isNull);

        await createClub(); // retry
        expect(db.profiles[uid]!['role'], 'club_owner');
        expect(c.read(sessionProvider).hasClubOwnerProfile, isTrue);
      });

      test('a club owner whose club can\'t load offline at start: the session is kept for retry', () async {
        final uid = await profiled();
        await createClub();
        final kept = {for (final k in prefs.getKeys()) k: prefs.get(k)!};
        await start(saved: kept);
        clubs.failNext = const GatewayNetworkException();
        await session().restore();
        expect(c.read(sessionProvider).isAuthenticated, isFalse);
        expect(
          prefs.getString('criceco.session.accountId'),
          uid,
          reason: 'kept for the next start',
        );
        await session().restore(); // back online
        expect(c.read(currentClubProvider), isNotNull);
      });
    });
  });

  test('memory mode: Create Club makes no Supabase request', () async {
    SharedPreferences.setMockInitialValues({});
    final memoryPrefs = await SharedPreferences.getInstance();
    final clubs = FakeClubDb(db);
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(memoryPrefs),
        // Wired but unused: memory mode must never reach them.
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(clubs),
      ],
    );
    addTearDown(c.dispose);
    final session = c.read(sessionProvider.notifier);
    await session.signIn(identifier: 'x', password: 'y'); // the demo account
    await session.createClub(
      name: 'Lahore Lions CC',
      city: 'Lahore',
      type: ClubType.corporate,
    );
    expect(c.read(sessionProvider).hasClubOwnerProfile, isTrue);
    expect(c.read(clubRepositoryProvider), isA<InMemoryClubRepository>());
    expect(db.calls, isEmpty);
    expect(auth.calls, isEmpty);
    expect(clubs.calls, isEmpty);
  });
}
