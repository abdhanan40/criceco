import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';
import '../widgets/challenge_widgets.dart';

/// My Challenges (prototype `screens.myChallenges`, :7044). Accept / Decline
/// are real state changes (fix: Decline did nothing in the prototype):
/// Accept creates ONE pending match and hands off to Match Management
/// (Waiting); Decline moves the card to Resolved.
class MyChallengesScreen extends ConsumerStatefulWidget {
  const MyChallengesScreen({super.key});

  @override
  ConsumerState<MyChallengesScreen> createState() => _MyChallengesScreenState();
}

class _MyChallengesScreenState extends ConsumerState<MyChallengesScreen> {
  final _busy = <String>{};

  Future<void> _respond(Challenge c, {required bool accept}) async {
    if (_busy.contains(c.id)) return;
    if (!accept) {
      final name = ref.read(clubDirectoryProvider).value?[c.opponentClubId]?.name ?? 'this club';
      final ok = await showCeConfirmSheet(
        context,
        title: 'Decline this challenge?',
        body: '$name will be told you declined. You can still challenge them later.',
        confirmLabel: 'Decline Challenge',
        destructive: true,
        icon: 'x-circle',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy.add(c.id));
    final ctrl = ref.read(challengesProvider.notifier);
    final result = accept ? await ctrl.accept(c.id) : await ctrl.decline(c.id);
    if (!mounted) return;
    setState(() => _busy.remove(c.id));
    switch (result?.status) {
      case ChallengeStatus.accepted:
        showCeToast(context, 'Challenge accepted!');
        context.go(Routes.matchManagement(MatchTab.waiting));
      case ChallengeStatus.declined:
        showCeToast(context, 'Challenge declined');
      case ChallengeStatus.expired:
        showCeToast(context, 'This challenge has expired');
      case ChallengeStatus.pending || null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(challengesProvider);
    final sections = ref.watch(myChallengeSectionsProvider);
    final dir = ref.watch(clubDirectoryProvider).value ?? const <String, ClubSummary>{};
    final now = ref.read(clockProvider).now();

    Widget empty(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 6, CeSpace.gutter, 4),
          child: Text(text, style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
        );

    List<Widget> details(Challenge c) => [
          if (c.format != null) InlineInfo(icon: 'circle-dot', text: c.format!.display()),
          if (c.proposedAt != null) InlineInfo(icon: 'calendar', text: CeFormat.dayDate(c.proposedAt!)),
          if (c.groundName != null) InlineInfo(icon: 'map-pin', text: c.groundName!),
        ];

    return Scaffold(
      appBar: const CeTopBar(title: 'Challenges', fallbackLocation: Routes.challenges),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        const ChallengesTabs(active: ChallengesSection.mine),
        if (async.isLoading)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (async.hasError)
          CeErrorState(title: 'Couldn\'t load your challenges', onRetry: () => ref.invalidate(challengesProvider))
        else ...[
          // ---- Received, awaiting a decision ----
          const CeSectionHeader('Awaiting your Decision',
              padding: EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0)),
          if (sections.awaitingDecision.isEmpty) empty('No challenges awaiting your decision.'),
          for (final c in sections.awaitingDecision)
            if (dir[c.opponentClubId] case final club?)
              ChallengeCard(
                abbr: club.abbr,
                color: club.color,
                name: club.name,
                nameTrailing: c.isNew ? const NewPill() : null,
                meta: Text('${club.city} · W${club.wins}, L${club.losses}'),
                details: details(c),
                onTap: () => context.push(Routes.clubProfile(club.id)),
                actions: _busy.contains(c.id)
                    ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                    : Row(children: [
                        Expanded(
                          // Label only: an icon makes "Decline" wrap in the 1/3 column.
                          child: CeButton.danger(label: 'Decline', dense: true, onPressed: () => _respond(c, accept: false)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: CeButton(
                            label: 'Accept Challenge',
                            dense: true,
                            icon: CeIcons.of('check'),
                            onPressed: () => _respond(c, accept: true),
                          ),
                        ),
                      ]),
              ),

          // ---- Sent, awaiting their reply (Demo OFF — approved P9) ----
          if (sections.sent.isNotEmpty) ...[
            const CeSectionHeader('Sent'),
            for (final c in sections.sent)
              if (dir[c.opponentClubId] case final club?)
                ChallengeCard(
                  abbr: club.abbr,
                  color: club.color,
                  name: club.name,
                  meta: Text('Sent ${CeFormat.dayMonth(c.createdAt)}'
                      '${c.expiresAt == null ? '' : ' · expires ${CeFormat.dayMonth(c.expiresAt!)}'}'),
                  trailing: challengeStatusChip(ChallengeStatus.pending, c.direction),
                  details: details(c),
                  onTap: () => context.push(Routes.clubProfile(club.id)),
                ),
          ],

          // ---- Resolved ----
          const CeSectionHeader('Resolved'),
          if (sections.resolved.isEmpty) empty('No resolved challenges yet.'),
          for (final c in sections.resolved)
            if (dir[c.opponentClubId] case final club?)
              ChallengeCard(
                abbr: club.abbr,
                color: club.color,
                name: club.name,
                meta: Text([
                  if (c.format != null) c.format!.display(),
                  if (c.proposedAt != null) CeFormat.dayDate(c.proposedAt!) else CeFormat.dayDate(c.createdAt),
                  c.direction == ChallengeDirection.sent ? 'Sent' : 'Received',
                ].join(' · ')),
                trailing: challengeStatusChip(c.statusAt(now), c.direction),
                onTap: () => context.push(Routes.clubProfile(club.id)),
              ),
        ],
      ]),
    );
  }
}
