import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import 'ce_icons.dart';

enum CeTone { green, amber, red, blue, neutral }

/// Uppercase status pill (`.status-chip`, `.status-badge`, `.tourney-status-pill`).
class CeStatusChip extends StatelessWidget {
  const CeStatusChip(this.label, {super.key, this.tone = CeTone.green, this.icon});
  final String label;
  final CeTone tone;
  final String? icon;

  static (Color, Color) colors(CeTone tone) => switch (tone) {
        CeTone.green => (CeColors.mint, CeColors.primaryDark),
        CeTone.amber => (CeColors.amberSoft, CeColors.amberInk),
        CeTone.red => (CeColors.redSoft, CeColors.red),
        CeTone.blue => (CeColors.blueSoft, CeColors.blue),
        CeTone.neutral => (CeColors.historySoft, CeColors.muted),
      };

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = colors(tone);
    return Container(
      constraints: const BoxConstraints(minHeight: CeSize.statusChipMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(CeRadius.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(CeIcons.of(icon!), size: 11, color: fg), const SizedBox(width: 4)],
        // Flexible: a long label ellipsizes instead of overflowing a narrow parent.
        Flexible(
          child: Text(label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: fg)),
        ),
      ]),
    );
  }
}

/// Selectable pill (`.role-pill`, `.tab-pill`, `.squad-filter-chip`), with an
/// optional count badge.
class CeChip extends StatelessWidget {
  const CeChip({super.key, required this.label, required this.selected, this.onTap, this.count, this.icon});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final int? count;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : CeColors.ink2;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? CeColors.primary : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: selected ? CeColors.primary : CeColors.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: CeSize.chipMinHeight),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(CeIcons.of(icon!), size: 14, color: fg), const SizedBox(width: 6)],
              // Flexible: a long label ellipsizes in a narrow Wrap / card
              // (320 px, large text) instead of overflowing.
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium!.copyWith(color: fg)),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text('$count',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: selected ? Colors.white.withValues(alpha: 0.85) : CeColors.muted)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Horizontal, scrollable row of chips (`.tab-pill-row`, `.squad-filter-row`).
class CeChipRow<T> extends StatelessWidget {
  const CeChipRow({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.countOf,
    this.wrap = false,
    this.padding = const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 4),
  });

  final List<T> values;
  final T? selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;
  final int? Function(T)? countOf;
  final bool wrap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final chips = [
      for (final v in values)
        CeChip(label: labelOf(v), selected: v == selected, count: countOf?.call(v), onTap: () => onSelected(v)),
    ];
    if (wrap) {
      return Padding(padding: padding, child: Wrap(spacing: 7, runSpacing: 7, children: chips));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(children: [
        for (var i = 0; i < chips.length; i++) ...[if (i > 0) const SizedBox(width: 8), chips[i]],
      ]),
    );
  }
}

/// Initial avatar (`.avatar`).
class CeAvatar extends StatelessWidget {
  const CeAvatar(this.name, {super.key, this.size = 40, this.background, this.foreground});
  final String name;
  final double size;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: background ?? CeColors.mint),
      child: Text(initial,
          style: TextStyle(
              fontSize: size * 0.38,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: foreground ?? (background == null ? CeColors.primaryDark : Colors.white))),
    );
  }
}

/// Last-5 W/L squares (`.ce-fd`, `.form-dot`).
class CeFormDots extends StatelessWidget {
  const CeFormDots(this.form, {super.key, this.size = 13});
  final List<MatchResult> form;
  final double size;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < form.length; i++) ...[
          if (i > 0) SizedBox(width: size > 16 ? 5 : 2),
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: form[i] == MatchResult.won ? CeColors.primary : CeColors.red,
              borderRadius: BorderRadius.circular(size > 16 ? 7 : 4),
            ),
            child: Text(form[i] == MatchResult.won ? 'W' : 'L',
                style: TextStyle(color: Colors.white, fontSize: size * 0.62, fontWeight: FontWeight.w800)),
          ),
        ],
      ]);
}

/// Stat tile (`.stat-card`, `.pd-stat-card`, `.mp-stat-card`).
class CeStatCard extends StatelessWidget {
  const CeStatCard({super.key, required this.value, required this.label, this.icon, this.sub, this.onTap});
  final String value;
  final String label;
  final String? icon;
  final String? sub;

  /// Opens the list behind the number (e.g. Requests → Join Requests).
  final VoidCallback? onTap;

  static final _decoration = BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(CeRadius.row),
    border: Border.all(color: CeColors.line),
    boxShadow: CeShadows.card,
  );

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (onTap == null) {
      return Container(padding: const EdgeInsets.all(12), decoration: _decoration, child: body);
    }
    return Semantics(
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(CeRadius.row),
          child: Ink(padding: const EdgeInsets.all(12), decoration: _decoration, child: body),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of(icon!), size: 17, color: CeColors.primaryDark),
          ),
          const SizedBox(height: 8),
        ],
        Text(label.toUpperCase(),
            maxLines: 2, style: Theme.of(context).textTheme.labelSmall!.copyWith(height: 1.25)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                  color: CeColors.ink,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(sub!, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: CeColors.muted2, fontSize: 11)),
        ],
      ]);
  }
}

/// Equal-width row of stat cards (`.stats-row`).
class CeStatsRow extends StatelessWidget {
  const CeStatsRow({super.key, required this.children, this.padding});
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding ?? const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(child: children[i]),
            ],
          ]),
        ),
      );
}

/// Role context badge (drawer `.ce-role-pill`, hero pills).
class CeRoleBadge extends StatelessWidget {
  const CeRoleBadge(this.role, {super.key, this.onDark = false});
  final UserRole role;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final fg = onDark ? Colors.white : CeColors.primaryDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: onDark ? Colors.white.withValues(alpha: 0.18) : CeColors.mint,
        borderRadius: BorderRadius.circular(CeRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(role == UserRole.player ? 'user' : 'shield'), size: 12, color: fg),
        const SizedBox(width: 5),
        Text(role.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
      ]),
    );
  }
}
