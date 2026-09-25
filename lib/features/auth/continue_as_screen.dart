import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_surfaces.dart';
import 'widgets/auth_widgets.dart';

/// Continue As (prototype `screens.continueAs`, :8017): choose the active
/// profile of the single account — never a second login.
class ContinueAsScreen extends ConsumerWidget {
  const ContinueAsScreen({super.key});

  void _pick(BuildContext context, WidgetRef ref, UserRole role) {
    // Only this explicit action (not navigation) sets the active role.
    switch (ref.read(roleControllerProvider.notifier).continueAs(role)) {
      case NeedsClubSetup(:final location):
      case GoToLocation(:final location):
        context.go(location);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final name = session.account?.fullName ?? 'Aman Ali';
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [
          AuthBanner(
            title: 'Continue as',
            subtitle: 'Signed in as $name · one account, every role',
            bottomPadding: 26,
          ),
          Padding(
            padding: const EdgeInsets.all(CeSpace.gutter),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _RoleCard(
                icon: 'user',
                title: 'Player Profile',
                body: 'Play matches, track performance, manage availability and view statistics.',
                onTap: () => _pick(context, ref, UserRole.player),
              ),
              const SizedBox(height: 12),
              _RoleCard(
                icon: 'shield',
                title: 'Club Owner',
                body: 'Manage clubs, teams, players, matches, tournaments and requests.',
                tag: session.hasClubOwnerProfile ? null : 'Setup required',
                onTap: () => _pick(context, ref, UserRole.clubOwner),
              ),
              const SizedBox(height: 12),
              const CeInfoNote(
                margin: EdgeInsets.zero,
                text: 'You can switch profiles any time from the menu — no second login.',
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// `.ce-role-card`
class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.icon, required this.title, required this.body, required this.onTap, this.tag});
  final String icon;
  final String title;
  final String body;
  final String? tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title. $body${tag == null ? '' : ' $tag.'}',
      excludeSemantics: true,
      child: CeCard(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          CeIconWell(icon, size: 44, iconSize: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
              const SizedBox(height: 3),
              Text(body, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.45, color: CeColors.muted)),
              if (tag != null) ...[
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: CeColors.amberSoft, borderRadius: BorderRadius.circular(CeRadius.pill)),
                  child: Text(tag!.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: CeColors.amberInk)),
                ),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2),
        ]),
      ),
    );
  }
}
