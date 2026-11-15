import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/account_error_text.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/constants/city_areas.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_list_sheet.dart';
import '../../shared/widgets/ce_surfaces.dart';
import 'personal_details_form.dart';

/// Club Owner: Settings → Account. The account's personal details (Full
/// name, City, Area, Date of Birth, Phone) in a sheet, opened in edit mode;
/// saved with the same flow as My Profile's edit mode (Player). Player-only
/// details (Club code, Availability) are not part of it. Never changes the
/// route; closes on Save, Cancel, Back, the close button or a drag down.
Future<void> showPersonalDetailsSheet(BuildContext context) =>
    showCeListSheet<void>(
      context,
      builder: (_) => const _PersonalDetailsSheet(),
    );

class _PersonalDetailsSheet extends ConsumerStatefulWidget {
  const _PersonalDetailsSheet();

  @override
  ConsumerState<_PersonalDetailsSheet> createState() =>
      _PersonalDetailsSheetState();
}

class _PersonalDetailsSheetState extends ConsumerState<_PersonalDetailsSheet> {
  final _formKey = GlobalKey<FormState>();
  final _details = PersonalDetailsEditor();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _details.load(ref.read(currentAccountProvider));
  }

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  CityAreas get _areas => ref.read(cityAreasProvider).value ?? CityAreas.empty;

  Future<void> _pickDateOfBirth() async {
    FocusScope.of(context).unfocus();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final saved = _details.dateOfBirth;
    final picked = await showDatePicker(
      context: context,
      // 1900 is the earliest date the database accepts.
      firstDate: DateTime(1900),
      lastDate: today,
      initialDate:
          saved != null &&
              !saved.isAfter(today) &&
              !saved.isBefore(DateTime(1900))
          ? saved
          : DateTime(now.year - 20, now.month, now.day),
      helpText: 'Date of birth',
    );
    if (picked == null || !mounted) return;
    setState(() => _details.setDateOfBirth(picked));
    _formKey.currentState?.validate();
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await savePersonalDetails(ref, _details, includeDateOfBirth: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // An expired session signs out (to Login, which closes this sheet).
      if (signOutIfNeeded(context, ref, e)) return;
      showCeToast(
        context,
        accountErrorText(
          e,
          fallback: "Couldn't save your profile — please try again",
        ),
      );
      return;
    }
    if (!mounted) return;
    showCeToast(context, 'Profile updated');
    // Close the sheet only while it is still the top route: closed during
    // the save (Close, Back, a drag down), it is already on its way out and a
    // pop here would pop the page beneath it (Settings) instead.
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop();
    } else {
      // A picker (City, Date of Birth) is open above the sheet, or the sheet
      // is on its way out: it stays as it is, ready to use again.
      setState(() => _saving = false);
    }
  }

  void _cancel() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    return CeListSheetFrame(
      key: const Key('personalDetails.sheet'),
      title: 'Personal Details',
      children: [
        CeCard(
          margin: const EdgeInsets.fromLTRB(
            CeSpace.gutter,
            8,
            CeSpace.gutter,
            0,
          ),
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 4),
          child: Form(
            key: _formKey,
            child: PersonalDetailsFields(
              keyPrefix: 'personal',
              editor: _details,
              phoneRequired: PersonalDetailsEditor.phoneRequiredFor(account),
              areaData: ref.watch(cityAreasProvider).value ?? CityAreas.empty,
              onCity: (city) => setState(() => _details.pickCity(city, _areas)),
              onPickArea: (area) =>
                  setState(() => _details.pickArea(area, _areas)),
              onArea: (_) => setState(() {}),
              onPickDateOfBirth: _pickDateOfBirth,
              onSubmit: _save,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CeSpace.gutter,
            16,
            CeSpace.gutter,
            0,
          ),
          child: Column(
            children: [
              CeButton(
                key: const Key('personalDetails.save'),
                label: 'Save Changes',
                loading: _saving,
                onPressed: _saving ? null : _save,
              ),
              const SizedBox(height: 10),
              CeButton.soft(
                key: const Key('personalDetails.cancel'),
                label: 'Cancel',
                onPressed: _saving ? null : _cancel,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
