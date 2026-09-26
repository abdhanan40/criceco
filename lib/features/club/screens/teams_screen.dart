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
import '../../../shared/widgets/ce_rows.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../club_providers.dart';
import '../teams/teams_controller.dart';

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
            _TeamRow(
              team: t,
              onTap: () {
                // Prototype openTeamSquad(): the squad filter starts at All.
                ref.read(teamSquadFilterProvider(t.id).notifier).select(null);
                context.go(Routes.teamSquad(t.id));
              },
            ),
      ]),
    );
  }
}

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

  static const maxCustomOvers = 50;

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
          for (final f in MatchFormat.standard)
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
        const SizedBox(height: 16),
        CeButton(label: 'Create Team', loading: _saving, onPressed: _saving ? null : _create),
        const SizedBox(height: 8),
        CeButton.soft(label: 'Cancel', onPressed: _saving ? null : () => Navigator.of(context).pop()),
      ]),
    );
  }
}

/// Compact entry point to the Create Team sheet (the former "New Team" hero).
class _NewTeamRow extends StatelessWidget {
  const _NewTeamRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'New Team. Create a team to organize your club players',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: Material(
            color: CeColors.mint,
            borderRadius: BorderRadius.circular(CeRadius.row),
            child: InkWell(
              borderRadius: BorderRadius.circular(CeRadius.row),
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(CeRadius.row),
                  border: Border.all(color: CeColors.mint2),
                ),
                child: Row(children: [
                  const CeIconWell('plus', size: 40, iconSize: 18, background: Colors.white),
                  const SizedBox(width: 11),
                  const Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('New Team', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
                      SizedBox(height: 2),
                      Text('Create a team to organize your club players',
                          style: TextStyle(fontSize: 11.5, color: CeColors.muted)),
                    ]),
                  ),
                  Icon(CeIcons.of('chevron-right'), size: 18, color: CeColors.primaryDark),
                ]),
              ),
            ),
          ),
        ),
      );
}

class _TeamRow extends StatelessWidget {
  const _TeamRow({required this.team, required this.onTap});
  final Team team;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = team;
    final players = '${t.playerCount} player${t.playerCount == 1 ? '' : 's'}';
    return CeListRow(
      semanticLabel: '${t.name}, $players, ${t.format.display(t.customOvers)}',
      leading: const CeIconWell('shield', size: 40, iconSize: 18),
      title: t.name,
      subtitle: '$players · ${t.format.display(t.customOvers)}',
      onTap: onTap,
    );
  }
}
