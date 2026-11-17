import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/session/account_error_text.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/validators.dart';
import '../../../data/repositories/repositories.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../screens/teams_screen.dart' show createTeamFormats;
import '../teams/teams_controller.dart';

/// Team Squad → pencil: Edit Team (name, format, Custom overs) in a bottom
/// sheet styled like Create Team. Saves with [TeamsController.updateDetails],
/// which keeps the squad, captain and vice-captain; the sheet toasts
/// "Team updated" and closes. Owner only — the Teams area is the club
/// owner's, and the database (`save_team`) checks it again.
Future<void> showEditTeamSheet(BuildContext context, Team team) =>
    showCeSheet<void>(context, builder: (_) => EditTeamSheet(team: team));

class EditTeamSheet extends ConsumerStatefulWidget {
  const EditTeamSheet({super.key, required this.team});

  /// The team as shown when the sheet opened (the form's starting values).
  final Team team;

  @override
  ConsumerState<EditTeamSheet> createState() => _EditTeamSheetState();
}

class _EditTeamSheetState extends ConsumerState<EditTeamSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.team.name);
  late final _overs = TextEditingController(
    text: widget.team.format == MatchFormat.custom && widget.team.customOvers != null
        ? '${widget.team.customOvers}'
        : '',
  );
  late MatchFormat _format = widget.team.format;
  String? _nameError; // from the save: duplicate name, also the database's
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _overs.dispose();
    super.dispose();
  }

  int? get _customOvers => _format == MatchFormat.custom ? int.tryParse(_overs.text) : null;

  /// Save is offered only once something differs from the team.
  bool get _changed {
    final t = widget.team;
    return normalizeTeamName(_name.text) != t.name ||
        _format != t.format ||
        (_format == MatchFormat.custom && _customOvers != t.customOvers);
  }

  Future<void> _save() async {
    if (_saving) return; // one submission at a time
    FocusScope.of(context).unfocus();
    setState(() => _nameError = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    final CreateTeamError? error;
    try {
      error = await ref
          .read(teamsProvider.notifier)
          .updateDetails(widget.team.id, _name.text, format: _format, customOvers: _customOvers);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // A name another device took meanwhile: shown on the field, like ours.
      if (e is TeamRuleException && e.message == CreateTeamError.duplicateName.message) {
        setState(() => _nameError = e.message);
        _formKey.currentState!.validate();
      } else {
        showCeToast(context, accountErrorText(e, fallback: "Couldn't update the team — please try again"));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    switch (error) {
      case null:
        showCeToast(context, 'Team updated');
        Navigator.of(context).pop();
      case CreateTeamError.duplicateName || CreateTeamError.nameRequired || CreateTeamError.nameTooLong:
        setState(() => _nameError = error!.message);
        _formKey.currentState!.validate();
      case CreateTeamError.formatRequired || CreateTeamError.oversRequired || CreateTeamError.oversOutOfRange:
        _formKey.currentState!.validate();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        key: const Key('editTeam.sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CeIconWell('edit-3', size: 40, iconSize: 19),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Edit Team', style: Theme.of(context).textTheme.titleLarge),
                    const Text(
                      'Change the team name or format. The squad stays as it is.',
                      style: TextStyle(fontSize: 12, color: CeColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const CeFieldLabel('Team Name *'),
          CeTextField(
            fieldKey: const Key('editTeam.name'),
            controller: _name,
            hint: 'e.g. Team A (First XI)',
            icon: 'users',
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            maxLength: CeValidators.nameMaxLength,
            onChanged: (_) => setState(() => _nameError = null),
            validator: (v) {
              final name = normalizeTeamName(v ?? '');
              if (name.isEmpty) return CreateTeamError.nameRequired.message;
              if (name.length > CeValidators.nameMaxLength) return CreateTeamError.nameTooLong.message;
              return _nameError;
            },
          ),
          const SizedBox(height: 4),
          const CeFieldLabel('Select Format *'),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final f in createTeamFormats)
                CeChip(
                  key: Key('editTeam.format.${f.name}'),
                  label: f.label,
                  selected: f == _format,
                  onTap: _saving ? null : () => setState(() => _format = f),
                ),
            ],
          ),
          if (_format == MatchFormat.custom) ...[
            const SizedBox(height: 10),
            const CeFieldLabel('Number of Overs *'),
            CeTextField(
              fieldKey: const Key('editTeam.overs'),
              controller: _overs,
              hint: 'e.g. 15',
              icon: 'hash',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              validator: (v) => CeValidators.customOvers(int.tryParse(v ?? '')),
            ),
          ],
          const SizedBox(height: 16),
          CeButton(
            key: const Key('editTeam.save'),
            label: 'Save',
            loading: _saving,
            onPressed: _saving || !_changed ? null : _save,
          ),
          const SizedBox(height: 8),
          CeButton.soft(
            key: const Key('editTeam.cancel'),
            label: 'Cancel',
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
