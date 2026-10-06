import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../player_providers.dart';
import '../screens/performance_screens.dart' show FormChip;

/// Player Dashboard → Performance: a compact summary of the player's real
/// numbers ([performanceProvider]) in a sheet. "View Full Performance" opens
/// the existing Performance screen.
Future<void> showPerformanceSheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => _PerformanceSheet(router: GoRouter.of(context)));

class _PerformanceSheet extends ConsumerWidget {
  const _PerformanceSheet({required this.router});
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(performanceProvider);
    final p = async.value;
    return Column(
      key: const Key('performance.sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of('bar-chart'), size: 18, color: CeColors.primaryDark),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text('Player Performance', style: Theme.of(context).textTheme.titleLarge)),
        ]),
        const SizedBox(height: 14),
        if (p == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: async.hasError
                ? const Text("Couldn't load your performance.", textAlign: TextAlign.center)
                : const Center(child: CircularProgressIndicator()),
          )
        else
          ..._summary(p),
        const SizedBox(height: 16),
        CeButton(
          label: 'View Full Performance',
          trailingIcon: CeIcons.of('arrow-right'),
          onPressed: () {
            Navigator.of(context).pop();
            router.go(Routes.myPerformance);
          },
        ),
      ],
    );
  }

  List<Widget> _summary(PerformanceSummary p) {
    String? snap(String label) => p.snapshot.where((t) => t.label == label).firstOrNull?.value;
    final cells = [
      ('${p.matches}', 'Matches'),
      ('${p.runs}', 'Runs'),
      ('${p.wickets}', 'Wickets'),
      (p.battingAverage, 'Bat Avg'),
      if (snap('Strike Rate') case final sr?) (sr, 'Strike Rate'),
      if (snap('Best Score') case final best?) (best, 'Best Score'),
    ];
    return [
      // ---- Rating ----
      Container(
        key: const Key('performance.rating'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [CeColors.primaryDark, CeColors.primary]),
          borderRadius: BorderRadius.circular(CeRadius.lg),
        ),
        child: Row(children: [
          const Expanded(
            child: Text('Performance Rating',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          Text(p.rating,
              style: const TextStyle(fontFamily: CeType.display, fontSize: 26, height: 1, fontWeight: FontWeight.w700, color: Colors.white)),
        ]),
      ),
      const SizedBox(height: 10),
      // ---- Key numbers: two rows of three ----
      for (var i = 0; i < cells.length; i += 3) ...[
        if (i > 0) const SizedBox(height: 8),
        Row(children: [
          for (var j = i; j < i + 3; j++) ...[
            if (j > i) const SizedBox(width: 8),
            Expanded(child: j < cells.length ? _Cell(value: cells[j].$1, label: cells[j].$2) : const SizedBox.shrink()),
          ],
        ]),
      ],
      // ---- Recent form ----
      if (p.recentForm.isNotEmpty) ...[
        const SizedBox(height: 14),
        Row(children: [
          const Expanded(
            child: Text('Recent Form', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
          ),
          Text('${p.recentWins}W - ${p.recentLosses}L',
              key: const Key('performance.formRecord'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.muted)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (var i = 0; i < p.recentForm.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(child: FormChip(entry: p.recentForm[i])),
          ],
        ]),
      ],
    ];
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        key: Key('performance.cell.$label'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.md),
          border: Border.all(color: CeColors.line),
        ),
        child: Column(children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: const TextStyle(fontFamily: CeType.display, fontSize: 17, fontWeight: FontWeight.w700, color: CeColors.ink)),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: const TextStyle(fontSize: 11, color: CeColors.muted)),
          ),
        ]),
      );
}
