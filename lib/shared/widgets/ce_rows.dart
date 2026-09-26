import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_icons.dart';

/// Dense list-card row (reference list style, used by Teams, Members and
/// other simple lists): leading visual, strong title, compact metadata, a
/// status / action on the right and an optional chevron — minimal height.
/// Rows are separated by [CeSpace.rowGap].
class CeListRow extends StatelessWidget {
  const CeListRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.meta,
    this.trailing,
    this.onTap,
    this.chevron,
    this.semanticLabel,
    this.margin = const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.rowGap, CeSpace.gutter, 0),
  });

  final String title;
  final Widget? leading;
  final String? subtitle;

  /// Extra compact line under the subtitle (tags, chips).
  final Widget? meta;

  /// Status chip / action on the right.
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Defaults to shown when the row is tappable.
  final bool? chevron;

  /// Replaces the row's semantics with one label (a single tap target).
  final String? semanticLabel;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final showChevron = chevron ?? onTap != null;
    final row = Container(
      margin: margin,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(CeRadius.row), boxShadow: CeShadows.card),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.row),
          side: const BorderSide(color: CeColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: CeSize.listRowMinHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              child: Row(children: [
                if (leading != null) ...[leading!, const SizedBox(width: 11)],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.3)),
                    ],
                    if (meta != null) ...[const SizedBox(height: 5), meta!],
                  ]),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                if (showChevron) ...[
                  const SizedBox(width: 4),
                  Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
    if (semanticLabel == null) return row;
    return Semantics(button: onTap != null, label: semanticLabel, excludeSemantics: true, child: row);
  }
}

/// Settings / profile row (`.ce-set-row`) with optional subtitle and trailing.
class CeSettingsRow extends StatelessWidget {
  const CeSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.showDivider = true,
  });

  final String icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: showDivider ? const BoxDecoration(border: Border(bottom: BorderSide(color: CeColors.hairline))) : null,
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of(icon), size: 15, color: CeColors.primaryDark),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.titleSmall!.copyWith(fontSize: 13)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: t.bodySmall!.copyWith(fontSize: 11)),
              ],
            ]),
          ),
          trailing ?? Icon(CeIcons.of('chevron-right'), size: 15, color: CeColors.muted2),
        ]),
      ),
    );
  }
}

/// Settings row with a switch (`ceToggleRow`).
class CeToggleRow extends StatelessWidget {
  const CeToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.showDivider = true,
  });

  final String icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) => CeSettingsRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        showDivider: showDivider,
        onTap: () => onChanged(!value),
        trailing: Switch(value: value, onChanged: onChanged),
      );
}

/// Grouped card of settings rows (`.om-card` with rows).
class CeGroupCard extends StatelessWidget {
  const CeGroupCard({super.key, required this.children, this.margin});
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) => Container(
        margin: margin ?? const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.lg),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: Column(children: children),
      );
}
