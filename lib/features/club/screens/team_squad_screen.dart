import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/account_error_text.dart';
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
      appBar: CeTopBar(
        title: team.name,
        fallbackLocation: Routes.teams,
        actions: [
          IconButton(
            key: const Key('team.delete'),
            tooltip: 'Delete team',
            icon: Icon(CeIcons.of('x-circle'), size: 20, color: CeColors.red),
            onPressed: () => _deleteTeam(context, ref, team),
          ),
        ],
      ),
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
        if (squad.isNotEmpty) _LeadersCard(team: team, squad: [for (final e in squad) e.player]),
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
              leader: e.player.id == team.captainId
                  ? 'Captain'
                  : e.player.id == team.viceCaptainId
                      ? 'Vice-captain'
                      : null,
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

/// "Delete team" → confirmation → archived (docs/TEAM_SQUAD_IMPLEMENTATION.md).
Future<void> _deleteTeam(BuildContext context, WidgetRef ref, Team team) async {
  final ok = await showCeConfirmSheet(
    context,
    title: 'Delete ${team.name}?',
    body: 'The team and its squad are removed from My Teams. The players stay in your club, '
        'and you can use this name again.',
    confirmLabel: 'Delete Team',
    destructive: true,
    icon: 'x-circle',
  );
  if (!ok || !context.mounted) return;
  try {
    await ref.read(teamsProvider.notifier).archive(team.id);
  } catch (e) {
    if (context.mounted) showCeToast(context, accountErrorText(e, fallback: "Couldn't delete the team — please try again"));
    return;
  }
  if (!context.mounted) return;
  showCeToast(context, '${team.name} was deleted');
  context.go(Routes.teams);
}

/// Captain and vice-captain: two squad players (both optional, never the
/// same person). Each row opens a picker of the squad.
class _LeadersCard extends ConsumerStatefulWidget {
  const _LeadersCard({required this.team, required this.squad});
  final Team team;
  final List<SquadPlayer> squad;

  @override
  ConsumerState<_LeadersCard> createState() => _LeadersCardState();
}

class _LeadersCardState extends ConsumerState<_LeadersCard> {
  bool _saving = false;

  String _name(String? id) =>
      widget.squad.where((p) => p.id == id).firstOrNull?.name ?? 'Not set';

  Future<void> _pick({required bool captain}) async {
    if (_saving) return;
    final team = widget.team;
    final choice = await showCeActionSheet(
      context,
      title: captain ? 'Choose captain' : 'Choose vice-captain',
      actions: [
        for (final p in widget.squad) CeSheetAction(icon: 'user', label: p.name, id: p.id),
        const CeSheetAction(icon: 'x', label: 'No one', id: ''),
      ],
    );
    if (choice == null || !mounted) return;
    final picked = choice.isEmpty ? null : choice;
    // Picking the other leader moves them: they can't hold both roles.
    final captainId = captain ? picked : (team.captainId == picked ? null : team.captainId);
    final viceId = captain ? (team.viceCaptainId == picked ? null : team.viceCaptainId) : picked;
    setState(() => _saving = true);
    try {
      await ref.read(teamsProvider.notifier).setLeaders(team.id, captainId: captainId, viceCaptainId: viceId);
    } catch (e) {
      if (mounted) showCeToast(context, accountErrorText(e, fallback: "Couldn't save — please try again"));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget row(String label, String? id, {required bool captain}) => InkWell(
          key: Key(captain ? 'team.captain' : 'team.viceCaptain'),
          onTap: _saving ? null : () => _pick(captain: captain),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, color: CeColors.muted))),
              Text(_name(id),
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: id == null ? CeColors.muted2 : CeColors.ink)),
              const SizedBox(width: 6),
              Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2),
            ]),
          ),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.row),
        border: Border.all(color: CeColors.line),
      ),
      child: Column(children: [
        row('Captain', widget.team.captainId, captain: true),
        const Divider(height: 1, color: CeColors.line),
        row('Vice-captain', widget.team.viceCaptainId, captain: false),
      ]),
    );
  }
}

/// A saved squad member. Tapping opens the player's stats sheet; injured or
/// unavailable players say so under their position (not by colour alone).
class _SquadMemberRow extends StatelessWidget {
  const _SquadMemberRow({required this.player, required this.role, required this.onTap, this.leader});
  final SquadPlayer player;
  final SelectionRole role;
  final VoidCallback onTap;

  /// "Captain" / "Vice-captain", or `null`.
  final String? leader;

  @override
  Widget build(BuildContext context) {
    final p = player;
    final roleLabel = role == SelectionRole.playing ? 'Playing XI' : 'Substitute';
    return Semantics(
      button: true,
      label: '${p.name}, ${p.position}${leader == null ? '' : ', $leader'}, $roleLabel'
          '${p.locked ? ', ${p.availability.label}' : ''}. View stats',
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
                    Text(leader == null ? p.position : '${p.position} · $leader',
                        style: const TextStyle(fontSize: 12, color: CeColors.muted)),
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
