import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import 'ce_feedback.dart';
import 'ce_top_bar.dart';

/// "Not available yet" — a module with no backend in this build (Supabase
/// mode, docs/PRODUCTION_DEMO_MODE.md). Deliberately different from an empty
/// list: empty means "connected, nothing yet"; this means "not connected".
class BackendPendingNotice extends StatelessWidget {
  const BackendPendingNotice({super.key, required this.module, this.icon = 'clock'});

  final BackendModule module;
  final String icon;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: '${BackendModules.pendingTitle}. ${BackendModules.pendingBody(module)}',
        child: ExcludeSemantics(
          child: CeEmptyState(
            key: Key('backendPending.${module.name}'),
            icon: icon,
            title: BackendModules.pendingTitle,
            body: BackendModules.pendingBody(module),
          ),
        ),
      );
}

/// Shows [child] when [module] has a backend in this build (always in the
/// demo); otherwise [BackendPendingNotice] in its place, so nothing from that
/// module — real-looking but unsaved — appears or can be created.
class BackendModuleGate extends ConsumerWidget {
  const BackendModuleGate({super.key, required this.module, required this.child, this.icon = 'clock'});

  final BackendModule module;
  final Widget child;
  final String icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backendModulesProvider).has(module)) return child;
    return BackendPendingNotice(module: module, icon: icon);
  }
}

/// A whole screen of [module] (router level): the screen itself when the
/// module has a backend in this build; otherwise the same top bar ([title],
/// Back to [fallbackLocation]) over [BackendPendingNotice]. Keeps every
/// route (deep links included) from showing or creating unsaved data.
class BackendModuleScreen extends ConsumerWidget {
  const BackendModuleScreen({
    super.key,
    required this.module,
    required this.title,
    this.fallbackLocation,
    required this.child,
  });

  final BackendModule module;
  final String title;
  /// Where Back goes when nothing can be popped; `null`: the active role's
  /// home (Role Selection without one).
  final String? fallbackLocation;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backendModulesProvider).has(module)) return child;
    final role = ref.watch(activeRoleProvider);
    final back = fallbackLocation ?? (role == null ? Routes.roleSelection : Routes.home(role));
    return Scaffold(
      appBar: CeTopBar(title: title, fallbackLocation: back),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [BackendPendingNotice(module: module)]),
    );
  }
}

/// Whether [module] has a backend in this build, for code that only has a
/// [BuildContext] (sheet launchers, buttons).
bool backendModuleAvailable(BuildContext context, BackendModule module) =>
    ProviderScope.containerOf(context, listen: false).read(backendModulesProvider).has(module);

/// The "not available yet" sheet: what a sheet launcher of a module with no
/// backend opens instead of its sheet — nothing is shown, saved or
/// pretended (docs/PRODUCTION_DEMO_MODE.md).
Future<void> showBackendPendingSheet(BuildContext context, BackendModule module, {required String title}) =>
    showCeSheet<void>(
      context,
      builder: (ctx) => Column(
        key: Key('backendPendingSheet.${module.name}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(ctx).textTheme.titleLarge),
          BackendPendingNotice(module: module),
        ],
      ),
    );

/// Opens [open] when [module] has a backend in this build, otherwise the
/// "not available yet" sheet titled [title].
Future<void> showModuleSheet(
  BuildContext context,
  BackendModule module, {
  required String title,
  required Future<void> Function() open,
}) =>
    backendModuleAvailable(context, module) ? open() : showBackendPendingSheet(context, module, title: title);

/// [BackendModuleGate] for a scrollable body: the notice inside a
/// [ListView], so it scrolls and keeps the screen's padding behaviour.
class BackendModuleListGate extends ConsumerWidget {
  const BackendModuleListGate({super.key, required this.module, required this.child, this.icon = 'clock'});

  final BackendModule module;
  final Widget child;
  final String icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backendModulesProvider).has(module)) return child;
    return ListView(children: [BackendPendingNotice(module: module, icon: icon)]);
  }
}
