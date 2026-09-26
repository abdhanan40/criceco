import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../widgets/ce_icons.dart';
import 'role_drawer.dart';

class NavItem {
  const NavItem(this.icon, this.label);
  final String icon;
  final String label;
}

/// One fixed bottom-nav set per role (approved decision 3).
abstract final class RoleNavItems {
  /// Player: Home · Matches · Performance · Profile.
  static const player = [
    NavItem('home', 'Home'),
    NavItem('calendar', 'Matches'),
    NavItem('bar-chart', 'Performance'),
    NavItem('user', 'Profile'),
  ];

  /// Club Owner: Home · Teams · Members · Profile (→ My Club, approved P7).
  static const club = [
    NavItem('home', 'Home'),
    NavItem('shield', 'Teams'),
    NavItem('users', 'Members'),
    NavItem('user', 'Profile'),
  ];
}

/// Bottom navigation (`.bottom-nav`). The selected item is the active branch.
/// Compact, docked bar (structural UI update): hairline divider, no floating
/// shadow; icon + short label, the active item marked by a tinted pill.
class CeBottomNav extends StatelessWidget {
  const CeBottomNav({super.key, required this.items, required this.currentIndex, required this.onTap});
  final List<NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: CeColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 5, 4, 5),
          child: Row(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(child: _NavButton(item: items[i], active: i == currentIndex, onTap: () => onTap(i))),
          ]),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.active, required this.onTap});
  final NavItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? CeColors.primary : CeColors.muted;
    return Semantics(
      selected: active,
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CeRadius.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: CeSize.navItemMinHeight),
          child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            AnimatedContainer(
              duration: CeMotion.slow,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 3),
              decoration: BoxDecoration(
                color: active ? CeColors.mint : Colors.transparent,
                borderRadius: BorderRadius.circular(CeRadius.pill),
              ),
              child: Icon(CeIcons.of(item.icon), size: 20, color: color),
            ),
            const SizedBox(height: 3),
            Text(item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, fontWeight: active ? FontWeight.w800 : FontWeight.w600, color: color)),
          ]),
        ),
      ),
    );
  }
}

/// Shell scaffold for a role's `StatefulShellRoute`. Tapping the current tab
/// returns that branch to its root.
class RoleShellScaffold extends StatelessWidget {
  const RoleShellScaffold({super.key, required this.shell, required this.items});
  final StatefulNavigationShell shell;
  final List<NavItem> items;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const RoleDrawer(),
      body: shell,
      bottomNavigationBar: CeBottomNav(
        items: items,
        currentIndex: shell.currentIndex,
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}
