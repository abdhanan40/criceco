import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_surfaces.dart';

/// One quick action (`.quick-item`): icon well above a label.
class CeQuickAction {
  const CeQuickAction({required this.icon, required this.label, required this.onTap});
  final String icon;
  final String label;
  final VoidCallback onTap;
}

/// Compact icon-tile grid (`.quick-grid`, reference-style): icon well above a
/// short centred label, several tiles per row.
///
/// Columns adapt to the width so labels never clip: 4 when a tile is at least
/// [_minTile] wide, otherwise 3 — except a 4-action set, which becomes 2 × 2
/// horizontal tiles instead of a lopsided 3 + 1. Rows size to their content,
/// so large text scales never clip.
class CeQuickActionGrid extends StatelessWidget {
  const CeQuickActionGrid({super.key, required this.actions});
  final List<CeQuickAction> actions;

  static const _gap = 8.0;
  static const _minTile = 78.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      child: LayoutBuilder(builder: (context, c) {
        final fourFit = (c.maxWidth - 3 * _gap) / 4 >= _minTile;
        final horizontal = !fourFit && actions.length == 4;
        final columns = fourFit ? 4 : (horizontal ? 2 : 3);
        final rows = <Widget>[];
        for (var i = 0; i < actions.length; i += columns) {
          if (i > 0) rows.add(const SizedBox(height: _gap));
          rows.add(IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var j = 0; j < columns; j++) ...[
                if (j > 0) const SizedBox(width: _gap),
                Expanded(
                  child: i + j < actions.length
                      ? _Tile(actions[i + j], horizontal: horizontal)
                      : const SizedBox.shrink(),
                ),
              ],
            ]),
          ));
        }
        return Column(children: rows);
      }),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.action, {required this.horizontal});
  final CeQuickAction action;
  final bool horizontal;

  static const _label = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: CeColors.ink2, height: 1.2);

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: action.label,
        excludeSemantics: true,
        child: CeCard(
          onTap: action.onTap,
          radius: CeRadius.row,
          padding: horizontal ? const EdgeInsets.fromLTRB(10, 9, 8, 9) : const EdgeInsets.fromLTRB(4, 11, 4, 10),
          child: horizontal
              ? Row(children: [
                  CeIconWell(action.icon, size: 34, iconSize: 16),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(action.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: _label),
                  ),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  CeIconWell(action.icon, size: 38, iconSize: 18),
                  const SizedBox(height: 7),
                  Text(action.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _label.copyWith(fontSize: 11)),
                ]),
        ),
      );
}

/// Role-home heroes draw under the transparent status bar. Once the hero
/// scrolls away, a deep-green strip keeps the light status-bar icons readable.
class CeStatusBarScrim extends StatefulWidget {
  const CeStatusBarScrim({super.key, required this.child});
  final Widget child;

  @override
  State<CeStatusBarScrim> createState() => _CeStatusBarScrimState();
}

class _CeStatusBarScrimState extends State<CeStatusBarScrim> {
  bool _visible = false;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final visible = n.metrics.pixels > 24;
    if (visible != _visible) setState(() => _visible = visible);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(children: [
      NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: top,
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: CeMotion.fast,
            child: const ColoredBox(color: CeColors.primaryDark),
          ),
        ),
      ),
    ]);
  }
}
