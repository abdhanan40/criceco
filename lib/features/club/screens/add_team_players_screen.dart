import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/ranked_search.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../fitness/fitness_providers.dart';
import '../../fitness/fitness_widgets.dart';
import '../club_providers.dart';
import '../teams/teams_controller.dart';
import '../widgets/squad_widgets.dart';

/// Add Players (prototype `screens.addTeamPlayers`, :5626). Edits the team's
/// squad draft (`squadEditorProvider`): seeded from the SAVED XI/Sub roles,
/// kept when leaving without saving (approved P5), committed by Save Squad.
class AddTeamPlayersScreen extends ConsumerStatefulWidget {
  const AddTeamPlayersScreen({super.key, required this.teamId});
  final String teamId;

  @override
  ConsumerState<AddTeamPlayersScreen> createState() => _AddTeamPlayersScreenState();
}

class _AddTeamPlayersScreenState extends ConsumerState<AddTeamPlayersScreen> {
  bool _saving = false;
  String _query = '';

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.teamSquad(widget.teamId));
    }
  }

  /// Tapping a player never adds them straight away: the Add Player sheet
  /// asks for Playing XI or Substitute first (or lets a picked player be
  /// moved / removed).
  Future<void> _tap(SquadPlayer p) async {
    if (p.locked) {
      showCeToast(context, "${p.name} is ${p.availability.label.toLowerCase()} and can't be added");
      return;
    }
    final draft = ref.read(squadEditorProvider(widget.teamId));
    final full = draft.playing >= SquadRules.maxPlaying && draft.subs >= SquadRules.maxSubs;
    if (full && !draft.picks.containsKey(p.id)) {
      showCeToast(context, 'Playing XI and substitutes are full');
      return;
    }
    final choice = await showCeSheet<_SquadChoice>(
      context,
      builder: (_) => _AddPlayerSheet(teamId: widget.teamId, player: p),
    );
    if (choice == null || !mounted) return;
    final outcome = ref.read(squadEditorProvider(widget.teamId).notifier).assign(p, choice.role);
    if (outcome == PickOutcome.full) {
      showCeToast(context, choice.role == SelectionRole.playing ? 'Playing XI is full' : 'Substitutes are full');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ref.read(squadEditorProvider(widget.teamId).notifier).save();
    if (!mounted) return;
    setState(() => _saving = false);
    showCeToast(context, 'Squad updated!');
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final teamId = widget.teamId;
    final team = ref.watch(teamProvider(teamId));
    final poolAsync = ref.watch(clubPlayerPoolProvider);
    final bar = CeTopBar(title: 'Add Players', onBack: _leave);

    if (poolAsync.isLoading || ref.watch(teamsProvider).isLoading) {
      return Scaffold(appBar: bar, body: const Center(child: CircularProgressIndicator()));
    }
    if (team == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'shield',
          title: 'Team not found',
          body: 'This team is no longer available.',
          primaryLabel: 'Back to Teams',
          onPrimary: () => context.go(Routes.teams),
        ),
      );
    }

    final draft = ref.watch(squadEditorProvider(teamId));
    final pool = poolAsync.value ?? const <SquadPlayer>[];
    final filter = ref.watch(addPlayersFilterProvider(teamId));
    final byCategory = filter == null ? pool : pool.where((p) => p.category == filter).toList();
    // Ranked search (exact → starts with → word starts with → contains) by
    // name, then position.
    final visible = rankedSearch(byCategory, _query, fields: [
      SearchField((SquadPlayer p) => p.name),
      SearchField((SquadPlayer p) => p.position, weight: 1),
    ]);
    int countOf(SquadCategory? c) => c == null ? pool.length : pool.where((p) => p.category == c).length;
    final full = draft.playing >= SquadRules.maxPlaying && draft.subs >= SquadRules.maxSubs;

    return Scaffold(
      appBar: bar,
      // Save stays in reach while scrolling a long player pool.
      bottomNavigationBar: _SaveBar(dirty: draft.dirty, saving: _saving, onSave: _save),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          child: Row(children: [
            Expanded(child: SquadCounter(value: '${draft.playing}/${SquadRules.maxPlaying}', label: 'Playing XI')),
            const SizedBox(width: 10),
            Expanded(child: SquadCounter(value: '${draft.subs}/${SquadRules.maxSubs}', label: 'Substitutes')),
          ]),
        ),
        if (full)
          const CeInfoNote(
            icon: 'check-circle',
            margin: EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
            text: 'Squad is full. Tap a selected player to change their role or remove them.',
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: CeSearchField(hint: 'Search players…', onChanged: (v) => setState(() => _query = v)),
        ),
        SquadFilterRow(
          selected: filter,
          countOf: countOf,
          onSelected: ref.read(addPlayersFilterProvider(teamId).notifier).select,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
          child: Text(
            "Tap a player to choose Playing XI or Substitute. Injured or unavailable players can't be selected.",
            style: TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.4),
          ),
        ),
        if (_query.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
            child: Text('${visible.length} of ${byCategory.length} players',
                style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
          ),
        if (visible.isEmpty)
          _query.trim().isNotEmpty
              ? CeEmptyState(icon: 'search', title: 'No results', body: 'No players match "${_query.trim()}".')
              : CeEmptyState(icon: 'users', title: 'No ${filter?.label ?? 'players'} available', body: 'Try another filter.')
        else
          for (final p in visible)
            SquadPickRow(
              player: p,
              role: draft.picks[p.id],
              onTap: () => _tap(p),
              onStats: () => showPlayerStatsSheet(
                context,
                player: p,
                stats: ref.read(squadPlayerStatsProvider((p.name, p.position, p.availability))),
              ),
            ),
      ]),
    );
  }
}

/// Result of the Add Player sheet: a squad position, or `null` = remove.
class _SquadChoice {
  const _SquadChoice(this.role);
  final SelectionRole? role;
}

/// Add Player sheet: who the player is (name, real cricket role, details),
/// then an explicit Squad Position — Playing XI or Substitute — before
/// anything is added. A player already in the squad can be moved or removed.
class _AddPlayerSheet extends ConsumerStatefulWidget {
  const _AddPlayerSheet({required this.teamId, required this.player});
  final String teamId;
  final SquadPlayer player;

  @override
  ConsumerState<_AddPlayerSheet> createState() => _AddPlayerSheetState();
}

class _AddPlayerSheetState extends ConsumerState<_AddPlayerSheet> {
  late final SelectionRole? _current = ref.read(squadEditorProvider(widget.teamId)).picks[widget.player.id];
  late SelectionRole? _role = _current;
  bool _remove = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final draft = ref.watch(squadEditorProvider(widget.teamId));
    final stats = ref.watch(squadPlayerStatsProvider((p.name, p.position, p.availability)));
    final fitness = ref.watch(poolFitnessProvider)[p.id];
    // The player's real role from their member profile when they have one.
    final member = ref.watch(clubMembersProvider).value?.where((m) => m.poolPlayerId == p.id).firstOrNull;
    final role = member != null && member.plays ? member.roleLine : p.category.label;
    final inSquad = _current != null;

    // Room left, not counting this player's own current place.
    bool room(SelectionRole r) =>
        _current == r ||
        (r == SelectionRole.playing ? draft.playing < SquadRules.maxPlaying : draft.subs < SquadRules.maxSubs);
    final changed = _remove || _role != _current;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        CeAvatar(p.name, size: 46, background: CeColors.primary, foreground: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: CeType.display, fontSize: 16, fontWeight: FontWeight.w700, color: CeColors.ink)),
            const SizedBox(height: 2),
            Text(role, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: CeColors.ink2)),
          ]),
        ),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SquadPill(p.position),
        SquadPill(p.availability.label),
        SquadPill('Rating ${stats.rating}'),
        SquadPill('${stats.matches} matches'),
        if (fitness != null) FitnessBadge(fitness),
      ]),
      const SizedBox(height: 16),
      const Text('SQUAD POSITION',
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: CeColors.muted)),
      const SizedBox(height: 8),
      _PositionOption(
        key: const Key('addPlayer.playing'),
        label: 'Playing XI',
        detail: room(SelectionRole.playing) ? '${draft.playing}/${SquadRules.maxPlaying} selected' : 'Full',
        selected: !_remove && _role == SelectionRole.playing,
        onTap: room(SelectionRole.playing)
            ? () => setState(() {
                  _role = SelectionRole.playing;
                  _remove = false;
                })
            : null,
      ),
      const SizedBox(height: 8),
      _PositionOption(
        key: const Key('addPlayer.sub'),
        label: 'Substitute',
        detail: room(SelectionRole.sub) ? '${draft.subs}/${SquadRules.maxSubs} selected' : 'Full',
        selected: !_remove && _role == SelectionRole.sub,
        onTap: room(SelectionRole.sub)
            ? () => setState(() {
                  _role = SelectionRole.sub;
                  _remove = false;
                })
            : null,
      ),
      if (inSquad) ...[
        const SizedBox(height: 8),
        _PositionOption(
          key: const Key('addPlayer.remove'),
          label: 'Remove from squad',
          detail: 'Back to unselected',
          selected: _remove,
          onTap: () => setState(() => _remove = true),
        ),
      ],
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(
          child: CeButton(
            label: inSquad ? 'Update Player' : 'Add Player',
            onPressed: (_remove || _role != null) && changed
                ? () => Navigator.of(context).pop(_SquadChoice(_remove ? null : _role))
                : null,
          ),
        ),
      ]),
    ]);
  }
}

/// One radio-style Squad Position row; disabled (no [onTap]) when full.
class _PositionOption extends StatelessWidget {
  const _PositionOption({super.key, required this.label, required this.detail, required this.selected, this.onTap});
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: '$label, $detail',
      excludeSemantics: true,
      child: Material(
        color: selected ? CeColors.mint : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.md),
          side: BorderSide(color: selected ? CeColors.primary : CeColors.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.md),
          onTap: onTap,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(children: [
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 20, color: selected ? CeColors.primary : CeColors.muted2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
                ),
                Text(detail, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pinned Save Squad bar; says when there are unsaved picks.
class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.dirty, required this.saving, required this.onSave});
  final bool dirty;
  final bool saving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: CeColors.line)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 10),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AnimatedSize(
                duration: CeMotion.base,
                child: dirty
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(CeIcons.of('info'), size: 13, color: CeColors.amberInk),
                          const SizedBox(width: 5),
                          const Text('Unsaved changes',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: CeColors.amberInk)),
                        ]),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              CeButton(
                label: 'Save Squad',
                trailingIcon: CeIcons.of('arrow-right'),
                loading: saving,
                onPressed: saving ? null : onSave,
              ),
            ]),
          ),
        ),
      );
}

