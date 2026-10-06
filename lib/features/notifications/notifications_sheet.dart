import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers/core_providers.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../club/announcements/announcements.dart';
import 'notifications_controller.dart';
import 'notifications_screen.dart' show NotificationRow;

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
  ref.read(notificationReadProvider.notifier).markRead(n.id);
  if (n.target case AnnouncementTarget(:final announcementId)) {
    final a = await ref.read(announcementRepositoryProvider).byId(announcementId);
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

/// Dashboard bell → the notifications inbox as a large panel over the
/// current screen (no route change, so the dashboard keeps its state).
/// Same panel for Player and Club Owner; content from [roleNotificationsProvider].
Future<void> showNotificationsSheet(BuildContext context, UserRole role) {
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

class NotificationsPanel extends ConsumerWidget {
  const NotificationsPanel({super.key, required this.role});
  final UserRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(roleNotificationsProvider(role));
    final items = async.value ?? const <NotificationItem>[];
    final read = ref.watch(notificationReadProvider);
    final unread = [for (final n in items) if (!read.contains(n.id)) n.id];
    final now = ref.read(clockProvider).now();

    Widget body;
    if (async.isLoading && items.isEmpty) {
      body = const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    } else if (async.hasError && items.isEmpty) {
      body = _Empty(
        icon: 'info',
        title: "Couldn't load notifications",
        body: 'Check your connection and try again.',
        action: TextButton(
          onPressed: () => ref.invalidate(roleNotificationsProvider(role)),
          child: const Text('Retry'),
        ),
      );
    } else if (items.isEmpty) {
      body = const _Empty(icon: 'bell', title: 'No notifications yet', body: "You're all caught up.");
    } else {
      body = ListView.separated(
        key: const Key('notifications.panel.list'),
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, thickness: 1, color: CeColors.hairline),
        itemBuilder: (context, i) {
          final n = items[i];
          return _PanelRow(
            item: n,
            unread: !read.contains(n.id),
            timeLabel: CeFormat.timeAgo(n.createdAt, now),
            onTap: () => openNotification(context, ref, n, leave: () => Navigator.of(context).pop()),
          );
        },
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
        padding: const EdgeInsets.fromLTRB(18, 4, 8, 8),
        child: Row(children: [
          // Title + badge take the room left by Mark all read; on very narrow
          // phones the title shrinks a little rather than being cut off.
          Expanded(
            child: Row(children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('Notifications', maxLines: 1, style: Theme.of(context).textTheme.titleLarge),
                ),
              ),
              if (unread.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  key: const Key('notifications.panel.newBadge'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.pill)),
                  child: Text('${unread.length} new',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
                ),
              ],
            ]),
          ),
          TextButton(
            key: const Key('notifications.panel.markAll'),
            onPressed: unread.isEmpty ? null : () => ref.read(notificationReadProvider.notifier).markAllRead(unread),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: const Text('Mark all read', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
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
        color: unread ? CeColors.mint.withValues(alpha: 0.45) : Colors.white,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 16, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(CeRadius.md)),
                child: Icon(CeIcons.of(item.icon), size: 18, color: fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.title,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                          color: CeColors.ink,
                          height: 1.3)),
                  const SizedBox(height: 2),
                  Text(item.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: CeColors.muted, height: 1.3)),
                  const SizedBox(height: 4),
                  Text(timeLabel, style: const TextStyle(fontSize: 11, color: CeColors.muted2)),
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
                        decoration: const BoxDecoration(color: CeColors.primary, shape: BoxShape.circle),
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
            child: Icon(CeIcons.of(icon), size: 24, color: CeColors.primaryDark),
          ),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: CeColors.muted)),
          ?action,
        ]),
      );
}
