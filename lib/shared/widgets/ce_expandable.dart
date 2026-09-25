import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_icons.dart';

/// A card whose detail folds away: a tappable header (icon, title, optional
/// summary line) with a rotating chevron, and an animated body. Used for
/// information that is useful but not always needed (payment breakdowns,
/// booking details). Open/closed is local to the screen visit unless the
/// caller drives [expanded].
class CeExpandableCard extends StatefulWidget {
  const CeExpandableCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.summary,
    this.initiallyExpanded = false,
    this.margin = const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
  });

  final String title;
  final String? icon;

  /// One line shown in the header in both states (e.g. the total).
  final String? summary;
  final Widget child;
  final bool initiallyExpanded;
  final EdgeInsetsGeometry margin;

  @override
  State<CeExpandableCard> createState() => _CeExpandableCardState();
}

class _CeExpandableCardState extends State<CeExpandableCard> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: widget.margin,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.row),
        border: Border.all(color: CeColors.line),
        boxShadow: CeShadows.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: CeSize.touchTarget + 4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    if (widget.icon != null) ...[
                      Icon(CeIcons.of(widget.icon!), size: 17, color: CeColors.primaryDark),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(widget.title,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
                    ),
                    if (widget.summary != null) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(widget.summary!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.ink2)),
                      ),
                    ],
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: CeMotion.base,
                      child: Icon(CeIcons.of('chevron-down'), size: 16, color: CeColors.muted),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: CeMotion.base,
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _open
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Divider(height: 1, color: CeColors.line),
                    Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 12), child: widget.child),
                  ])
                : const SizedBox(width: double.infinity),
          ),
        ]),
      ),
    );
  }
}
