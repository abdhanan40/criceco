import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../booking/widgets/booking_widgets.dart';
import '../lineup_controller.dart';
import '../widgets/lineup_widgets.dart';

/// Where the line-up flow returns: the match's own card, on Scheduled.
final _scheduled = Routes.matchManagement(MatchTab.scheduled);

String _matchMeta(BookingContext c) {
  final start = c.match.startsAt;
  return [
    if (start != null) CeFormat.dayDate(start),
    if (start != null) CeFormat.time(start),
    if (c.ground != null) c.ground!.name,
  ].join(' · ');
}

// ---------------------------------------------------------------------------
// Select Team (prototype `screens.selectTeam`, :6713) — also the match's
// line-up overview: shows the confirmed line-up and lets you edit it before
// the match. Back → the match on Scheduled (never the dashboard).
// ---------------------------------------------------------------------------

class SelectTeamScreen extends ConsumerWidget {
  const SelectTeamScreen({super.key, required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = MatchLineupTarget(matchId);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(_scheduled);
      },
      child: BookingScaffold(
        matchId: matchId,
        title: 'Select Team',
        onBack: () => context.go(_scheduled),
        builder: (context, c) {
          final editable = ref.watch(lineupEditableProvider(matchId));
          final lineup = c.match.lineup;
          final draft = ref.watch(lineupDraftProvider(target));

          if (c.match.status != MatchStatus.confirmed && c.match.status != MatchStatus.completed) {
            return CeEmptyState(
              icon: 'lock',
              title: 'Booking not confirmed yet',
              body: 'You can pick your Playing XI once both clubs have paid for the ground.',
              primaryLabel: 'Back to Upcoming Matches',
              onPrimary: () => context.go(Routes.matchManagement(MatchTab.waiting)),
            );
          }

          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            BookingHeaderCard(
              leading: opponentBadge(c.opponent),
              title: 'vs ${c.opponent.name}',
              meta: _matchMeta(c),
            ),
            if (lineup == null && editable)
              const LineupIntroCard(
                icon: 'check',
                title: 'Booking Confirmed!',
                body: "Now pick who's playing this match.",
              ),
            if (!editable)
              const CeInfoNote(
                margin: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                icon: 'lock',
                text: 'This match has started, so its line-up is locked.',
              ),
            if (draft.dirty && editable)
              UnsavedLineupBanner(onContinue: () => context.go(Routes.matchLineupBuild(matchId))),
            if (lineup != null) ...[
              CeSectionHeader(editable ? 'Confirmed Line-up' : 'Line-up'),
              LineupCard(lineup: lineup),
              if (editable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                  child: CeButton(
                    label: 'Edit Playing XI',
                    icon: CeIcons.of('edit-3'),
                    onPressed: () {
                      ref.read(lineupDraftProvider(target).notifier).startEdit();
                      context.go(Routes.matchLineupBuild(matchId));
                    },
                  ),
                ),
            ],
            if (editable) ...[
              CeSectionHeader(lineup == null ? 'Choose Your Team' : 'Or Choose Another Team'),
              LineupOptions(
                target: target,
                onBuild: () => context.go(Routes.matchLineupBuild(matchId)),
                onPick: () => context.go(Routes.matchLineupPick(matchId)),
              ),
            ],
          ]);
        },
      ),
    );
  }
}

Widget _locked(BuildContext context, String matchId) => CeEmptyState(
      icon: 'lock',
      title: 'Line-up locked',
      body: 'The line-up can only be changed for a confirmed match that has not started.',
      primaryLabel: 'Back to the match',
      onPrimary: () => context.go(Routes.matchLineup(matchId)),
    );

// ---------------------------------------------------------------------------
// Build Your Team (prototype `screens.teamBuilder`, :6750). Picks persist
// when leaving; "Confirm Team" saves them as the match's line-up. "Create
// New Team" here never adds to My Teams (architecture §7).
// ---------------------------------------------------------------------------

class TeamBuilderScreen extends ConsumerWidget {
  const TeamBuilderScreen({super.key, required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = MatchLineupTarget(matchId);
    final editable = ref.watch(lineupEditableProvider(matchId));
    return BookingScaffold(
      matchId: matchId,
      title: 'Build Your Team',
      onBack: () => context.go(Routes.matchLineup(matchId)),
      actions: [if (editable) LineupDiscardAction(target: target)],
      builder: (context, c) {
        if (!editable) return _locked(context, matchId);
        return LineupBuilderView(
          target: target,
          onConfirmed: () {
            showCeToast(context, 'Team confirmed!');
            context.go(_scheduled); // prototype: assignTeamToActiveMatch → Scheduled
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Select Existing Team (prototype `screens.teamPicker`, :6832): one of My
// Teams (with its saved XI / subs) becomes the match's line-up.
// ---------------------------------------------------------------------------

class TeamPickerScreen extends ConsumerWidget {
  const TeamPickerScreen({super.key, required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editable = ref.watch(lineupEditableProvider(matchId));
    return BookingScaffold(
      matchId: matchId,
      title: 'Select Existing Team',
      onBack: () => context.go(Routes.matchLineup(matchId)),
      builder: (context, c) {
        if (!editable) return _locked(context, matchId);
        return LineupTeamPickerView(
          target: MatchLineupTarget(matchId),
          intro: "Choose which of your club's teams will play this match.",
          initialTeamId: c.match.lineup?.sourceTeamId,
          onGoToTeams: () => context.go(Routes.teams),
          onConfirmed: (leftOut) {
            showCeToast(context, teamConfirmedToast(leftOut));
            context.go(_scheduled);
          },
        );
      },
    );
  }
}
