import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_indicators.dart';
import '../../shared/widgets/ce_surfaces.dart';

const fitnessNote = 'Workload indication from the last 7 days of matches — not a medical assessment.';

CeTone fitnessTone(FitnessLevel l) => switch (l) {
      FitnessLevel.fresh => CeTone.green,
      FitnessLevel.moderate => CeTone.blue,
      FitnessLevel.fatigued => CeTone.amber,
      FitnessLevel.overloaded => CeTone.red,
    };

/// "7/10 · MODERATE" pill (member cards, suggestion rows).
class FitnessBadge extends StatelessWidget {
  const FitnessBadge(this.report, {super.key});
  final FitnessReport report;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Fitness ${report.score} out of 10, ${report.level.label}',
        excludeSemantics: true,
        child: CeStatusChip('${report.score}/10 · ${report.level.label}',
            tone: report.avoidPlaying ? CeTone.red : fitnessTone(report.level), icon: 'activity'),
      );
}

/// Ten-segment meter bar.
class _MeterBar extends StatelessWidget {
  const _MeterBar({required this.score, required this.color});
  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < FitnessReport.max; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: Container(
              height: 7,
              decoration: BoxDecoration(
                color: i < score ? color : CeColors.line,
                borderRadius: BorderRadius.circular(CeRadius.pill),
              ),
            ),
          ),
        ],
      ]);
}

/// The Fitness Meter card: score, level, recommendation and the top alert.
/// [onTap] (Player Dashboard) opens the details sheet; [expanded] (Member
/// Profile) shows the 7-day breakdown and every alert inline.
class FitnessMeterCard extends StatelessWidget {
  const FitnessMeterCard({
    super.key,
    required this.report,
    this.onTap,
    this.expanded = false,
    this.margin = const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
  });

  final FitnessReport report;
  final VoidCallback? onTap;
  final bool expanded;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final (bg, fg) = CeStatusChip.colors(r.avoidPlaying ? CeTone.red : fitnessTone(r.level));
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        CeIconWell('activity', size: 36, iconSize: 17, background: bg, color: fg),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Fitness Meter', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: CeColors.ink)),
            Text('Last 7 days · match workload', style: TextStyle(fontSize: 11, color: CeColors.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: '${r.score}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: fg)),
            const TextSpan(text: '/10', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.muted)),
          ]),
        ),
      ]),
      const SizedBox(height: 10),
      _MeterBar(score: r.score, color: fg),
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CeStatusChip(r.level.label, tone: fitnessTone(r.level)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(r.recommendation,
              key: const Key('fitness.recommendation'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink, height: 1.3)),
        ),
      ]),
      if (!expanded && r.alerts.isNotEmpty) ...[
        const SizedBox(height: 8),
        _AlertLine(r.alerts.first),
      ],
      if (expanded) ...[
        const SizedBox(height: 12),
        FitnessBreakdown(report: r),
      ],
      if (onTap != null) ...[
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          const Text('Details', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.primary)),
          Icon(CeIcons.of('chevron-right'), size: 13, color: CeColors.primary),
        ]),
      ],
    ]);
    return Semantics(
      button: onTap != null,
      label: 'Fitness Meter, ${r.score} out of 10, ${r.level.label}. ${r.recommendation}',
      child: CeCard(
        key: const Key('fitness.card'),
        margin: margin,
        onTap: onTap,
        child: body,
      ),
    );
  }
}

class _AlertLine extends StatelessWidget {
  const _AlertLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(CeIcons.of('info'), size: 13, color: CeColors.amberInk),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: CeColors.ink2, height: 1.3))),
        ]),
      );
}

/// 7-day breakdown, all alerts and the note.
class FitnessBreakdown extends StatelessWidget {
  const FitnessBreakdown({super.key, required this.report});
  final FitnessReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final since = r.daysSinceLastMatch;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CeStatGroup(
        margin: EdgeInsets.zero,
        cells: [
          CeStatCell(value: '${r.matches}', label: 'Matches'),
          CeStatCell(value: r.oversBowled, label: 'Overs bowled'),
          CeStatCell(value: '${r.ballsFaced}', label: 'Balls faced'),
          CeStatCell(
            value: since == null ? '–' : '$since',
            label: since == 1 ? 'Day since last' : 'Days since last',
          ),
        ],
      ),
      if (r.alerts.isNotEmpty) ...[
        const SizedBox(height: 10),
        for (final a in r.alerts) _AlertLine(a),
      ],
      if (r.restDays > 0) ...[
        const SizedBox(height: 4),
        Text('Suggested rest: ${r.restDays} day${r.restDays == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
      ],
      const SizedBox(height: 8),
      const Text(fitnessNote, style: TextStyle(fontSize: 10.5, color: CeColors.muted2, height: 1.35)),
    ]);
  }
}

/// Player Dashboard → Fitness Meter details (no navigation).
Future<void> showFitnessSheet(BuildContext context, FitnessReport report) => showCeSheet<void>(
      context,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Fitness Meter', style: Theme.of(ctx).textTheme.titleLarge),
        const SizedBox(height: 12),
        FitnessMeterCard(report: report, expanded: true, margin: EdgeInsets.zero),
        const SizedBox(height: 16),
        CeButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
      ]),
    );
