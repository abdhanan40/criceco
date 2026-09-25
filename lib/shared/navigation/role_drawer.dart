import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/role_destinations.dart';
import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../demo/seed_data.dart';
import '../widgets/ce_feedback.dart';
import '../widgets/ce_icons.dart';
import '../widgets/ce_indicators.dart';

/// The role drawer is UI chrome (`Scaffold.drawer`), never a route (approved
/// decision 15). Item taps close the drawer, then `go()` to a destination
/// declared under the role home — so Back returns to the dashboard, not here.
class RoleDrawer extends ConsumerWidget {
  const RoleDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(activeRoleProvider) ?? UserRole.player;
    final session = ref.watch(sessionProvider);
    final account = session.account;
    final router = GoRouter.of(context);
    final location = router.routerDelegate.currentConfiguration.uri.path;
    final other = role == UserRole.player ? UserRole.clubOwner : UserRole.player;
    final needsSetup = other == UserRole.clubOwner && !session.hasClubOwnerProfile;
    final name = account?.fullName ?? 'Aman Ali';
    final clubTag = role == UserRole.clubOwner
        ? '${session.ownClub?.name ?? 'Shalimar Cricket Club'} · ${session.ownClub?.code ?? '35HLWZ'}'
        : 'Club ${account?.memberships.firstOrNull?.clubCode ?? SeedData.demoJoinCode}';

    void navigate(String target) {
      Navigator.of(context).pop(); // close drawer first
      router.go(target);
    }

    void switchRole() {
      Navigator.of(context).pop();
      switch (ref.read(roleControllerProvider.notifier).switchTo(other)) {
        case NeedsClubSetup(:final location):
          router.go(location);
        case GoToLocation(:final location):
          router.go(location);
          showCeToast(context, 'Switched to ${other.label}');
      }
    }

    final t = Theme.of(context).textTheme;
    return Drawer(
      width: (MediaQuery.sizeOf(context).width * 0.82).clamp(0, 320).toDouble(),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Close menu',
                icon: Icon(CeIcons.of('x'), size: 18, color: CeColors.muted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Row(children: [
              CeAvatar(name, size: 46, background: CeColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: t.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  CeRoleBadge(role),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: CeColors.line),
                      borderRadius: BorderRadius.circular(CeRadius.pill),
                    ),
                    child: Text(clubTag,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall!.copyWith(fontSize: 11)),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Material(
              color: CeColors.mint,
              borderRadius: BorderRadius.circular(CeRadius.row),
              child: InkWell(
                borderRadius: BorderRadius.circular(CeRadius.row),
                onTap: switchRole,
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                          color: CeColors.primaryDark, borderRadius: BorderRadius.circular(9)),
                      child: Icon(CeIcons.of(needsSetup ? 'plus' : 'repeat'), size: 17, color: Colors.white),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          needsSetup
                              ? 'Set up Club Owner profile'
                              : (other == UserRole.clubOwner ? 'Switch to Club Owner' : 'Switch to Player profile'),
                          style: t.titleSmall!.copyWith(fontSize: 12),
                        ),
                        if (needsSetup) Text('Create clubs and teams', style: t.bodySmall!.copyWith(fontSize: 10.5)),
                      ]),
                    ),
                    Icon(CeIcons.of('chevron-right'), size: 14, color: CeColors.primaryDark),
                  ]),
                ),
              ),
            ),
            const Divider(height: 28),
            for (final group in RoleDestinations.forRole(role)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                child: Text(group.label.toUpperCase(),
                    style: t.labelSmall!.copyWith(color: CeColors.muted2, fontWeight: FontWeight.w700)),
              ),
              for (final d in group.items)
                _DrawerItem(
                  icon: d.icon,
                  label: d.label,
                  active: location == d.location,
                  onTap: () => navigate(d.location),
                ),
            ],
            _DrawerItem(
              icon: 'sliders',
              label: 'Settings',
              active: location == Routes.settings,
              onTap: () => navigate(Routes.settings),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: CeColors.red, alignment: Alignment.centerLeft),
              onPressed: () {
                Navigator.of(context).pop();
                ref.read(sessionProvider.notifier).logout();
                router.go(Routes.login);
              },
              icon: Icon(CeIcons.of('power'), size: 16),
              label: const Text('Logout'),
            ),
            const SizedBox(height: 8),
            Text('CricEco v1.0 · Made for Pakistan Cricket',
                textAlign: TextAlign.center, style: t.bodySmall!.copyWith(fontSize: 11, color: CeColors.muted2)),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({required this.icon, required this.label, required this.active, required this.onTap});
  final String icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? CeColors.mint : Colors.transparent,
      borderRadius: BorderRadius.circular(CeRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(CeRadius.md),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: CeSize.drawerItemMinHeight),
          child: Row(children: [
            const SizedBox(width: 4),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: active ? CeColors.primary : CeColors.mint,
                borderRadius: BorderRadius.circular(CeRadius.sm),
              ),
              child: Icon(CeIcons.of(icon), size: 17, color: active ? Colors.white : CeColors.primaryDark),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: Theme.of(context).textTheme.titleSmall!.copyWith(
                      color: active ? CeColors.primaryDark : CeColors.ink2, fontWeight: FontWeight.w600)),
            ),
            if (active) Icon(CeIcons.of('chevron-right'), size: 14, color: CeColors.primary),
            const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}
