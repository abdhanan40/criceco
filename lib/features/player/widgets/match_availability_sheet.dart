import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../player_providers.dart';
import '../screens/availability_screen.dart' show resolveUntil;

/// Match Availability (Player Dashboard quick action): a quick Available /
/// Unavailable update in a sheet, written to the same record as the
/// Availability tab ([playerAvailabilityProvider]) — so the tab shows it at
/// once. Unavailable takes an "until" date (Today / Tomorrow / This Weekend /
/// a picked date) and an optional reason and note, like the full screen.
Future<void> showMatchAvailabilitySheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => const _MatchAvailabilitySheet());

class _MatchAvailabilitySheet extends ConsumerStatefulWidget {
  const _MatchAvailabilitySheet();

  @override
  ConsumerState<_MatchAvailabilitySheet> createState() => _MatchAvailabilitySheetState();
}

class _MatchAvailabilitySheetState extends ConsumerState<_MatchAvailabilitySheet> {
  late final PlayerAvailabilityRecord _saved = ref.read(playerAvailabilityProvider);

  /// Available / Unavailable. Other saved states (Limited, Injured, Other)
  /// are kept unless the player picks one of these two.
  late PlayerAvailability? _status = switch (_saved.status) {
    PlayerAvailability.available || PlayerAvailability.unavailable => _saved.status,
    _ => null,
  };
  late AvailabilityUntil _until =
      _saved.status == PlayerAvailability.unavailable ? _saved.until : AvailabilityUntil.today;
  late DateTime? _custom = _saved.until == AvailabilityUntil.custom ? _saved.untilDate : null;
  late AvailabilityReason? _reason = _saved.status == PlayerAvailability.unavailable ? _saved.reason : null;
  late final _note =
      TextEditingController(text: _saved.status == PlayerAvailability.unavailable ? _saved.notes : '');
  bool _pickerOpen = false;
  late DateTime _month = _custom ?? _today;

  DateTime get _today => CeFormat.dateOnly(ref.read(clockProvider).now());

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  DateTime? get _untilDate => resolveUntil(_until, _today, _custom);

  bool get _canSave =>
      _status == PlayerAvailability.available || (_status == PlayerAvailability.unavailable && _untilDate != null);

  void _save() {
    final unavailable = _status == PlayerAvailability.unavailable;
    ref.read(playerAvailabilityProvider.notifier).update(
          status: _status!,
          reason: unavailable ? _reason : null,
          until: unavailable ? _until : AvailabilityUntil.custom,
          untilDate: unavailable ? _untilDate : null,
          notes: unavailable ? _note.text.trim() : '',
        );
    Navigator.of(context).pop();
    showCeToast(context, 'Availability updated');
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
      );

  @override
  Widget build(BuildContext context) {
    final unavailable = _status == PlayerAvailability.unavailable;
    final current = [
      _saved.status.label,
      if (_saved.untilDate != null) 'until ${CeFormat.dayDate(_saved.untilDate!)}',
    ].join(' ');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Match Availability', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text('Current: $current', key: const Key('matchAvailability.current'),
          style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
      _label('Status'),
      _StatusOption(
        key: const Key('matchAvailability.available'),
        label: 'Available',
        detail: 'From today',
        selected: _status == PlayerAvailability.available,
        onTap: () => setState(() => _status = PlayerAvailability.available),
      ),
      const SizedBox(height: 8),
      _StatusOption(
        key: const Key('matchAvailability.unavailable'),
        label: 'Unavailable',
        detail: 'Until a date',
        selected: unavailable,
        onTap: () => setState(() => _status = PlayerAvailability.unavailable),
      ),
      if (unavailable) ...[
        _label('Unavailable until'),
        Wrap(spacing: 7, runSpacing: 7, children: [
          for (final o in AvailabilityUntil.values)
            CeChip(
              label: o == AvailabilityUntil.custom && _custom != null ? CeFormat.dayMonth(_custom!) : o.label,
              selected: o == _until,
              onTap: () => setState(() {
                _until = o;
                _pickerOpen = o == AvailabilityUntil.custom;
              }),
            ),
        ]),
        if (_pickerOpen)
          CeMonthCalendar(
            margin: const EdgeInsets.only(top: 8),
            visibleMonth: _month,
            today: _today,
            selected: _custom,
            isEnabled: (d) => !d.isBefore(_today),
            onMonthChanged: (m) => setState(() => _month = m),
            onSelected: (d) => setState(() {
              _custom = d;
              _pickerOpen = false;
            }),
          )
        else if (_untilDate != null) ...[
          const SizedBox(height: 6),
          Text('Unavailable until ${CeFormat.dayDate(_untilDate!)}',
              style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
        ],
        _label('Reason (optional)'),
        Wrap(spacing: 7, runSpacing: 7, children: [
          for (final r in AvailabilityReason.values)
            CeChip(
              label: r.label,
              selected: r == _reason,
              onTap: () => setState(() => _reason = _reason == r ? null : r),
            ),
        ]),
        const SizedBox(height: 10),
        CeTextField(
          fieldKey: const Key('matchAvailability.note'),
          controller: _note,
          hint: 'Short note (optional)',
          icon: 'file-text',
          maxLength: PlayerAvailabilityRecord.notesMaxLength,
          textCapitalization: TextCapitalization.sentences,
        ),
      ],
      if (_status == null) ...[
        const SizedBox(height: 8),
        Row(children: [
          Icon(CeIcons.of('info'), size: 13, color: CeColors.muted),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('Pick Available or Unavailable to replace your current status.',
                style: TextStyle(fontSize: 11.5, color: CeColors.muted)),
          ),
        ]),
      ],
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(child: CeButton(label: 'Save', onPressed: _canSave ? _save : null)),
      ]),
    ]);
  }
}

/// Radio-style status row.
class _StatusOption extends StatelessWidget {
  const _StatusOption({super.key, required this.label, required this.detail, required this.selected, required this.onTap});
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        button: true,
        label: label,
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(children: [
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 20, color: selected ? CeColors.primary : CeColors.muted2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
                ),
                Text(detail, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ]),
            ),
          ),
        ),
      );
}
