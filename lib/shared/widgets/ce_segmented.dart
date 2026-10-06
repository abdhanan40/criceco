import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';

/// Compact segmented control for switching a view in place (a chart metric,
/// a card's detail level). Tabs that change the route use
/// [CeWorkspaceTabs] / [CeSegmentedTabs]; this is for local, same-screen
/// choices. Same look as [CeSegmentedTabs], sized to its content.
class CeSegmented<T> extends StatelessWidget {
  const CeSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return _Track(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final v in values)
          _Segment(
            label: labelOf(v),
            selected: v == selected,
            onTap: v == selected ? null : () => onSelected(v),
            minWidth: 44,
            compact: true,
          ),
      ]),
    );
  }
}

/// Full-width segmented tabs (reference style): a #E3ECE6 track (radius 14,
/// padding 4) with equal 40px segments (radius 11, Manrope 13 Bold); the
/// selected one is #12544F with white text, counts sit in 18px pills. For tab sets of
/// up to four; labels (and optional counts) scale down rather than wrap or
/// clip at 320 px. Selecting the current segment does nothing.
class CeSegmentedTabs<T> extends StatelessWidget {
  const CeSegmentedTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.countOf,
    this.padding = const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 4),
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  /// Optional badge per segment (e.g. pending counts); null hides it.
  final int? Function(T)? countOf;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: _Track(
        child: Row(children: [
          for (final v in values)
            Expanded(
              child: _Segment(
                label: labelOf(v),
                count: countOf?.call(v),
                selected: v == selected,
                onTap: v == selected ? null : () => onSelected(v),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.input)),
        child: child,
      );
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.minWidth = 0,
    this.compact = false,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final int? count;
  final double minWidth;

  /// In-place view switch ([CeSegmented]): a shorter segment, smaller label.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : CeColors.muted;
    final radius = BorderRadius.circular(CeRadius.tab);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: CeMotion.base,
          curve: Curves.easeOut,
          constraints: BoxConstraints(minHeight: compact ? 32 : 40, minWidth: minWidth),
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? CeColors.primary : Colors.transparent,
            borderRadius: radius,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: (compact ? CeType.chip.copyWith(fontSize: 12) : CeType.buttonSmall).copyWith(color: fg)),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: selected ? CeColors.accent : CeColors.mint2,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text('$count',
                      textAlign: TextAlign.center,
                      style: CeType.micro.copyWith(color: selected ? Colors.white : CeColors.primaryDark)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
