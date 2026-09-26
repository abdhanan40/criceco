import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';

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
          ),
      ]),
    );
  }
}

/// Full-width segmented tabs (reference style): a rounded track with equal
/// segments; the selected one is filled with the brand green. For tab sets of
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
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.pill),
          border: Border.all(color: CeColors.line),
        ),
        child: child,
      );
}

class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.selected, required this.onTap, this.count, this.minWidth = 0});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final int? count;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : CeColors.muted;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: CeMotion.base,
          curve: Curves.easeOut,
          constraints: BoxConstraints(minHeight: 34, minWidth: minWidth),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? CeColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(CeRadius.pill),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
              if (count != null) ...[
                const SizedBox(width: 5),
                Container(
                  constraints: const BoxConstraints(minWidth: 17),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: selected ? Colors.white.withValues(alpha: 0.24) : CeColors.mint,
                    borderRadius: BorderRadius.circular(CeRadius.pill),
                  ),
                  child: Text('$count',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: selected ? Colors.white : CeColors.primaryDark)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
