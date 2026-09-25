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
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../club_providers.dart';
import '../teams/teams_controller.dart';

/// Teams / My Teams (prototype `screens.teams`, :5453): inline Create Team
/// form + All Teams. Format (and Custom overs) is stored on the team (fix).
class TeamsScreen extends ConsumerStatefulWidget {
  const TeamsScreen({super.key});

  @override
  ConsumerState<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends ConsumerState<TeamsScreen> {
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
        _name.clear();
        _overs.clear();
        setState(() => _format = null);
        _formKey.currentState!.reset();
        showCeToast(context, 'Team created!');
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
    final teamsAsync = ref.watch(teamsProvider);
    final teams = teamsAsync.value ?? const <Team>[];

    return Scaffold(
      appBar: CeTopBar(title: 'Teams', onBack: () => context.go(Routes.clubHome)),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(bottom: 24 + MediaQuery.viewInsetsOf(context).bottom),
          children: [
            Form(
              key: _formKey,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(CeSpace.form, 14, CeSpace.form, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const _NewTeamHero(),
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 12),
                  CeButton(label: 'Create Team', loading: _saving, onPressed: _saving ? null : _create),
                ]),
              ),
            ),
            const CeSectionHeader('All Teams', padding: EdgeInsets.fromLTRB(CeSpace.gutter, 22, CeSpace.gutter, 4)),
            if (teamsAsync.isLoading)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (teams.isEmpty)
              const CeEmptyState(
                icon: 'shield',
                title: 'No teams yet',
                body: 'Create a team above to organize your club players.',
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
          ],
        ),
      ),
    );
  }
}

class _NewTeamHero extends StatelessWidget {
  const _NewTeamHero();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        decoration: BoxDecoration(
          color: CeColors.mint,
          borderRadius: BorderRadius.circular(CeRadius.lg),
          border: Border.all(color: CeColors.mint2),
        ),
        child: Column(children: [
          const CeIconWell('users', size: 50, iconSize: 24, background: Colors.white),
          const SizedBox(height: 10),
          Text('New Team', style: Theme.of(context).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Create a team to organize your club players',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: CeColors.muted)),
        ]),
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
    return Semantics(
      button: true,
      label: '${t.name}, $players, ${t.format.display(t.customOvers)}',
      excludeSemantics: true,
      child: CeCard(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        onTap: onTap,
        child: Row(children: [
          const CeIconWell('shield', size: 44, iconSize: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
              const SizedBox(height: 2),
              Text('$players · ${t.format.display(t.customOvers)}',
                  style: const TextStyle(fontSize: 12, color: CeColors.muted, height: 1.35)),
            ]),
          ),
          Icon(CeIcons.of('chevron-right'), size: 18, color: CeColors.muted),
        ]),
      ),
    );
  }
}
