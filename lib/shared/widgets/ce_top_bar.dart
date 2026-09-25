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
        builder: (ctx) => IconButton(
          tooltip: 'Open menu',
          icon: Icon(CeIcons.of('menu'), size: 20),
          onPressed: () => openDrawer(ctx),
        ),
      );
    } else if (showBack) {
      leading = IconButton(
        tooltip: 'Back',
        icon: Icon(CeIcons.of('arrow-left'), size: 20),
        onPressed: onBack ?? () => goBack(context, fallbackLocation),
      );
    }
    return AppBar(
      toolbarHeight: CeSize.topBarMinHeight,
      automaticallyImplyLeading: false,
      leading: leading,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [...actions, const SizedBox(width: 6)],
      shape: const Border(bottom: BorderSide(color: CeColors.line)),
    );
  }
}
