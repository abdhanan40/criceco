import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_indicators.dart';

/// The one tab style for consolidated workspaces (Performance, Match,
/// Tournament host): compact chips, horizontally scrollable at 320 px, never
/// wrapping. Tabs live in the route (`?tab=`), so switching replaces the
/// location instead of stacking history entries.
class CeWorkspaceTabs<T> extends StatelessWidget {
  const CeWorkspaceTabs({
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
  // Full width in any parent (a Column centres a shrink-wrapped child), so
  // the chips start at the gutter and the divider spans the screen.
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        alignment: Alignment.centerLeft,
        decoration: const BoxDecoration(
          color: CeColors.bg,
          border: Border(bottom: BorderSide(color: CeColors.line)),
        ),
        child: CeChipRow<T>(
          values: values,
          selected: selected,
          labelOf: labelOf,
          onSelected: (t) {
            if (t != selected) onSelected(t);
          },
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 10),
        ),
      );
}
