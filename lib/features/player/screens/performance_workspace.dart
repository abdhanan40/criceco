import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../../shared/widgets/ce_workspace_tabs.dart';
import 'performance_screens.dart';

/// Tabs of the Performance workspace, kept in `?tab=`.
enum PerformanceView {
  overview('Overview'),
  history('History');

  const PerformanceView(this.label);
  final String label;

  static PerformanceView parse(String? raw) => values.where((v) => v.name == raw).firstOrNull ?? overview;

  /// Canonical location. The legacy `/player/performance/history` redirects
  /// to the History form.
  String get location => this == overview ? Routes.myPerformance : '${Routes.myPerformance}?tab=$name';
}

/// Performance workspace (consolidation Phase A): My Performance (Overview)
/// and Match History (History) in one screen.
///
/// Back: from History → Overview (what Back from Match History did before);
/// from Overview → the Dashboard (as My Performance did). Switching tabs
/// replaces the location, so it adds no history entries.
class PerformanceWorkspace extends StatelessWidget {
  const PerformanceWorkspace({super.key, this.tab = PerformanceView.overview});
  final PerformanceView tab;

  @override
  Widget build(BuildContext context) {
    void back() => tab == PerformanceView.overview
        ? context.go(Routes.playerHome)
        : context.go(PerformanceView.overview.location);
    return PopScope(
      canPop: tab == PerformanceView.overview,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: Scaffold(
        appBar: CeTopBar(title: 'My Performance', onBack: back),
        body: Column(children: [
          CeWorkspaceTabs<PerformanceView>(
            values: PerformanceView.values,
            selected: tab,
            labelOf: (v) => v.label,
            onSelected: (v) => context.go(v.location),
          ),
          Expanded(
            child: switch (tab) {
              PerformanceView.overview =>
                PerformanceOverviewView(onViewAll: () => context.go(PerformanceView.history.location)),
              PerformanceView.history => const MatchHistoryView(),
            },
          ),
        ]),
      ),
    );
  }
}
