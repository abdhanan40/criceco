import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../player_providers.dart';

/// Match Availability (Player Dashboard quick action) — the quick version:
/// Current Status → Change Status (expands in place, every existing status)
/// → optional notes → Save. Writes the same record as the Availability tab
/// ([playerAvailabilityProvider]); the full screen keeps dates and reasons.
Future<void> showMatchAvailabilitySheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => const _MatchAvailabilitySheet());

class _MatchAvailabilitySheet extends ConsumerStatefulWidget {
  const _MatchAvailabilitySheet();

  @override
  ConsumerState<_MatchAvailabilitySheet> createState() => _MatchAvailabilitySheetState();
}

class _MatchAvailabilitySheetState extends ConsumerState<_MatchAvailabilitySheet> {
  late final PlayerAvailabilityRecord _saved = ref.read(playerAvailabilityProvider);
  late PlayerAvailability _status = _saved.status;
  late final _notes = TextEditingController(text: _saved.notes);
  bool _expanded = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  bool get _changed => _status != _saved.status || _notes.text.trim() != _saved.notes;

  void _save() {
    final same = _status == _saved.status;
    // Same status: only the note changes (its date / reason are kept).
    // New status: open-ended — dates and reasons live on the full screen.
    ref.read(playerAvailabilityProvider.notifier).update(
          status: _status,
          reason: same ? _saved.reason : null,
          until: same ? _saved.until : AvailabilityUntil.custom,
          untilDate: same ? _saved.untilDate : null,
          notes: _notes.text.trim(),
        );
    Navigator.of(context).pop();
    showCeToast(context, 'Availability updated');
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = availabilityStyle(_saved.status);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Match Availability', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      const Text('Current Status', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
      const SizedBox(height: 8),
      Row(key: const Key('matchAvailability.current'), children: [
        Icon(CeIcons.of(icon), size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_saved.status.label,
              style: const TextStyle(fontFamily: CeType.display, fontSize: 15, fontWeight: FontWeight.w700, color: CeColors.ink)),
        ),
        CeButton.soft(
          key: const Key('matchAvailability.change'),
          label: _expanded ? 'Done' : 'Change Status',
          dense: true,
          expand: false,
          onPressed: () => setState(() => _expanded = !_expanded),
        ),
      ]),
      // ---- Change Status: every existing status, inline ----
      AnimatedSize(
        duration: CeMotion.base,
        alignment: Alignment.topCenter,
        child: _expanded
            ? Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(children: [
                  for (final s in PlayerAvailability.values) ...[
                    _StatusOption(
                      key: Key('matchAvailability.${s.name}'),
                      status: s,
                      selected: s == _status,
                      onTap: () => setState(() => _status = s),
                    ),
                    if (s != PlayerAvailability.values.last) const SizedBox(height: 6),
                  ],
                ]),
              )
            : const SizedBox(width: double.infinity),
      ),
      const SizedBox(height: 14),
      const CeFieldLabel('Notes (optional)'),
      CeTextField(
        fieldKey: const Key('matchAvailability.note'),
        controller: _notes,
        hint: 'e.g. Back from Saturday',
        icon: 'file-text',
        maxLength: PlayerAvailabilityRecord.notesMaxLength,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
      ),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(child: CeButton(label: 'Save', onPressed: _changed ? _save : null)),
      ]),
    ]);
  }
}

/// Radio-style status row (the app's own status labels and icons).
class _StatusOption extends StatelessWidget {
  const _StatusOption({super.key, required this.status, required this.selected, required this.onTap});
  final PlayerAvailability status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = availabilityStyle(status);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: status.label,
      excludeSemantics: true,
      child: Material(
        color: selected ? CeColors.mint : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.md),
          side: BorderSide(color: selected ? CeColors.primary : CeColors.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20, color: selected ? CeColors.primary : CeColors.muted2),
              const SizedBox(width: 10),
              Icon(CeIcons.of(icon), size: 15, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(status.label,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
