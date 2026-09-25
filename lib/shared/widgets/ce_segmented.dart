import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';

/// Compact segmented control for switching a view in place (a chart metric,
/// a card's detail level). Tabs that change the route use
/// [CeWorkspaceTabs]; this is for local, same-screen choices.
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
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: CeColors.historySoft, borderRadius: BorderRadius.circular(CeRadius.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final v in values)
          Semantics(
            button: true,
            selected: v == selected,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: v == selected ? null : () => onSelected(v),
              child: AnimatedContainer(
                duration: CeMotion.base,
                curve: Curves.easeOut,
                constraints: const BoxConstraints(minHeight: 34, minWidth: 48),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: v == selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(CeRadius.pill),
                  boxShadow: v == selected ? CeShadows.card : null,
                ),
                child: Text(
                  labelOf(v),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: v == selected ? CeColors.primaryDark : CeColors.muted,
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
