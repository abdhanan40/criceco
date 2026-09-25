import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
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

    final playing = squad.where((e) => e.role == SelectionRole.playing).length;
    final subs = squad.where((e) => e.role == SelectionRole.sub).length;
    final unavailable = squad.where((e) => e.player.locked).length;

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
        // Squad status at a glance: the saved XI / subs against the limits.
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
          child: Row(children: [
            Expanded(child: SquadCounter(value: '$playing/${SquadRules.maxPlaying}', label: 'Playing XI')),
            const SizedBox(width: 10),
            Expanded(child: SquadCounter(value: '$subs/${SquadRules.maxSubs}', label: 'Substitutes')),
          ]),
        ),
        if (unavailable > 0)
          CeInfoNote(
            icon: 'info',
            margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
            text: unavailable == 1
                ? '1 squad player is injured or unavailable'
                : '$unavailable squad players are injured or unavailable',
          ),
        // An empty squad has one call to action (the empty state's); the
        // header button and the all-zero filter row appear once there are players.
        if (squad.isNotEmpty) ...[
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
        ],
        if (squad.isEmpty)
          CeEmptyState(
            icon: 'users',
            title: 'No players in this squad yet',
            body: 'Pick your Playing XI and substitutes from the club players.',
            primaryLabel: 'Add Players',
            onPrimary: () {
              ref.read(addPlayersFilterProvider(teamId).notifier).select(null);
              context.push(Routes.addTeamPlayers(teamId));
            },
          )
        else if (visible.isEmpty)
          CeEmptyState(icon: 'search', title: 'No ${filter!.label} in this squad', body: 'Try another filter.')
        else
          for (final e in visible)
            _SquadMemberRow(
              player: e.player,
              role: e.role,
              onTap: () => showPlayerStatsSheet(
                context,
                player: e.player,
                stats: ref.read(squadPlayerStatsProvider((e.player.name, e.player.position, e.player.availability))),
              ),
            ),
      ]),
    );
  }
}

/// A saved squad member. Tapping opens the player's stats sheet; injured or
/// unavailable players say so under their position (not by colour alone).
class _SquadMemberRow extends StatelessWidget {
  const _SquadMemberRow({required this.player, required this.role, required this.onTap});
  final SquadPlayer player;
  final SelectionRole role;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = player;
    final roleLabel = role == SelectionRole.playing ? 'Playing XI' : 'Substitute';
    return Semantics(
      button: true,
      label: '${p.name}, ${p.position}, $roleLabel${p.locked ? ', ${p.availability.label}' : ''}. View stats',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.row),
            side: const BorderSide(color: CeColors.line),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                CeAvatar(p.name,
                    size: 40, background: p.locked ? CeColors.muted2 : CeColors.primary, foreground: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                    const SizedBox(height: 1),
                    Text(p.position, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                    if (p.locked) ...[
                      const SizedBox(height: 3),
                      Row(children: [
                        Icon(CeIcons.of(availabilityStyle(p.availability).$2), size: 11, color: CeColors.red),
                        const SizedBox(width: 4),
                        Text(p.availability.label,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: CeColors.red)),
                      ]),
                    ],
                  ]),
                ),
                const SizedBox(width: 8),
                SelectionBadge(role: role),
                const SizedBox(width: 4),
                Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
