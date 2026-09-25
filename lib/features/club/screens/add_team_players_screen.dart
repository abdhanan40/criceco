import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
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
    final visible = filter == null ? pool : pool.where((p) => p.category == filter).toList();
    int countOf(SquadCategory? c) => c == null ? pool.length : pool.where((p) => p.category == c).length;

    return Scaffold(
      appBar: bar,
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
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
          onSelected: ref.read(addPlayersFilterProvider(teamId).notifier).select,
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
            child: Text('No ${filter?.label ?? 'players'} available.',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
          )
        else
          for (final p in visible)
            SquadPickRow(
              player: p,
              role: draft.picks[p.id],
              onTap: () => _tap(p),
              onStats: () => showPlayerStatsSheet(context, player: p, stats: readSquadPlayerStats(ref, p)),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 22, CeSpace.gutter, 0),
          child: CeButton(
            label: 'Save Squad',
            trailingIcon: CeIcons.of('arrow-right'),
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ),
      ]),
    );
  }
}

