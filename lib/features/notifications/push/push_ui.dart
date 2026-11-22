import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config/push_config.dart';
import '../../../app/providers/core_providers.dart';
import '../../../app/router/app_router.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/role_controller.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../data/supabase/notification_row_mapper.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../notifications_controller.dart';
import '../server_inbox_controller.dart';
import '../server_notification_adapter.dart';
import 'push_controller.dart';
import 'push_messaging.dart';

/// The one-time offer, when the inbox first opens (M3 P5): what push is,
/// then Android's own question. Nothing is asked again after an answer;
/// Notification settings can still turn it on or off.
Future<void> offerPush(BuildContext context, WidgetRef ref) async {
  final push = ref.read(pushControllerProvider.notifier);
  if (!push.shouldOffer) return;
  final yes = await showCeSheet<bool>(
    context,
    builder: (ctx) => Column(
      key: const Key('push.offer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: CeColors.mint,
                borderRadius: BorderRadius.circular(CeRadius.md),
              ),
              child: Icon(
                CeIcons.of('bell'),
                size: 20,
                color: CeColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Get notified on this phone',
                style: CeType.cardTitle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'CricEco can tell you about join decisions, line-ups, match changes, results and club announcements '
          'even when the app is closed. You choose which in Notification settings.',
          style: CeType.body.copyWith(color: CeColors.muted),
        ),
        const SizedBox(height: 18),
        CeButton(
          key: const Key('push.offer.yes'),
          label: 'Turn on',
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
        const SizedBox(height: 8),
        CeButton(
          key: const Key('push.offer.no'),
          label: 'Not now',
          variant: CeButtonVariant.soft,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
      ],
    ),
  );
  if (yes == true) {
    final on = await push.turnOn();
    if (!on && context.mounted) {
      showCeToast(
        context,
        'Notifications are off for CricEco — you can allow them in Android settings.',
      );
    }
  } else {
    await push.notNow();
  }
}

/// Opens what a tapped push is about (inside its own inbox's role) and keeps
/// the inbox current while the app is open. Only with push available.
class PushRouter extends ConsumerStatefulWidget {
  const PushRouter({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<PushRouter> createState() => _PushRouterState();
}

class _PushRouterState extends ConsumerState<PushRouter> {
  final _subs = <StreamSubscription<Object?>>[];
  PushTap? _pending;

  @override
  void initState() {
    super.initState();
    // The controller registers the device; it lives as long as the app.
    ref.listenManual(pushControllerProvider, (_, _) {}, fireImmediately: true);
    ref.listenManual<bool>(
      pushAvailableProvider,
      (_, available) => available ? _start() : _stop(),
      fireImmediately: true,
    );
    // A tap that launched the app waits until someone is signed in.
    ref.listenManual(currentAccountProvider.select((a) => a?.id), (_, id) {
      if (id != null && _pending != null) {
        final tap = _pending!;
        _pending = null;
        unawaited(_open(tap));
      }
    });
  }

  void _start() {
    if (_subs.isNotEmpty) return;
    final messaging = ref.read(pushMessagingProvider);
    _subs
      ..add(
        messaging.taps.listen(
          (t) => unawaited(_open(t)),
          onError: (Object _) {},
        ),
      )
      ..add(
        messaging.foregroundMessages.listen(
          (_) => _refreshInbox(),
          onError: (Object _) {},
        ),
      );
    messaging.initialTap().then((t) {
      if (t != null) unawaited(_open(t));
    }, onError: (Object _) {});
  }

  void _stop() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  void _refreshInbox() {
    final role = ref.read(activeRoleProvider);
    if (role != null && ref.exists(serverInboxProvider(role))) {
      ref
          .read(serverInboxProvider(role).notifier)
          .refresh()
          .catchError((Object _) {});
    }
  }

  Future<void> _open(PushTap tap) async {
    if (!mounted) return;
    if (ref.read(currentAccountProvider) == null) {
      _pending = tap;
      return;
    }
    // Read: on the server (quietly), then the inbox catches up.
    unawaited(
      ref
          .read(notificationInboxRepositoryProvider)
          .markRead([tap.notificationId])
          .then((_) {
            if (mounted && ref.exists(serverInboxProvider(tap.role))) {
              return ref.read(serverInboxProvider(tap.role).notifier).refresh();
            }
          })
          .catchError((Object _) {}),
    );

    final router = ref.read(routerProvider);
    // A push from the other inbox switches the role first (as the drawer does).
    if (ref.read(activeRoleProvider) != tap.role) {
      final nav = ref.read(roleControllerProvider.notifier).switchTo(tap.role);
      if (nav is NeedsClubSetup) {
        router.go(nav.location);
        return;
      }
    }
    router.go(pushLocation(tap));
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Where a tapped push leads: its inbox row's destination, or the inbox
/// itself (an announcement is read there; an unknown type too).
String pushLocation(PushTap tap) {
  final n = NotificationRowMapper.notification(tap.role, {
    'notification_id': tap.notificationId,
    'type': tap.type,
    'params': const <String, Object?>{},
    'club_id': tap.clubId,
    'match_id': tap.matchId,
    'subject_id': tap.subjectId,
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'read_at': null,
  });
  if (n == null) return Routes.notifications;
  return notificationLocation(ServerNotificationAdapter.item(n).target) ??
      Routes.notifications;
}
