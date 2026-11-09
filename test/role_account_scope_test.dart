import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// The remembered active role belongs to one account (Step 6 fix): a stale
/// role from an earlier session never sends a new account past Role
/// Selection. Memory mode and Supabase mode (gateway fakes, no network).
void main() {
  const kRole = 'criceco.activeRole';
  const kOwner = 'criceco.activeRole.account';
  const kSaved = 'criceco.session.accountId';
  const seedId = 'acc_aman'; // the demo seed account: a completed Player

  late SharedPreferences prefs;
  late ProviderContainer c;
  late FakeDb db;
  late FakeAuth auth;

  final supabase = BackendConfig.parse(
    backend: 'supabase',
    supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
    supabasePublishableKey: 'sb_publishable_test_0000000000000000',
  );

  setUp(() {
    db = FakeDb();
    auth = FakeAuth(db);
  });

  /// A (re)started app with [saved] preferences. [auth] / [db] model the
  /// server and the SDK's stored session, so they outlive a restart.
  Future<void> start(
    Map<String, Object> saved, {
    bool remote = false,
    bool restore = false,
  }) async {
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (remote) ...[
          backendConfigProvider.overrideWithValue(supabase),
          authGatewayProvider.overrideWithValue(auth),
          profileGatewayProvider.overrideWithValue(db),
        ],
      ],
    );
    addTearDown(c.dispose);
    // As main(): restore first, then the router builds the role state.
    if (restore) await c.read(sessionProvider.notifier).restore();
    c.read(activeRoleProvider);
  }

  /// The preferences as they are now (what the next start would read).
  Map<String, Object> kept() => {
    for (final k in prefs.getKeys()) k: prefs.get(k)!,
  };

  SessionController session() => c.read(sessionProvider.notifier);
  RoleController roles() => c.read(roleControllerProvider.notifier);

  Future<void> signUpNew({bool remote = false}) => session().signUp(
    fullName: '',
    method: remote ? ContactMethod.email : ContactMethod.phone,
    identifier: remote ? 'new@example.com' : '03339876543',
    password: 'Cricket@123',
  );

  Future<void> profileSetup() => session().completeProfile(
    fullName: 'New User',
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

  /// Where User Profile Setup's Continue goes (`_continue`).
  String afterProfileSetup() {
    final role = c.read(activeRoleProvider);
    return role == null ? Routes.roleSelection : Routes.home(role);
  }

  void expectNoStoredRole() {
    expect(prefs.getString(kRole), isNull);
    expect(prefs.getString(kOwner), isNull);
    for (final r in UserRole.values) {
      expect(prefs.getString('criceco.lastRoute.${r.name}'), isNull);
    }
  }

  group('memory mode', () {
    test('1. clean device + new sign-up → Role Selection', () async {
      await start({});
      await signUpNew();
      await profileSetup();
      expect(c.read(roleControllerProvider).active, isNull);
      expect(afterProfileSetup(), Routes.roleSelection);
    });

    test(
      '2. stale Player role of account A + new account B → Role Selection',
      () async {
        await start({
          kRole: 'player',
          kOwner: 'acc_other',
          'criceco.lastRoute.player': Routes.myMatches,
        });
        expect(
          c.read(roleControllerProvider).active,
          isNull,
          reason: 'not applied while signed out',
        );
        expect(
          prefs.getString(kRole),
          'player',
          reason: 'kept until its owner (or someone else) signs in',
        );
        await signUpNew();
        expectNoStoredRole();
        await profileSetup();
        expect(afterProfileSetup(), Routes.roleSelection);
      },
    );

    test('2b. stale role of the demo id + sign-up (memory reuses that id) → Role Selection', () async {
      await start({kRole: 'player', kOwner: seedId});
      await signUpNew(); // a new account, onboarding: never inherits a role
      expectNoStoredRole();
      await profileSetup();
      expect(afterProfileSetup(), Routes.roleSelection);
    });

    test('4. normal logout + new account → Role Selection', () async {
      await start({});
      await session().signIn(identifier: 'x', password: 'y');
      roles().continueAs(UserRole.player);
      session().logout();
      expectNoStoredRole();
      await signUpNew();
      await profileSetup();
      expect(afterProfileSetup(), Routes.roleSelection);
    });

    test(
      '5. the same account restores its chosen role after a restart',
      () async {
        await start({});
        await session().signIn(identifier: 'x', password: 'y');
        roles()
          ..continueAs(UserRole.player)
          ..recordLocation(Routes.myMatches);
        expect(
          (prefs.getString(kRole), prefs.getString(kOwner)),
          ('player', seedId),
        );

        await start(kept(), restore: true);
        expect(c.read(sessionProvider).account!.id, seedId);
        expect(c.read(roleControllerProvider).active, UserRole.player);
        expect(c.read(roleControllerProvider).lastRoute, {
          UserRole.player: Routes.myMatches,
        });
      },
    );

    test('5b. the same account signing back in (no restored session) gets its role', () async {
      // e.g. offline at start: the session wasn't restored, nothing logged out.
      await start({kRole: 'player', kOwner: seedId});
      expect(c.read(roleControllerProvider).active, isNull);
      await session().signIn(identifier: 'x', password: 'y');
      expect(c.read(roleControllerProvider).active, UserRole.player);
    });

    test(
      '6. a different account signing in clears the previous role',
      () async {
        await start({kRole: 'clubOwner', kOwner: 'acc_other'});
        await session().signIn(identifier: 'x', password: 'y'); // acc_aman
        expect(c.read(roleControllerProvider).active, isNull);
        expectNoStoredRole();
        expect(
          c.read(activeRoleProvider),
          UserRole.player,
          reason: 'its own completed Player profile',
        );
      },
    );

    test(
      '6b. signing up while another account is signed in drops its role',
      () async {
        await start({});
        await session().signIn(identifier: 'x', password: 'y');
        roles().continueAs(UserRole.player);
        await signUpNew(); // a different account, without logging out first
        expect(c.read(roleControllerProvider).active, isNull);
        expectNoStoredRole();
        await profileSetup();
        expect(afterProfileSetup(), Routes.roleSelection);
      },
    );

    test('7. the Club Owner role stays with the same account', () async {
      await start({});
      await session().signIn(identifier: 'x', password: 'y');
      await session().createClub(
        name: 'Lahore Lions CC',
        city: 'Lahore',
        type: ClubType.corporate,
      );
      roles().becomeClubOwner();
      expect(
        (prefs.getString(kRole), prefs.getString(kOwner)),
        ('clubOwner', seedId),
      );

      // Account changes (same id) never reset it.
      await session().updateSettings((s) => s.copyWith(loginAlerts: false));
      expect(c.read(activeRoleProvider), UserRole.clubOwner);

      // A restart restores it for this account; whether it applies still
      // depends on the Club Owner profile (unchanged rule, D6 demo data).
      await start(kept(), restore: true);
      expect(c.read(roleControllerProvider).active, UserRole.clubOwner);
    });

    test('8. a legacy role saved without an account is cleared', () async {
      // Signed out at start.
      await start({
        kRole: 'player',
        'criceco.lastRoute.player': Routes.myMatches,
      });
      expectNoStoredRole();
      expect(c.read(roleControllerProvider).active, isNull);

      // A restored session at start: still cleared; inference still works.
      await start({kSaved: seedId, kRole: 'clubOwner'}, restore: true);
      expectNoStoredRole();
      expect(c.read(roleControllerProvider).active, isNull);
      expect(c.read(activeRoleProvider), UserRole.player);
    });
  });

  group('Supabase mode', () {
    test('1. clean device + new sign-up → Role Selection', () async {
      await start({}, remote: true);
      await signUpNew(remote: true);
      await profileSetup();
      expect(afterProfileSetup(), Routes.roleSelection);
    });

    test('3. stale Player role after a failed restore + new sign-up → Role Selection', () async {
      final old = auth.addUser('old@example.com', 'Cricket@123');
      auth.current = old; // the SDK still holds the old stored session
      db.failNext = const GatewayUnexpectedException(
        'auth:400',
      ); // refresh refused
      await start(
        {kSaved: old.id, kRole: 'player', kOwner: old.id},
        remote: true,
        restore: true,
      );
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
      expect(c.read(roleControllerProvider).active, isNull);

      await signUpNew(remote: true);
      expectNoStoredRole();
      await profileSetup();
      expect(
        db.profiles[c.read(currentAccountProvider)!.id]!['role'],
        isNull,
        reason: 'no role written',
      );
      expect(afterProfileSetup(), Routes.roleSelection);
    });

    test('5. the same account restores its role', () async {
      final u = auth.addUser('player@example.com', 'Cricket@123');
      // A role is only ever chosen after Profile Setup.
      db.profiles[u.id] = {
        ...db.profiles[u.id]!,
        'full_name': 'Ali Raza',
        'phone': '+923339876543',
        'date_of_birth': '2000-05-01',
        'profile_completed': true,
      };
      final address = {
        'user_id': u.id,
        'city': 'Karachi',
        'area': 'Clifton',
        'address': 'Street 1',
      };
      db.currentAddresses[u.id] = address;
      db.permanentAddresses[u.id] = Map.of(address);
      auth.current = u;
      await start(
        {kSaved: u.id, kRole: 'player', kOwner: u.id},
        remote: true,
        restore: true,
      );
      expect(c.read(sessionProvider).account!.id, u.id);
      expect(c.read(roleControllerProvider).active, UserRole.player);
    });

    test('6. login with another account clears the previous role', () async {
      final a = auth.addUser('a@example.com', 'Cricket@123');
      auth.addUser('b@example.com', 'Cricket@123');
      await start({kRole: 'player', kOwner: a.id}, remote: true);
      await session().signIn(
        identifier: 'b@example.com',
        password: 'Cricket@123',
      );
      expect(c.read(roleControllerProvider).active, isNull);
      expectNoStoredRole();
      await profileSetup();
      expect(afterProfileSetup(), Routes.roleSelection);
    });

    test(
      'switching from a memory build: a demo-account role never applies',
      () async {
        // Same install, earlier memory-mode run: the demo account chose Player.
        await start(
          {kSaved: seedId, kRole: 'player', kOwner: seedId},
          remote: true,
          restore: true,
        );
        expect(
          c.read(sessionProvider).isAuthenticated,
          isFalse,
          reason: 'no Supabase session for it',
        );
        await signUpNew(remote: true);
        await profileSetup();
        expect(afterProfileSetup(), Routes.roleSelection);
      },
    );
  });
}
