import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_list_sheet.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../fitness/fitness_providers.dart';
import '../../fitness/fitness_widgets.dart';
import '../club_providers.dart';
import '../screens/teams_screen.dart' show createTeamFormats;
import '../teams/team_suggestion.dart';
import '../teams/teams_controller.dart';
import 'squad_widgets.dart';

/// Club Owner bottom nav → center "+": create a complete team in ONE sheet —
/// name, format, squad setup (live XI / Subs counts and role balance), the
/// club's players (Playing XI / Substitute / Not selected) and Suggest Team.
/// Saves with the existing [TeamsController.create] (the same squad rules as
/// Add Players); no screens, no route change.
Future<void> showCreateTeamFlowSheet(BuildContext context) =>
    showCeListSheet<void>(context, builder: (_) => const _CreateTeamFlowSheet());

class _CreateTeamFlowSheet extends ConsumerStatefulWidget {
  const _CreateTeamFlowSheet();

  @override
  ConsumerState<_CreateTeamFlowSheet> createState() => _CreateTeamFlowSheetState();
}

class _CreateTeamFlowSheetState extends ConsumerState<_CreateTeamFlowSheet> {
  static const _maxCustomOvers = CeValidators.maxCustomOvers;

  final _name = TextEditingController();
  final _overs = TextEditingController();
  MatchFormat _format = MatchFormat.t20;
  Map<String, SelectionRole> _picks = const {};
  List<(SquadPlayer, String)> _leftOut = const [];
  SquadCategory? _filter;
  String? _nameError; // e.g. a duplicate name, from the save
  String? _note; // why a pick was refused
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _overs.dispose();
    super.dispose();
  }

  int? get _customOvers {
    final n = int.tryParse(_overs.text);
    return n == null || n < 1 || n > _maxCustomOvers ? null : n;
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty && (_format != MatchFormat.custom || _customOvers != null) && !_saving;

  void _pick(SquadPlayer p, SelectionRole? role) {
    final (picks, outcome) = setSquadPick(_picks, p, role);
    setState(() {
      switch (outcome) {
        case PickOutcome.changed:
          _picks = picks;
          _note = null;
        case PickOutcome.locked:
          _note = "${p.name} is ${p.availability.label.toLowerCase()} and can't be selected";
        case PickOutcome.full:
          _note = role == SelectionRole.playing
              ? 'Playing XI is full (${SquadRules.maxPlaying}) — make someone a substitute first'
              : 'Substitutes are full (${SquadRules.maxSubs})';
      }
    });
  }

  /// The existing Suggest Team: 11 + 2 from rating, form and fitness, left
  /// for the owner to review and change here.
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
      _filter = null;
      _note = null;
    });
  }

  Future<void> _create() async {
    if (!_valid) return; // also covers a second tap while saving
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _nameError = null;
    });
    final CreateTeamError? error;
    try {
      error = await ref.read(teamsProvider.notifier).create(
            name: _name.text,
            format: _format,
            customOvers: _format == MatchFormat.custom ? _customOvers : null,
            members: [for (final e in _picks.entries) TeamMember(playerId: e.key, selection: e.value)],
          );
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        showCeToast(context, "Couldn't create the team — please try again");
      }
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (error == null) {
      showCeToast(context, 'Team created!');
      Navigator.of(context).pop();
    } else {
      setState(() => _nameError = error!.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final poolAsync = ref.watch(clubPlayerPoolProvider);
    final pool = poolAsync.value ?? const <SquadPlayer>[];
    final fitness = ref.watch(poolFitnessProvider);
    // Suggest Team needs the club players, members and their activity.
    final ready = poolAsync.hasValue && ref.watch(clubMembersProvider).hasValue && ref.watch(memberActivityProvider).hasValue;
    final byId = {for (final p in pool) p.id: p};
    int count(SelectionRole r) => _picks.values.where((x) => x == r).length;
    int ofCategory(SquadCategory c) => _picks.keys.where((id) => byId[id]?.category == c).length;
    final keepers = _picks.keys.where((id) => byId[id] != null && TeamSuggestion.isKeeper(byId[id]!)).length;
    final visible = _filter == null ? pool : pool.where((p) => p.category == _filter).toList();
    // Selected players first (XI, then subs), then the rest.
    final ordered = [
      for (final p in visible) if (_picks[p.id] == SelectionRole.playing) p,
      for (final p in visible) if (_picks[p.id] == SelectionRole.sub) p,
      for (final p in visible) if (!_picks.containsKey(p.id)) p,
    ];

    return CeListSheetFrame(
      key: const Key('createTeam.sheet'),
      title: 'Create Team',
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'XI ${count(SelectionRole.playing)}/${SquadRules.maxPlaying} · Subs ${count(SelectionRole.sub)}/${SquadRules.maxSubs}'
            '${_name.text.trim().isEmpty ? ' · add a team name to create' : ''}',
            key: const Key('createTeam.footerSummary'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: CeColors.muted),
          ),
          // Why a pick was refused — next to the buttons, always in view.
          if (_note != null) ...[
            const SizedBox(height: 4),
            Text(_note!,
                key: const Key('createTeam.note'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: CeColors.red)),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: CeButton.soft(label: 'Cancel', onPressed: _saving ? null : () => Navigator.of(context).pop())),
            const SizedBox(width: 8),
            Expanded(
              child: CeButton(
                key: const Key('createTeam.create'),
                label: 'Create Team',
                loading: _saving,
                onPressed: _valid ? _create : null,
              ),
            ),
          ]),
        ]),
      ),
      children: [
        // ---- Team details ----
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 6, CeSpace.gutter, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const CeFieldLabel('Team Name', required: true),
            CeTextField(
              fieldKey: const Key('createTeam.name'),
              controller: _name,
              hint: 'e.g. Team A (First XI)',
              icon: 'users',
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              maxLength: CeValidators.nameMaxLength,
              onChanged: (_) => setState(() => _nameError = null),
            ),
            CeInlineError(_nameError),
            const CeFieldLabel('Match Format', required: true),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final f in createTeamFormats)
                CeChip(label: f.label, selected: f == _format, onTap: () => setState(() => _format = f)),
            ]),
            if (_format == MatchFormat.custom) ...[
              const SizedBox(height: 10),
              const CeFieldLabel('Number of Overs', required: true),
              CeTextField(
                fieldKey: const Key('createTeam.overs'),
                controller: _overs,
                hint: 'e.g. 15',
                icon: 'hash',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                onChanged: (_) => setState(() {}),
              ),
              if (_overs.text.isNotEmpty && _customOvers == null)
                const CeInlineError('Enter between 1 and $_maxCustomOvers overs'),
            ],
          ]),
        ),

        // ---- Squad setup: live counts and role balance ----
        const CeSectionHeader('Squad Setup'),
        Container(
          key: const Key('createTeam.setup'),
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(CeRadius.card),
            border: Border.all(color: CeColors.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: SquadCounter(value: '${count(SelectionRole.playing)}/${SquadRules.maxPlaying}', label: 'Playing XI'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SquadCounter(value: '${count(SelectionRole.sub)}/${SquadRules.maxSubs}', label: 'Substitutes'),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (label, n) in [
                ('Batsmen', ofCategory(SquadCategory.batsman)),
                ('Bowlers', ofCategory(SquadCategory.bowler)),
                ('All-Rounders', ofCategory(SquadCategory.allRounder)),
                ('Wicket Keepers', keepers),
              ])
                SquadPill('$label $n', key: Key('createTeam.balance.$label')),
            ]),
          ]),
        ),

        // ---- Players: Suggest Team, or pick each player ----
        CeSectionHeader('Select Players', actionLabel: ready ? 'Suggest Team' : null, onAction: ready ? _suggest : null),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Text(
            _picks.isEmpty
                ? 'Pick Playing XI and substitutes, or use Suggest Team (rating, recent form and Fitness Meter). '
                    "Injured or unavailable players can't be selected."
                : 'Review the selection — change any player below.',
            style: const TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.4),
          ),
        ),
        if (_leftOut.isNotEmpty)
          CeInfoNote(
            margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
            text: 'Left out: ${_leftOut.map((e) => '${e.$1.name} — ${e.$2}').join(' · ')}',
          ),
        SquadFilterRow(
          selected: _filter,
          countOf: (c) => c == null ? pool.length : pool.where((p) => p.category == c).length,
          onSelected: (c) => setState(() => _filter = c),
        ),
        if (poolAsync.isLoading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (pool.isEmpty)
          const CeEmptyState(icon: 'users', title: 'No players yet', body: 'Approve join requests to build your squad.')
        else
          for (final p in ordered)
            _PlayerChoiceRow(
              key: Key('createTeam.player.${p.id}'),
              player: p,
              role: _picks[p.id],
              fitness: fitness[p.id],
              onChanged: (role) => _pick(p, role),
            ),
      ],
    );
  }
}

/// A club player with the three choices: Playing XI · Substitute · Not selected.
/// Injured / unavailable players show why and can't be picked.
class _PlayerChoiceRow extends StatelessWidget {
  const _PlayerChoiceRow({
    super.key,
    required this.player,
    required this.role,
    required this.onChanged,
    this.fitness,
  });
  final SquadPlayer player;
  final SelectionRole? role;
  final FitnessReport? fitness;
  final ValueChanged<SelectionRole?> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = player;
    final (bg, border) = p.locked
        ? (CeColors.historySoft, CeColors.line)
        : switch (role) {
            SelectionRole.playing => (CeColors.mint, CeColors.sage),
            SelectionRole.sub => (CeColors.amberSoft, CeColors.countdownBorder),
            null => (Colors.white, CeColors.line),
          };
    Widget choice(String label, SelectionRole? value) {
      final on = role == value;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: '${p.name}: $label',
          excludeSemantics: true,
          child: InkWell(
            key: Key('createTeam.choice.${p.id}.${value?.name ?? 'none'}'),
            borderRadius: BorderRadius.circular(CeRadius.pill),
            onTap: () => onChanged(value), // the squad rule explains a refusal
            child: AnimatedContainer(
              duration: CeMotion.base,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? CeColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(CeRadius.pill),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w700, color: on ? Colors.white : CeColors.ink2)),
              ),
            ),
          ),
        ),
      );
    }

    return Opacity(
      opacity: p.locked ? 0.7 : 1,
      child: Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(CeRadius.row),
          border: Border.all(color: border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CeAvatar(p.name, size: 34, background: CeColors.primary, foreground: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
                Text(p.locked ? '${p.position} · ${p.availability.label}' : p.position,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ]),
            ),
            // A long level ("10/10 · OVERLOADED") scales down rather than
            // overflowing at 320 px.
            if (fitness != null) ...[
              const SizedBox(width: 6),
              Flexible(
                child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: FitnessBadge(fitness!)),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(CeRadius.pill),
              border: Border.all(color: CeColors.line),
            ),
            child: Row(children: [
              choice('Playing XI', SelectionRole.playing),
              choice('Substitute', SelectionRole.sub),
              choice('Not selected', null),
            ]),
          ),
        ]),
      ),
    );
  }
}
