import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_surfaces.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'notifications_controller.dart';

/// Notifications (prototype `screens.notifications`, :8105): one screen,
/// content from the active role. Each row opens its real destination inside
/// that same role (never a toast); Back → the previous screen, else the
/// role's home.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(activeRoleProvider);
    if (role == null) {
      return Scaffold(
        appBar: const CeTopBar(title: 'Notifications', fallbackLocation: Routes.roleSelection),
        body: CeEmptyState(
          icon: 'bell',
          title: 'Choose a profile first',
          body: 'Notifications are shown for your active profile.',
          primaryLabel: 'Continue',
          onPrimary: () => context.go(Routes.roleSelection),
        ),
      );
    }
    final home = Routes.home(role);
    final async = ref.watch(roleNotificationsProvider(role));
    final items = async.value ?? const <NotificationItem>[];
    final read = ref.watch(notificationReadProvider);
    final unread = items.where((n) => !read.contains(n.id)).toList();
    final now = ref.read(clockProvider).now();

    return Scaffold(
      appBar: CeTopBar(
        title: 'Notifications',
        fallbackLocation: home,
        actions: [
          if (unread.isNotEmpty)
            TextButton(
              onPressed: () => ref.read(notificationReadProvider.notifier).markAllRead(unread.map((n) => n.id)),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: async.isLoading && items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : async.hasError && items.isEmpty
              ? ListView(children: [
                  CeErrorState(
                    title: 'Couldn\'t load notifications',
                    onRetry: () => ref.invalidate(roleNotificationsProvider(role)),
                  ),
                ])
              : items.isEmpty
                  ? ListView(children: [
                      CeEmptyState(
                        icon: 'bell',
                        title: 'No notifications yet',
                        body: 'Match requests, approvals and booking updates will appear here.',
                        primaryLabel: 'Back to dashboard',
                        onPrimary: () => context.go(home),
                      ),
                    ])
                  : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                      // Newest first, grouped by day: Today, then Earlier.
                      for (final (label, group) in [
                        ('Today', [for (final n in items) if (_sameDay(n.createdAt, now)) n]),
                        ('Earlier', [for (final n in items) if (!_sameDay(n.createdAt, now)) n]),
                      ])
                        if (group.isNotEmpty) ...[
                          CeSectionHeader(label,
                              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 8)),
                          for (final n in group)
                            NotificationRow(
                              item: n,
                              unread: !read.contains(n.id),
                              timeLabel: CeFormat.timeAgo(n.createdAt, now),
                              onTap: () {
                                ref.read(notificationReadProvider.notifier).markRead(n.id);
                                final location = notificationLocation(n.target);
                                if (location != null) context.go(location);
                              },
                            ),
                        ],
                    ]),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}

/// `.ce-notif`: tone icon, title, subtitle, age; unread rows are marked.
class NotificationRow extends StatelessWidget {
  const NotificationRow({
    super.key,
    required this.item,
    required this.unread,
    required this.timeLabel,
    required this.onTap,
  });
  final NotificationItem item;
  final bool unread;
  final String timeLabel;
  final VoidCallback onTap;

  static (Color, Color) toneColors(NotificationTone t) => switch (t) {
        NotificationTone.green => (CeColors.mint, CeColors.primaryDark),
        NotificationTone.amber => (CeColors.amberSoft, CeColors.amberInk),
        NotificationTone.blue => (CeColors.blueSoft, CeColors.blue),
      };

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = toneColors(item.tone);
    final navigable = item.target != null;
    return Semantics(
      button: navigable,
      label: '${unread ? 'Unread. ' : ''}${item.title}. ${item.subtitle}. $timeLabel',
      excludeSemantics: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 8),
        child: Material(
          color: unread ? Colors.white : CeColors.historySoft,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.row),
            side: const BorderSide(color: CeColors.line),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(CeRadius.md)),
                  child: Icon(CeIcons.of(item.icon), size: 18, color: fg),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.title,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                            color: CeColors.ink,
                            height: 1.3)),
                    const SizedBox(height: 3),
                    Text(item.subtitle, style: const TextStyle(fontSize: 12, color: CeColors.muted, height: 1.3)),
                  ]),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(timeLabel, style: const TextStyle(fontSize: 11, color: CeColors.muted2)),
                  const SizedBox(height: 8),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    if (unread)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(color: CeColors.primary, shape: BoxShape.circle),
                      ),
                    if (navigable) ...[
                      const SizedBox(width: 4),
                      Icon(CeIcons.of('chevron-right'), size: 15, color: CeColors.muted2),
                    ],
                  ]),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
