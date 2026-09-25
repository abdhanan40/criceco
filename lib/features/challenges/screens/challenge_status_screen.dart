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

/// Challenge Status (prototype `screens.challengeAccepted`, :6160). Terminal:
/// system Back hands off to Match Management → Waiting. The pending match was
/// created when the challenge was accepted (fix: the prototype created it on
/// this screen's button, so leaving or revisiting could lose or duplicate it).
/// Pending / declined / expired states are shown too (Demo OFF, deep links).
class ChallengeStatusScreen extends ConsumerWidget {
  const ChallengeStatusScreen({super.key, required this.challengeId});
  final String challengeId;

  static final _waiting = Routes.matchManagement(MatchTab.waiting);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(challengesProvider).isLoading || ref.watch(clubDirectoryProvider).isLoading;
    final c = ref.watch(challengeProvider(challengeId));
    final club = c == null ? null : ref.watch(clubDirectoryProvider).value?[c.opponentClubId];
    final status = c?.statusAt(ref.read(clockProvider).now());

    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (c == null || club == null) {
      body = CeEmptyState(
        icon: 'swords',
        title: 'Challenge not found',
        body: 'This challenge is no longer available.',
        primaryLabel: 'Back to Challenges',
        onPrimary: () => context.go(Routes.challenges),
      );
    } else {
      final (icon, title, text, danger) = switch (status!) {
        ChallengeStatus.accepted => (
            'check',
            'Challenge Accepted!',
            "${club.name} has accepted your challenge. It's now in your Upcoming Matches — "
                "open it whenever you're ready to set up the match.",
            false,
          ),
        ChallengeStatus.pending => (
            'hourglass',
            'Challenge Sent',
            "Waiting for ${club.name} to respond. You'll find it under Sent on My Challenges"
                '${c.expiresAt == null ? '' : ' until it expires on ${CeFormat.date(c.expiresAt!)}'}.',
            false,
          ),
        ChallengeStatus.declined => ('x', 'Challenge Declined', '${club.name} declined this challenge.', true),
        ChallengeStatus.expired => ('timer', 'Challenge Expired', 'This challenge expired without a response.', true),
      };
      body = ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        CeSuccessPanel(
          icon: icon,
          title: title,
          danger: danger,
          body: Text(text, textAlign: TextAlign.center),
        ),
        CeSummaryCard(rows: [
          ('Opponent', CeSummaryCard.value(context, club.name)),
          ('City', CeSummaryCard.value(context, club.city)),
          ('Preferred Format', CeSummaryCard.value(context, c.format?.display() ?? club.formats)),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
          child: status == ChallengeStatus.accepted
              ? CeButton(
                  label: 'View in Upcoming Matches',
                  trailingIcon: CeIcons.of('arrow-right'),
                  onPressed: () => context.go(_waiting),
                )
              : CeButton(label: 'View My Challenges', onPressed: () => context.go(Routes.myChallenges)),
        ),
      ]);
    }

    final exit = status == null || status == ChallengeStatus.accepted ? _waiting : Routes.myChallenges;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(exit);
      },
      child: Scaffold(
        appBar: const CeTopBar(title: 'Challenge Status', showBack: false),
        body: body,
      ),
    );
  }
}
