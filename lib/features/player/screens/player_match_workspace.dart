import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../../shared/widgets/ce_workspace_tabs.dart';
import '../player_providers.dart';
import 'match_scorecard_screen.dart';
import 'player_match_details_screen.dart';

/// Tabs of the Player Match workspace, kept in `?tab=`.
enum PlayerMatchView {
  details('Details'),
  scorecard('Scorecard');

  const PlayerMatchView(this.label);
  final String label;

  static PlayerMatchView parse(String? raw) => values.where((v) => v.name == raw).firstOrNull ?? details;

  /// Canonical location. The legacy `/player/matches/:id/scorecard`
  /// redirects to the Scorecard form.
  String location(String matchId) => this == details
      ? Routes.playerMatchDetails(matchId)
      : '${Routes.playerMatchDetails(matchId)}?tab=$name';
}

/// Player Match workspace (consolidation Phase A): Match Details and the
/// Scorecard in one screen, keyed by the match id in the path.
///
/// * The Scorecard tab exists only for a past match with a scorecard; an
///   upcoming or cancelled match shows Details only (no tab row), even if
///   `?tab=scorecard` is requested.
/// * Back: Scorecard → Details (what Back from the Scorecard did before);
///   Details → My Matches. Switching tabs replaces the location.
class PlayerMatchWorkspace extends ConsumerWidget {
  const PlayerMatchWorkspace({super.key, required this.matchId, this.tab = PlayerMatchView.details});
  final String matchId;
  final PlayerMatchView tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(playerMatchesProvider).isLoading;
    final match = ref.watch(playerMatchProvider(matchId));
    final hasScorecard = match?.hasScorecard ?? false;
    final view = hasScorecard ? tab : PlayerMatchView.details;

    void back() => view == PlayerMatchView.scorecard
        ? context.go(PlayerMatchView.details.location(matchId))
        : CeTopBar.goBack(context, Routes.myMatches);

    final bar = CeTopBar(
      title: view == PlayerMatchView.scorecard ? 'Scorecard' : 'Match Details',
      onBack: back,
    );
    if (loading) return Scaffold(appBar: bar, body: const Center(child: CircularProgressIndicator()));
    if (match == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'search',
          title: 'Match not found',
          body: 'This match is no longer available.',
          primaryLabel: 'Back to My Matches',
          onPrimary: () => context.go(Routes.myMatches),
        ),
      );
    }
    return PopScope(
      canPop: view == PlayerMatchView.details,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: Scaffold(
        appBar: bar,
        body: Column(children: [
          if (hasScorecard)
            CeWorkspaceTabs<PlayerMatchView>(
              values: PlayerMatchView.values,
              selected: view,
              labelOf: (v) => v.label,
              onSelected: (v) => context.go(v.location(matchId)),
            ),
          Expanded(
            child: switch (view) {
              PlayerMatchView.details => MatchDetailsView(
                  match: match,
                  onViewScorecard: () => context.go(PlayerMatchView.scorecard.location(matchId)),
                ),
              PlayerMatchView.scorecard => MatchScorecardView(match: match),
            },
          ),
        ]),
      ),
    );
  }
}
