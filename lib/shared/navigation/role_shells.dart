import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../features/club/widgets/club_profile_sheet.dart' show showClubProfileSheet;
import '../../features/club/widgets/create_team_sheet.dart' show showCreateTeamFlowSheet;
import '../../features/player/widgets/join_club_sheet.dart' show showClubSheet;
import '../../features/player/widgets/player_status_sheet.dart' show showPlayerStatusSheet;
import '../widgets/ce_icons.dart';
import 'role_drawer.dart';

/// A bottom-nav item does one of three things: switch to a shell [branch],
/// open a [location] (highlighted while it is showing), or [open] a sheet
/// over the current screen (never highlighted, no route change).
class NavItem {
  const NavItem(this.icon, this.label, {this.branch, this.location, this.open, this.center = false, this.tooltip})
      : assert((branch != null ? 1 : 0) + (location != null ? 1 : 0) + (open != null ? 1 : 0) == 1);
  final String icon;
  final String label;
  final int? branch;
  final String? location;
  final Future<void> Function(BuildContext context)? open;

  /// Drawn as the raised round action in the middle of the bar (an [open]
  /// item: a sheet, never a tab).
  final bool center;

  /// Long-press hint (defaults to [label]).
  final String? tooltip;
}

/// One fixed bottom-nav set per role (approved decision 3).
abstract final class RoleNavItems {
  /// Player: Home · Matches · [Status] · Club · Profile. Status is the raised
  /// center button (Set Your Status sheet); Club is a sheet (join a club /
  /// pending request / My Club); Profile is My Profile (in the Home branch).
  /// Availability and Performance keep their routes and branches — reached
  /// from the dashboard quick actions and the sidebar.
  static const player = [
    NavItem('home', 'Home', branch: 0),
    NavItem('calendar', 'Matches', branch: 1),
    NavItem('user-check', 'Status', open: showPlayerStatusSheet, center: true, tooltip: 'Set your status'),
    NavItem('shield', 'Club', open: showClubSheet),
    NavItem('user', 'Profile', location: Routes.playerProfile),
  ];

  /// Club Owner: Home · Matches (Match Management) · [+] · Teams · Profile. The
  /// raised "+" opens the Create Team sheet (details, players, Suggest Team).
  /// Profile
  /// is the club profile in a sheet (editable); Members open from the
  /// dashboard (a sheet). The Members branch keeps its routes.
  static const club = [
    NavItem('home', 'Home', branch: 0),
    NavItem('calendar', 'Matches', branch: 1),
    NavItem('plus', 'New Team', open: showCreateTeamFlowSheet, center: true, tooltip: 'Create team'),
    NavItem('shield', 'Teams', branch: 2),
    NavItem('user', 'Profile', open: showClubProfileSheet),
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

  /// How far the center button rises above the bar.
  static const centerRise = 20.0;
  static const _centerSize = 52.0;

  @override
  Widget build(BuildContext context) {
    final hasCenter = items.any((i) => i.center);
    final bar = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 5, 4, 5),
        child: Row(children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: items[i].center
                  ? _CenterLabel(item: items[i])
                  : _NavButton(item: items[i], active: i == currentIndex, onTap: () => onTap(i)),
            ),
        ]),
      ),
    );
    if (!hasCenter) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: CeColors.line)),
        ),
        child: bar,
      );
    }
    // The bar plus a strip above it, so the raised button stays inside this
    // widget (tappable, and never drawn over page content).
    final center = items.indexWhere((i) => i.center);
    return Stack(children: [
      const Positioned.fill(
        top: centerRise,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: CeColors.line)),
          ),
        ),
      ),
      Padding(padding: const EdgeInsets.only(top: centerRise), child: bar),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Center(
          child: _CenterButton(item: items[center], size: _centerSize, onTap: () => onTap(center)),
        ),
      ),
    ]);
  }
}

/// The raised round action (`NavItem.center`): CricEco green, white ring,
/// soft shadow. Its label sits in the bar under it ([_CenterLabel]).
class _CenterButton extends StatelessWidget {
  const _CenterButton({required this.item, required this.size, required this.onTap});
  final NavItem item;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: item.label,
        excludeSemantics: true,
        child: Tooltip(
          message: item.tooltip ?? item.label,
          child: Container(
            key: const Key('nav.center'),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: [BoxShadow(color: CeColors.paletteDeep.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 3))],
            ),
            child: Material(
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [CeColors.primary, CeColors.primaryDark],
                  ),
                ),
                child: InkWell(
                  onTap: onTap,
                  child: Center(child: Icon(CeIcons.of(item.icon), size: 21, color: Colors.white)),
                ),
              ),
            ),
          ),
        ),
      );
}

/// The center item's slot in the bar: just its label, under the button.
class _CenterLabel extends StatelessWidget {
  const _CenterLabel({required this.item});
  final NavItem item;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(
          height: CeSize.navItemMinHeight,
          child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
            Text(item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
            const SizedBox(height: 2),
          ]),
        ),
      );
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
  const RoleShellScaffold({super.key, required this.shell, required this.items, required this.location});
  final StatefulNavigationShell shell;
  final List<NavItem> items;

  /// The current location's path (decides which item is highlighted).
  final String location;

  /// A [NavItem.location] item showing wins; else the item for the current
  /// branch; else none (e.g. a branch reached from the sidebar).
  static int selectedIndex(List<NavItem> items, int branch, String location) {
    final atLocation = items.indexWhere((i) => i.location != null && location == i.location);
    if (atLocation != -1) return atLocation;
    return items.indexWhere((i) => i.branch == branch);
  }

  void _onTap(BuildContext context, NavItem item) {
    if (item.open case final open?) {
      open(context);
    } else if (item.location case final loc?) {
      if (location != loc) context.go(loc);
    } else {
      final b = item.branch!;
      // The current tab again → that branch's root (also from a page on top).
      shell.goBranch(b, initialLocation: b == shell.currentIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const RoleDrawer(),
      body: shell,
      bottomNavigationBar: CeBottomNav(
        items: items,
        currentIndex: selectedIndex(items, shell.currentIndex, location),
        onTap: (i) => _onTap(context, items[i]),
      ),
    );
  }
}
