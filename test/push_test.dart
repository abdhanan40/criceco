// M3 P5: push on the device — availability, registration (only after the
// person says yes), the one-time offer from the inbox, "Push on this device",
// and opening a tapped push in the right inbox. Firebase is replaced by a fake
// PushMessaging; the server side is covered by supabase/tests/local/22 / 22b
// and the push-dispatch tests (node --test supabase/functions/push-dispatch/).
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
import 'package:criceco/data/supabase/supabase_gateways.dart';
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
const _token = 'fcm_token_one_aaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class FakePushMessaging implements PushMessaging {
  PushPermission current = PushPermission.notAsked;
  PushPermission answer = PushPermission.granted;
  String? nextToken = _token;
  final calls = <String>[];
  final refreshes = StreamController<String>.broadcast();
  final tapped = StreamController<PushTap>.broadcast();
  final foreground = StreamController<void>.broadcast();
  PushTap? launchedBy;

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
  Future<String?> token() async {
    calls.add('token');
    return nextToken;
  }

  @override
  Stream<String> get tokenRefreshes => refreshes.stream;
  @override
  Stream<PushTap> get taps => tapped.stream;
  @override
  Future<PushTap?> initialTap() async => launchedBy;
  @override
  Stream<void> get foregroundMessages => foreground.stream;

  @override
  Future<void> deleteToken() async => calls.add('deleteToken');
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

class _World {
  final db = FakeNotificationsDb();
  final messaging = FakePushMessaging();
  bool live = true;
  PushConfig config = _config;
  bool android = true;
  Map<String, Object> prefs = {};
  UserRole role = UserRole.player;

  Future<List<Override>> overrides() async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    return [
      sharedPreferencesProvider.overrideWithValue(p),
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
      currentAccountProvider.overrideWith((ref) => ref.watch(_accountProvider)),
      activeRoleProvider.overrideWithValue(role),
    ];
  }

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: await overrides());
    addTearDown(c.dispose);
    return c;
  }

  List<String> fns() => [for (final c in db.calls) c.fn];
}

/// Lets the controller's startup sync (a microtask) and its awaits finish.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

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

  group('registration', () {
    test(
      'off until the person says yes: nothing registered, the offer is due',
      () async {
        final w = _World()..messaging.current = PushPermission.granted;
        final c = await w.container();
        c.read(pushControllerProvider);
        await _settle();
        expect(w.fns(), isNot(contains('register_push_device')));
        expect(c.read(pushControllerProvider.notifier).shouldOffer, isTrue);
      },
    );

    test('"Turn on": the system is asked, the device registered', () async {
      final w = _World();
      final c = await w.container();
      c.read(pushControllerProvider);
      await _settle();
      expect(await c.read(pushControllerProvider.notifier).turnOn(), isTrue);
      expect(w.messaging.calls, contains('requestPermission'));
      expect(w.db.devices, {_token});
      expect(c.read(pushControllerProvider).active, isTrue);
      expect(c.read(pushControllerProvider.notifier).shouldOffer, isFalse);
    });

    test('Android says no: nothing registered, not offered again', () async {
      final w = _World()..messaging.answer = PushPermission.denied;
      final c = await w.container();
      c.read(pushControllerProvider);
      await _settle();
      expect(await c.read(pushControllerProvider.notifier).turnOn(), isFalse);
      expect(w.db.devices, isEmpty);
      expect(c.read(pushControllerProvider.notifier).shouldOffer, isFalse);
    });

    test('"Not now": not offered again, nothing registered', () async {
      final w = _World();
      final c = await w.container();
      c.read(pushControllerProvider);
      await _settle();
      await c.read(pushControllerProvider.notifier).notNow();
      expect(c.read(pushControllerProvider.notifier).shouldOffer, isFalse);
      expect(w.db.devices, isEmpty);
      expect(w.messaging.calls, isNot(contains('requestPermission')));
    });

    test('once on, the next start registers by itself; a new token is registered too', () async {
      final w = _World()
        ..prefs = {
          PushController.enabledKey: true,
          PushController.askedKey: true,
        }
        ..messaging.current = PushPermission.granted;
      final c = await w.container();
      c.read(pushControllerProvider);
      await _settle();
      expect(w.db.devices, {_token});
      w.messaging.refreshes.add('fcm_token_two_bbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      await _settle();
      expect(
        w.db.devices,
        contains('fcm_token_two_bbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      );
      expect(w.fns().where((f) => f == 'register_push_device'), hasLength(2));
    });

    test(
      '"Push on this device" off: unregistered and the token invalidated',
      () async {
        final w = _World()
          ..prefs = {
            PushController.enabledKey: true,
            PushController.askedKey: true,
          }
          ..messaging.current = PushPermission.granted;
        final c = await w.container();
        c.read(pushControllerProvider);
        await _settle();
        await c.read(pushControllerProvider.notifier).turnOff();
        expect(w.db.devices, isEmpty);
        expect(w.messaging.calls, contains('deleteToken'));
        expect(c.read(pushControllerProvider).active, isFalse);
      },
    );

    test(
      'signing out invalidates the token (no call needing the old session)',
      () async {
        final w = _World()
          ..prefs = {
            PushController.enabledKey: true,
            PushController.askedKey: true,
          }
          ..messaging.current = PushPermission.granted;
        final c = await w.container();
        c.listen(pushControllerProvider, (_, _) {});
        await _settle();
        expect(w.db.devices, {_token});
        final before = w.fns().length;
        c.read(_accountProvider.notifier).signOut();
        await _settle();
        expect(w.messaging.calls.last, 'deleteToken');
        expect(w.fns().length, before, reason: 'no server call after sign-out');
      },
    );

    test(
      'a failing registration is quiet (the inbox works without push)',
      () async {
        final w = _World()
          ..prefs = {
            PushController.enabledKey: true,
            PushController.askedKey: true,
          }
          ..messaging.current = PushPermission.granted;
        w.db.failOn['register_push_device'] = const GatewayNetworkException();
        final c = await w.container();
        c.read(pushControllerProvider);
        await _settle();
        expect(c.read(pushControllerProvider).enabled, isTrue);
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
        expect(w.db.devices, {_token});
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
        expect(w.db.devices, {_token});
        expect(
          find.descendant(of: row, matching: find.textContaining('On —')),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: row, matching: find.byType(Switch)),
        );
        await tester.pumpAndSettle();
        expect(w.db.devices, isEmpty);
      },
    );

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
