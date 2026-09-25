import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_icons.dart';

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
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: showDivider ? const BoxDecoration(border: Border(bottom: BorderSide(color: CeColors.line))) : null,
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of(icon), size: 16, color: CeColors.primaryDark),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.lg),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: Column(children: children),
      );
}
