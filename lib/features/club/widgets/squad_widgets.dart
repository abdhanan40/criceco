import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../club_providers.dart';

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
/// `.pick-counter`: "x/11" + label.
class SquadCounter extends StatelessWidget {
  const SquadCounter({super.key, required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.md)),
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: CeColors.primaryDark,
                  fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10.5, color: CeColors.muted)),
        ]),
      );
}

/// `.squad-pick-row` shared by Add Players and the match-day Team Builder:
/// playing / sub / locked states. Scouting meta and the Stats button only
/// show when [onStats] is given (Add Players; prototype parity).
class SquadPickRow extends ConsumerWidget {
  const SquadPickRow({super.key, required this.player, required this.role, required this.onTap, this.onStats});
  final SquadPlayer player;
  final SelectionRole? role;
  final VoidCallback onTap;
  final VoidCallback? onStats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = player;
    final s = readSquadPlayerStats(ref, p);
    final scouting = onStats != null;
    final locked = p.locked;
    final (bg, border) = locked
        ? (CeColors.historySoft, CeColors.line)
        : switch (role) {
            SelectionRole.playing => (CeColors.mint2, const Color(0xFF9FD9BB)),
            SelectionRole.sub => (CeColors.amberSoft, const Color(0xFFF0D9A8)),
            null => (Colors.white, CeColors.line),
          };
    final state = locked
        ? p.availability.label
        : switch (role) {
            SelectionRole.playing => 'Playing XI',
            SelectionRole.sub => 'Substitute',
            null => 'Not selected',
          };

    return Opacity(
      opacity: locked ? 0.72 : 1,
      child: Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.row), side: BorderSide(color: border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(crossAxisAlignment: scouting ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
                Semantics(
                  button: true,
                  label: '${p.name}, ${p.position}, $state',
                  excludeSemantics: true,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: CeAvatar(p.name,
                        size: 40, background: locked ? CeColors.muted2 : CeColors.primary, foreground: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text(p.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                      ),
                      if (scouting && s.verified) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Verified player',
                          child: Icon(CeIcons.of('check-circle'), size: 14, color: CeColors.primary),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 1),
                    Text(p.position, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                    if (scouting) ...[
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        _Meta(icon: 'star', text: s.rating),
                        _Meta(icon: 'circle-dot', text: '${s.matches}'),
                        CeFormDots(s.form, size: 12),
                      ]),
                    ],
                  ]),
                ),
                const SizedBox(width: 8),
                // Capped so a long status ("Unavailable") never squeezes the details.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 104),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _StateBadge(role: role, locked: locked, availability: p.availability),
                    ),
                    if (scouting) ...[
                    const SizedBox(height: 7),
                    OutlinedButton(
                      onPressed: onStats,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(64, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: const BorderSide(color: CeColors.line2),
                        backgroundColor: Colors.white,
                        foregroundColor: CeColors.primaryDark,
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                      child: Text('Stats', semanticsLabel: 'Stats for ${p.name}'),
                    ),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.role, required this.locked, required this.availability});
  final SelectionRole? role;
  final bool locked;
  final PlayerAvailability availability;

  @override
  Widget build(BuildContext context) {
    if (!locked && role != null) return SelectionBadge(role: role!);
    final (_, icon) = availabilityStyle(availability);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: locked ? CeColors.line : CeColors.mint,
        borderRadius: BorderRadius.circular(CeRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (locked) ...[Icon(CeIcons.of(icon), size: 11, color: CeColors.muted), const SizedBox(width: 3)],
        Text(locked ? availability.label : 'Tap to add',
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: locked ? CeColors.muted : CeColors.primaryDark)),
      ]),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 12, color: CeColors.primary),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: CeColors.muted)),
      ]);
}
