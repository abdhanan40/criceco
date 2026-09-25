import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../core/enums/enums.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_top_bar.dart';

/// Role Setup (prototype `screens.roleSetup`, :7900): shown when the drawer's
/// "Set up Club Owner profile" is tapped without a Club Owner profile.
class RoleSetupScreen extends ConsumerWidget {
  const RoleSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = Routes.home(ref.watch(activeRoleProvider) ?? UserRole.player);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: CeTopBar(title: 'Club Owner', onBack: () => context.go(home)),
      body: SingleChildScrollView(
        child: CeEmptyState(
          icon: 'shield',
          title: 'Become a Club Owner',
          body: 'Create your Club Owner profile to create clubs, manage teams, invite players and organise matches.',
          primaryLabel: 'Set Up Club Owner Profile',
          onPrimary: () => context.go(Routes.clubSetup),
          secondaryLabel: 'Not now',
          onSecondary: () => context.go(home),
        ),
      ),
    );
  }
}
