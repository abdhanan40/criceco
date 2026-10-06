import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_form_widgets.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../notifications/notifications_controller.dart';
import '../club_providers.dart';

// Club announcements: Create (sheet) → Publish → one in-app notification per
// selected member → the member reads it from Notifications (sheet). In-app
// only: there is no backend or push service yet, so nothing leaves the device.

int _seq = 0;

/// Members of the owner's club an announcement to [audience] reaches.
List<ClubMember> announcementRecipients(List<ClubMember> members, AnnouncementAudience audience) =>
    [for (final m in members) if (audience.includes(m)) m];

/// Stores the announcement and delivers a "Club Announcement"
/// notification to every selected member. Returns it (with its recipients).
Future<ClubAnnouncement> publishAnnouncement(
  WidgetRef ref, {
  required String title,
  required String message,
  required AnnouncementAudience audience,
}) async {
  final club = ref.read(currentClubProvider)!;
  final account = ref.read(currentAccountProvider)!;
  final now = ref.read(clockProvider).now();
  final recipients = announcementRecipients(await ref.read(clubMembersProvider.future), audience);
  final announcement = await ref.read(announcementRepositoryProvider).publish(ClubAnnouncement(
        id: 'ann_${now.microsecondsSinceEpoch}_${_seq++}',
        clubId: club.id,
        clubName: club.name,
        title: title.trim(),
        message: message.trim(),
        audience: audience,
        createdBy: account.id,
        createdAt: now,
        recipientMemberIds: [for (final m in recipients) m.id],
      ));
  await ref.read(notificationRepositoryProvider).deliver([
    for (final m in recipients)
      NotificationItem(
        id: 'n_${announcement.id}_${m.id}',
        role: UserRole.player, // a member's (player-side) inbox
        icon: 'megaphone',
        title: 'Club Announcement',
        subtitle: '${club.name} · ${announcementPreview(announcement)}',
        createdAt: now,
        tone: NotificationTone.green,
        target: AnnouncementTarget(announcement.id),
        recipientMemberId: m.id,
      ),
  ]);
  ref.invalidate(roleNotificationsProvider(UserRole.player));
  return announcement;
}

/// The short preview a member sees in Notifications: the title, then the start
/// of the message (the full text opens in [showAnnouncementSheet]).
String announcementPreview(ClubAnnouncement a, {int max = 64}) {
  final text = '${a.title} — ${a.message}'.replaceAll(RegExp(r'\s+'), ' ');
  return text.length <= max ? text : '${text.substring(0, max - 1).trimRight()}…';
}

/// Create Announcement sheet (Club Owner Dashboard quick action).
Future<void> showCreateAnnouncementSheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => const _CreateAnnouncementSheet());

class _CreateAnnouncementSheet extends ConsumerStatefulWidget {
  const _CreateAnnouncementSheet();

  @override
  ConsumerState<_CreateAnnouncementSheet> createState() => _CreateAnnouncementSheetState();
}

class _CreateAnnouncementSheetState extends ConsumerState<_CreateAnnouncementSheet> {
  final _title = TextEditingController();
  final _message = TextEditingController();
  AnnouncementAudience _audience = AnnouncementAudience.all;
  bool _publishing = false;

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    FocusScope.of(context).unfocus();
    setState(() => _publishing = true);
    final a = await publishAnnouncement(ref, title: _title.text, message: _message.text, audience: _audience);
    if (!mounted) return;
    final n = a.recipientMemberIds.length;
    final messenger = context;
    Navigator.of(context).pop();
    if (messenger.mounted) showCeToast(messenger, 'Announcement published to $n member${n == 1 ? '' : 's'}.');
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(clubMembersProvider).value ?? const <ClubMember>[];
    final count = announcementRecipients(members, _audience).length;
    final valid = _title.text.trim().isNotEmpty && _message.text.trim().isNotEmpty && count > 0;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Create Announcement', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      const CeFieldLabel('Title', required: true),
      CeTextField(
        fieldKey: const Key('announcement.title'),
        controller: _title,
        hint: 'e.g. Training update',
        icon: 'megaphone',
        maxLength: ClubAnnouncement.titleMaxLength,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.next,
        onChanged: (_) => setState(() {}),
      ),
      const CeFieldLabel('Message', required: true),
      CeTextField(
        fieldKey: const Key('announcement.message'),
        controller: _message,
        hint: 'e.g. Training session tomorrow at 5:00 PM.',
        maxLength: ClubAnnouncement.messageMaxLength,
        maxLines: 4,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
      ),
      const CeFieldLabel('Audience'),
      CeChoiceGroup<AnnouncementAudience>(
        values: AnnouncementAudience.values,
        selected: _audience,
        labelOf: (a) => a.label,
        onSelected: (a) => setState(() => _audience = a),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Icon(CeIcons.of('users'), size: 13, color: CeColors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            count == 0 ? 'No members in this audience yet.' : 'Goes to $count member${count == 1 ? '' : 's'}',
            key: const Key('announcement.count'),
            style: const TextStyle(fontSize: 11.5, color: CeColors.muted),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: _publishing ? null : () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(
          child: CeButton(
            label: 'Publish',
            loading: _publishing,
            onPressed: valid && !_publishing ? _publish : null,
          ),
        ),
      ]),
    ]);
  }
}

/// A member reads an announcement (from Notifications) — in a sheet.
Future<void> showAnnouncementSheet(BuildContext context, ClubAnnouncement a) => showCeSheet<void>(
      context,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of('megaphone'), size: 18, color: CeColors.primaryDark),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('CLUB ANNOUNCEMENT',
                  style: TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: CeColors.primaryDark)),
              const SizedBox(height: 2),
              Text(a.title, key: const Key('announcement.title.view'), style: Theme.of(ctx).textTheme.titleLarge),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        // Club name and when it was published (date and time).
        Wrap(spacing: 14, runSpacing: 6, children: [
          _AnnouncementMeta(key: const Key('announcement.club'), icon: 'shield', label: a.clubName),
          _AnnouncementMeta(
              key: const Key('announcement.when'),
              icon: 'calendar',
              label: '${CeFormat.dayDate(a.createdAt)} · ${CeFormat.time(a.createdAt)}'),
        ]),
        const SizedBox(height: 14),
        Text(a.message,
            key: const Key('announcement.body'),
            style: Theme.of(ctx).textTheme.bodyMedium!.copyWith(color: CeColors.ink, height: 1.5)),
        const SizedBox(height: 20),
        CeButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
      ]),
    );

class _AnnouncementMeta extends StatelessWidget {
  const _AnnouncementMeta({super.key, required this.icon, required this.label});
  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 13, color: CeColors.muted),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.ink2)),
        ),
      ]);
}
