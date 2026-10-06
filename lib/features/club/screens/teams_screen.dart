import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_list_sheet.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../fitness/fitness_providers.dart';
import '../../fitness/fitness_widgets.dart';
import '../club_providers.dart';
import '../teams/team_suggestion.dart';
import '../teams/teams_controller.dart';
import '../widgets/squad_widgets.dart';

/// Teams / My Teams (prototype `screens.teams`, :5453): All Teams, with
/// Create Team (name, format, Custom overs) in a bottom sheet opened from the
/// "New Team" row (Phase B: the list is no longer below an always-open form).
/// Format (and Custom overs) is stored on the team (fix).
class TeamsScreen extends ConsumerWidget {
  const TeamsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamsAsync = ref.watch(teamsProvider);
    final teams = teamsAsync.value ?? const <Team>[];
    ref.watch(clubPlayerPoolProvider); // squad names and availability on the cards

    return Scaffold(
      appBar: CeTopBar(title: 'Teams', onBack: () => context.go(Routes.clubHome)),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        _NewTeamRow(onTap: () => showCreateTeamSheet(context)),
        CeSectionHeader(teams.isEmpty ? 'All Teams' : 'All Teams · ${teams.length}',
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 0)),
        if (teamsAsync.isLoading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (teamsAsync.hasError)
          CeErrorState(
            title: 'Couldn\'t load your teams',
            onRetry: () => ref.invalidate(teamsProvider),
          )
        else if (teams.isEmpty)
          CeEmptyState(
            icon: 'shield',
            title: 'No teams yet',
            body: 'Create a team to organize your club players.',
            primaryLabel: 'Create Team',
            onPrimary: () => showCreateTeamSheet(context),
          )
        else
          for (final t in teams)
            _TeamCard(
              team: t,
              onView: () {
                // Prototype openTeamSquad(): the squad filter starts at All.
                ref.read(teamSquadFilterProvider(t.id).notifier).select(null);
                context.go(Routes.teamSquad(t.id));
              },
              onAddPlayers: () {
                // Same as Team Squad's Add Players: the filter starts at All.
                ref.read(addPlayersFilterProvider(t.id).notifier).select(null);
                // Pushed over Teams: Back returns here.
                context.push(Routes.addTeamPlayers(t.id));
              },
            ),
      ]),
    );
  }
}

/// Club Dashboard → Teams: the club's teams in a sheet, with New Team (the
/// Create Team sheet on top). A team still opens its squad to manage it.
Future<void> showTeamsSheet(BuildContext context) =>
    showCeListSheet<void>(context, builder: (_) => _TeamsSheet(router: GoRouter.of(context)));

class _TeamsSheet extends ConsumerWidget {
  const _TeamsSheet({required this.router});
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamsAsync = ref.watch(teamsProvider);
    final teams = teamsAsync.value ?? const <Team>[];
    ref.watch(clubPlayerPoolProvider); // squad names and availability on the cards
    void leaveTo(String location) {
      Navigator.of(context).pop();
      router.go(location);
    }

    return CeListSheetFrame(
      key: const Key('teams.sheet'),
      title: 'Teams',
      titleTrailing: teamsAsync.hasValue ? CeCountPill(teams.length) : null,
      children: [
        _NewTeamRow(onTap: () => showCreateTeamSheet(context)),
        if (teamsAsync.isLoading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (teamsAsync.hasError)
          CeErrorState(title: 'Couldn\'t load your teams', onRetry: () => ref.invalidate(teamsProvider))
        else if (teams.isEmpty)
          const CeEmptyState(icon: 'shield', title: 'No teams yet', body: 'Create a team to organize your club players.')
        else
          for (final t in teams)
            _TeamCard(
              team: t,
              onView: () {
                ref.read(teamSquadFilterProvider(t.id).notifier).select(null);
                leaveTo(Routes.teamSquad(t.id));
              },
              onAddPlayers: () {
                ref.read(addPlayersFilterProvider(t.id).notifier).select(null);
                leaveTo(Routes.addTeamPlayers(t.id));
              },
            ),
      ],
    );
  }
}

/// Create Team formats, in the order the club picks them most.
const createTeamFormats = [MatchFormat.t20, MatchFormat.odi, MatchFormat.test, MatchFormat.custom];

/// Opens the Create Team sheet; the sheet toasts "Team created!" and closes.
Future<void> showCreateTeamSheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => const _CreateTeamSheet());

class _CreateTeamSheet extends ConsumerStatefulWidget {
  const _CreateTeamSheet();

  @override
  ConsumerState<_CreateTeamSheet> createState() => _CreateTeamSheetState();
}

class _CreateTeamSheetState extends ConsumerState<_CreateTeamSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _overs = TextEditingController();
  MatchFormat? _format;
  String? _formatError;
  String? _nameError; // server-side (duplicate name)
  bool _saving = false;

  /// Suggest Team: the reviewed selection (null = not used) and who was left
  /// out, with the reason.
  Map<String, SelectionRole>? _picks;
  List<(SquadPlayer, String)> _leftOut = const [];

  static const maxCustomOvers = 50;

  void _suggest() {
    FocusScope.of(context).unfocus();
    final pool = ref.read(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
    final s = TeamSuggestion.build(
      pool,
      stats: {for (final p in pool) p.id: ref.read(squadPlayerStatsProvider((p.name, p.position, p.availability)))},
      fitness: ref.read(poolFitnessProvider),
    );
    setState(() {
      _picks = s.picks;
      _leftOut = s.leftOut;
    });
  }

  /// The existing squad rule: Playing XI → Substitute → Not selected.
  void _cycle(SquadPlayer p) {
    final (picks, outcome) = cycleSquadPick(_picks!, p);
    switch (outcome) {
      case PickOutcome.locked:
        showCeToast(context, "${p.name} is ${p.availability.label.toLowerCase()} and can't be added");
      case PickOutcome.full:
        showCeToast(context, 'Playing XI and substitutes are full');
      case PickOutcome.changed:
        setState(() => _picks = picks);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _overs.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _nameError = null;
      _formatError = _format == null ? CreateTeamError.formatRequired.message : null;
    });
    final fieldsOk = _formKey.currentState!.validate();
    if (!fieldsOk || _format == null) return;

    setState(() => _saving = true);
    final error = await ref.read(teamsProvider.notifier).create(
          name: _name.text,
          format: _format,
          customOvers: _format == MatchFormat.custom ? int.tryParse(_overs.text) : null,
          members: [
            for (final e in (_picks ?? const <String, SelectionRole>{}).entries)
              TeamMember(playerId: e.key, selection: e.value),
          ],
        );
    if (!mounted) return;
    setState(() => _saving = false);
    switch (error) {
      case null:
        showCeToast(context, 'Team created!');
        Navigator.of(context).pop();
      case CreateTeamError.duplicateName || CreateTeamError.nameRequired:
        setState(() => _nameError = error.message);
        _formKey.currentState!.validate();
      case CreateTeamError.formatRequired:
        setState(() => _formatError = error.message);
      case CreateTeamError.oversRequired:
        _formKey.currentState!.validate();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Suggest Team needs the club players, members and their activity.
    final ready = ref.watch(clubPlayerPoolProvider).hasValue &&
        ref.watch(clubMembersProvider).hasValue &&
        ref.watch(memberActivityProvider).hasValue;
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const CeIconWell('users', size: 40, iconSize: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('New Team', style: Theme.of(context).textTheme.titleLarge),
              const Text('Create a team to organize your club players',
                  style: TextStyle(fontSize: 12, color: CeColors.muted)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        const CeFieldLabel('Team Name *'),
        CeTextField(
          fieldKey: const Key('teams.name'),
          controller: _name,
          hint: 'e.g. Team A (First XI)',
          icon: 'users',
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
          validator: (v) {
            if ((v ?? '').trim().isEmpty) return CreateTeamError.nameRequired.message;
            return _nameError;
          },
        ),
        const SizedBox(height: 4),
        const CeFieldLabel('Select Format *'),
        Wrap(spacing: 7, runSpacing: 7, children: [
          for (final f in createTeamFormats)
            CeChip(
              label: f.label,
              selected: f == _format,
              onTap: () => setState(() {
                _format = f;
                _formatError = null;
              }),
            ),
        ]),
        CeInlineError(_formatError),
        if (_format == MatchFormat.custom) ...[
          const SizedBox(height: 10),
          const CeFieldLabel('Number of Overs *'),
          CeTextField(
            fieldKey: const Key('teams.overs'),
            controller: _overs,
            hint: 'e.g. 15',
            icon: 'hash',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
            textInputAction: TextInputAction.done,
            validator: (v) {
              final n = int.tryParse(v ?? '');
              if (n == null) return CreateTeamError.oversRequired.message;
              if (n < 1 || n > maxCustomOvers) return 'Enter between 1 and $maxCustomOvers overs';
              return null;
            },
          ),
        ],
        const SizedBox(height: 12),
        if (_picks == null)
          CeButton.soft(
            key: const Key('teams.suggest'),
            label: 'Suggest Team',
            icon: CeIcons.of('users'),
            dense: true,
            onPressed: _saving || !ready ? null : _suggest,
          )
        else
          _SuggestedTeam(
            picks: _picks!,
            leftOut: _leftOut,
            onCycle: _cycle,
            onRemove: () => setState(() {
              _picks = null;
              _leftOut = const [];
            }),
          ),
        const SizedBox(height: 16),
        CeButton(label: 'Create Team', loading: _saving, onPressed: _saving ? null : _create),
        const SizedBox(height: 8),
        CeButton.soft(label: 'Cancel', onPressed: _saving ? null : () => Navigator.of(context).pop()),
      ]),
    );
  }
}

/// Suggest Team, inside the New Team sheet: the suggested 11 + 2 for review,
/// using the existing squad selection (counters, pick rows and the Playing →
/// Substitute → Not selected cycle), with each player's fitness and the
/// players left out. Create Team saves this selection as the squad.
class _SuggestedTeam extends ConsumerWidget {
  const _SuggestedTeam({required this.picks, required this.leftOut, required this.onCycle, required this.onRemove});
  final Map<String, SelectionRole> picks;
  final List<(SquadPlayer, String)> leftOut;
  final ValueChanged<SquadPlayer> onCycle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pool = ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
    final fitness = ref.watch(poolFitnessProvider);
    int count(SelectionRole r) => picks.values.where((x) => x == r).length;
    // Suggested players first (XI, then substitutes), then everyone else.
    final byId = {for (final p in pool) p.id: p};
    final ordered = [
      for (final id in picks.keys) ?byId[id],
      for (final p in pool) if (!picks.containsKey(p.id)) p,
    ];
    return Container(
      key: const Key('teams.suggestion'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.lg),
        border: Border.all(color: CeColors.sage, width: 1.4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(
            child: Text('Suggested Team',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: CeColors.ink)),
          ),
          TextButton(onPressed: onRemove, child: const Text('Remove')),
        ]),
        const Text(
          'Best available players by rating, recent form and Fitness Meter. Tap a player to change: '
          'Playing XI → Substitute → Not selected.',
          style: TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.4),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: SquadCounter(value: '${count(SelectionRole.playing)}/${SquadRules.maxPlaying}', label: 'Playing XI')),
          const SizedBox(width: 8),
          Expanded(child: SquadCounter(value: '${count(SelectionRole.sub)}/${SquadRules.maxSubs}', label: 'Substitutes')),
        ]),
        if (leftOut.isNotEmpty) ...[
          const SizedBox(height: 10),
          CeInfoNote(
            margin: EdgeInsets.zero,
            text: 'Left out: ${leftOut.map((e) => '${e.$1.name} — ${e.$2}').join(' · ')}',
          ),
        ],
        for (final p in ordered)
          SquadPickRow(
            player: p,
            role: picks[p.id],
            onTap: () => onCycle(p),
            badge: fitness[p.id] == null ? null : FitnessBadge(fitness[p.id]!),
            margin: const EdgeInsets.only(top: 8),
          ),
      ]),
    );
  }
}

/// "Create New Team" banner (reference layout): opens the New Team sheet,
/// where Suggest Team is available.
class _NewTeamRow extends StatelessWidget {
  const _NewTeamRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Create New Team. Build a team, then add players or use Suggest Team',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: Material(
            color: CeColors.mint,
            borderRadius: BorderRadius.circular(CeRadius.lg),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(CeRadius.lg),
                  border: Border.all(color: CeColors.mint2),
                ),
                child: Stack(children: [
                  // Faint sports motif behind the text (decorative).
                  Positioned(
                    right: 36,
                    bottom: -14,
                    child: Icon(CeIcons.of('trophy'), size: 76, color: CeColors.primary.withValues(alpha: 0.08)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
                    child: Row(children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(color: CeColors.primary, borderRadius: BorderRadius.circular(CeRadius.md)),
                        child: Icon(CeIcons.of('plus'), size: 22, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Create New Team',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: CeColors.ink)),
                          SizedBox(height: 2),
                          Text('Build a team, then add players or use Suggest Team',
                              style: TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.35)),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(color: CeColors.primaryDark, shape: BoxShape.circle),
                        child: Icon(CeIcons.of('chevron-right'), size: 16, color: Colors.white),
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

/// Team card (reference layout): identity, squad stats, squad avatars with
/// Add Players, and View Team — all from the saved squad.
class _TeamCard extends ConsumerWidget {
  const _TeamCard({required this.team, required this.onView, required this.onAddPlayers});
  final Team team;
  final VoidCallback onView;
  final VoidCallback onAddPlayers;

  static const _squadMax = SquadRules.maxPlaying + SquadRules.maxSubs; // 15

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = team;
    final pool = {for (final p in ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[]) p.id: p};
    final squad = [for (final m in t.members) ?pool[m.playerId]];
    final available = squad.where((p) => !p.locked).length;
    final players = '${t.playerCount} player${t.playerCount == 1 ? '' : 's'}';
    final format = t.format.display(t.customOvers);

    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(CeRadius.lg), boxShadow: CeShadows.card),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.lg),
          side: const BorderSide(color: CeColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ---- Identity (tap → Team Squad) ----
          Semantics(
            button: true,
            label: '${t.name}, $players, $format',
            excludeSemantics: true,
            child: InkWell(
              onTap: onView,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Row(children: [
                  const CeIconWell('shield', size: 46, iconSize: 21),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: CeColors.ink)),
                      const SizedBox(height: 4),
                      Text('$format · $players',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                    ]),
                  ),
                  Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2),
                ]),
              ),
            ),
          ),
          // ---- Squad stats ----
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (final (i, (icon, value, label)) in [
                ('users', '${t.playerCount}/$_squadMax', 'Players'),
                ('star', '${t.playingCount}/${SquadRules.maxPlaying}', 'Playing XI'),
                ('repeat', '${t.subCount}/${SquadRules.maxSubs}', 'Subs'),
                ('check-circle', '$available', 'Available'),
              ].indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(child: _StatTile(icon: icon, value: value, label: label)),
              ],
            ]),
          ),
          // ---- Squad avatars + Add Players ----
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(children: [
              Expanded(child: _AvatarStrip(names: [for (final p in squad) p.name])),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: 'Add Players to ${t.name}',
                excludeSemantics: true,
                child: Material(
                  color: CeColors.mint,
                  shape: const StadiumBorder(side: BorderSide(color: CeColors.mint2)),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: onAddPlayers,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: CeSize.touchTarget),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(CeIcons.of('user-plus'), size: 15, color: CeColors.primaryDark),
                          const SizedBox(width: 6),
                          const Text('Add Players',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          // ---- Action ----
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: CeButton.soft(
              label: 'View Team',
              icon: CeIcons.of('clipboard-list'),
              dense: true,
              onPressed: onView,
            ),
          ),
        ]),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.value, required this.label});
  final String icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
        decoration: BoxDecoration(color: CeColors.bg, borderRadius: BorderRadius.circular(CeRadius.md)),
        child: Row(children: [
          Icon(CeIcons.of(icon), size: 14, color: CeColors.primaryDark),
          const SizedBox(width: 5),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: CeColors.ink,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9.5, color: CeColors.muted)),
            ]),
          ),
        ]),
      );
}

/// Up to five squad initials, then "+N"; empty seats when the squad is empty.
class _AvatarStrip extends StatelessWidget {
  const _AvatarStrip({required this.names});
  final List<String> names;

  static const _shown = 5;
  static const _size = 28.0;

  @override
  Widget build(BuildContext context) {
    final extra = names.length - _shown;
    return Semantics(
      label: names.isEmpty ? 'No players yet' : '${names.length} players in squad',
      excludeSemantics: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(children: [
          for (var i = 0; i < _shown; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            i < names.length
                ? CeAvatar(names[i], size: _size, background: CeColors.primary, foreground: Colors.white)
                : Container(
                    width: _size,
                    height: _size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: CeColors.historySoft,
                      border: Border.all(color: CeColors.line),
                    ),
                    child: Icon(CeIcons.of('user'), size: 13, color: CeColors.muted2),
                  ),
          ],
          if (extra > 0) ...[
            const SizedBox(width: 4),
            Container(
              height: _size,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.pill)),
              child: Text('+$extra',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
            ),
          ],
        ]),
      ),
    );
  }
}
