import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config/backend_modules.dart';
import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../data/repositories/repositories.dart' show AccountException;
import '../../shared/widgets/backend_pending.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../club/announcements/announcements.dart';
import 'notifications_controller.dart';
import 'notifications_screen.dart' show NotificationRow, OlderNotificationsButton;
import 'push/push_ui.dart' show offerPush;

/// Opens a notification: marks it read, then its existing action — an
/// announcement is read in place (sheet on top), anything else opens its
/// destination route (inside the same role). [leave] runs just before a
/// route change (the panel closes itself first). Shared by the panel and the
/// Notifications screen.
Future<void> openNotification(
  BuildContext context,
  WidgetRef ref,
  NotificationItem n, {
  VoidCallback? leave,
}) async {
  markNotificationRead(ref, n);
  if (n.target case AnnouncementTarget(:final announcementId)) {
    final ClubAnnouncement? a;
    try {
      a = await _announcement(ref, announcementId);
    } on AccountException catch (e) {
      if (context.mounted) showCeToast(context, e.message);
      return;
    }
    if (!context.mounted) return;
    a == null
        ? showCeToast(context, 'This announcement is no longer available.')
        : await showAnnouncementSheet(context, a);
    return;
  }
  final location = notificationLocation(n.target);
  if (location == null) return;
  final router = GoRouter.of(context);
  leave?.call();
  router.go(location);
}

/// The announcement behind a notification: from the server with the
/// notifications switch (its recipients and the club's owner may read it),
/// else the demo's own store.
Future<ClubAnnouncement?> _announcement(WidgetRef ref, String id) async {
  if (!ref.read(notificationsBackendLiveProvider)) return ref.read(announcementRepositoryProvider).byId(id);
  final r = await ref.read(announcementServerRepositoryProvider).announcement(id);
  return ClubAnnouncement(
    id: r.id,
    clubId: r.clubId,
    clubName: r.clubName,
    title: r.title,
    message: r.message,
    audience: r.audience,
    createdBy: '', // not sent to recipients
    createdAt: r.createdAt,
    recipientMemberIds: const [],
  );
}

/// Dashboard bell → the notifications inbox as a large panel over the
/// current screen (no route change, so the dashboard keeps its state).
/// Same panel for Player and Club Owner; content from [roleNotificationsProvider].
Future<void> showNotificationsSheet(BuildContext context, UserRole role) {
  if (!backendModuleAvailable(context, BackendModule.notifications)) {
    return showBackendPendingSheet(context, BackendModule.notifications, title: 'Notifications');
  }
  final height = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true, // covers the bottom navigation too
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    constraints: BoxConstraints(maxHeight: height * 0.78),
    builder: (_) => NotificationsPanel(role: role),
  );
}

class NotificationsPanel extends ConsumerStatefulWidget {
  const NotificationsPanel({super.key, required this.role});
  final UserRole role;

  @override
  ConsumerState<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends ConsumerState<NotificationsPanel> {
  UserRole get role => widget.role;

  @override
  void initState() {
    super.initState();
    // Opening the panel shows what is new (D12); a failure keeps what was shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(notificationsBackendLiveProvider)) return;
      refreshNotifications(ref, role).catchError((Object _) {});
      // M3 P5: the one-time push offer, the first time the inbox opens.
      offerPush(context, ref);
    });
  }

  Future<void> _refresh() async {
    try {
      await refreshNotifications(ref, role);
    } catch (_) {
      if (mounted) showCeToast(context, "Couldn't refresh notifications — please try again");
    }
  }

  Future<void> _markAll(Iterable<String> unread) async {
    try {
      await markAllNotificationsRead(ref, role, unread);
    } catch (_) {
      if (mounted) showCeToast(context, "Couldn't mark them read — please try again");
    }
  }

  Future<void> _more() async {
    try {
      await loadMoreNotifications(ref, role);
    } catch (_) {
      if (mounted) showCeToast(context, "Couldn't load older notifications — please try again");
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(roleNotificationsProvider(role));
    final items = async.value ?? const <NotificationItem>[];
    final unread = ref.watch(unreadNotificationIdsProvider(role));
    final newCount = ref.watch(unreadNotificationCountProvider(role));
    final paging = ref.watch(notificationPagingProvider(role));
    final now = ref.read(clockProvider).now();

    Widget body;
    if (async.isLoading && items.isEmpty) {
      body = const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    } else if (async.hasError && items.isEmpty) {
      body = _Empty(
        icon: 'info',
        title: "Couldn't load notifications",
        body: 'Check your connection and try again.',
        action: TextButton(onPressed: _refresh, child: const Text('Retry')),
      );
    } else if (items.isEmpty) {
      body = const _Empty(icon: 'bell', title: 'No notifications yet', body: "You're all caught up.");
    } else {
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView.separated(
          key: const Key('notifications.panel.list'),
          shrinkWrap: true,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: items.length + (paging.hasMore ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(height: 1, thickness: 1, color: CeColors.hairline),
          itemBuilder: (context, i) {
            if (i == items.length) return OlderNotificationsButton(loading: paging.loading, onPressed: _more);
            final n = items[i];
            return _PanelRow(
              item: n,
              unread: unread.contains(n.id),
              timeLabel: CeFormat.timeAgo(n.createdAt, now),
              onTap: () => openNotification(context, ref, n, leave: () => Navigator.of(context).pop()),
            );
          },
        ),
      );
    }

    return Column(key: const Key('notifications.panel'), mainAxisSize: MainAxisSize.min, children: [
      Center(
        child: Container(
          width: 38,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 6),
          decoration: BoxDecoration(color: CeColors.line2, borderRadius: BorderRadius.circular(CeRadius.pill)),
        ),
      ),
      // ---- Header: title · "N new" · Mark all read (stays put while the list scrolls) ----
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 4, 10, 10),
        child: Row(children: [
          // Title + badge take the room left by Mark all read; on very narrow
          // phones the title shrinks a little rather than being cut off.
          Expanded(
            child: Row(children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('Notifications', maxLines: 1, style: CeType.pageTitle),
                ),
              ),
              if (newCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  key: const Key('notifications.panel.newBadge'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: CeColors.sage, borderRadius: BorderRadius.circular(CeRadius.xs)),
                  child: Text('$newCount new', style: CeType.micro.copyWith(fontSize: 11, color: CeColors.ink)),
                ),
              ],
            ]),
          ),
          // D8: the settings live inside the inbox (server inbox only).
          if (ref.watch(notificationsBackendLiveProvider))
            IconButton(
              key: const Key('notifications.panel.settings'),
              tooltip: 'Notification settings',
              visualDensity: VisualDensity.compact,
              icon: Icon(CeIcons.of('sliders'), size: 19, color: CeColors.ink2),
              onPressed: () {
                final router = GoRouter.of(context);
                Navigator.of(context).pop();
                router.push(Routes.notificationSettings);
              },
            ),
          TextButton(
            key: const Key('notifications.panel.markAll'),
            onPressed: newCount == 0 ? null : () => _markAll(unread),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text('Mark all read',
                style: CeType.buttonSmall.copyWith(color: newCount == 0 ? CeColors.muted2 : CeColors.accent)),
          ),
        ]),
      ),
      const Divider(height: 1, thickness: 1, color: CeColors.line),
      Flexible(child: body),
    ]);
  }
}

/// One inbox row: soft icon well, title, short detail, age, unread dot.
/// Unread rows carry a light CricEco tint.
class _PanelRow extends StatelessWidget {
  const _PanelRow({required this.item, required this.unread, required this.timeLabel, required this.onTap});
  final NotificationItem item;
  final bool unread;
  final String timeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = NotificationRow.toneColors(item.tone);
    return Semantics(
      button: true,
      label: '${unread ? 'Unread. ' : ''}${item.title}. ${item.subtitle}. $timeLabel',
      excludeSemantics: true,
      child: Material(
        color: unread ? CeColors.surfaceAlt : Colors.white,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 13, 18, 13),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(CeRadius.md)),
                child: Icon(CeIcons.of(item.icon), size: 18, color: fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.title,
                      style: CeType.listTitle.copyWith(fontSize: 13.5, fontWeight: unread ? FontWeight.w700 : FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(item.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CeType.bodySmall.copyWith(fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(timeLabel, style: CeType.caption.copyWith(color: CeColors.muted2)),
                ]),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: unread
                    ? Container(
                        key: Key('notifications.panel.dot.${item.id}'),
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(color: CeColors.accent, shape: BoxShape.circle),
                      )
                    : const SizedBox(width: 9, height: 9),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body, this.action});
  final String icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        key: const Key('notifications.panel.empty'),
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 36),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.xl)),
            child: Icon(CeIcons.of(icon), size: 24, color: CeColors.primary),
          ),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: CeType.cardTitle),
          const SizedBox(height: 4),
          Text(body, textAlign: TextAlign.center, style: CeType.body.copyWith(color: CeColors.muted)),
          ?action,
        ]),
      );
}
