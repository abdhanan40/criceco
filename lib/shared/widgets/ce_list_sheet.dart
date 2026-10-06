import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_icons.dart';

/// A tall bottom sheet for list content that used to be a full screen
/// (Members, Teams, Requests, …): drag handle, a header that stays put, and a
/// scrolling body whose rows keep their screen gutters. Closes by tapping
/// outside, dragging down or Back; never changes the route.
Future<T?> showCeListSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final height = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true, // above the bottom navigation
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxHeight: height * 0.88),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: builder(ctx),
    ),
  );
}

/// The frame inside [showCeListSheet]: handle, [title] (+ [titleTrailing],
/// e.g. a count), [actions] on the right, an optional [top] area (search,
/// tabs) and the scrolling [children].
class CeListSheetFrame extends StatelessWidget {
  const CeListSheetFrame({
    super.key,
    required this.title,
    required this.children,
    this.titleTrailing,
    this.actions = const [],
    this.top = const [],
    this.listKey,
    this.footer,
  });

  final String title;
  final Widget? titleTrailing;
  final List<Widget> actions;
  final List<Widget> top;
  final List<Widget> children;
  final Key? listKey;

  /// Pinned under the list (e.g. Cancel / Create), above the system inset.
  final Widget? footer;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Center(
          child: Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            decoration: BoxDecoration(color: CeColors.line2, borderRadius: BorderRadius.circular(CeRadius.pill)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 2, 6, 4),
          child: Row(children: [
            Expanded(
              child: Row(children: [
                Flexible(
                  child: Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
                ),
                if (titleTrailing != null) ...[const SizedBox(width: 8), titleTrailing!],
              ]),
            ),
            ...actions,
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(CeIcons.of('x'), size: 20, color: CeColors.muted),
            ),
          ]),
        ),
        ...top,
        Flexible(
          child: ListView(
            key: listKey,
            shrinkWrap: true,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            // Clear of the home indicator when nothing is pinned below.
            padding: EdgeInsets.only(bottom: 20 + (footer == null ? MediaQuery.paddingOf(context).bottom : 0)),
            children: children,
          ),
        ),
        if (footer != null)
          DecoratedBox(
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: CeColors.line))),
            child: SafeArea(top: false, child: footer!),
          ),
      ]);
}

/// "N" count pill beside a sheet title.
class CeCountPill extends StatelessWidget {
  const CeCountPill(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.pill)),
        child: Text('$count',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
      );
}
