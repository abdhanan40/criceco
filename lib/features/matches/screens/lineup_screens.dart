import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/state/selection_controller.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../booking/widgets/booking_widgets.dart';
import '../../club/teams/teams_controller.dart';
import '../../club/widgets/squad_widgets.dart';
import '../lineup_controller.dart';

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
          final teamCount = ref.watch(teamsProvider).value?.length ?? 0;

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
              Container(
                margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.lg)),
                child: Column(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: Icon(CeIcons.of('check'), size: 20, color: CeColors.primaryDark),
                  ),
                  const SizedBox(height: 8),
                  const Text('Booking Confirmed!', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  const Text("Now pick who's playing this match.",
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: CeColors.muted)),
                ]),
              ),
            if (!editable)
              const CeInfoNote(
                margin: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                icon: 'lock',
                text: 'This match has started, so its line-up is locked.',
              ),
            if (draft.dirty && editable)
              _UnsavedBanner(onContinue: () => context.go(Routes.matchLineupBuild(matchId))),
            if (lineup != null) ...[
              CeSectionHeader(editable ? 'Confirmed Line-up' : 'Line-up'),
              _LineupCard(lineup: lineup),
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
              _OptionCard(
                icon: 'sparkles',
                accent: CeColors.amber,
                title: 'Create New Team',
                body: 'Pick Playing XI (${SquadRules.maxPlaying}) + ${SquadRules.maxSubs} substitutes from your squad',
                onTap: () {
                  ref.read(lineupDraftProvider(target).notifier).startNew();
                  context.go(Routes.matchLineupBuild(matchId));
                },
              ),
              _OptionCard(
                icon: 'shield',
                accent: CeColors.primaryDark,
                title: 'Select Existing Team',
                body: 'Choose from $teamCount team${teamCount == 1 ? '' : 's'} already created in your club',
                onTap: () => context.go(Routes.matchLineupPick(matchId)),
              ),
            ],
          ]);
        },
      ),
    );
  }
}

class _UnsavedBanner extends StatelessWidget {
  const _UnsavedBanner({required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: CeColors.amberSoft,
          borderRadius: BorderRadius.circular(CeRadius.md),
          border: Border.all(color: CeColors.countdownBorder),
        ),
        child: Row(children: [
          Icon(CeIcons.of('edit-3'), size: 15, color: CeColors.amberInk),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('You have unsaved line-up picks.',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: CeColors.amberInk)),
          ),
          TextButton(onPressed: onContinue, child: const Text('Continue')),
        ]),
      );
}

/// The saved line-up: name, counts, then the XI and the substitutes.
class _LineupCard extends ConsumerWidget {
  const _LineupCard({required this.lineup});
  final Lineup lineup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pool = ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
    final byId = {for (final p in pool) p.id: p};
    final xi = [for (final m in lineup.members) if (m.selection == SelectionRole.playing) byId[m.playerId]].nonNulls.toList();
    final subs = [for (final m in lineup.members) if (m.selection == SelectionRole.sub) byId[m.playerId]].nonNulls.toList();

    Widget names(String title, List<SquadPlayer> players) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title.toUpperCase(),
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4, color: CeColors.muted)),
          const SizedBox(height: 6),
          for (final (i, p) in players.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(children: [
                SizedBox(
                  width: 22,
                  child: Text('${i + 1}.', style: const TextStyle(fontSize: 12, color: CeColors.muted2)),
                ),
                Expanded(
                  child: Text(p.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CeColors.ink)),
                ),
                Text(p.category.label, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ]),
            ),
        ]);

    return CeCard(
      margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const CeIconWell('shield', size: 40, iconSize: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(lineup.name, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
              const SizedBox(height: 2),
              Text(
                lineup.members.isEmpty
                    ? 'No players picked yet'
                    : '${xi.length} Playing XI · ${subs.length} Substitute${subs.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: CeColors.muted),
              ),
            ]),
          ),
          if (lineup.sourceTeamId != null) const CeStatusChip('Club team', tone: CeTone.neutral),
        ]),
        if (xi.isNotEmpty) ...[const SizedBox(height: 14), names('Playing XI', xi)],
        if (subs.isNotEmpty) ...[const SizedBox(height: 10), names('Substitutes', subs)],
      ]),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.icon, required this.accent, required this.title, required this.body, required this.onTap});
  final String icon;
  final Color accent;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: title,
        excludeSemantics: true,
        child: CeCard(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 10),
          onTap: onTap,
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(CeIcons.of(icon), size: 21, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(body, style: const TextStyle(fontSize: 12, color: CeColors.muted, height: 1.35)),
              ]),
            ),
            Icon(CeIcons.of('chevron-right'), size: 18, color: CeColors.muted),
          ]),
        ),
      );
}

// ---------------------------------------------------------------------------
// Build Your Team (prototype `screens.teamBuilder`, :6750). Same pick rule
// and rows as Add Players (no scouting stats — prototype parity). Picks
// persist when leaving; "Confirm Team" saves them as the match's line-up.
// "Create New Team" here never adds to My Teams (architecture §7).
// ---------------------------------------------------------------------------

/// Filter chip per match builder (`null` = All).
final lineupFilterProvider = NotifierProvider.family<SelectionController<SquadCategory?>, SquadCategory?, String>(
    (_) => SelectionController<SquadCategory?>(null));

class TeamBuilderScreen extends ConsumerStatefulWidget {
  const TeamBuilderScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<TeamBuilderScreen> createState() => _TeamBuilderScreenState();
}

class _TeamBuilderScreenState extends ConsumerState<TeamBuilderScreen> {
  String? _error;
  bool _saving = false;

  MatchLineupTarget get _target => MatchLineupTarget(widget.matchId);

  void _tap(SquadPlayer p) {
    final outcome = ref.read(lineupDraftProvider(_target).notifier).cycle(p);
    switch (outcome) {
      case PickOutcome.locked:
        showCeToast(context, "${p.name} is ${p.availability.label.toLowerCase()} and can't be selected");
      case PickOutcome.full:
        showCeToast(context, 'Playing XI and substitutes are full');
      case PickOutcome.changed:
        if (_error != null) setState(() => _error = null);
    }
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    final error = await ref.read(lineupDraftProvider(_target).notifier).confirmBuilt();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
    if (error != null) return;
    showCeToast(context, 'Team confirmed!');
    context.go(_scheduled); // prototype: assignTeamToActiveMatch → Scheduled
  }

  @override
  Widget build(BuildContext context) {
    final matchId = widget.matchId;
    final draft = ref.watch(lineupDraftProvider(_target));
    final editable = ref.watch(lineupEditableProvider(matchId));
    return BookingScaffold(
      matchId: matchId,
      title: 'Build Your Team',
      onBack: () => context.go(Routes.matchLineup(matchId)),
      actions: [
        if (draft.dirty)
          TextButton(
            onPressed: () {
              ref.read(lineupDraftProvider(_target).notifier).discard();
              setState(() => _error = null);
              showCeToast(context, 'Unsaved picks discarded');
            },
            child: const Text('Discard'),
          ),
      ],
      builder: (context, c) {
        if (!editable) {
          return CeEmptyState(
            icon: 'lock',
            title: 'Line-up locked',
            body: 'The line-up can only be changed for a confirmed match that has not started.',
            primaryLabel: 'Back to the match',
            onPrimary: () => context.go(Routes.matchLineup(matchId)),
          );
        }
        final poolAsync = ref.watch(clubPlayerPoolProvider);
        if (poolAsync.isLoading) return const Center(child: CircularProgressIndicator());
        final pool = poolAsync.value ?? const <SquadPlayer>[];
        final filter = ref.watch(lineupFilterProvider(matchId));
        final visible = filter == null ? pool : pool.where((p) => p.category == filter).toList();
        int countOf(SquadCategory? cat) => cat == null ? pool.length : pool.where((p) => p.category == cat).length;

        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
            child: Row(children: [
              Expanded(child: SquadCounter(value: '${draft.playing}/${SquadRules.maxPlaying}', label: 'Playing XI')),
              const SizedBox(width: 10),
              Expanded(child: SquadCounter(value: '${draft.subs}/${SquadRules.maxSubs}', label: 'Substitutes')),
            ]),
          ),
          SquadFilterRow(
            selected: filter,
            countOf: countOf,
            onSelected: ref.read(lineupFilterProvider(matchId).notifier).select,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
            child: Text(
              "Tap a player to mark Playing → Substitute → Unselected. Injured or unavailable players can't be selected.",
              style: TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.4),
            ),
          ),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter, vertical: 20),
              child: Text('No ${filter?.label ?? 'players'} in your squad.',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
            )
          else
            for (final p in visible) SquadPickRow(player: p, role: draft.picks[p.id], onTap: () => _tap(p)),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
              child: CeErrorBanner(_error!),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
            child: CeButton(
              label: 'Confirm Team',
              trailingIcon: CeIcons.of('arrow-right'),
              loading: _saving,
              onPressed: _saving ? null : _confirm,
            ),
          ),
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Select Existing Team (prototype `screens.teamPicker`, :6832): one of My
// Teams (with its saved XI / subs) becomes the match's line-up.
// ---------------------------------------------------------------------------

class TeamPickerScreen extends ConsumerStatefulWidget {
  const TeamPickerScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<TeamPickerScreen> createState() => _TeamPickerScreenState();
}

class _TeamPickerScreenState extends ConsumerState<TeamPickerScreen> {
  String? _selected;
  bool _seeded = false;
  String? _error;
  bool _saving = false;

  Future<void> _confirm(List<Team> teams) async {
    final team = teams.where((t) => t.id == _selected).firstOrNull;
    if (team == null) {
      setState(() => _error = 'Please select a team');
      return;
    }
    // Never replace a line-up with an empty squad.
    if (team.playerCount == 0) {
      setState(() => _error = '${team.name} has no players yet — add players in My Teams first');
      return;
    }
    setState(() => _saving = true);
    final leftOut = await ref.read(lineupDraftProvider(MatchLineupTarget(widget.matchId)).notifier).useTeam(team);
    if (!mounted) return;
    showCeToast(
      context,
      leftOut == 0
          ? 'Team confirmed!'
          : 'Team confirmed! $leftOut injured or unavailable player${leftOut == 1 ? ' was' : 's were'} left out',
    );
    context.go(_scheduled);
  }

  @override
  Widget build(BuildContext context) {
    final matchId = widget.matchId;
    final editable = ref.watch(lineupEditableProvider(matchId));
    return BookingScaffold(
      matchId: matchId,
      title: 'Select Existing Team',
      onBack: () => context.go(Routes.matchLineup(matchId)),
      builder: (context, c) {
        if (!editable) {
          return CeEmptyState(
            icon: 'lock',
            title: 'Line-up locked',
            body: 'The line-up can only be changed for a confirmed match that has not started.',
            primaryLabel: 'Back to the match',
            onPrimary: () => context.go(Routes.matchLineup(matchId)),
          );
        }
        final teamsAsync = ref.watch(teamsProvider);
        if (teamsAsync.isLoading) return const Center(child: CircularProgressIndicator());
        final teams = teamsAsync.value ?? const <Team>[];
        if (!_seeded) {
          _selected = c.match.lineup?.sourceTeamId;
          _seeded = true;
        }
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 4),
            child: Text("Choose which of your club's teams will play this match.",
                style: TextStyle(fontSize: 13, color: CeColors.muted)),
          ),
          if (teams.isEmpty)
            CeEmptyState(
              icon: 'shield',
              title: 'No teams yet',
              body: 'Create a team in My Teams, or build a new match-day squad instead.',
              primaryLabel: 'Go to My Teams',
              onPrimary: () => context.go(Routes.teams),
            )
          else
            for (final t in teams)
              _TeamRadio(
                team: t,
                selected: _selected == t.id,
                onTap: () => setState(() {
                  _selected = t.id;
                  _error = null;
                }),
              ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: CeInlineError(_error),
            ),
          if (teams.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
              child: CeButton(
                label: 'Confirm Team',
                trailingIcon: CeIcons.of('arrow-right'),
                loading: _saving,
                onPressed: _saving ? null : () => _confirm(teams),
              ),
            ),
        ]);
      },
    );
  }
}

class _TeamRadio extends StatelessWidget {
  const _TeamRadio({required this.team, required this.selected, required this.onTap});
  final Team team;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = team;
    final squad = t.playerCount == 0
        ? 'No players yet'
        : '${t.playingCount} Playing XI · ${t.subCount} Sub${t.subCount == 1 ? '' : 's'}';
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      child: Semantics(
        button: true,
        selected: selected,
        label: '${t.name}, $squad',
        excludeSemantics: true,
        child: Material(
          color: selected ? CeColors.mint : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.lg),
            side: BorderSide(color: selected ? CeColors.primary : CeColors.line, width: selected ? 1.6 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.lg),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(CeIcons.of(selected ? 'check-circle' : 'circle'),
                    size: 20, color: selected ? CeColors.primary : CeColors.muted2),
                const SizedBox(width: 10),
                const CeIconWell('shield', size: 40, iconSize: 19),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
                    const SizedBox(height: 2),
                    Text('$squad · ${t.format.display(t.customOvers)}',
                        style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
