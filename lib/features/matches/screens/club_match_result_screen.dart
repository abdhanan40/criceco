import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router/routes.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/pakistan_time.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../player/player_providers.dart' show scorecardProvider;
import '../../player/screens/match_scorecard_screen.dart';
import '../club_matches_controller.dart';

/// The OFFICIAL result of a club match, read-only (M2 P4): the result, the
/// innings totals and — when published — the batting and bowling cards.
/// Nothing here can be entered, edited, confirmed or disputed: official
/// results come from a trusted source, never from the app. Opened from
/// Match Management → History ("View Result").
class ClubMatchResultScreen extends ConsumerWidget {
  const ClubMatchResultScreen({super.key, required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const fallback = '${Routes.matchManagementPath}?tab=history';
    final match = ref
        .watch(clubMatchesProvider)
        .value
        ?.where((m) => m.id == matchId)
        .firstOrNull;
    final async = ref.watch(scorecardProvider(matchId));
    return Scaffold(
      appBar: const CeTopBar(title: 'Match Result', fallbackLocation: fallback),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => CeEmptyState(
          icon: 'info',
          title: 'Result unavailable',
          body: 'The result could not be loaded. Please try again.',
          primaryLabel: 'Try again',
          onPrimary: () => ref.invalidate(scorecardProvider(matchId)),
        ),
        data: (sc) {
          if (sc == null) {
            return const CeEmptyState(
              key: Key('clubResult.pending'),
              icon: 'hourglass',
              title: 'Result pending',
              body: 'The official result of this match hasn’t been published yet.',
            );
          }
          if (sc.innings.isEmpty) {
            return CeEmptyState(
              key: const Key('clubResult.noInnings'),
              icon: 'file-text',
              title: sc.result,
              body: 'No innings were played in this match.',
            );
          }
          final meta = [
            if (match?.startsAt case final at?) CeFormat.dayDate(at.inPakistan),
            if (match?.format case final f?) f.display(match?.customOvers),
            ?match?.venueName,
          ].join(' · ');
          return ScorecardBody(scorecard: sc, meta: meta);
        },
      ),
    );
  }
}
