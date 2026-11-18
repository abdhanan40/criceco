// Phone-sharing consent and account deletion (docs/ACCOUNT_PRIVACY_AND_DELETION.md)
// on the Supabase account repository over fakes, the gateway's error
// mapping, the build switches and the safe production defaults. No network,
// no database.
import 'package:clock/clock.dart';
import 'package:criceco/app/config/account_privacy.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/config_error_app.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_account_overlay.dart';
import 'package:criceco/data/supabase/supabase_account_repository.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// The server side of phone consent and deletion: one stored flag per user,
/// a password for deletion, and the calls made.
class FakePrivacy implements AccountPrivacyGateway {
  FakePrivacy({this.password = 'Cricket@2026'});
  final String password;
  bool sharing = false;
  bool deleted = false;
  Exception? failDelete;
  final calls = <String>[];

  @override
  Future<bool> fetchPhoneSharing() async {
    calls.add('fetchPhoneSharing');
    return sharing;
  }

  @override
  Future<void> setPhoneSharing(bool share) async {
    calls.add('setPhoneSharing:$share');
    sharing = share;
  }

  @override
  Future<void> deleteAccount({required String password}) async {
    calls.add('deleteAccount');
    if (failDelete != null) throw failDelete!;
    if (password != this.password) throw const GatewayWrongPasswordException();
    deleted = true;
  }
}

void main() {
  final today = DateTime(2026, 11, 18, 10);
  const email = 'player@example.com';
  const password = 'Cricket@2026';

  late SharedPreferences prefs;
  late FakeDb db;
  late FakeAuth auth;
  late FakePrivacy privacy;

  SupabaseAccountRepository repo({bool withPrivacy = true}) => SupabaseAccountRepository(
    auth: auth,
    db: db,
    overlay: LocalAccountOverlay(prefs),
    clock: Clock(() => today),
    privacy: withPrivacy ? privacy : null,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    privacy = FakePrivacy();
  });

  Future<UserAccount> signedUp(SupabaseAccountRepository r) =>
      r.signUp(fullName: 'Hamza Sheikh', method: ContactMethod.email, identifier: email, password: password);

  group('phone sharing consent (server, with the switch)', () {
    test('read from the server; off by default', () async {
      final r = repo();
      final a = await signedUp(r);
      expect(a.settings.showPhone, isFalse);
      expect(privacy.calls, contains('fetchPhoneSharing'));
    });

    test('the server value wins over this device\'s copy', () async {
      final r = repo();
      final a = await signedUp(r);
      // A stale local copy says "shared"; the server says no.
      await LocalAccountOverlay(prefs).save(a.copyWith(settings: a.settings.copyWith(showPhone: true)));
      expect((await r.byId(a.id))!.settings.showPhone, isFalse);
      privacy.sharing = true;
      expect((await r.byId(a.id))!.settings.showPhone, isTrue);
    });

    test('changing the setting sends it once; other changes send nothing', () async {
      final r = repo();
      final a = await signedUp(r);
      privacy.calls.clear();
      final on = await r.update(a.copyWith(settings: a.settings.copyWith(showPhone: true)));
      expect(privacy.calls, ['setPhoneSharing:true']);
      expect(privacy.sharing, isTrue);
      expect(on.settings.showPhone, isTrue);
      privacy.calls.clear();
      await r.update(on.copyWith(settings: on.settings.copyWith(loginAlerts: !on.settings.loginAlerts)));
      expect(privacy.calls, isEmpty, reason: 'the consent didn\'t change');
      await r.update(on.copyWith(settings: on.settings.copyWith(showPhone: false)));
      expect(privacy.calls, ['setPhoneSharing:false']);
      expect(privacy.sharing, isFalse);
    });

    test('without the switch: no server calls, the setting stays on the device', () async {
      final r = repo(withPrivacy: false);
      final a = await signedUp(r);
      await r.update(a.copyWith(settings: a.settings.copyWith(showPhone: true)));
      expect(privacy.calls, isEmpty);
    });
  });

  group('account deletion', () {
    test('wrong password: WrongPasswordException, nothing deleted, still signed in', () async {
      final r = repo();
      final a = await signedUp(r);
      await expectLater(r.deleteAccount(a.id, password: 'nope'), throwsA(isA<WrongPasswordException>()));
      expect(privacy.deleted, isFalse);
      expect(auth.current, isNotNull);
    });

    test('an empty password never reaches the server', () async {
      final r = repo();
      final a = await signedUp(r);
      await expectLater(r.deleteAccount(a.id, password: ''), throwsA(isA<WrongPasswordException>()));
      expect(privacy.calls, isNot(contains('deleteAccount')));
    });

    test('success: deleted on the server, signed out, this device forgets the account', () async {
      final r = repo();
      final a = await signedUp(r);
      await r.update(a.copyWith(settings: a.settings.copyWith(loginAlerts: false)));
      expect(prefs.getString(LocalAccountOverlay.keyFor(a.id)), isNotNull);
      await r.deleteAccount(a.id, password: password);
      expect(privacy.deleted, isTrue);
      expect(auth.current, isNull);
      expect(prefs.getString(LocalAccountOverlay.keyFor(a.id)), isNull);
    });

    test('offline: BackendUnavailableException, nothing forgotten', () async {
      final r = repo();
      final a = await signedUp(r);
      privacy.failDelete = const GatewayNetworkException();
      await expectLater(r.deleteAccount(a.id, password: password), throwsA(isA<BackendUnavailableException>()));
      expect(auth.current, isNotNull);
    });

    test('another account id is refused before any call', () async {
      final r = repo();
      await signedUp(r);
      await expectLater(r.deleteAccount('someone-else', password: password), throwsA(isA<AccountException>()));
      expect(privacy.calls, isNot(contains('deleteAccount')));
    });

    test('without the switch: not available', () async {
      final r = repo(withPrivacy: false);
      final a = await signedUp(r);
      await expectLater(r.deleteAccount(a.id, password: password), throwsA(isA<AccountDeletionUnavailableException>()));
    });

    test('a club owner is refused before any password is sent; nothing deleted', () async {
      final r = repo();
      final a = await signedUp(r);
      FakeClubDb(db).clubs[a.id] = {'id': 'club-1', 'owner_id': a.id, 'name': 'Owner CC'};
      expect((await r.byId(a.id))!.hasClubOwnerProfile, isTrue);
      await expectLater(
        r.deleteAccount(a.id, password: password),
        throwsA(isA<ClubOwnershipTransferRequiredException>()),
      );
      expect(privacy.calls, isNot(contains('deleteAccount')));
      expect(privacy.deleted, isFalse);
      expect(auth.current, isNotNull);
    });

    test('the server refuses an owner (club created elsewhere): the ownership error, still signed in', () async {
      final r = repo();
      final a = await signedUp(r);
      privacy.failDelete = const GatewayOwnershipTransferRequiredException();
      await expectLater(
        r.deleteAccount(a.id, password: password),
        throwsA(isA<ClubOwnershipTransferRequiredException>()),
      );
      expect(auth.current, isNotNull);
    });

    test('incomplete deletion (Auth user not deleted): a clear error, still signed in; a retry completes it', () async {
      final r = repo();
      final a = await signedUp(r);
      privacy.failDelete = const GatewayDeletionIncompleteException();
      await expectLater(r.deleteAccount(a.id, password: password), throwsA(isA<AccountDeletionIncompleteException>()));
      expect(auth.current, isNotNull, reason: 'the user can repeat the request');
      privacy.failDelete = null;
      await r.deleteAccount(a.id, password: password);
      expect(privacy.deleted, isTrue);
      expect(auth.current, isNull);
    });

    test('demo repository: a club owner is refused', () async {
      final demo = InMemoryAccountRepository(SeedData(today));
      final a = (await demo.signIn(identifier: 'x', password: 'secret'))!;
      await demo.update(a.copyWith(hasClubOwnerProfile: true, ownedClubId: 'club_sc'));
      await expectLater(
        demo.deleteAccount(a.id, password: 'secret'),
        throwsA(isA<ClubOwnershipTransferRequiredException>()),
      );
      expect(await demo.byId(a.id), isNotNull);
    });

    test('demo repository: checks the sign-in password, then the account is gone', () async {
      final demo = InMemoryAccountRepository(SeedData(today));
      final a = (await demo.signIn(identifier: 'x', password: 'secret'))!;
      await expectLater(demo.deleteAccount(a.id, password: 'wrong'), throwsA(isA<WrongPasswordException>()));
      await demo.deleteAccount(a.id, password: 'secret');
      expect(await demo.byId(a.id), isNull);
    });
  });

  group('delete-account function errors → gateway errors', () {
    test('403 invalid_password, 401, 429, 5xx, other', () {
      expect(
        SupabaseAccountPrivacyGateway.functionError(403, {'error': 'invalid_password'}),
        isA<GatewayWrongPasswordException>(),
      );
      expect(
        SupabaseAccountPrivacyGateway.functionError(401, {'error': 'not_authenticated'}),
        isA<GatewayPermissionException>(),
      );
      expect(SupabaseAccountPrivacyGateway.functionError(429, null), isA<GatewayRateLimitedException>());
      expect(
        SupabaseAccountPrivacyGateway.functionError(409, {'error': 'CLUB_OWNERSHIP_TRANSFER_REQUIRED', 'clubs': 1}),
        isA<GatewayOwnershipTransferRequiredException>(),
      );
      expect(
        SupabaseAccountPrivacyGateway.functionError(500, {'error': 'auth_delete_failed'}),
        isA<GatewayDeletionIncompleteException>(),
      );
      expect(SupabaseAccountPrivacyGateway.functionError(409, {'error': 'other'}), isA<GatewayUnexpectedException>());
      expect(
        SupabaseAccountPrivacyGateway.functionError(500, {'error': 'delete_failed'}),
        isA<GatewayNetworkException>(),
      );
      expect(
        SupabaseAccountPrivacyGateway.functionError(400, {'error': 'invalid_request'}),
        isA<GatewayUnexpectedException>(),
      );
      expect(
        SupabaseAccountPrivacyGateway.functionError(403, {'error': 'something_else'}),
        isA<GatewayUnexpectedException>(),
      );
    });
  });

  group('build switches', () {
    final supabase = BackendConfig.parse(
      backend: 'supabase',
      supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
      supabasePublishableKey: 'sb_publishable_test_0000000000000000',
    );

    test('account controls: demo, Supabase with and without the switch', () {
      const demo = BackendConfig.memory();
      expect(AccountControls.of(demo, privacy: false).phoneSharing, PhoneSharingMode.device);
      expect(AccountControls.of(demo, privacy: false).canDeleteAccount, isTrue);
      expect(AccountControls.of(supabase, privacy: true).phoneSharing, PhoneSharingMode.server);
      expect(AccountControls.of(supabase, privacy: true).canDeleteAccount, isTrue);
      expect(AccountControls.of(supabase, privacy: false).phoneSharing, PhoneSharingMode.ownersSee);
      expect(AccountControls.of(supabase, privacy: false).canDeleteAccount, isFalse);
    });

    test('demo controls: the define decides; without it, only the memory backend', () {
      const demo = BackendConfig.memory();
      expect(demoControlsFor(demo, defined: false, flag: false), isTrue);
      expect(demoControlsFor(supabase, defined: false, flag: false), isFalse, reason: 'forgotten define');
      expect(demoControlsFor(supabase, defined: true, flag: true), isTrue);
      expect(demoControlsFor(demo, defined: true, flag: false), isFalse);
    });
  });

  group('safe production defaults', () {
    test('a release build must name its backend', () {
      expect(
        () => BackendConfig.parse(backend: '', requireBackend: true),
        throwsA(
          isA<BackendConfigException>().having((e) => e.message, 'message', contains('CRICECO_BACKEND is not set')),
        ),
      );
      expect(
        BackendConfig.parse(backend: 'memory', requireBackend: true).isSupabase,
        isFalse,
        reason: 'an explicit demo build is allowed',
      );
      expect(BackendConfig.parse(backend: '').isSupabase, isFalse, reason: 'debug builds: the demo, as before');
    });

    test('a release Supabase build refuses the demo simulators', () {
      expect(
        () => BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
          supabasePublishableKey: 'sb_publishable_test_0000000000000000',
          requireBackend: true,
          demoControlsRequested: true,
        ),
        throwsA(isA<BackendConfigException>().having((e) => e.message, 'message', contains('CRICECO_DEMO=true'))),
      );
      expect(
        BackendConfig.parse(
          backend: 'supabase',
          supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
          supabasePublishableKey: 'sb_publishable_test_0000000000000000',
          requireBackend: true,
        ).isSupabase,
        isTrue,
      );
    });

    testWidgets('the configuration error screen says what to fix and shows nothing else', (tester) async {
      await tester.pumpWidget(const ConfigurationErrorApp(message: 'CRICECO_BACKEND is not set.'));
      expect(find.text('CricEco can’t start'), findsOneWidget);
      expect(find.text('CRICECO_BACKEND is not set.'), findsOneWidget);
      expect(find.byKey(const Key('configError')), findsOneWidget);
    });
  });
}
