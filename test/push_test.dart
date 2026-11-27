// M3 P5 / C3 Fix A: push on the device — availability, registration by
// Firebase Installation ID (only after the person says yes), FID rotation,
// failures shown with "Try again", push off and sign-out, the one-time offer
// from the inbox, "Push on this device", and opening a tapped push in the
// right inbox. Firebase is replaced by a fake PushMessaging, and the FID
// bookkeeping (FidRegistration) is tested against streams that behave like
// firebase_messaging's (broadcast, no replay). The server side is covered by
// supabase/tests/local/22 / 22b and the push-dispatch tests
// (node --test supabase/functions/push-dispatch/).
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/config/push_config.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:criceco/features/notifications/notification_settings_screen.dart';
import 'package:criceco/features/notifications/notifications_screen.dart';
import 'package:criceco/features/notifications/push/push_controller.dart';
import 'package:criceco/features/notifications/push/push_messaging.dart';
import 'package:criceco/features/notifications/push/push_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);
const _config = PushConfig(
  apiKey: 'AIza-test',
  appId: '1:123:android:abc',
  senderId: '123',
  projectId: 'criceco-test',
);
// Made-up Firebase Installation IDs (22 characters, like real ones).
const _fid = 'fidOneAaaaaaaaaaaaaaaa';
const _fid2 = 'fidTwoBbbbbbbbbbbbbbbb';

/// FCM on this phone, as PushController sees it.
class FakePushMessaging implements PushMessaging {
  PushPermission current = PushPermission.notAsked;
  PushPermission answer = PushPermission.granted;

  /// The FID FCM gives this installation on register().
  String nextFid = _fid;

  /// register() fails like this while set (e.g. the FID API disabled).
  PushRegistrationFailure? failWith;
  bool unregisterFails = false;

  /// This installation's FCM registration (null: none).
  String? registered;
  final calls = <String>[];
  final rotations = StreamController<String>.broadcast();
  final tapped = StreamController<PushTap>.broadcast();
  final foreground = StreamController<void>.broadcast();
  PushTap? launchedBy;

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<PushPermission> permission() async {
    calls.add('permission');
    return current;
  }

  @override
  Future<PushPermission> requestPermission() async {
    calls.add('requestPermission');
    return current = answer;
  }

  @override
  Future<String> installationId() async {
    calls.add('installationId');
    if (failWith case final f?) throw PushRegistrationException(f);
    return registered ??= nextFid;
  }

  /// FCM hands this installation a new FID.
  void rotate(String fid) {
    registered = fid;
    rotations.add(fid);
  }

  @override
  Stream<String> get installationIds => Stream.multi((c) {
    final sub = rotations.stream.listen(c.add);
    if (registered case final f?) c.add(f);
    c.onCancel = sub.cancel;
  });

  @override
  Stream<PushTap> get taps => tapped.stream;
  @override
  Future<PushTap?> initialTap() async => launchedBy;
  @override
  Stream<void> get foregroundMessages => foreground.stream;

  @override
  Future<void> unregister() async {
    calls.add('unregister');
    if (unregisterFails) {
      throw const PushRegistrationException(PushRegistrationFailure.rejected);
    }
    registered = null;
  }
}

class _Account extends Notifier<UserAccount?> {
  @override
  UserAccount? build() => const UserAccount(
    id: 'user-1',
    fullName: 'Ali Khan',
    contactMethod: ContactMethod.email,
  );
  void signOut() => state = null;
}

final _accountProvider = NotifierProvider<_Account, UserAccount?>(_Account.new);

/// The demo account store, noting what was registered when Auth signed out.
class _Accounts extends InMemoryAccountRepository {
  _Accounts(super.seed, this.db);
  final FakeNotificationsDb db;
  Set<String>? devicesAtSignOut;

  @override
  Future<void> signOut() {
    devicesAtSignOut = {...db.devices};
    return super.signOut();
  }
}

class _World {
  final db = FakeNotificationsDb();
  final messaging = FakePushMessaging();
  bool live = true;
  PushConfig config = _config;
  bool android = true;
  Map<String, Object> prefs = {};
  UserRole role = UserRole.player;

  /// Use the real SessionController (sign in / logout) instead of a fixed
  /// signed-in account.
  bool realSession = false;
  late final accounts = _Accounts(SeedData(DateTime.utc(2026, 11, 22)), db);
  SharedPreferences? _prefs;

  Future<List<Override>> overrides() async {
    if (_prefs == null) {
      SharedPreferences.setMockInitialValues(prefs);
      _prefs = await SharedPreferences.getInstance();
    }
    final seed = SeedData(DateTime.utc(2026, 11, 22));
    return [
      sharedPreferencesProvider.overrideWithValue(_prefs!),
      backendConfigProvider.overrideWithValue(
        live ? _supabase : const BackendConfig.memory(),
      ),
      membershipsEnabledProvider.overrideWithValue(true),
      notificationsEnabledProvider.overrideWithValue(live),
      pushConfigProvider.overrideWithValue(config),
      pushPlatformSupportedProvider.overrideWithValue(android),
      pushMessagingProvider.overrideWithValue(messaging),
      clockProvider.overrideWithValue(
        Clock.fixed(DateTime.utc(2026, 11, 22, 12)),
      ),
      notificationsGatewayProvider.overrideWith(
        (ref) => live
            ? db
            : throw StateError(
                'notifications gateway used with the switch off',
              ),
      ),
      if (realSession) ...[
        accountRepositoryProvider.overrideWithValue(accounts),
        clubRepositoryProvider.overrideWithValue(InMemoryClubRepository(seed)),
      ] else
        currentAccountProvider.overrideWith(
          (ref) => ref.watch(_accountProvider),
        ),
      activeRoleProvider.overrideWithValue(role),
    ];
  }

  /// A new app process on this phone: same saved settings, same FCM.
  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: await overrides());
    addTearDown(c.dispose);
    return c;
  }

  /// Starts a process with push's controller running, and lets it settle.
  Future<ProviderContainer> start() async {
    final c = await container();
    c.listen(pushControllerProvider, (_, _) {});
    await _settle();
    return c;
  }

  List<String> fns() => [for (final c in db.calls) c.fn];
  int count(String fn) => fns().where((f) => f == fn).length;
  List<Object?> unregistered() => [
    for (final c in db.calls)
      if (c.fn == 'unregister_push_device') c.params['p_token'],
  ];
  String? savedFid() => _prefs?.getString(PushController.registeredKey);
}

/// Lets the controller's syncs (microtasks, queued awaits) finish.
Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object> get _on => {
  PushController.enabledKey: true,
  PushController.askedKey: true,
};

Future<_World> _pump(
  WidgetTester tester, {
  String location = Routes.notifications,
  void Function(_World w)? before,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final w = _World();
  before?.call(w);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: Routes.notifications,
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        path: Routes.notificationSettings,
        builder: (_, _) => const NotificationSettingsScreen(),
      ),
      GoRoute(
        path: '/player/matches/:id',
        builder: (_, s) => Text('match ${s.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/club/requests/:id',
        builder: (_, s) => Text('request ${s.pathParameters['id']}'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...await w.overrides(),
        routerProvider.overrideWithValue(router),
      ],
      child: PushRouter(
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return w;
}

/// Streams that behave like firebase_messaging's onRegistered /
/// onUnregistered: broadcast, each FID delivered once, never replayed.
class _Plugin {
  final registered = StreamController<String>.broadcast();
  final unregistered = StreamController<String>.broadcast();
  int registers = 0;
  int unregisters = 0;

  /// What register() does (default: FCM answers with [fid] a moment later).
  Future<void> Function()? onRegister;
  String fid = _fid;
  Object? unregisterError;

  FidRegistration make({Duration timeout = const Duration(seconds: 2)}) =>
      FidRegistration(
        registered: registered.stream,
        unregistered: unregistered.stream,
        fcmRegister: () async {
          registers++;
          if (onRegister case final f?) return f();
          // The plugin's event comes after register() has completed.
          Timer(const Duration(milliseconds: 5), () => registered.add(fid));
        },
        fcmUnregister: () async {
          unregisters++;
          if (unregisterError case final e?) throw e;
          scheduleMicrotask(() => unregistered.add(fid));
        },
        timeout: timeout,
      );
}

void main() {
  group('a tapped push', () {
    test('reads only the dispatcher'
        's data', () {
      final t = PushTap.fromData({
        'notification_id': 'n1',
        'type': 'lineup_selected',
        'inbox': 'player',
        'match_id': 'm1',
        'subject_id': '',
      })!;
      expect(
        (t.notificationId, t.type, t.role, t.matchId, t.subjectId),
        ('n1', 'lineup_selected', UserRole.player, 'm1', null),
      );
      expect(
        PushTap.fromData({
          'notification_id': 'n1',
          'type': 'x',
          'inbox': 'admin',
        }),
        isNull,
      );
      expect(PushTap.fromData({'type': 'x', 'inbox': 'player'}), isNull);
      expect(PushTap.fromData(const {}), isNull);
    });

    test('opens its inbox row'
        's screen, inside its own role; else the inbox', () {
      PushTap tap(
        String type,
        UserRole role, {
        String? match,
        String? subject,
      }) => PushTap(
        notificationId: 'n1',
        type: type,
        role: role,
        matchId: match,
        subjectId: subject,
      );
      expect(
        pushLocation(tap('lineup_selected', UserRole.player, match: 'm1')),
        Routes.playerMatchDetails('m1'),
      );
      expect(
        pushLocation(
          tap('join_request_received', UserRole.clubOwner, subject: 'r1'),
        ),
        Routes.joinRequestProfile('r1'),
      );
      expect(
        pushLocation(tap('result_published', UserRole.clubOwner, match: 'm2')),
        Routes.clubMatchResult('m2'),
      );
      expect(
        pushLocation(tap('announcement', UserRole.player, subject: 'a1')),
        Routes.notifications,
        reason: 'read in place, from the inbox',
      );
      expect(
        pushLocation(tap('tournament_reminder', UserRole.player)),
        Routes.notifications,
      );
    });
  });

  group('availability', () {
    test(
      'only with the server inbox, complete Firebase settings, on Android',
      () async {
        for (final (live, config, android, expected) in [
          (true, _config, true, true),
          (false, _config, true, false),
          (true, PushConfig.none, true, false),
          (true, _config, false, false),
        ]) {
          final w = _World()
            ..live = live
            ..config = config
            ..android = android;
          final c = await w.container();
          expect(
            c.read(pushAvailableProvider),
            expected,
            reason: '$live/${config.isComplete}/$android',
          );
        }
        expect(
          PushConfig.fromEnvironment.isComplete,
          isFalse,
          reason: 'no Firebase settings in a default build',
        );
      },
    );

    test('unavailable: Firebase is never touched', () async {
      final w = _World()..config = PushConfig.none;
      final c = await w.container();
      expect(c.read(pushControllerProvider).available, isFalse);
      await _settle();
      expect(w.messaging.calls, isEmpty);
      expect(c.read(pushControllerProvider.notifier).shouldOffer, isFalse);
    });
  });

  group('the FID as firebase_messaging delivers it (FidRegistration)', () {
    test('startup listener: an FID delivered before anyone asks is kept, not missed', () async {
      final p = _Plugin();
      final fids = p.make();
      // FCM's startup sync arrives before the app asks for the FID.
      p.registered.add(_fid);
      await _settle();
      expect(await fids.installationId(), _fid);
      expect(p.registers, 0, reason: 'already known: no second register()');
    });

    test('initial registration: register(), then the FID event; asked again, the same', () async {
      final p = _Plugin();
      final fids = p.make();
      expect(fids.current, isNull);
      expect(await fids.installationId(), _fid);
      expect(p.registers, 1);
      expect(await fids.installationId(), _fid);
      expect(p.registers, 1);
      expect(fids.current, _fid);
    });

    test('an FID event that comes while register() runs is not lost', () async {
      final p = _Plugin();
      p.onRegister = () async => p.registered.add(_fid);
      final fids = p.make();
      expect(await fids.installationId(), _fid);
    });

    test(
      'FCM refuses (the FID API disabled): a typed error, not silence',
      () async {
        final p = _Plugin();
        p.onRegister = () async =>
            throw Exception('IllegalStateException: API disabled');
        final fids = p.make();
        await expectLater(
          fids.installationId(),
          throwsA(
            isA<PushRegistrationException>().having(
              (e) => e.failure,
              'failure',
              PushRegistrationFailure.rejected,
            ),
          ),
        );
        // Fixed: the next attempt works.
        p.onRegister = null;
        expect(await fids.installationId(), _fid);
      },
    );

    test('no FID in time: timedOut', () async {
      final p = _Plugin();
      p.onRegister = () async {}; // register() completes, no event follows
      final fids = p.make(timeout: const Duration(milliseconds: 20));
      await expectLater(
        fids.installationId(),
        throwsA(
          isA<PushRegistrationException>().having(
            (e) => e.failure,
            'failure',
            PushRegistrationFailure.timedOut,
          ),
        ),
      );
    });

    test(
      'rotation: a listener gets the latest FID first, then each new one',
      () async {
        final p = _Plugin();
        final fids = p.make();
        await fids.installationId();
        final seen = <String>[];
        final sub = fids.ids.listen(seen.add);
        addTearDown(sub.cancel);
        await _settle();
        p.registered.add(_fid2);
        await _settle();
        expect(seen, [_fid, _fid2]);
        expect(fids.current, _fid2);
      },
    );

    test(
      'unregister forgets the FID; the next request registers again',
      () async {
        final p = _Plugin();
        final fids = p.make();
        await fids.installationId();
        await fids.unregister();
        expect(fids.current, isNull);
        expect(p.unregisters, 1);
        p.fid = _fid2;
        expect(await fids.installationId(), _fid2);
        expect(p.registers, 2);
        // FCM ends the current registration by itself (onUnregistered).
        p.unregistered.add(_fid2);
        await _settle();
        expect(fids.current, isNull);
      },
    );

    test(
      'a failing unregister is reported (typed), the FID still forgotten',
      () async {
        final p = _Plugin()..unregisterError = Exception('offline');
        final fids = p.make();
        await fids.installationId();
        await expectLater(
          fids.unregister(),
          throwsA(isA<PushRegistrationException>()),
        );
        expect(fids.current, isNull);
      },
    );
  });

  group('registration', () {
    test(
      'off until the person says yes: nothing registered, the offer is due',
      () async {
        final w = _World()..messaging.current = PushPermission.granted;
        final c = await w.start();
        expect(w.fns(), isNot(contains('register_push_device')));
        expect(w.messaging.calls, isNot(contains('installationId')));
        expect(c.read(pushControllerProvider.notifier).shouldOffer, isTrue);
      },
    );

    test('"Turn on": the system is asked, the FID registered', () async {
      final w = _World();
      final c = await w.start();
      expect(await c.read(pushControllerProvider.notifier).turnOn(), isTrue);
      expect(w.messaging.calls, contains('requestPermission'));
      expect(w.db.devices, {_fid});
      expect(
        w.db.calls.singleWhere((c) => c.fn == 'register_push_device').params,
        {'p_token': _fid, 'p_platform': 'android'},
      );
      expect(w.savedFid(), _fid);
      expect(c.read(pushControllerProvider).active, isTrue);
      expect(c.read(pushControllerProvider).failure, isNull);
      expect(c.read(pushControllerProvider.notifier).shouldOffer, isFalse);
    });

    test('Android says no: nothing registered, not offered again', () async {
      final w = _World()..messaging.answer = PushPermission.denied;
      final c = await w.start();
      expect(await c.read(pushControllerProvider.notifier).turnOn(), isFalse);
      expect(w.db.devices, isEmpty);
      expect(w.messaging.calls, isNot(contains('installationId')));
      expect(c.read(pushControllerProvider.notifier).shouldOffer, isFalse);
    });

    test(
      'permission taken back in Android settings: no registration at start',
      () async {
        final w = _World()
          ..prefs = _on
          ..messaging.current = PushPermission.denied;
        final c = await w.start();
        expect(w.db.devices, isEmpty);
        expect(w.messaging.calls, isNot(contains('installationId')));
        expect(c.read(pushControllerProvider).active, isFalse);
        expect(c.read(pushControllerProvider).failure, isNull);
      },
    );

    test('"Not now": not offered again, nothing registered', () async {
      final w = _World();
      final c = await w.start();
      await c.read(pushControllerProvider.notifier).notNow();
      expect(c.read(pushControllerProvider.notifier).shouldOffer, isFalse);
      expect(w.db.devices, isEmpty);
      expect(w.messaging.calls, isNot(contains('requestPermission')));
    });

    test('repeated registration: each start registers the same FID again (last seen), once', () async {
      final w = _World()
        ..prefs = _on
        ..messaging.current = PushPermission.granted;
      final first = await w.start();
      expect(w.db.devices, {_fid});
      first.dispose();
      await w.start(); // the next app start
      expect(w.db.devices, {_fid});
      expect(w.count('register_push_device'), 2);
      expect(w.count('unregister_push_device'), 0);
    });

    test(
      'rotation while open: the new FID is registered, the old one removed',
      () async {
        final w = _World()
          ..prefs = _on
          ..messaging.current = PushPermission.granted;
        await w.start();
        expect(
          w.count('register_push_device'),
          1,
          reason: 'the replayed FID is not registered twice',
        );
        w.messaging.rotate(_fid2);
        await _settle();
        expect(w.db.devices, {_fid2});
        expect(w.unregistered(), [_fid]);
        expect(w.savedFid(), _fid2);
        expect(w.count('register_push_device'), 2);
      },
    );

    test(
      'rotation while closed: the next start replaces the old FID',
      () async {
        final w = _World()
          ..prefs = _on
          ..messaging.current = PushPermission.granted;
        (await w.start()).dispose();
        w.messaging
          ..registered = null
          ..nextFid = _fid2; // FCM gave a new one meanwhile
        await w.start();
        expect(w.db.devices, {_fid2});
        expect(w.unregistered(), [_fid]);
        expect(w.savedFid(), _fid2);
      },
    );

    test('FCM fails (FID API disabled / no FID in time): shown, not silent; "Try again" registers', () async {
      for (final failure in PushRegistrationFailure.values) {
        final w = _World()
          ..prefs = _on
          ..messaging.current = PushPermission.granted
          ..messaging.failWith = failure;
        final c = await w.start();
        expect(w.db.devices, isEmpty, reason: failure.name);
        expect(c.read(pushControllerProvider).failure, PushFailure.phone);
        expect(c.read(pushControllerProvider).enabled, isTrue);
        w.messaging.failWith = null;
        await c.read(pushControllerProvider.notifier).retry();
        await _settle();
        expect(w.db.devices, {_fid}, reason: failure.name);
        expect(c.read(pushControllerProvider).failure, isNull);
      }
    });

    test('CricEco unreachable: shown as a connection problem; "Try again" registers', () async {
      final w = _World()
        ..prefs = _on
        ..messaging.current = PushPermission.granted;
      w.db.failOn['register_push_device'] = const GatewayNetworkException();
      final c = await w.container();
      c.listen(pushControllerProvider, (_, _) {});
      await _settle();
      expect(c.read(pushControllerProvider).failure, PushFailure.server);
      expect(w.savedFid(), isNull);
      w.db.failOn.clear();
      await c.read(pushControllerProvider.notifier).retry();
      expect(w.db.devices, {_fid});
      expect(c.read(pushControllerProvider).failure, isNull);
    });

    // Migration 30: register_push_device refuses a phone moved between
    // accounts too often (P0001) — the existing server failure, no crash.
    test('too many device moves: shown as the server failure; "Try again" registers', () async {
      final w = _World()
        ..prefs = _on
        ..messaging.current = PushPermission.granted;
      w.db.failOn['register_push_device'] = const GatewayConstraintException(
        sqlState: 'P0001',
        message: 'push: too many device moves',
      );
      final c = await w.container();
      c.listen(pushControllerProvider, (_, _) {});
      await _settle();
      expect(c.read(pushControllerProvider).failure, PushFailure.server);
      expect(c.read(pushControllerProvider).enabled, isTrue);
      expect(w.db.devices, isEmpty);
      w.db.failOn.clear();
      await c.read(pushControllerProvider.notifier).retry();
      expect(w.db.devices, {_fid});
      expect(c.read(pushControllerProvider).failure, isNull);
    });

    test('"Push on this device" off: removed at CricEco and at FCM', () async {
      final w = _World()
        ..prefs = _on
        ..messaging.current = PushPermission.granted;
      final c = await w.start();
      await c.read(pushControllerProvider.notifier).turnOff();
      expect(w.db.devices, isEmpty);
      expect(w.unregistered(), [_fid]);
      expect(w.messaging.calls.last, 'unregister');
      expect(w.messaging.registered, isNull);
      expect(w.savedFid(), isNull);
      expect(c.read(pushControllerProvider).active, isFalse);
      // A later rotation event is not registered any more.
      w.messaging.rotate(_fid2);
      await _settle();
      expect(w.db.devices, isEmpty);
    });

    test('off while CricEco is unreachable: FCM stops it now, the next start removes it', () async {
      final w = _World()
        ..prefs = _on
        ..messaging.current = PushPermission.granted;
      final c = await w.start();
      w.db.failOn['unregister_push_device'] = const GatewayNetworkException();
      await c.read(pushControllerProvider.notifier).turnOff();
      expect(w.messaging.calls.last, 'unregister');
      expect(w.savedFid(), _fid, reason: 'kept to finish the removal');
      c.dispose();
      w.db.failOn.clear();
      await w.start();
      expect(w.db.devices, isEmpty);
      expect(w.savedFid(), isNull);
      expect(w.count('register_push_device'), 1, reason: 'push stays off');
    });

    test('session ended without logout (expired): FCM registration ended, no server call', () async {
      final w = _World()
        ..prefs = _on
        ..messaging.current = PushPermission.granted;
      final c = await w.start();
      expect(w.db.devices, {_fid});
      final before = w.fns().length;
      c.read(_accountProvider.notifier).signOut();
      await _settle();
      expect(w.messaging.calls.last, 'unregister');
      expect(
        w.fns().length,
        before,
        reason: 'no server call without a session',
      );
      expect(w.savedFid(), isNull);
    });

    test(
      'logout: removed at CricEco before the session ends, then at FCM',
      () async {
        final w = _World()
          ..prefs = _on
          ..realSession = true
          ..messaging.current = PushPermission.granted;
        final c = await w.start();
        expect(
          await c
              .read(sessionProvider.notifier)
              .signIn(identifier: 'ali@example.com', password: 'secret123'),
          isTrue,
        );
        await _settle();
        expect(w.db.devices, {_fid});
        c.read(sessionProvider.notifier).logout();
        await _settle();
        expect(w.unregistered(), [_fid]);
        expect(
          w.accounts.devicesAtSignOut,
          isEmpty,
          reason: 'removed while the session still worked',
        );
        expect(w.messaging.calls.last, 'unregister');
        expect(w.savedFid(), isNull);
        expect(c.read(sessionProvider).account, isNull);
      },
    );

    test(
      'logout offline: the session still ends; FCM stops the pushes',
      () async {
        final w = _World()
          ..prefs = _on
          ..realSession = true
          ..messaging.current = PushPermission.granted;
        final c = await w.start();
        await c
            .read(sessionProvider.notifier)
            .signIn(identifier: 'ali@example.com', password: 'secret123');
        await _settle();
        w.db.failOn['unregister_push_device'] = const GatewayNetworkException();
        c.read(sessionProvider.notifier).logout();
        await _settle();
        expect(w.accounts.devicesAtSignOut, {
          _fid,
        }, reason: 'Auth signed out anyway');
        expect(w.messaging.calls.last, 'unregister');
      },
    );

    test(
      'logout, then signing in at once: the new session is kept and registered',
      () async {
        final w = _World()
          ..prefs = _on
          ..realSession = true
          ..messaging.current = PushPermission.granted;
        final c = await w.start();
        final session = c.read(sessionProvider.notifier);
        await session.signIn(
          identifier: 'ali@example.com',
          password: 'secret123',
        );
        await _settle();
        session.logout();
        // No pause: the sign-in waits for the sign-out, which can't end it.
        expect(
          await session.signIn(
            identifier: 'ali@example.com',
            password: 'secret123',
          ),
          isTrue,
        );
        await _settle();
        expect(w.accounts.devicesAtSignOut, isEmpty);
        expect(c.read(sessionProvider).account, isNotNull);
        expect(w.db.devices, {
          _fid,
        }, reason: 'registered again for the new session');
      },
    );

    test(
      'logout without push: no Firebase, the session ends as before',
      () async {
        final w = _World()
          ..config = PushConfig.none
          ..realSession = true;
        final c = await w.start();
        await c
            .read(sessionProvider.notifier)
            .signIn(identifier: 'ali@example.com', password: 'secret123');
        c.read(sessionProvider.notifier).logout();
        await _settle();
        expect(w.accounts.devicesAtSignOut, isEmpty);
        expect(w.messaging.calls, isEmpty);
      },
    );
  });

  group('the offer and the settings switch', () {
    testWidgets(
      'the first inbox opening offers push; "Turn on" registers; never again',
      (tester) async {
        final w = await _pump(tester);
        expect(find.byKey(const Key('push.offer')), findsOneWidget);
        expect(find.text('Get notified on this phone'), findsOneWidget);
        await tester.tap(find.byKey(const Key('push.offer.yes')));
        await tester.pumpAndSettle();
        expect(w.db.devices, {_fid});
        // Back to the inbox later: no offer.
        final router = GoRouter.of(
          tester.element(find.byType(NotificationsScreen)),
        );
        router.go(Routes.notificationSettings);
        await tester.pumpAndSettle();
        router.go(Routes.notifications);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('push.offer')), findsNothing);
      },
    );

    testWidgets('"Not now" registers nothing', (tester) async {
      final w = await _pump(tester);
      await tester.tap(find.byKey(const Key('push.offer.no')));
      await tester.pumpAndSettle();
      expect(w.db.devices, isEmpty);
      expect(w.messaging.calls, isNot(contains('requestPermission')));
    });

    testWidgets('no offer without push in the build', (tester) async {
      await _pump(tester, before: (w) => w.config = PushConfig.none);
      expect(find.byKey(const Key('push.offer')), findsNothing);
    });

    testWidgets(
      'startup: Firebase listens for the FID before anything registers',
      (tester) async {
        final w = await _pump(
          tester,
          before: (w) => w
            ..prefs = _on
            ..messaging.current = PushPermission.granted,
        );
        final calls = w.messaging.calls;
        expect(calls.first, 'start');
        expect(
          calls.indexOf('start'),
          lessThan(calls.indexOf('installationId')),
        );
        expect(w.db.devices, {_fid});
      },
    );

    testWidgets(
      'Notification settings: "Push on this device" turns it on and off',
      (tester) async {
        final w = await _pump(
          tester,
          location: Routes.notificationSettings,
          before: (w) => w.prefs = {PushController.askedKey: true},
        );
        final row = find.byKey(const Key('notificationSettings.push'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: row, matching: find.text('Off')),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: row, matching: find.byType(Switch)),
        );
        await tester.pumpAndSettle();
        expect(w.db.devices, {_fid});
        expect(
          find.descendant(of: row, matching: find.textContaining('On —')),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: row, matching: find.byType(Switch)),
        );
        await tester.pumpAndSettle();
        expect(w.db.devices, isEmpty);
        expect(w.messaging.registered, isNull);
      },
    );

    testWidgets(
      'Notification settings: a failed registration says so, with "Try again"',
      (tester) async {
        final w = await _pump(
          tester,
          location: Routes.notificationSettings,
          before: (w) => w
            ..prefs = _on
            ..messaging.current = PushPermission.granted
            ..messaging.failWith = PushRegistrationFailure.rejected,
        );
        final row = find.byKey(const Key('notificationSettings.push'));
        final retry = find.byKey(const Key('notificationSettings.push.retry'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: row,
            matching: find.text(pushFailureText(PushFailure.phone)),
          ),
          findsOneWidget,
        );
        expect(retry, findsOneWidget);
        expect(w.db.devices, isEmpty);
        // Still failing: still shown.
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(retry, findsOneWidget);
        // Fixed: "Try again" registers and the message goes away.
        w.messaging.failWith = null;
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(w.db.devices, {_fid});
        expect(retry, findsNothing);
        expect(
          find.descendant(of: row, matching: find.textContaining('On —')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Notification settings: CricEco unreachable is told apart', (
      tester,
    ) async {
      await _pump(
        tester,
        location: Routes.notificationSettings,
        before: (w) {
          w
            ..prefs = _on
            ..messaging.current = PushPermission.granted;
          w.db.failOn['register_push_device'] = const GatewayNetworkException();
        },
      );
      await tester.ensureVisible(
        find.byKey(const Key('notificationSettings.push')),
      );
      await tester.pumpAndSettle();
      expect(find.text(pushFailureText(PushFailure.server)), findsOneWidget);
      expect(
        find.byKey(const Key('notificationSettings.push.retry')),
        findsOneWidget,
      );
    });

    testWidgets('the switch is not shown without push in the build', (
      tester,
    ) async {
      await _pump(
        tester,
        location: Routes.notificationSettings,
        before: (w) => w.config = PushConfig.none,
      );
      expect(find.byKey(const Key('notificationSettings.push')), findsNothing);
    });
  });

  group('tapped pushes and pushes while the app is open', () {
    testWidgets('a tap opens the screen and marks the notification read', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        before: (w) => w.prefs = {PushController.askedKey: true},
      );
      w.messaging.tapped.add(
        const PushTap(
          notificationId: 'n-tap',
          type: 'lineup_selected',
          role: UserRole.player,
          matchId: 'm7',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('match m7'), findsOneWidget);
      expect(
        w.db.calls
            .where((c) => c.fn == 'mark_notifications_read')
            .single
            .params,
        {
          'p_ids': ['n-tap'],
        },
      );
    });

    testWidgets('the push that launched the app opens too', (tester) async {
      await _pump(
        tester,
        before: (w) {
          w.prefs = {PushController.askedKey: true};
          w.messaging.launchedBy = const PushTap(
            notificationId: 'n-launch',
            type: 'join_request_received',
            role: UserRole.player,
            subjectId: 'r9',
          );
        },
      );
      // A Club Owner type in the Player inbox can't open an owner screen.
      expect(find.byType(NotificationsScreen), findsOneWidget);
    });

    testWidgets(
      'a launch tap delivered twice (cold start, as on the Vivo) is opened once',
      (tester) async {
        const tap = PushTap(
          notificationId: 'n-twice',
          type: 'lineup_selected',
          role: UserRole.player,
          matchId: 'm9',
        );
        final w = await _pump(
          tester,
          before: (w) {
            w.prefs = {PushController.askedKey: true};
            w.messaging.launchedBy = tap;
          },
        );
        // The same tap again, as onMessageOpenedApp also delivers it.
        w.messaging.tapped.add(tap);
        await tester.pumpAndSettle();
        expect(find.text('match m9'), findsOneWidget);
        expect(
          w.db.calls.where((c) => c.fn == 'mark_notifications_read'),
          hasLength(1),
        );
      },
    );

    testWidgets('a push while the app is open refreshes the inbox', (
      tester,
    ) async {
      final w = await _pump(
        tester,
        before: (w) => w.prefs = {PushController.askedKey: true},
      );
      final before = w.db.calls.where((c) => c.fn == 'my_notifications').length;
      w.messaging.foreground.add(null);
      await tester.pumpAndSettle();
      expect(
        w.db.calls.where((c) => c.fn == 'my_notifications').length,
        before + 1,
      );
    });
  });
}
