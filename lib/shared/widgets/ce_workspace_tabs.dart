import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_segmented.dart';

/// The one tab style for consolidated workspaces (Performance, Match,
/// Tournament host): a compact full-width segmented track under the top bar.
/// Tabs live in the route (`?tab=`), so switching replaces the location
/// instead of stacking history entries.
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
  // the track spans the gutters and the divider spans the screen.
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: CeColors.bg,
          border: Border(bottom: BorderSide(color: CeColors.line)),
        ),
        child: CeSegmentedTabs<T>(
          values: values,
          selected: selected,
          labelOf: labelOf,
          onSelected: onSelected,
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 8),
        ),
      );
}
