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
import '../../../shared/widgets/ce_segmented.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../player_providers.dart';

/// Status chip for a player match (CONFIRMED / PLAYED / CANCELLED).
Widget playerMatchStatusChip(PlayerMatchStatus status) => switch (status) {
      PlayerMatchStatus.upcoming => const CeStatusChip('Confirmed', icon: 'check'),
      PlayerMatchStatus.past => const CeStatusChip('Played', tone: CeTone.neutral),
      PlayerMatchStatus.cancelled => const CeStatusChip('Cancelled', tone: CeTone.red, icon: 'x'),
    };

/// My Matches (prototype `screens.myMatches`, :3419). Tabs Upcoming / Past /
/// Cancelled; the tab lives in the URL (`?tab=`) so it survives branch
/// switches and deep links. Every card opens Player Match Details (P2).
class MyMatchesScreen extends ConsumerWidget {
  const MyMatchesScreen({super.key, this.tab = PlayerMatchStatus.upcoming});

  final PlayerMatchStatus tab;

  static PlayerMatchStatus parseTab(String? raw) =>
      PlayerMatchStatus.values.where((s) => s.name == raw).firstOrNull ?? PlayerMatchStatus.upcoming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(playerMatchesProvider).isLoading;
    final matches = ref.watch(playerMatchesByStatusProvider(tab));
    return Scaffold(
      appBar: CeTopBar(title: 'My Matches', onBack: () => context.go(Routes.playerHome)),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        CeSegmentedTabs<PlayerMatchStatus>(
          values: PlayerMatchStatus.values,
          selected: tab,
          labelOf: (s) => s.label,
          onSelected: (s) => context.go('${Routes.myMatches}?tab=${s.name}'),
        ),
        if (loading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (matches.isEmpty)
          CeEmptyState(
            icon: 'circle-dot',
            title: 'No ${tab.label.toLowerCase()} matches',
            body: 'Matches will show up here.',
          )
        else
          for (final m in matches) PlayerMatchCard(match: m),
      ]),
    );
  }
}

/// `.confirmed-match-card` in the Player context.
class PlayerMatchCard extends StatelessWidget {
  const PlayerMatchCard({super.key, required this.match});
  final PlayerMatch match;

  @override
  Widget build(BuildContext context) {
    final m = match;
    Widget? footer;
    if (m.status == PlayerMatchStatus.past && m.resultText != null) {
      final won = m.result == MatchResult.won;
      final color = won ? CeColors.primaryDark : CeColors.red;
      footer = Row(children: [
        Flexible(
          child: Text(m.resultText!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
        ),
        if (m.hasScorecard) ...[
          Text(' · Tap for details', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(width: 3),
          Icon(CeIcons.of('arrow-right'), size: 13, color: color),
        ],
      ]);
    } else if (m.status == PlayerMatchStatus.cancelled && m.cancelReason != null) {
      footer = Text('Reason: ${m.cancelReason}', style: const TextStyle(fontSize: 12, color: CeColors.muted));
    }
    return Semantics(
      button: true,
      label: '${m.ownTeamName} vs ${m.opponentName}, ${m.status.label}',
      child: CeMatchCard(
        homeAbbr: m.ownTeamAbbr,
        awayAbbr: m.opponentAbbr,
        title: '${m.ownTeamName} vs ${m.opponentName}',
        status: playerMatchStatusChip(m.status),
        infoChips: [
          CeInfoChip(icon: 'calendar', label: CeFormat.dayDate(m.startsAt)),
          CeInfoChip(icon: 'clock', label: CeFormat.time(m.startsAt)),
          CeInfoChip(icon: 'circle-dot', label: m.format.display()),
        ],
        ground: m.ground,
        playingTeam: m.playingTeamName,
        footer: footer,
        onTap: () => context.go(Routes.playerMatchDetails(m.id)),
      ),
    );
  }
}
