import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../widgets/ce_buttons.dart';
import '../widgets/ce_surfaces.dart';
import '../widgets/ce_top_bar.dart';
import 'role_drawer.dart';

/// A navigation link on a placeholder (Foundation phase only).
class PlaceholderLink {
  const PlaceholderLink(this.label, this.location, {this.replace = false});
  final String label;
  final String location;

  /// `go` replaces the stack per the route hierarchy; placeholders always use
  /// `go` so the page stack equals the path hierarchy.
  final bool replace;
}

/// Foundation placeholder for every route. Real screens replace these one by
/// one in the migration phases; route, top-bar and back behaviour are final.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.screenKey,
    this.showMenu = false,
    this.showBack = true,
    this.fallbackLocation,
    this.terminalRedirect,
    this.links = const [],
    this.actions = const [],
    this.details = const [],
  });

  final String title;

  /// Prototype screen key (e.g. `playerDashboard`).
  final String screenKey;
  final bool showMenu;
  final bool showBack;
  final String? fallbackLocation;

  /// Terminal screens intercept system Back and go here instead.
  final String? terminalRedirect;
  final List<PlaceholderLink> links;
  final List<Widget> actions;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // Inside a role shell the shell scaffold owns the drawer (full-screen
    // overlay); standalone screens with a hamburger (Set Up Your Club) own one.
    final ownsDrawer = showMenu && Scaffold.maybeOf(context) == null;
    Widget scaffold = Scaffold(
      drawer: ownsDrawer ? const RoleDrawer() : null,
      appBar: CeTopBar(
        title: title,
        showMenu: showMenu,
        showBack: showBack && terminalRedirect == null,
        fallbackLocation: fallbackLocation,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          CeCard(
            margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Foundation placeholder', style: t.labelSmall),
              const SizedBox(height: 4),
              Text(title, style: t.titleMedium),
              const SizedBox(height: 2),
              Text('Prototype screen: $screenKey', style: t.bodySmall),
              Text('Route: ${GoRouter.of(context).routerDelegate.currentConfiguration.uri}', style: t.bodySmall),
              for (final d in details) Text(d, style: t.bodySmall),
            ]),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final a in actions)
              Padding(padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 10), child: a),
          ],
          if (links.isNotEmpty) const CeSectionHeader('Navigate'),
          for (final l in links)
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 10),
              child: CeButton.soft(label: l.label, onPressed: () => context.go(l.location)),
            ),
        ],
      ),
    );
    if (terminalRedirect != null) {
      scaffold = PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.go(terminalRedirect!);
        },
        child: scaffold,
      );
    }
    return scaffold;
  }
}
