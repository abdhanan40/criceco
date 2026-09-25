import 'package:flutter/material.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';

/// `.squad-filter-row`: All / Batsman / Bowler / All-Rounder with counts.
class SquadFilterRow extends StatelessWidget {
  const SquadFilterRow({super.key, required this.selected, required this.countOf, required this.onSelected});
  final SquadCategory? selected;
  final int Function(SquadCategory?) countOf;
  final ValueChanged<SquadCategory?> onSelected;

  @override
  Widget build(BuildContext context) => CeChipRow<SquadCategory?>(
        values: const [null, ...SquadCategory.values],
        selected: selected,
        labelOf: (c) => c?.label ?? 'All',
        countOf: countOf,
        onSelected: onSelected,
      );
}

/// PLAYING XI / SUB badge (`.spr-badge`), shared by Team Squad and Add Players.
class SelectionBadge extends StatelessWidget {
  const SelectionBadge({super.key, required this.role});
  final SelectionRole role;

  @override
  Widget build(BuildContext context) {
    final playing = role == SelectionRole.playing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: playing ? CeColors.primaryDark : CeColors.amber,
        borderRadius: BorderRadius.circular(CeRadius.pill),
      ),
      child: Text(playing ? 'PLAYING XI' : 'SUB',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.3, color: Colors.white)),
    );
  }
}

/// Player scouting sheet (prototype `ceOpenPlayerSheet`, :7734).
Future<void> showPlayerStatsSheet(BuildContext context, {required SquadPlayer player, required PlayerStats stats}) {
  return showCeSheet<void>(context, builder: (ctx) => _PlayerStatsSheet(player: player, stats: stats));
}

class _PlayerStatsSheet extends StatelessWidget {
  const _PlayerStatsSheet({required this.player, required this.stats});
  final SquadPlayer player;
  final PlayerStats stats;

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: CeColors.muted)),
      );

  Widget _grid(List<(String, String)> cells) => Row(children: [
        for (var i = 0; i < cells.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(CeRadius.md),
                border: Border.all(color: CeColors.line),
              ),
              child: Column(children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(cells[i].$2,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                ),
                const SizedBox(height: 2),
                Text(cells[i].$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: CeColors.muted)),
              ]),
            ),
          ),
        ],
      ]);

  @override
  Widget build(BuildContext context) {
    final s = stats;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        CeAvatar(player.name, size: 46, background: CeColors.primary, foreground: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(text: player.name),
                if (s.verified)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 5),
                      child: Semantics(
                        label: 'Verified player',
                        child: Icon(CeIcons.of('check-circle'), size: 15, color: CeColors.primary),
                      ),
                    ),
                  ),
              ]),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: CeColors.ink),
            ),
            const SizedBox(height: 2),
            Text('${player.position} · ${s.skill.label} level',
                style: const TextStyle(fontSize: 12, color: CeColors.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.md)),
          child: Column(children: [
            Text(s.rating, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
            const Text('Rating', style: TextStyle(fontSize: 9.5, color: CeColors.muted)),
          ]),
        ),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 6, runSpacing: 6, children: [
        _Pill(player.category.label),
        _Pill(player.availability.label),
        _Pill('${s.matches} matches'),
      ]),
      _label('Batting'),
      _grid([
        ('Runs', '${s.batting.runs}'),
        ('Average', s.batting.average),
        ('Strike rate', s.batting.strikeRate),
        ('Best', s.batting.best),
      ]),
      _label('Bowling'),
      _grid([
        ('Wickets', '${s.bowling.wickets}'),
        ('Economy', s.bowling.economy),
        ('Average', s.bowling.average),
        ('Best', s.bowling.best),
      ]),
      _label('Recent form'),
      Row(children: [
        CeFormDots(s.form, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text('${s.wins}W · ${s.losses}L in last 5',
              style: const TextStyle(fontSize: 12, color: CeColors.muted)),
        ),
      ]),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.md),
          border: Border.all(color: CeColors.line),
        ),
        child: Row(children: [
          Icon(CeIcons.of('circle-dot'), size: 14, color: CeColors.primaryDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: 'Last match vs ${s.lastMatch.opponent} — '),
                TextSpan(text: s.lastMatch.line, style: const TextStyle(fontWeight: FontWeight.w800, color: CeColors.ink)),
              ]),
              style: const TextStyle(fontSize: 12, color: CeColors.ink2),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      CeButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.pill),
          border: Border.all(color: CeColors.line),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: CeColors.ink2)),
      );
}
