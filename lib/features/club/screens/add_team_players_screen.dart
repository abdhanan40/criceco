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
            Expanded(child: _Counter(value: '${draft.playing}/${SquadRules.maxPlaying}', label: 'Playing XI')),
            const SizedBox(width: 10),
            Expanded(child: _Counter(value: '${draft.subs}/${SquadRules.maxSubs}', label: 'Substitutes')),
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
            _PickRow(
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

class _Counter extends StatelessWidget {
  const _Counter({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.md)),
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: CeColors.primaryDark,
                  fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10.5, color: CeColors.muted)),
        ]),
      );
}

/// `.squad-pick-row`: playing / sub / locked states, scouting meta and Stats.
class _PickRow extends ConsumerWidget {
  const _PickRow({required this.player, required this.role, required this.onTap, required this.onStats});
  final SquadPlayer player;
  final SelectionRole? role;
  final VoidCallback onTap;
  final VoidCallback onStats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = player;
    final s = readSquadPlayerStats(ref, p);
    final locked = p.locked;
    final (bg, border) = locked
        ? (CeColors.historySoft, CeColors.line)
        : switch (role) {
            SelectionRole.playing => (CeColors.mint2, const Color(0xFF9FD9BB)),
            SelectionRole.sub => (CeColors.amberSoft, const Color(0xFFF0D9A8)),
            null => (Colors.white, CeColors.line),
          };
    final state = locked
        ? p.availability.label
        : switch (role) {
            SelectionRole.playing => 'Playing XI',
            SelectionRole.sub => 'Substitute',
            null => 'Not selected',
          };

    return Opacity(
      opacity: locked ? 0.72 : 1,
      child: Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.row), side: BorderSide(color: border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(
                  button: true,
                  label: '${p.name}, ${p.position}, $state',
                  excludeSemantics: true,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: CeAvatar(p.name,
                        size: 40, background: locked ? CeColors.muted2 : CeColors.primary, foreground: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text(p.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                      ),
                      if (s.verified) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Verified player',
                          child: Icon(CeIcons.of('check-circle'), size: 14, color: CeColors.primary),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 1),
                    Text(p.position, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      _Meta(icon: 'star', text: s.rating),
                      _Meta(icon: 'circle-dot', text: '${s.matches}'),
                      CeFormDots(s.form, size: 12),
                    ]),
                  ]),
                ),
                const SizedBox(width: 8),
                // Capped so a long status ("Unavailable") never squeezes the details.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 104),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _StateBadge(role: role, locked: locked, availability: p.availability),
                    ),
                    const SizedBox(height: 7),
                    OutlinedButton(
                      onPressed: onStats,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(64, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: const BorderSide(color: CeColors.line2),
                        backgroundColor: Colors.white,
                        foregroundColor: CeColors.primaryDark,
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                      child: Text('Stats', semanticsLabel: 'Stats for ${p.name}'),
                    ),
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

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.role, required this.locked, required this.availability});
  final SelectionRole? role;
  final bool locked;
  final PlayerAvailability availability;

  @override
  Widget build(BuildContext context) {
    if (!locked && role != null) return SelectionBadge(role: role!);
    final (_, icon) = availabilityStyle(availability);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: locked ? CeColors.line : CeColors.mint,
        borderRadius: BorderRadius.circular(CeRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (locked) ...[Icon(CeIcons.of(icon), size: 11, color: CeColors.muted), const SizedBox(width: 3)],
        Text(locked ? availability.label : 'Tap to add',
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: locked ? CeColors.muted : CeColors.primaryDark)),
      ]),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 12, color: CeColors.primary),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: CeColors.muted)),
      ]);
}
