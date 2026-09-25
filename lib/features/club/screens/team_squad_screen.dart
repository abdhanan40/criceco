import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../club_providers.dart';
import '../teams/teams_controller.dart';
import '../widgets/squad_widgets.dart';

/// Team Squad (prototype `screens.teamSquad`, :5549). Reads the SAVED
/// `team.members`; each row shows its PLAYING XI / SUB badge (approved P5).
class TeamSquadScreen extends ConsumerWidget {
  const TeamSquadScreen({super.key, required this.teamId});
  final String teamId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamsLoading = ref.watch(teamsProvider).isLoading;
    final team = ref.watch(teamProvider(teamId));
    final poolAsync = ref.watch(clubPlayerPoolProvider);
    const bar = CeTopBar(title: 'Team Squad', fallbackLocation: Routes.teams);

    if (teamsLoading || poolAsync.isLoading) {
      return const Scaffold(appBar: bar, body: Center(child: CircularProgressIndicator()));
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

    final byId = {for (final p in poolAsync.value ?? const <SquadPlayer>[]) p.id: p};
    final squad = [
      for (final m in team.members)
        if (byId[m.playerId] != null) (player: byId[m.playerId]!, role: m.selection),
    ];
    final filter = ref.watch(teamSquadFilterProvider(teamId));
    final visible = filter == null ? squad : squad.where((e) => e.player.category == filter).toList();
    int countOf(SquadCategory? c) => c == null ? squad.length : squad.where((e) => e.player.category == c).length;

    return Scaffold(
      appBar: CeTopBar(title: team.name, fallbackLocation: Routes.teams),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: Text(
            '${squad.length} player${squad.length == 1 ? '' : 's'} in squad',
            style: const TextStyle(fontSize: 12, color: CeColors.muted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: CeButton(
            label: 'Add Players',
            icon: CeIcons.of('plus'),
            onPressed: () {
              // Prototype openAddPlayers(): the filter starts at All. The
              // unsaved draft itself is kept (approved P5).
              ref.read(addPlayersFilterProvider(teamId).notifier).select(null);
              context.push(Routes.addTeamPlayers(teamId));
            },
          ),
        ),
        SquadFilterRow(
          selected: filter,
          countOf: countOf,
          onSelected: ref.read(teamSquadFilterProvider(teamId).notifier).select,
        ),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter, vertical: 30),
            child: Text(
              squad.isEmpty ? 'No players in this squad yet.' : 'No ${filter!.label} in this squad.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: CeColors.muted),
            ),
          )
        else
          for (final e in visible)
            Container(
              margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(CeRadius.row),
                border: Border.all(color: CeColors.line),
                boxShadow: CeShadows.card,
              ),
              child: Row(children: [
                CeAvatar(e.player.name, size: 40, background: CeColors.primary, foreground: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.player.name,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                    const SizedBox(height: 1),
                    Text(e.player.position, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                  ]),
                ),
                const SizedBox(width: 8),
                SelectionBadge(role: e.role),
              ]),
            ),
      ]),
    );
  }
}
