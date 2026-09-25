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

/// 2-column quick-action grid (`.quick-grid`). Rows size to their content
/// (no fixed aspect ratio), so large text scales never clip.
class CeQuickActionGrid extends StatelessWidget {
  const CeQuickActionGrid({super.key, required this.actions});
  final List<CeQuickAction> actions;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < actions.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 12));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _Tile(actions[i])),
          const SizedBox(width: 12),
          Expanded(child: i + 1 < actions.length ? _Tile(actions[i + 1]) : const SizedBox.shrink()),
        ]),
      ));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      child: Column(children: rows),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.action);
  final CeQuickAction action;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: action.label,
        excludeSemantics: true,
        child: CeCard(
          onTap: action.onTap,
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            CeIconWell(action.icon, size: 44, iconSize: 21),
            const SizedBox(height: 14),
            Text(action.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink2)),
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
