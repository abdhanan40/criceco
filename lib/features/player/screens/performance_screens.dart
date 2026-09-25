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
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../player_providers.dart';

const _blueTint = CeColors.blueSoft;
const _amberTint = CeColors.amberSoft;
const _redTint = CeColors.redSoft;
const _mintTint = CeColors.mint;

/// Icon + tint per stat label (prototype `battingStatsData` etc.).
const Map<String, (String, Color)> _statStyle = {
  'Matches Played': ('flag', _blueTint),
  'Runs Scored': ('circle-dot', _mintTint),
  'Batting Average': ('bar-chart', _blueTint),
  'Strike Rate': ('zap', _amberTint),
  'Best Score': ('star', _redTint),
  'Half Centuries': ('award', _mintTint),
  'Centuries': ('star', _blueTint),
  'Not Outs': ('shield', _amberTint),
  'Boundaries (4s/6s)': ('rocket', _redTint),
  'Wickets Taken': ('target', _mintTint),
  'Bowling Average': ('bar-chart', _blueTint),
  'Economy Rate': ('zap', _amberTint),
  'Best Bowling': ('star', _redTint),
  'Overs Bowled': ('circle-dot', _mintTint),
  'Maiden Overs': ('snowflake', _blueTint),
  'Catches Taken': ('hand', _mintTint),
  'Run Outs': ('wind', _blueTint),
  'Stumpings': ('target', _amberTint),
  'Direct Hits': ('circle-dot', _redTint),
};

Widget _loadingOr(AsyncValue<PerformanceSummary> async, Widget Function(PerformanceSummary) builder) =>
    async.when(
      data: builder,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const CeEmptyState(
        icon: 'info',
        title: 'Performance unavailable',
        body: 'Your stats could not be loaded. Please try again later.',
      ),
    );

/// My Performance (prototype `screens.myPerformance`, :3906).
class MyPerformanceScreen extends ConsumerWidget {
  const MyPerformanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(performanceTabProvider);
    return Scaffold(
      appBar: CeTopBar(title: 'My Performance', onBack: () => context.go(Routes.playerHome)),
      body: _loadingOr(ref.watch(performanceProvider), (p) {
        final stats = switch (tab) {
          PerformanceTab.batting => p.batting,
          PerformanceTab.bowling => p.bowling,
          PerformanceTab.fielding => p.fielding,
        };
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          CeSummaryStrip(items: [
            ('${p.matches}', 'Matches'),
            ('${p.recentWins}W - ${p.recentLosses}L', 'Recent Form'),
            ('${p.runs}', 'Runs'),
            ('${p.wickets}', 'Wickets'),
          ]),
          const CeSectionHeader('Recent Form', padding: EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0)),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
            child: Row(children: [
              for (var i = 0; i < p.recentForm.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(child: _FormChip(entry: p.recentForm[i])),
              ],
            ]),
          ),
          const CeSectionHeader('Statistics', padding: EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0)),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
            child: Row(children: [
              for (final t in PerformanceTab.values) ...[
                if (t.index > 0) const SizedBox(width: 8),
                CeChip(
                  label: t.label,
                  icon: t.icon,
                  selected: t == tab,
                  onTap: () => ref.read(performanceTabProvider.notifier).select(t),
                ),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
            child: _StatGrid(tiles: stats),
          ),
          CeSectionHeader('Match-by-Match',
              actionLabel: 'View All',
              onAction: () {
                ref.read(historyFilterProvider.notifier).select(HistoryFilter.all);
                context.go(Routes.matchHistory);
              },
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0)),
          for (final m in p.matchLog.take(5)) MatchLogCard(entry: m),
        ]);
      }),
    );
  }
}

/// Match History (prototype `screens.matchHistory`, :3875).
class MatchHistoryScreen extends ConsumerWidget {
  const MatchHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(historyFilterProvider);
    return Scaffold(
      appBar: const CeTopBar(title: 'Match History', fallbackLocation: Routes.myPerformance),
      body: _loadingOr(ref.watch(performanceProvider), (p) {
        final log = p.matchLog;
        final wins = log.where((m) => m.result == MatchResult.won).length;
        final filtered = log.where((m) => filter.matches(m.result)).toList();
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          CeSummaryStrip(items: [('${log.length}', 'Total'), ('$wins', 'Won'), ('${log.length - wins}', 'Lost')]),
          CeChipRow<HistoryFilter>(
            values: HistoryFilter.values,
            selected: filter,
            labelOf: (f) => f.label,
            onSelected: ref.read(historyFilterProvider.notifier).select,
          ),
          if (filtered.isEmpty)
            const CeEmptyState(icon: 'circle-dot', title: 'No matches', body: 'No matches found for this filter.')
          else
            for (final m in filtered) MatchLogCard(entry: m),
        ]);
      }),
    );
  }
}

class _FormChip extends StatelessWidget {
  const _FormChip({required this.entry});
  final FormEntry entry;

  @override
  Widget build(BuildContext context) {
    final won = entry.result == MatchResult.won;
    return Semantics(
      label: '${won ? 'Won' : 'Lost'} against ${entry.opponentAbbr}, ${entry.runs} runs',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.md),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: Column(children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: won ? CeColors.fresh : CeColors.red,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(won ? 'W' : 'L',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('${entry.opponentAbbr} · ${entry.runs}r',
                style: const TextStyle(fontSize: 9, color: CeColors.muted)),
          ),
        ]),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.tiles});
  final List<StatTile> tiles;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += 2) {
      Widget cell(StatTile t) {
        final (icon, tint) = _statStyle[t.label] ?? ('circle-dot', _mintTint);
        return CeStatTile(icon: icon, value: t.value, label: t.label, tint: tint);
      }

      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: cell(tiles[i])),
            const SizedBox(width: 10),
            Expanded(child: i + 1 < tiles.length ? cell(tiles[i + 1]) : const SizedBox.shrink()),
          ]),
        ),
      ));
    }
    return Column(children: rows);
  }
}

/// `.mp-match-card` — one match in the player's log.
class MatchLogCard extends StatelessWidget {
  const MatchLogCard({super.key, required this.entry});
  final MatchLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final m = entry;
    return CeCard(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CeTeamBadge(m.opponentAbbr, color: clubBadgeColor(m.opponentAbbr), size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('vs ${m.opponentName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(CeIcons.of('calendar'), size: 11, color: CeColors.muted),
                const SizedBox(width: 4),
                Text(CeFormat.date(m.date), style: const TextStyle(fontSize: 11, color: CeColors.muted)),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          CeResultPill(won: m.result == MatchResult.won),
        ]),
        const Padding(padding: EdgeInsets.only(top: 10), child: Divider(height: 1, color: Color(0xFFF1F5F2))),
        const SizedBox(height: 10),
        Wrap(spacing: 14, runSpacing: 4, children: [
          _Stat(icon: 'circle-dot', strong: '${m.runs}', rest: ' (${m.balls}b)'),
          _Stat(icon: 'target', strong: '${m.wickets}', rest: '/${m.overs} ov'),
        ]),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.strong, required this.rest});
  final String icon;
  final String strong;
  final String rest;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 13, color: CeColors.primaryDark),
        const SizedBox(width: 5),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: strong, style: const TextStyle(fontWeight: FontWeight.w800, color: CeColors.ink)),
            TextSpan(text: rest),
          ]),
          style: const TextStyle(fontSize: 12, color: CeColors.muted),
        ),
      ]);
}
