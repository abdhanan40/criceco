// M3 P4: notification preferences (migration 26) — the categories (checked
// against the migration itself), the data layer, the controller and the
// Notification settings screen opened from inside the inbox (D8). The SQL is
// verified by supabase/tests/local/21 and 21b on a disposable Postgres.
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/match_row_mapper.dart';
import 'package:criceco/data/supabase/notification_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_notification_repository.dart';
import 'package:criceco/features/notifications/notification_preferences_controller.dart';
import 'package:criceco/features/notifications/notification_settings_screen.dart';
import 'package:criceco/features/notifications/notifications_screen.dart';
import 'package:criceco/features/notifications/notifications_sheet.dart';
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

Future<Object?> errorOf(Future<Object?> call) =>
    call.then<Object?>((_) => null, onError: (Object e) => e);

/// Migration 26's `notification_category`: type code → category code.
Map<String, String> migrationCategories() {
  final sql = File(
    'supabase/migrations/20261122090100_create_notification_preferences.sql',
  ).readAsStringSync();
  final body = RegExp(
    r'function public\.notification_category\(p_type text\)[\s\S]*?\$\$([\s\S]*?)\$\$',
  ).firstMatch(sql)!.group(1)!;
  final out = <String, String>{};
  for (final m in RegExp(
    r"when p_type (?:= '([a-z_]+)'|in \(([^)]*)\)) then '([a-z_]+)'",
  ).allMatches(body)) {
    final codes = m.group(1) != null
        ? [m.group(1)!]
        : [
            for (final c in RegExp(r"'([a-z_]+)'").allMatches(m.group(2)!))
              c.group(1)!,
          ];
    for (final c in codes) {
      out[c] = m.group(3)!;
    }
  }
  return out;
}

const _categoryCodes = {
  'join_requests': NotificationCategory.joinRequests,
  'challenges': NotificationCategory.challenges,
  'matches': NotificationCategory.matches,
  'results': NotificationCategory.results,
  'announcements': NotificationCategory.announcements,
};

class _World {
  final db = FakeNotificationsDb();
  bool live = true;

  Future<List<Override>> overrides() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(
        live ? _supabase : const BackendConfig.memory(),
      ),
      membershipsEnabledProvider.overrideWithValue(true),
      notificationsEnabledProvider.overrideWithValue(live),
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
      currentAccountProvider.overrideWithValue(null),
      activeRoleProvider.overrideWithValue(UserRole.player),
    ];
  }

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: await overrides());
    addTearDown(c.dispose);
    return c;
  }

  List<Map<String, Object?>> saves() => [
    for (final c in db.calls)
      if (c.fn == 'set_notification_preferences') c.params,
  ];
}

Future<_World> _pump(
  WidgetTester tester, {
  String location = Routes.notificationSettings,
  void Function(_World w)? before,
}) async {
  tester.view.physicalSize = const Size(360 * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final w = _World();
  before?.call(w);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => showNotificationsSheet(context, UserRole.player),
            child: const Text('Open panel'),
          ),
        ),
      ),
      GoRoute(
        path: Routes.notifications,
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        path: Routes.notificationSettings,
        builder: (_, _) => const NotificationSettingsScreen(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: await w.overrides(),
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return w;
}

Finder _switchOf(NotificationCategory c) => find.descendant(
  of: find.byKey(Key('notificationSettings.${c.name}')),
  matching: find.byType(Switch),
);

bool _isOn(WidgetTester tester, NotificationCategory c) =>
    tester.widget<Switch>(_switchOf(c)).value;

void main() {
  group('categories', () {
    test('the app sorts every type exactly as migration 26 does', () {
      final server = migrationCategories();
      expect(server, isNotEmpty);
      for (final type in ServerNotificationType.values) {
        final code = NotificationRowMapper.typeCode(type);
        expect(
          NotificationCategory.of(type),
          _categoryCodes[server[code]] ?? NotificationCategory.membership,
          reason: code,
        );
      }
      // Every server category code is one the app knows.
      expect(_categoryCodes.keys.toSet().containsAll(server.values), isTrue);
    });

    test('membership is the one that is always on', () {
      expect(
        [
          for (final c in NotificationCategory.values)
            if (c.alwaysOn) c,
        ],
        [NotificationCategory.membership],
      );
      const p = NotificationPreferences(
        joinRequests: false,
        challenges: false,
        matches: false,
        results: false,
        announcements: false,
      );
      expect(p.isOn(NotificationCategory.membership), isTrue);
      expect(
        p.withCategory(NotificationCategory.membership, false),
        p,
        reason: 'not a setting',
      );
      expect(
        NotificationPreferences.allOn
            .withCategory(NotificationCategory.results, false)
            .isOn(NotificationCategory.results),
        isFalse,
      );
    });
  });

  group('data layer', () {
    test('rows ↔ preferences; a broken row is an error, never a guess', () {
      final p = NotificationRowMapper.preferences({
        'join_requests': true,
        'challenges': false,
        'matches': true,
        'results': false,
        'announcements': true,
        'updated_at': '2026-11-22T12:00:00+00:00',
      });
      expect(p.challenges, isFalse);
      expect(p.results, isFalse);
      expect(p.updatedAt, isNotNull);
      expect(NotificationRowMapper.preferencesParams(p), {
        'p_join_requests': true,
        'p_challenges': false,
        'p_matches': true,
        'p_results': false,
        'p_announcements': true,
      });
      expect(
        () => NotificationRowMapper.preferences({'join_requests': true}),
        throwsA(isA<MatchRowFormatException>()),
      );
    });

    test('the repository loads and saves through the two functions', () async {
      final db = FakeNotificationsDb();
      final repo = SupabaseNotificationPreferencesRepository(db: db);
      expect(await repo.load(), NotificationPreferences.allOn);
      final saved = await repo.save(
        NotificationPreferences.allOn.withCategory(
          NotificationCategory.matches,
          false,
        ),
      );
      expect(saved.matches, isFalse);
      expect(db.calls.map((c) => c.fn), [
        'my_notification_preferences',
        'set_notification_preferences',
      ]);
      db.failOn['my_notification_preferences'] =
          const GatewayConstraintException(
            sqlState: '42501',
            message: 'notification: not authenticated',
          );
      expect(await errorOf(repo.load()), isA<NotSignedInException>());
      db.failOn['set_notification_preferences'] =
          const GatewayNetworkException();
      expect(
        await errorOf(repo.save(NotificationPreferences.allOn)),
        isA<BackendUnavailableException>(),
      );
    });

    test(
      'with the switch → Supabase; without → unavailable, never asked',
      () async {
        final live = await (_World()).container();
        expect(
          live.read(notificationPreferencesRepositoryProvider),
          isA<SupabaseNotificationPreferencesRepository>(),
        );
        final off = _World()..live = false;
        final c = await off.container();
        final r = c.read(notificationPreferencesRepositoryProvider);
        expect(r, isA<UnavailableNotificationPreferencesRepository>());
        expect(await errorOf(r.load()), isA<ModuleUnavailableException>());
        expect(off.db.calls, isEmpty);
      },
    );
  });

  group('controller', () {
    test('a switch changes at once and is saved whole', () async {
      final w = _World();
      final c = await w.container();
      await c.read(notificationPreferencesProvider.future);
      await c
          .read(notificationPreferencesProvider.notifier)
          .set(NotificationCategory.results, false);
      expect(c.read(notificationPreferencesProvider).value!.results, isFalse);
      expect(w.saves().single, {
        'p_join_requests': true,
        'p_challenges': true,
        'p_matches': true,
        'p_results': false,
        'p_announcements': true,
      });
    });

    test(
      'quick taps are saved in order, each with everything chosen so far',
      () async {
        final w = _World();
        final c = await w.container();
        await c.read(notificationPreferencesProvider.future);
        final n = c.read(notificationPreferencesProvider.notifier);
        await Future.wait([
          n.set(NotificationCategory.results, false),
          n.set(NotificationCategory.matches, false),
        ]);
        expect(w.saves(), hasLength(2));
        expect(w.saves().last['p_results'], isFalse);
        expect(w.saves().last['p_matches'], isFalse);
        final now = c.read(notificationPreferencesProvider).value!;
        expect((now.results, now.matches), (false, false));
      },
    );

    test(
      'a refused save puts back what was saved; membership never changes',
      () async {
        final w = _World();
        final c = await w.container();
        await c.read(notificationPreferencesProvider.future);
        final n = c.read(notificationPreferencesProvider.notifier);
        await n.set(NotificationCategory.membership, false);
        expect(w.saves(), isEmpty);
        w.db.failOn['set_notification_preferences'] =
            const GatewayNetworkException();
        await expectLater(
          n.set(NotificationCategory.announcements, false),
          throwsA(isA<BackendUnavailableException>()),
        );
        expect(
          c.read(notificationPreferencesProvider).value!.announcements,
          isTrue,
        );
      },
    );
  });

  group('Notification settings screen', () {
    testWidgets('both groups; membership "Always on"; saved choices shown', (
      tester,
    ) async {
      await _pump(
        tester,
        before: (w) => w.db.preferencesRow = {
          'join_requests': true,
          'challenges': false,
          'matches': true,
          'results': true,
          'announcements': true,
          'updated_at': '2026-11-21T12:00:00+00:00',
        },
      );
      expect(find.text('Notification settings'), findsOneWidget);
      expect(find.text(NotificationSettingsScreen.intro), findsOneWidget);
      expect(find.text('Your notifications'), findsOneWidget);
      expect(find.text('For club owners'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('notificationSettings.membership')),
          matching: find.text('Always on'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('notificationSettings.membership')),
          matching: find.byType(Switch),
        ),
        findsNothing,
      );
      for (final c in NotificationCategory.values) {
        expect(find.text(c.label), findsOneWidget);
      }
      expect(_isOn(tester, NotificationCategory.challenges), isFalse);
      expect(_isOn(tester, NotificationCategory.results), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('turning one off saves it', (tester) async {
      final w = await _pump(tester);
      await tester.tap(_switchOf(NotificationCategory.announcements));
      await tester.pumpAndSettle();
      expect(_isOn(tester, NotificationCategory.announcements), isFalse);
      expect(w.saves().single['p_announcements'], isFalse);
    });

    testWidgets('a refused save says so and the switch goes back', (
      tester,
    ) async {
      await _pump(
        tester,
        before: (w) => w.db.failOn['set_notification_preferences'] =
            const GatewayNetworkException(),
      );
      await tester.tap(_switchOf(NotificationCategory.matches));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('connect', findRichText: true), findsWidgets);
      expect(_isOn(tester, NotificationCategory.matches), isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('a failed load: an error, then Retry', (tester) async {
      final w = await _pump(
        tester,
        before: (w) => w.db.failOn['my_notification_preferences'] =
            const GatewayNetworkException(),
      );
      expect(
        find.text("Couldn't load your notification settings"),
        findsOneWidget,
      );
      w.db.failOn.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('notificationSettings.list')),
        findsOneWidget,
      );
    });

    testWidgets('without the switch: "not available yet", nothing asked', (
      tester,
    ) async {
      final w = await _pump(tester, before: (w) => w.live = false);
      expect(find.text(BackendModules.pendingTitle), findsOneWidget);
      expect(w.db.calls, isEmpty);
    });
  });

  group('opened from inside the inbox (D8)', () {
    testWidgets('the Notifications screen has the entry and opens it', (
      tester,
    ) async {
      await _pump(tester, location: Routes.notifications);
      await tester.tap(find.byKey(const Key('notifications.settings')));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationSettingsScreen), findsOneWidget);
    });

    testWidgets('the panel closes and opens it', (tester) async {
      await _pump(tester, location: '/');
      await tester.tap(find.text('Open panel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notifications.panel.settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notifications.panel')), findsNothing);
      expect(find.byType(NotificationSettingsScreen), findsOneWidget);
    });

    testWidgets('the panel header fits at 320 px with the entry', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320 * 3, 800 * 3);
      await _pump(tester, location: '/');
      tester.view.physicalSize = const Size(320 * 3, 800 * 3);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open panel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('notifications.panel.settings')),
        findsOneWidget,
      );
    });

    testWidgets('the demo inbox has no entry (no server preferences)', (
      tester,
    ) async {
      await _pump(
        tester,
        location: Routes.notifications,
        before: (w) => w.live = false,
      );
      expect(find.byKey(const Key('notifications.settings')), findsNothing);
    });
  });
}
