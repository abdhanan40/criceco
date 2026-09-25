import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/constants/cities.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';

/// Create Availability Slot (prototype `screens.createAvailabilitySlot`,
/// :7188). The prototype's toast-only validation becomes inline errors.
class CreateSlotScreen extends ConsumerStatefulWidget {
  const CreateSlotScreen({super.key});

  @override
  ConsumerState<CreateSlotScreen> createState() => _CreateSlotScreenState();
}

class _CreateSlotScreenState extends ConsumerState<CreateSlotScreen> {
  static const maxOvers = 50;

  MatchFormat? _format;
  final _overs = TextEditingController();
  String? _city;
  Ground? _ground;
  DateTime? _date;
  bool _pickerOpen = false;
  late DateTime _month;
  TimeSlot? _slot;
  final _notes = TextEditingController();
  bool _saving = false;
  final _errors = <String, String>{};

  DateTime get _today => CeFormat.dateOnly(ref.read(clockProvider).now());

  @override
  void initState() {
    super.initState();
    _month = _today;
  }

  @override
  void dispose() {
    _overs.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool _validate() {
    _errors.clear();
    final overs = int.tryParse(_overs.text);
    if (_format == null) _errors['format'] = 'Please select a format';
    if (_format == MatchFormat.custom && (overs == null || overs < 1 || overs > maxOvers)) {
      _errors['overs'] = overs == null ? 'Please enter the number of overs' : 'Enter between 1 and $maxOvers overs';
    }
    if (_city == null) _errors['city'] = 'Please select a city';
    if (_date == null) _errors['date'] = 'Please pick a date';
    if (_slot == null) _errors['slot'] = 'Please pick a time slot';
    setState(() {});
    return _errors.isEmpty;
  }

  Future<void> _post() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) return;
    setState(() => _saving = true);
    final now = ref.read(clockProvider).now();
    await ref.read(availabilitySlotsProvider.notifier).post(AvailabilitySlot(
          id: 'slot_${now.microsecondsSinceEpoch}',
          format: _format!,
          customOvers: _format == MatchFormat.custom ? int.parse(_overs.text) : null,
          city: _city!,
          groundId: _ground?.id,
          date: _date!,
          slot: _slot!,
          notes: _notes.text.trim(),
        ));
    if (!mounted) return;
    showCeToast(context, 'Availability slot posted!');
    context.go(Routes.findMatch); // prototype: go('findMatch')
  }

  Widget _title(String t, {bool optional = false}) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 8),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: t),
            if (optional)
              const TextSpan(text: ' (optional)', style: TextStyle(fontWeight: FontWeight.w500, color: CeColors.muted)),
          ]),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: CeColors.ink),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final grounds = (ref.watch(groundDirectoryProvider).value ?? const <String, Ground>{}).values.toList();
    return Scaffold(
      appBar: const CeTopBar(title: 'Create Availability Slot', fallbackLocation: Routes.findMatch),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 24 + MediaQuery.viewInsetsOf(context).bottom),
          children: [
            const Text(
              'Post an open date and time — other clubs looking for a match can see it and send you a request.',
              style: TextStyle(fontSize: 13, color: CeColors.muted, height: 1.4),
            ),

            _title('Format'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final f in MatchFormat.standard)
                CeChip(
                  label: f == MatchFormat.custom ? 'Custom Overs' : f.label,
                  icon: formatIcon(f),
                  selected: f == _format,
                  onTap: () => setState(() {
                    _format = f;
                    _errors.remove('format');
                  }),
                ),
            ]),
            CeInlineError(_errors['format']),
            if (_format == MatchFormat.custom) ...[
              const SizedBox(height: 10),
              CeTextField(
                fieldKey: const Key('slot.overs'),
                controller: _overs,
                hint: 'Number of overs (e.g. 15)',
                icon: 'hash',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                onChanged: (_) => setState(() => _errors.remove('overs')),
              ),
              CeInlineError(_errors['overs']),
            ],

            _title('City'),
            CeSelectField<String>(
              fieldKey: const Key('slot.city'),
              items: kPakistanCities,
              value: _city,
              labelOf: (c) => c,
              onChanged: (c) => setState(() {
                _city = c;
                _errors.remove('city');
              }),
              sheetTitle: 'City',
              hint: 'Select city',
              icon: 'building-2',
              itemIcon: 'building-2',
            ),
            CeInlineError(_errors['city']),

            _title('Preferred Ground', optional: true),
            CeSelectField<Ground?>(
              fieldKey: const Key('slot.ground'),
              items: [null, ...grounds],
              value: _ground,
              labelOf: (g) => g == null ? 'Any ground in the city' : '${g.name} — ${g.city}',
              onChanged: (g) => setState(() => _ground = g),
              sheetTitle: 'Preferred Ground',
              hint: 'Any ground in the city',
              icon: 'flag',
              itemIcon: 'flag',
            ),

            _title('Date'),
            _DateRow(
              date: _date,
              open: _pickerOpen,
              hasError: _errors.containsKey('date'),
              onTap: () => setState(() {
                _pickerOpen = !_pickerOpen;
                if (_pickerOpen) _month = _date ?? _today;
              }),
            ),
            CeInlineError(_errors['date']),
            if (_pickerOpen)
              CeMonthCalendar(
                margin: const EdgeInsets.only(top: 8),
                visibleMonth: _month,
                today: _today,
                selected: _date,
                isEnabled: (d) => !d.isBefore(_today),
                onMonthChanged: (m) => setState(() => _month = m),
                onSelected: (d) => setState(() {
                  _date = d;
                  _pickerOpen = false;
                  _errors.remove('date');
                }),
              ),

            _title('Time Slot'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final s in TimeSlot.standard)
                CeChip(
                  label: s.label,
                  selected: s == _slot,
                  onTap: () => setState(() {
                    _slot = s;
                    _errors.remove('slot');
                  }),
                ),
            ]),
            CeInlineError(_errors['slot']),

            _title('Notes', optional: true),
            CeTextField(
              fieldKey: const Key('slot.notes'),
              controller: _notes,
              hint: 'e.g. Looking for a competitive T20 friendly',
              maxLines: 3,
              maxLength: 200,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textCapitalization: TextCapitalization.sentences,
            ),

            const SizedBox(height: 16),
            CeButton(
              label: 'Post Availability Slot',
              icon: CeIcons.of('megaphone'),
              loading: _saving,
              onPressed: _saving ? null : _post,
            ),
          ],
        ),
      ),
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({required this.date, required this.open, required this.hasError, required this.onTap});
  final DateTime? date;
  final bool open;
  final bool hasError;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Date, ${date == null ? 'not set' : CeFormat.date(date!)}',
        excludeSemantics: true,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.md),
            side: BorderSide(color: hasError ? CeColors.red : CeColors.line2),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.md),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: CeSize.inputMinHeight),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(children: [
                Icon(CeIcons.of('calendar'), size: 17, color: CeColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(date == null ? 'Pick a date' : CeFormat.dayDate(date!),
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: date == null ? CeColors.muted2 : CeColors.ink)),
                ),
                Icon(CeIcons.of(open ? 'chevron-up' : 'chevron-down'), size: 17, color: CeColors.muted),
              ]),
            ),
          ),
        ),
      );
}
