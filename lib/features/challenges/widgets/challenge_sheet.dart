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
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';
import 'challenge_widgets.dart';

enum _ChallengeAction { accept, decline, viewClub }

/// My Challenges → a challenge: its details in a sheet. A received challenge
/// still awaiting a decision is answered right here (Accept / Decline, each
/// confirmed, via [respondToChallenge]); the club's full profile is one tap
/// further ("View Club Profile").
Future<void> openChallengeSheet(BuildContext context, WidgetRef ref, Challenge c) async {
  final action = await showCeSheet<_ChallengeAction>(context, builder: (_) => _ChallengeSheet(challengeId: c.id));
  if (action == null || !context.mounted) return;
  switch (action) {
    case _ChallengeAction.accept:
      await respondToChallenge(context, ref, c, accept: true);
    case _ChallengeAction.decline:
      await respondToChallenge(context, ref, c, accept: false);
    case _ChallengeAction.viewClub:
      await context.push(Routes.clubProfile(c.opponentClubId, challengeId: c.id));
  }
}

class _ChallengeSheet extends ConsumerWidget {
  const _ChallengeSheet({required this.challengeId});
  final String challengeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(challengeProvider(challengeId));
    final summary = c == null ? null : ref.watch(clubDirectoryProvider).value?[c.opponentClubId];
    final club = c == null ? null : ChallengeOpponent.forChallenge(c, summary);
    final live = ref.watch(challengesLiveProvider);
    final busy = ref.watch(respondingChallengesProvider).contains(challengeId);
    if (c == null || club == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('This challenge is no longer available.', textAlign: TextAlign.center),
      );
    }
    final now = ref.read(clockProvider).now();
    final status = c.statusAt(now);
    final received = c.direction == ChallengeDirection.received;
    final canAnswer = received && status == ChallengeStatus.pending;
    void close(_ChallengeAction a) => Navigator.of(context).pop(a);

    return Column(
      key: const Key('challenge.sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          CeTeamBadge(club.abbr, color: opponentColor(club), size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(club.name, style: Theme.of(context).textTheme.titleLarge),
              Text(club.meta,
                  style: const TextStyle(fontSize: 12, color: CeColors.muted)),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: Text(received ? 'Challenge received' : 'Challenge sent',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.ink2)),
          ),
          const SizedBox(width: 8),
          challengeStatusChip(status, c.direction),
        ]),
        const SizedBox(height: 4),
        CeSummaryCard(
          margin: EdgeInsets.zero,
          rows: [
            ('Format', CeSummaryCard.value(context, c.format?.display(c.customOvers) ?? 'Not set')),
            // A date-only proposal (midnight) shows no time.
            if (c.proposedAt case final at?)
              at.hour == 0 && at.minute == 0
                  ? ('Date', CeSummaryCard.value(context, CeFormat.dayDate(at)))
                  : ('Date & time', CeSummaryCard.value(context, '${CeFormat.dayDate(at)} · ${CeFormat.time(at)}')),
            if (c.groundName != null) (live ? 'Venue' : 'Ground', CeSummaryCard.value(context, c.groundName!)),
            if (c.message != null) ('Message', CeSummaryCard.value(context, c.message!)),
            (received ? 'Received' : 'Sent', CeSummaryCard.value(context, CeFormat.dayMonth(c.createdAt))),
            if (status == ChallengeStatus.pending && c.expiresAt != null)
              ('Expires', CeSummaryCard.value(context, CeFormat.dayMonth(c.expiresAt!))),
          ],
        ),
        const SizedBox(height: 16),
        if (canAnswer) ...[
          Row(children: [
            Expanded(
              child: CeButton.danger(
                key: const Key('challenge.decline'),
                label: 'Decline',
                icon: CeIcons.of('x'),
                onPressed: busy ? null : () => close(_ChallengeAction.decline),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CeButton(
                key: const Key('challenge.accept'),
                label: 'Accept',
                icon: CeIcons.of('check'),
                loading: busy,
                onPressed: busy ? null : () => close(_ChallengeAction.accept),
              ),
            ),
          ]),
          const SizedBox(height: 8),
        ],
        // Club profiles exist only for the demo's clubs (no server profiles yet).
        if (club.summary != null)
          CeButton.soft(label: 'View Club Profile', onPressed: () => close(_ChallengeAction.viewClub)),
      ],
    );
  }
}
