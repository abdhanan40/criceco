import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers/core_providers.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
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
              if (unread.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  key: const Key('notifications.panel.newBadge'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: CeColors.sage, borderRadius: BorderRadius.circular(CeRadius.xs)),
                  child: Text('${unread.length} new', style: CeType.micro.copyWith(fontSize: 11, color: CeColors.ink)),
                ),
              ],
            ]),
          ),
          TextButton(
            key: const Key('notifications.panel.markAll'),
            onPressed: unread.isEmpty ? null : () => ref.read(notificationReadProvider.notifier).markAllRead(unread),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text('Mark all read', style: CeType.buttonSmall.copyWith(color: unread.isEmpty ? CeColors.muted2 : CeColors.accent)),
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
