import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../widgets/ce_feedback.dart';
import '../widgets/ce_top_bar.dart';

/// Unknown location (prototype `ceNotFound`): never a dead end — "Go to
/// dashboard" opens the active role's home (or the right entry point when
/// signed out / no role yet), "Go back" pops when possible.
class NotFoundScreen extends ConsumerWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(sessionProvider.select((s) => s.isAuthenticated));
    final role = ref.watch(activeRoleProvider);
    final home = !signedIn ? Routes.login : (role == null ? Routes.roleSelection : Routes.home(role));
    return Scaffold(
      appBar: CeTopBar(title: 'Not found', fallbackLocation: home),
      body: ListView(children: [
        CeEmptyState(
          icon: 'search',
          title: 'Screen not found',
          body: 'This item is no longer available, or it was opened without a selection.',
          primaryLabel: signedIn ? 'Go to dashboard' : 'Go to login',
          onPrimary: () => context.go(home),
          secondaryLabel: context.canPop() ? 'Go back' : null,
          onSecondary: () => context.pop(),
        ),
      ]),
    );
  }
}
