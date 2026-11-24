import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/config/push_config.dart';
import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart' show AccountException;
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_rows.dart';
import '../../shared/widgets/ce_surfaces.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'notification_preferences_controller.dart';
import 'push/push_controller.dart';
import 'push/push_messaging.dart' show PushPermission;
import 'push/push_ui.dart' show pushFailureText;

/// Notification settings (M3 P4, decision D8): opened from inside the
/// inbox. Which categories CricEco tells this person about — enforced on the
/// server (migration 26). Club membership and ownership is always on.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  static const intro =
      'Choose what CricEco tells you about in the app. Turning a category off stops new notifications '
      'of that kind; what is already in your inbox stays.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const bar = CeTopBar(
      title: 'Notification settings',
      fallbackLocation: Routes.notifications,
    );
    // The demo has no server preferences (its inbox isn't filtered).
    if (!ref.watch(notificationsBackendLiveProvider)) {
      return Scaffold(
        appBar: bar,
        body: ListView(
          children: [
            CeEmptyState(
              icon: 'bell',
              title: BackendModules.pendingTitle,
              body: BackendModules.pendingBody(BackendModule.notifications),
            ),
          ],
        ),
      );
    }
    final async = ref.watch(notificationPreferencesProvider);
    final prefs = async.value;

    Future<void> toggle(NotificationCategory c, bool on) async {
      try {
        await ref.read(notificationPreferencesProvider.notifier).set(c, on);
      } catch (e) {
        if (context.mounted) {
          showCeToast(
            context,
            e is AccountException
                ? e.message
                : "Couldn't save your choice — please try again",
          );
        }
      }
    }

    Widget row(NotificationCategory c, {bool last = false}) => c.alwaysOn
        ? CeSettingsRow(
            key: Key('notificationSettings.${c.name}'),
            icon: c.icon,
            title: c.label,
            subtitle: c.description,
            showDivider: !last,
            trailing: Text(
              'Always on',
              style: CeType.caption.copyWith(color: CeColors.muted),
            ),
          )
        : CeToggleRow(
            key: Key('notificationSettings.${c.name}'),
            icon: c.icon,
            title: c.label,
            subtitle: c.description,
            value: prefs!.isOn(c),
            showDivider: !last,
            onChanged: (on) => toggle(c, on),
          );

    final everyone = [
      for (final c in NotificationCategory.values)
        if (!c.forOwners) c,
    ];
    final owners = [
      for (final c in NotificationCategory.values)
        if (c.forOwners) c,
    ];

    return Scaffold(
      appBar: bar,
      body: prefs == null && async.isLoading
          ? const Center(child: CircularProgressIndicator())
          : prefs == null
          ? ListView(
              children: [
                CeErrorState(
                  title: "Couldn't load your notification settings",
                  onRetry: () =>
                      ref.invalidate(notificationPreferencesProvider),
                ),
              ],
            )
          : ListView(
              key: const Key('notificationSettings.list'),
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    CeSpace.gutter,
                    14,
                    CeSpace.gutter,
                    4,
                  ),
                  child: Text(
                    intro,
                    style: CeType.body.copyWith(color: CeColors.muted),
                  ),
                ),
                const CeSectionHeader(
                  'Your notifications',
                  padding: EdgeInsets.fromLTRB(
                    CeSpace.gutter,
                    14,
                    CeSpace.gutter,
                    8,
                  ),
                ),
                CeGroupCard(
                  children: [
                    for (final c in everyone) row(c, last: c == everyone.last),
                  ],
                ),
                const CeSectionHeader(
                  'For club owners',
                  padding: EdgeInsets.fromLTRB(
                    CeSpace.gutter,
                    18,
                    CeSpace.gutter,
                    8,
                  ),
                ),
                CeGroupCard(
                  children: [
                    for (final c in owners) row(c, last: c == owners.last),
                  ],
                ),
                // M3 P5: push for this phone (only in builds that have it).
                if (ref.watch(pushAvailableProvider)) const _PushOnThisDevice(),
              ],
            ),
    );
  }
}

/// "Push on this device": the categories above apply to push too (a
/// category that is off is never created, so never pushed).
class _PushOnThisDevice extends ConsumerWidget {
  const _PushOnThisDevice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final push = ref.watch(pushControllerProvider);
    final failure = push.active ? push.failure : null;
    final subtitle = failure != null
        ? pushFailureText(failure)
        : push.active
        ? 'On — they arrive even when CricEco is closed'
        : push.enabled && push.permission == PushPermission.denied
        ? 'Allow notifications for CricEco in Android settings'
        : 'Off';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CeSectionHeader(
          'This phone',
          padding: EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 8),
        ),
        CeGroupCard(
          children: [
            CeToggleRow(
              key: const Key('notificationSettings.push'),
              icon: 'bell',
              title: 'Push on this device',
              subtitle: subtitle,
              value: push.active,
              showDivider: failure != null,
              onChanged: (on) async {
                final controller = ref.read(pushControllerProvider.notifier);
                if (!on) return controller.turnOff();
                if (!await controller.turnOn() && context.mounted) {
                  showCeToast(
                    context,
                    'Notifications are off for CricEco — you can allow them in Android settings.',
                  );
                }
              },
            ),
            // C3 Fix A: a failed registration is shown, with a way to retry.
            if (failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: CeButton.soft(
                  key: const Key('notificationSettings.push.retry'),
                  label: 'Try again',
                  dense: true,
                  onPressed: () =>
                      ref.read(pushControllerProvider.notifier).retry(),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
