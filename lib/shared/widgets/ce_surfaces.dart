import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_icons.dart';

/// Base card (prototype card system, criceco-app.js :2019).
class CeCard extends StatelessWidget {
  const CeCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(CeSpace.card),
    this.margin,
    this.onTap,
    this.radius = CeRadius.lg,
    this.selected = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final double radius;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: selected ? CeColors.primary : CeColors.line, width: selected ? 1.5 : 1),
    );
    return Container(
      margin: margin,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), boxShadow: CeShadows.card),
      child: Material(
        color: Colors.white,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// Gradient brand surface with the boundary-arc motif
/// (`.banner`, `.club-hero`, `.tourney-banner`, …).
class CeBrandHero extends StatelessWidget {
  const CeBrandHero({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(24, 30, 24, 22),
    this.radius = 0,
    this.bottomRadius,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Rounds only the bottom corners (compact dashboard headers); overrides
  /// [radius].
  final double? bottomRadius;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        gradient: CeColors.brandGradient,
        borderRadius: bottomRadius != null
            ? BorderRadius.vertical(bottom: Radius.circular(bottomRadius!))
            : BorderRadius.circular(radius),
        boxShadow: CeShadows.hero,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -70,
            top: -90,
            child: IgnorePointer(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // Boundary-arc motif in the palette's sage.
                  border: Border.all(color: CeColors.sage.withValues(alpha: 0.32), width: 1.5),
                  boxShadow: [
                    BoxShadow(color: CeColors.sage.withValues(alpha: 0.06), spreadRadius: 20),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: padding,
            child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: child),
          ),
        ],
      ),
    );
  }
}

/// Section title row with optional trailing action ("View All ›").
class CeSectionHeader extends StatelessWidget {
  const CeSectionHeader(this.title, {super.key, this.actionLabel, this.onAction, this.padding});
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(title,
                style: t.titleMedium!.copyWith(fontSize: 14.5, fontWeight: FontWeight.w800),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          if (actionLabel != null)
            InkWell(
              onTap: onAction,
              borderRadius: BorderRadius.circular(CeRadius.sm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: CeSize.touchTarget),
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(actionLabel!, style: t.labelMedium!.copyWith(color: CeColors.primary, fontSize: 12, fontWeight: FontWeight.w700)),
                    Icon(CeIcons.of('chevron-right'), size: 13, color: CeColors.primary),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Key/value summary card (`.summary-card`). Values wrap; labels flex.
class CeSummaryCard extends StatelessWidget {
  const CeSummaryCard({super.key, required this.rows, this.total, this.margin});
  final List<(String, Widget)> rows;
  final (String, Widget)? total;
  final EdgeInsetsGeometry? margin;

  static Widget value(BuildContext context, String text, {Color? color}) => Text(
        text,
        textAlign: TextAlign.right,
        style: Theme.of(context).textTheme.titleSmall!.copyWith(color: color ?? CeColors.ink),
      );

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.bodyMedium!.copyWith(color: CeColors.muted);
    Widget row((String, Widget) r, {bool isTotal = false}) => Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: CeColors.mint2))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(r.$1, style: isTotal ? label.copyWith(color: CeColors.ink, fontWeight: FontWeight.w700) : label)),
            const SizedBox(width: 16),
            Flexible(child: Align(alignment: Alignment.centerRight, child: r.$2)),
          ]),
        );
    return CeCard(
      margin: margin ?? const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      padding: const EdgeInsets.symmetric(horizontal: CeSpace.card, vertical: 4),
      child: Column(children: [
        for (final r in rows) row(r),
        if (total != null) row(total!, isTotal: true),
      ]),
    );
  }
}

/// Quiet mint note (`.demo-box`, `.wallet-note`, `.avail2-tip`, `.ce-picker-note`).
class CeInfoNote extends StatelessWidget {
  const CeInfoNote({super.key, required this.text, this.icon = 'info', this.margin});
  final String text;
  final String icon;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) => Container(
        margin: margin ?? const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.md)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(CeIcons.of(icon), size: 14, color: CeColors.primaryDark),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.bodySmall!.copyWith(color: CeColors.ink2, fontSize: 11.5)),
          ),
        ]),
      );
}

/// Rounded icon well (mint background).
class CeIconWell extends StatelessWidget {
  const CeIconWell(this.icon, {super.key, this.size = 44, this.iconSize, this.background, this.color, this.circle = false});
  final String icon;
  final double size;
  final double? iconSize;
  final Color? background;
  final Color? color;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: background ?? CeColors.mint,
          borderRadius: circle ? null : BorderRadius.circular(size >= 44 ? CeRadius.md : CeRadius.sm),
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
        ),
        alignment: Alignment.center,
        child: Icon(CeIcons.of(icon), size: iconSize ?? size * 0.45, color: color ?? CeColors.primaryDark),
      );
}
