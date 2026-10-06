import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import 'ce_icons.dart';

/// The one top bar (`.top-header`). Leading rule (approved decision 15):
/// * [showMenu] → hamburger opens the Scaffold drawer (role homes only);
/// * otherwise → back arrow pops the previous logical screen, falling back to
///   [fallbackLocation] when there is nothing to pop (deep link / cold start).
class CeTopBar extends StatelessWidget implements PreferredSizeWidget {
  const CeTopBar({
    super.key,
    required this.title,
    this.showMenu = false,
    this.showBack = true,
    this.fallbackLocation,
    this.actions = const [],
    this.onBack,
  });

  final String title;
  final bool showMenu;
  final bool showBack;
  final String? fallbackLocation;
  final List<Widget> actions;

  /// Overrides the default pop (e.g. terminal screens redirecting).
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(CeSize.topBarMinHeight);

  /// Opens the nearest Scaffold that owns a drawer. Inside a role shell this is
  /// the shell scaffold, so the drawer covers the bottom nav (prototype overlay).
  static void openDrawer(BuildContext context) {
    var scaffold = Scaffold.maybeOf(context);
    while (scaffold != null && !scaffold.hasDrawer) {
      scaffold = scaffold.context.findAncestorStateOfType<ScaffoldState>();
    }
    scaffold?.openDrawer();
  }

  static void goBack(BuildContext context, String? fallbackLocation) {
    if (context.canPop()) {
      context.pop();
    } else if (fallbackLocation != null) {
      context.go(fallbackLocation);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget? leading;
    if (showMenu) {
      leading = Builder(
        builder: (ctx) => CeHeaderButton(tooltip: 'Open menu', icon: 'menu', onPressed: () => openDrawer(ctx)),
      );
    } else if (showBack) {
      leading = CeHeaderButton(
        tooltip: 'Back',
        icon: 'arrow-left',
        onPressed: onBack ?? () => goBack(context, fallbackLocation),
      );
    }
    // The reference page header: sticky, page-coloured, padding 12 / 20 / 14,
    // a boxed 40px back button, then the Sora 20 title (left-aligned).
    return AppBar(
      toolbarHeight: CeSize.topBarMinHeight,
      automaticallyImplyLeading: false,
      leading: leading == null
          ? null
          : Padding(padding: const EdgeInsets.only(left: CeSpace.gutter), child: Center(child: leading)),
      leadingWidth: CeSpace.gutter + CeSize.backButton,
      titleSpacing: leading == null ? CeSpace.gutter : 14,
      title: _FitTitle(title),
      actions: [...actions, const SizedBox(width: 12)],
    );
  }
}

/// The boxed header button (`Back`, `Open menu`): 40 × 40, radius 12, white
/// with a 1.5px border (#D5E3DA), 18px icon.
class CeHeaderButton extends StatelessWidget {
  const CeHeaderButton({super.key, required this.tooltip, required this.icon, required this.onPressed});
  final String tooltip;
  final String icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: CeSize.backButton, height: CeSize.backButton),
        style: IconButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: CeColors.ink,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.md),
            side: const BorderSide(color: CeColors.line2, width: 1.5),
          ),
        ),
        icon: Icon(CeIcons.of(icon), size: 18, color: CeColors.ink),
      );
}

/// Header title: a title that is only a little too long (e.g. "My
/// Tournaments" next to an action at 320 px) shrinks up to ~15% to fit;
/// anything longer keeps its size and ends with an ellipsis.
class _FitTitle extends StatelessWidget {
  const _FitTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final style = DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          text: TextSpan(text: title, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final fits = painter.width <= box.maxWidth;
        final nearly = painter.width * 0.85 <= box.maxWidth;
        painter.dispose();
        if (fits || !nearly) return Text(title, maxLines: 1, overflow: TextOverflow.ellipsis);
        return FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(title, maxLines: 1));
      });
}
