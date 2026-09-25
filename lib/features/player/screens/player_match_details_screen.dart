import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../player_providers.dart';
import 'my_matches_screen.dart';

/// Details tab of the Player Match workspace — the former Player Match
/// Details screen (revised architecture §3). Read-only, Player context only:
/// no Club Owner actions.
class MatchDetailsView extends ConsumerWidget {
  const MatchDetailsView({super.key, required this.match, this.onViewScorecard});
  final PlayerMatch match;

  /// "View Scorecard" (past matches with a scorecard) → the Scorecard tab.
  final VoidCallback? onViewScorecard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = match;
    final availability = ref.watch(playerAvailabilityProvider);
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        // ---- Header ----
        CeBrandHero(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          radius: 18,
          padding: const EdgeInsets.all(18),
          child: Column(children: [
            Align(alignment: Alignment.centerRight, child: playerMatchStatusChip(m.status)),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              CeTeamBadge(m.ownTeamAbbr, size: 48, onDark: true),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('VS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
              ),
              CeTeamBadge(m.opponentAbbr, size: 48, onDark: true),
            ]),
            const SizedBox(height: 10),
            Text('${m.ownTeamName} vs ${m.opponentName}',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            if (m.matchType != null) ...[
              const SizedBox(height: 4),
              Text(m.matchType!, style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.85))),
            ],
          ]),
        ),

        // ---- Status-specific block ----
        switch (m.status) {
          PlayerMatchStatus.upcoming => _Countdown(startsAt: m.startsAt),
          PlayerMatchStatus.past => _ResultBlock(match: m, onViewScorecard: onViewScorecard),
          PlayerMatchStatus.cancelled => _Notice(
              icon: 'x-circle',
              text: 'This match was cancelled. Reason: ${m.cancelReason ?? 'Not specified'}',
              danger: true,
            ),
        },

        // ---- Match info ----
        const CeSectionHeader('Match Info'),
        CeCard(
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              CeInfoChip(icon: 'calendar', label: CeFormat.dayDate(m.startsAt)),
              CeInfoChip(icon: 'clock', label: CeFormat.time(m.startsAt)),
              CeInfoChip(icon: 'circle-dot', label: m.format.display()),
            ]),
            const SizedBox(height: 10),
            CeGroundRow(ground: m.ground),
            const SizedBox(height: 10),
            Row(children: [
              Icon(CeIcons.of('users'), size: 13, color: CeColors.muted),
              const SizedBox(width: 5),
              const Text('Playing: ', style: TextStyle(fontSize: 12, color: CeColors.muted)),
              Flexible(
                child: Text(m.playingTeamName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink)),
              ),
            ]),
          ]),
        ),

        // ---- Availability (upcoming only: past/cancelled can't be changed) ----
        if (m.status == PlayerMatchStatus.upcoming) ...[
          const CeSectionHeader('Your Availability'),
          CeCard(
            margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const CeIconWell('check-circle', size: 40, iconSize: 19),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CeStatusChip(availability.status.label, tone: availabilityTone(availability.status)),
                    const SizedBox(height: 4),
                    Text(availability.status.description,
                        style: const TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.35)),
                  ]),
                ),
              ]),
              const SizedBox(height: 12),
              CeButton.soft(
                label: 'Update Availability',
                icon: CeIcons.of('check-circle'),
                onPressed: () => context.go(Routes.availability),
              ),
            ]),
          ),
        ],
      ]);
  }
}

class _Countdown extends ConsumerWidget {
  const _Countdown({required this.startsAt});
  final DateTime startsAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider).value ?? ref.read(clockProvider).now();
    final remaining = startsAt.difference(now);
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
      child: Row(children: [
        Icon(CeIcons.of('clock'), size: 18, color: CeColors.primaryDark),
        const SizedBox(width: 10),
        const Text('Match starts in', style: TextStyle(fontSize: 12, color: CeColors.primaryDark)),
        const SizedBox(width: 8),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(remaining.isNegative ? 'Started' : CeFormat.hms(remaining),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: CeColors.primaryDark,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ),
      ]),
    );
  }
}

class _ResultBlock extends StatelessWidget {
  const _ResultBlock({required this.match, this.onViewScorecard});
  final PlayerMatch match;
  final VoidCallback? onViewScorecard;

  @override
  Widget build(BuildContext context) {
    final won = match.result == MatchResult.won;
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: won ? CeColors.mint : CeColors.redSoft,
        borderRadius: BorderRadius.circular(CeRadius.row),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(CeIcons.of('trophy'), size: 18, color: won ? CeColors.primaryDark : CeColors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(match.resultText ?? (won ? 'Won' : 'Lost'),
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: won ? CeColors.primaryDark : CeColors.red)),
          ),
        ]),
        if (match.hasScorecard && onViewScorecard != null) ...[
          const SizedBox(height: 12),
          CeButton(
            label: 'View Scorecard',
            icon: CeIcons.of('file-text'),
            onPressed: onViewScorecard,
          ),
        ],
      ]),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.danger = false});
  final String icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: danger ? CeColors.redSoft : CeColors.mint,
          borderRadius: BorderRadius.circular(CeRadius.row),
          border: Border.all(color: danger ? CeColors.redBorder : CeColors.mint2),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(CeIcons.of(icon), size: 17, color: danger ? CeColors.red : CeColors.primaryDark),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600, color: danger ? CeColors.red : CeColors.primaryDark)),
          ),
        ]),
      );
}
