import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/ranked_search.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
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

  void _tap(SquadPlayer p) {
    final outcome = ref.read(squadEditorProvider(widget.teamId).notifier).cycle(p);
    switch (outcome) {
      case PickOutcome.locked:
        showCeToast(context, "${p.name} is ${p.availability.label.toLowerCase()} and can't be added");
      case PickOutcome.full:
        showCeToast(context, 'Playing XI and substitutes are full');
      case PickOutcome.changed:
        break;
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
            "Tap a player to mark Playing → Substitute → Unselected. Injured or unavailable players can't be selected.",
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

