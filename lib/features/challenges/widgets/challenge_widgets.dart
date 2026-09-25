import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';

enum ChallengesSection {
  challenges('Challenges', Routes.challenges),
  mine('My Challenges', Routes.myChallenges),
  find('Find Match', Routes.findMatch);

  const ChallengesSection(this.label, this.location);
  final String label;
  final String location;
}

/// `challengesTabRow`: sibling screens, switched with `go` (replaces). My
/// Challenges carries the number of challenges awaiting your decision.
class ChallengesTabs extends ConsumerWidget {
  const ChallengesTabs({super.key, required this.active});
  final ChallengesSection active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final awaiting = ref.watch(myChallengeSectionsProvider).awaitingDecision.length;
    return CeChipRow<ChallengesSection>(
      values: ChallengesSection.values,
      selected: active,
      labelOf: (s) => s.label,
      countOf: (s) => s == ChallengesSection.mine && awaiting > 0 ? awaiting : null,
      onSelected: (s) {
        if (s != active) context.go(s.location);
      },
    );
  }
}

/// Sends a challenge and routes by the resulting state: Demo Mode accepts it
/// instantly → Challenge Accepted; otherwise it stays pending → My Challenges
/// ("Sent", approved P9).
Future<void> sendChallenge(BuildContext context, WidgetRef ref, ClubSummary club, {MatchFormat? format}) async {
  final c = await ref.read(challengesProvider.notifier).send(club.id, format: format);
  if (!context.mounted) return;
  if (c.status == ChallengeStatus.accepted) {
    showCeToast(context, 'Challenge sent to ${club.name}!');
    context.go(Routes.challengeAccepted(c.id));
  } else {
    showCeToast(context, 'Challenge sent to ${club.name} — awaiting their reply');
    context.go(Routes.myChallenges);
  }
}

/// `.avail-box`: dashed mint call-to-action for Create Availability Slot.
class AvailabilitySlotCta extends StatelessWidget {
  const AvailabilitySlotCta({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        child: Material(
          color: CeColors.mint,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.row),
            side: const BorderSide(color: CeColors.mint2, width: 1.4),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: () => context.push(Routes.createAvailabilitySlot),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(CeIcons.of('plus'), size: 16, color: CeColors.primaryDark),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'Create Availability Slot', style: TextStyle(fontWeight: FontWeight.w800)),
                      TextSpan(text: ' — Post your open dates, teams will send you requests'),
                    ]),
                    style: TextStyle(fontSize: 12.5, color: CeColors.primaryDark, height: 1.4),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// `.my-slot-card` list with Remove.
class MySlotsList extends ConsumerWidget {
  const MySlotsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = ref.watch(availabilitySlotsProvider).value ?? const <AvailabilitySlot>[];
    final grounds = ref.watch(groundDirectoryProvider).value ?? const <String, Ground>{};
    return Column(children: [
      for (final s in slots)
        Container(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(CeRadius.row),
            border: Border.all(color: CeColors.mint2),
            boxShadow: CeShadows.card,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(CeIcons.of('megaphone'), size: 13, color: CeColors.primaryDark),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Your Open Slot',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: CeColors.red,
                  minimumSize: const Size(48, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
                onPressed: () async {
                  final ok = await showCeConfirmSheet(
                    context,
                    title: 'Remove this slot?',
                    body: 'Clubs will no longer see your ${CeFormat.dayDate(s.date)} slot in Find Match.',
                    confirmLabel: 'Remove Slot',
                    destructive: true,
                    icon: 'x-circle',
                  );
                  if (!ok) return;
                  await ref.read(availabilitySlotsProvider.notifier).remove(s.id);
                  if (context.mounted) showCeToast(context, 'Availability slot removed');
                },
                child: const Text('Remove'),
              ),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 6, children: [
              InlineInfo(icon: 'circle-dot', text: s.format.display(s.customOvers)),
              InlineInfo(icon: 'building-2', text: s.city),
              if (s.groundId != null && grounds[s.groundId] != null)
                InlineInfo(icon: 'flag', text: grounds[s.groundId]!.name),
              InlineInfo(icon: 'calendar', text: CeFormat.dayDate(s.date)),
              InlineInfo(icon: 'clock', text: s.slot.label),
            ]),
            if (s.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              InlineInfo(icon: 'file-text', text: s.notes, maxLines: 3),
            ],
          ]),
        ),
    ]);
  }
}

/// Icon + text used in challenge and slot cards (`.challenge-detail span`).
class InlineInfo extends StatelessWidget {
  const InlineInfo({super.key, required this.icon, required this.text, this.maxLines = 1});
  final String icon;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(CeIcons.of(icon), size: 12.5, color: CeColors.muted),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: CeColors.ink2, height: 1.3)),
        ),
      ]);
}

/// `.challenge-card` shell: badge, name (+ trailing), meta, optional details
/// and actions. Tap opens the opponent's Club Profile when [onTap] is set.
class ChallengeCard extends StatelessWidget {
  const ChallengeCard({
    super.key,
    required this.abbr,
    required this.color,
    required this.name,
    required this.meta,
    this.nameTrailing,
    this.trailing,
    this.details = const [],
    this.actions,
    this.onTap,
  });

  final String abbr;
  final Color color;
  final String name;
  final Widget meta;
  final Widget? nameTrailing;
  final Widget? trailing;
  final List<Widget> details;
  final Widget? actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.lg),
            side: const BorderSide(color: CeColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  CeTeamBadge(abbr, color: color, size: 40),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                        ?nameTrailing,
                      ]),
                      const SizedBox(height: 1),
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontSize: 11.5, color: CeColors.muted),
                        child: meta,
                      ),
                    ]),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                ]),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 12, runSpacing: 6, children: details),
                ],
                if (actions != null) ...[const SizedBox(height: 12), actions!],
              ]),
            ),
          ),
        ),
      );
}

/// Small NEW pill (`.new-pill`).
class NewPill extends StatelessWidget {
  const NewPill({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: CeColors.amberSoft, borderRadius: BorderRadius.circular(CeRadius.pill)),
        child: const Text('NEW', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: CeColors.amberInk)),
      );
}

/// Chip for a challenge's (effective) status.
Widget challengeStatusChip(ChallengeStatus s, ChallengeDirection d) => switch (s) {
      ChallengeStatus.pending => CeStatusChip(
          d == ChallengeDirection.sent ? 'Awaiting reply' : 'New', tone: CeTone.amber, icon: 'hourglass'),
      ChallengeStatus.accepted => const CeStatusChip('Accepted', icon: 'check'),
      ChallengeStatus.declined => const CeStatusChip('Declined', tone: CeTone.red, icon: 'x'),
      ChallengeStatus.expired => const CeStatusChip('Expired', tone: CeTone.neutral, icon: 'timer'),
    };
