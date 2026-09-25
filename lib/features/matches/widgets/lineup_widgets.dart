import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/state/selection_controller.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../club/teams/teams_controller.dart';
import '../../club/widgets/squad_widgets.dart';
import '../lineup_controller.dart';

/// Pieces of the line-up flow (Select Team / Build Your Team / Select
/// Existing Team) shared by match-day line-ups and tournament entries
/// (revised architecture §7: one flow, a `LineupTarget` per context).

/// Amber "unsaved picks" banner with a Continue action.
class UnsavedLineupBanner extends StatelessWidget {
  const UnsavedLineupBanner({super.key, required this.onContinue});
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

/// `.wf-success` intro card at the top of Select Team.
class LineupIntroCard extends StatelessWidget {
  const LineupIntroCard({super.key, required this.icon, required this.title, required this.body});
  final String icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.lg)),
        child: Column(children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: Icon(CeIcons.of(icon), size: 20, color: CeColors.primaryDark),
          ),
          const SizedBox(height: 8),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
        ]),
      );
}

/// A saved line-up: name, counts, then the XI and the substitutes.
class LineupCard extends ConsumerWidget {
  const LineupCard({super.key, required this.lineup, this.margin});
  final Lineup lineup;
  final EdgeInsetsGeometry? margin;

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
      margin: margin ?? const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
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

/// `.team-option-card.fancy`: Create New Team / Select Existing Team.
class LineupOptionCard extends StatelessWidget {
  const LineupOptionCard({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.body,
    required this.onTap,
  });
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

/// The two Select Team options, wired to the target's draft.
class LineupOptions extends ConsumerWidget {
  const LineupOptions({super.key, required this.target, required this.onBuild, required this.onPick});
  final LineupTarget target;
  final VoidCallback onBuild;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamCount = ref.watch(teamsProvider).value?.length ?? 0;
    return Column(children: [
      LineupOptionCard(
        icon: 'sparkles',
        accent: CeColors.amber,
        title: 'Create New Team',
        body: 'Pick Playing XI (${SquadRules.maxPlaying}) + ${SquadRules.maxSubs} substitutes from your squad',
        onTap: () {
          ref.read(lineupDraftProvider(target).notifier).startNew();
          onBuild();
        },
      ),
      LineupOptionCard(
        icon: 'shield',
        accent: CeColors.primaryDark,
        title: 'Select Existing Team',
        body: 'Choose from $teamCount team${teamCount == 1 ? '' : 's'} already created in your club',
        onTap: onPick,
      ),
    ]);
  }
}

/// Filter chip per builder (`null` = All).
final lineupFilterProvider = NotifierProvider.family<SelectionController<SquadCategory?>, SquadCategory?, LineupTarget>(
    (_) => SelectionController<SquadCategory?>(null));

/// Build Your Team body (prototype `screens.teamBuilder`, :6750): counters,
/// filter chips, pick rows and "Confirm Team". Same pick rule and rows as Add
/// Players (no scouting stats — prototype parity). [onConfirmed] runs once
/// the target's line-up is saved.
class LineupBuilderView extends ConsumerStatefulWidget {
  const LineupBuilderView({super.key, required this.target, required this.onConfirmed});
  final LineupTarget target;
  final VoidCallback onConfirmed;

  @override
  ConsumerState<LineupBuilderView> createState() => _LineupBuilderViewState();
}

class _LineupBuilderViewState extends ConsumerState<LineupBuilderView> {
  String? _error;
  bool _saving = false;

  void _tap(SquadPlayer p) {
    final outcome = ref.read(lineupDraftProvider(widget.target).notifier).cycle(p);
    switch (outcome) {
      case PickOutcome.locked:
        showCeToast(context, "${p.name} is ${p.availability.label.toLowerCase()} and can't be selected");
      case PickOutcome.full:
        showCeToast(context, 'Playing XI and substitutes are full');
      case PickOutcome.changed:
        break;
    }
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    final error = await ref.read(lineupDraftProvider(widget.target).notifier).confirmBuilt();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
    if (error == null) widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    // Any change to the picks (tap, Discard) clears a stale error.
    ref.listen(lineupDraftProvider(target), (_, _) {
      if (_error != null) setState(() => _error = null);
    });
    final draft = ref.watch(lineupDraftProvider(target));
    final poolAsync = ref.watch(clubPlayerPoolProvider);
    if (poolAsync.isLoading) return const Center(child: CircularProgressIndicator());
    final pool = poolAsync.value ?? const <SquadPlayer>[];
    final filter = ref.watch(lineupFilterProvider(target));
    final visible = filter == null ? pool : pool.where((p) => p.category == filter).toList();
    int countOf(SquadCategory? cat) => cat == null ? pool.length : pool.where((p) => p.category == cat).length;

    // Role balance of the current picks (XI + subs), shown in the pinned bar.
    final byId = {for (final p in pool) p.id: p};
    final balance = [
      for (final cat in SquadCategory.values)
        (cat, draft.picks.keys.where((id) => byId[id]?.category == cat).length),
    ].where((e) => e.$2 > 0).map((e) => '${e.$2} ${e.$1.label}').join(' · ');

    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
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
        onSelected: ref.read(lineupFilterProvider(target).notifier).select,
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
      ])),
      // Pinned: counts, role balance, any error and Confirm stay in reach.
      Container(
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: CeColors.line))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 10),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Semantics(
                liveRegion: true,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: 'XI ${draft.playing}/${SquadRules.maxPlaying} · Subs ${draft.subs}/${SquadRules.maxSubs}',
                      style: const TextStyle(fontWeight: FontWeight.w800, color: CeColors.ink),
                    ),
                    if (balance.isNotEmpty) TextSpan(text: '  ·  $balance'),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11.5, color: CeColors.muted),
                ),
              ),
              if (_error != null) ...[const SizedBox(height: 8), CeErrorBanner(_error!)],
              const SizedBox(height: 8),
              CeButton(
                label: 'Confirm Team',
                trailingIcon: CeIcons.of('arrow-right'),
                loading: _saving,
                onPressed: _saving ? null : _confirm,
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// "Discard" app-bar action for the builder (shown while picks are unsaved).
class LineupDiscardAction extends ConsumerWidget {
  const LineupDiscardAction({super.key, required this.target});
  final LineupTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(lineupDraftProvider(target)).dirty) return const SizedBox.shrink();
    return TextButton(
      onPressed: () {
        ref.read(lineupDraftProvider(target).notifier).discard();
        showCeToast(context, 'Unsaved picks discarded');
      },
      child: const Text('Discard'),
    );
  }
}

/// Select Existing Team body (prototype `screens.teamPicker`, :6832): one of
/// My Teams (with its saved XI / subs) becomes the target's line-up.
/// [onConfirmed] gets how many injured / unavailable players were left out.
class LineupTeamPickerView extends ConsumerStatefulWidget {
  const LineupTeamPickerView({
    super.key,
    required this.target,
    required this.intro,
    required this.onConfirmed,
    required this.onGoToTeams,
    this.initialTeamId,
  });
  final LineupTarget target;
  final String intro;
  final String? initialTeamId;
  final ValueChanged<int> onConfirmed;
  final VoidCallback onGoToTeams;

  @override
  ConsumerState<LineupTeamPickerView> createState() => _LineupTeamPickerViewState();
}

class _LineupTeamPickerViewState extends ConsumerState<LineupTeamPickerView> {
  late String? _selected = widget.initialTeamId;
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
    final leftOut = await ref.read(lineupDraftProvider(widget.target).notifier).useTeam(team);
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onConfirmed(leftOut);
  }

  @override
  Widget build(BuildContext context) {
    final teamsAsync = ref.watch(teamsProvider);
    if (teamsAsync.isLoading) return const Center(child: CircularProgressIndicator());
    final teams = teamsAsync.value ?? const <Team>[];
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 4),
        child: Text(widget.intro, style: const TextStyle(fontSize: 13, color: CeColors.muted)),
      ),
      if (teams.isEmpty)
        CeEmptyState(
          icon: 'shield',
          title: 'No teams yet',
          body: 'Create a team in My Teams, or build a new squad instead.',
          primaryLabel: 'Go to My Teams',
          onPrimary: widget.onGoToTeams,
        )
      else
        for (final t in teams)
          TeamRadioRow(
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
  }
}

/// `.team-radio-row`: a selectable club team with its squad counts.
class TeamRadioRow extends StatelessWidget {
  const TeamRadioRow({super.key, required this.team, required this.selected, required this.onTap});
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

/// "Team confirmed!" (+ how many injured / unavailable players were left out).
String teamConfirmedToast(int leftOut) => leftOut == 0
    ? 'Team confirmed!'
    : 'Team confirmed! $leftOut injured or unavailable player${leftOut == 1 ? ' was' : 's were'} left out';
