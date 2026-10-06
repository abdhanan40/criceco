import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';
import '../widgets/challenge_sheet.dart';
import '../widgets/challenge_widgets.dart';

/// My Challenges (prototype `screens.myChallenges`, :7044): incoming and
/// outgoing challenges. A card opens the challenge in a bottom sheet, where a
/// pending incoming challenge is accepted or declined (no new screen); the
/// opponent's Club Profile is one tap further.
class MyChallengesScreen extends ConsumerWidget {
  const MyChallengesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    // A sheet first (details; Accept / Decline for a received challenge).
    void open(Challenge c) => openChallengeSheet(context, ref, c);

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
                onTap: () => open(c),
                actions: const _RespondHint(),
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
                  onTap: () => open(c),
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
                onTap: () => open(c),
              ),
        ],
      ]),
    );
  }
}

/// Where the answer happens, in place of the old Accept / Decline buttons.
class _RespondHint extends StatelessWidget {
  const _RespondHint();

  @override
  Widget build(BuildContext context) => Row(children: [
        const Expanded(
          child: Text('Tap to accept or decline',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: CeColors.primaryDark)),
        ),
        Icon(CeIcons.of('chevron-right'), size: 15, color: CeColors.primaryDark),
      ]);
}
