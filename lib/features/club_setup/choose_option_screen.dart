import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../demo/seed_data.dart';
import '../../shared/navigation/role_drawer.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_surfaces.dart';
import '../../shared/widgets/ce_top_bar.dart';
import '../../shared/widgets/demo_widgets.dart';

/// Set Up Your Club (prototype `screens.chooseOption`, :3120): Create a Club
/// or Join a Club. Reached from Continue As (no Club Owner profile) or from
/// Role Setup.
class ChooseOptionScreen extends ConsumerWidget {
  const ChooseOptionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(currentAccountProvider)?.fullName ?? '';
    final activeRole = ref.watch(activeRoleProvider);
    // Back / exit target: the role the user came from, else Continue As.
    final exitTo = activeRole == null ? Routes.continueAs : Routes.home(activeRole);
    final top = MediaQuery.paddingOf(context).top;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(exitTo);
      },
      child: Scaffold(
        // The drawer is only meaningful once a role is active (came via the
        // drawer's "Set up Club Owner profile"); from Continue As there is no
        // role context yet, so the hamburger is hidden.
        drawer: activeRole == null ? null : const RoleDrawer(),
        body: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle.light,
              child: CeBrandHero(
                padding: EdgeInsets.fromLTRB(20, 12 + top, 20, 26),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (activeRole != null)
                      Builder(
                        builder: (ctx) => IconButton(
                          tooltip: 'Open menu',
                          icon: Icon(CeIcons.of('menu'), color: Colors.white, size: 20),
                          onPressed: () => CeTopBar.openDrawer(ctx),
                        ),
                      )
                    else
                      IconButton(
                        tooltip: 'Back',
                        icon: Icon(CeIcons.of('arrow-left'), color: Colors.white, size: 20),
                        onPressed: () => context.go(exitTo),
                      ),
                    const Spacer(),
                    _LogoutPill(onTap: () {
                      ref.read(sessionProvider.notifier).logout();
                      context.go(Routes.login);
                    }),
                  ]),
                  const SizedBox(height: 18),
                  Text('Welcome,', style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.78))),
                  const SizedBox(height: 2),
                  Text(name.isEmpty ? 'there' : name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.8, color: Colors.white)),
                  const SizedBox(height: 2),
                  Text('Create your club or join an existing one',
                      style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.78))),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Set up your club',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.66, color: CeColors.muted)),
                const SizedBox(height: 10),
                _OptionCard(
                  primary: true,
                  icon: 'plus-circle',
                  title: 'Create a Club',
                  body: 'Start your own cricket club and invite players to join',
                  onTap: () => context.go(Routes.createClub),
                ),
                const SizedBox(height: 12),
                _OptionCard(
                  primary: false,
                  icon: 'users',
                  title: 'Join a Club',
                  body: 'Enter a club code to send a join request',
                  onTap: () => context.push('${Routes.enterClubCode}?from=clubSetup'),
                ),
                const DemoOnly(
                  child: Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: CeInfoNote(
                      margin: EdgeInsets.zero,
                      text: 'Try club code ${SeedData.demoJoinCode} to explore a pre-built club',
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _LogoutPill extends StatelessWidget {
  const _LogoutPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white.withValues(alpha: 0.16),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: CeSize.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(CeIcons.of('power'), size: 14, color: Colors.white),
                const SizedBox(width: 5),
                const Text('Logout', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
              ]),
            ),
          ),
        ),
      );
}

/// `.option-card` — primary (brand gradient) or secondary (mint).
class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.primary, required this.icon, required this.title, required this.body, required this.onTap});
  final bool primary;
  final String icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Colors.white : CeColors.ink;
    return Semantics(
      button: true,
      label: '$title. $body',
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          gradient: primary ? CeColors.brandGradient : null,
          color: primary ? null : CeColors.mint,
          borderRadius: BorderRadius.circular(CeRadius.lg),
          boxShadow: primary ? CeShadows.hero : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.lg),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: primary ? Colors.white.withValues(alpha: 0.18) : const Color(0xFFC2E4D2),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(CeIcons.of(icon), size: 22, color: primary ? Colors.white : CeColors.primaryDark),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
                    const SizedBox(height: 2),
                    Text(body, style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.85), height: 1.35)),
                  ]),
                ),
                const SizedBox(width: 8),
                Icon(CeIcons.of('chevron-right'), size: 18, color: fg),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
