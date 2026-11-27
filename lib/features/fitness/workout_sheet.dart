import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/session/account_error_text.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../shared/widgets/backend_pending.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_calendar.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_indicators.dart';
import '../../shared/widgets/ce_inputs.dart';
import 'fitness_providers.dart';

/// Add Workout (Fitness Meter header on the Player Dashboard): log a training
/// session so the Fitness Meter counts it as training load.
Future<void> showAddWorkoutSheet(BuildContext context) => showModuleSheet(
      context,
      BackendModule.playerStats,
      title: 'Add Workout',
      open: () => showCeSheet<void>(context, builder: (_) => const _AddWorkoutSheet()),
    );

class _AddWorkoutSheet extends ConsumerStatefulWidget {
  const _AddWorkoutSheet();

  @override
  ConsumerState<_AddWorkoutSheet> createState() => _AddWorkoutSheetState();
}

class _AddWorkoutSheetState extends ConsumerState<_AddWorkoutSheet> {
  // Today in Pakistan when workouts are saved on the server (as it checks).
  late final DateTime _today = ref.read(workoutTodayProvider)();
  late DateTime _date = _today;
  late DateTime _month = _today;
  bool _pickerOpen = false;
  WorkoutType _type = WorkoutType.training;
  WorkoutIntensity _intensity = WorkoutIntensity.moderate;
  final _minutes = TextEditingController();
  final _notes = TextEditingController();

  @override
  void dispose() {
    _minutes.dispose();
    _notes.dispose();
    super.dispose();
  }

  int? get _duration {
    final m = int.tryParse(_minutes.text.trim());
    return m == null || m <= 0 || m > WorkoutEntry.maxMinutes ? null : m;
  }

  String? get _durationError {
    if (_minutes.text.trim().isEmpty) return null;
    return _duration == null ? 'Enter minutes between 1 and ${WorkoutEntry.maxMinutes}' : null;
  }

  bool _saving = false; // one save at a time (rapid taps)

  Future<void> _save() async {
    final minutes = _duration;
    if (_saving || minutes == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(playerWorkoutsProvider.notifier).save(
            date: _date,
            type: _type,
            minutes: minutes,
            intensity: _intensity,
            notes: _notes.text,
          );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (signOutIfNeeded(context, ref, e)) return;
      showCeToast(
        context,
        e is ArgumentError
            ? '${e.message}'
            : accountErrorText(e, fallback: "Couldn't save the workout — please try again"),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    showCeToast(context, 'Workout added');
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
      );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Add Workout', style: Theme.of(context).textTheme.titleLarge),
      _label('Date'),
      CeDateRow(
        key: const Key('workout.date'),
        date: _date,
        open: _pickerOpen,
        hasError: false,
        onTap: () => setState(() {
          _pickerOpen = !_pickerOpen;
          _month = _date;
        }),
      ),
      if (_pickerOpen)
        CeMonthCalendar(
          margin: const EdgeInsets.only(top: 8),
          visibleMonth: _month,
          today: _today,
          selected: _date,
          // Today or earlier (a workout that happened).
          isEnabled: (d) => !d.isAfter(_today),
          onMonthChanged: (m) => setState(() => _month = m),
          onSelected: (d) => setState(() {
            _date = d;
            _pickerOpen = false;
          }),
        ),
      _label('Workout Type'),
      Wrap(spacing: 7, runSpacing: 7, children: [
        for (final t in WorkoutType.values)
          CeChip(label: t.label, selected: t == _type, onTap: () => setState(() => _type = t)),
      ]),
      _label('Duration'),
      CeTextField(
        fieldKey: const Key('workout.minutes'),
        controller: _minutes,
        hint: 'e.g. 60 minutes',
        icon: 'clock',
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
        onChanged: (_) => setState(() {}),
      ),
      if (_durationError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(_durationError!, style: const TextStyle(fontSize: 12, color: CeColors.red)),
        ),
      const Text('Intensity', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
      const SizedBox(height: 8),
      Wrap(spacing: 7, runSpacing: 7, children: [
        for (final i in WorkoutIntensity.values)
          CeChip(label: i.label, selected: i == _intensity, onTap: () => setState(() => _intensity = i)),
      ]),
      _label('Notes (optional)'),
      CeTextField(
        fieldKey: const Key('workout.notes'),
        controller: _notes,
        hint: 'e.g. Bowling drills',
        icon: 'file-text',
        maxLength: WorkoutEntry.notesMaxLength,
        textCapitalization: TextCapitalization.sentences,
      ),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(child: CeButton(label: 'Save Workout', onPressed: _duration == null || _saving ? null : _save)),
      ]),
    ]);
  }
}
