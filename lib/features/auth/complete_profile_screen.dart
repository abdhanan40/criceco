import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'onboarding_controller.dart';
import 'widgets/auth_widgets.dart';

/// Complete Your Profile (prototype `screens.completeProfile`, :3001).
/// Step 2 of 3 — photo, full name, date of birth, phone, playing role.
class CompleteProfileScreen extends ConsumerStatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  ConsumerState<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends ConsumerState<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _dob;
  String? _roleError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final d = ref.read(onboardingProvider);
    _name = TextEditingController(text: d.fullName);
    _phone = TextEditingController(text: d.phone);
    _dob = TextEditingController(text: d.dateOfBirth == null ? '' : CeFormat.date(d.dateOfBirth!));
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _dob.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final draft = ref.read(onboardingProvider);
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: draft.dateOfBirth ?? DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(now.year - 80),
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked == null) return;
    ref.read(onboardingProvider.notifier).setDateOfBirth(picked);
    _dob.text = CeFormat.date(picked);
  }

  Future<void> _continue() async {
    final draft = ref.read(onboardingProvider);
    final formOk = _formKey.currentState?.validate() ?? false;
    setState(() => _roleError = draft.role == null ? 'Please select your role' : null);
    if (!formOk || draft.role == null) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    await ref.read(onboardingProvider.notifier).savePlayerDetails();
    if (!mounted) return;
    setState(() => _saving = false);
    unawaited(context.push(Routes.roleDetails));
  }

  Future<void> _skip() async {
    await ref.read(onboardingProvider.notifier).skip();
    if (mounted) context.go(Routes.continueAs);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(onboardingProvider);
    final notifier = ref.read(onboardingProvider.notifier);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: CeTopBar(
        title: 'Complete Your Profile',
        fallbackLocation: Routes.signup,
        actions: [TextButton(onPressed: _skip, child: const Text('Skip', style: TextStyle(fontWeight: FontWeight.w600)))],
      ),
      body: Column(children: [
        const CeStepProgress(value: 0.66, label: 'Step 2 of 3 — Player Details'),
        Expanded(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(CeSpace.form, 14, CeSpace.form, CeSpace.form),
            child: Form(
              key: _formKey,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const AuthHeading(title: 'Your Player Profile', subtitle: 'Tell us about yourself'),
                const SizedBox(height: 18),
                Center(
                  child: CePhotoPicker(
                    placeholderIcon: 'user',
                    caption: 'Profile photo (optional)',
                    hasPhoto: draft.hasPhoto,
                    initial: draft.fullName.trim().isEmpty ? null : draft.fullName.trim()[0].toUpperCase(),
                    semanticLabel: draft.hasPhoto ? 'Remove profile photo' : 'Add profile photo',
                    onTap: notifier.togglePhoto,
                  ),
                ),
                const SizedBox(height: 20),
                const CeFieldLabel('Full Name', required: true),
                CeTextField(
                  fieldKey: const Key('profile.name'),
                  controller: _name,
                  hint: 'Muhammad Ali',
                  icon: 'user',
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  validator: CeValidators.personName,
                  onChanged: notifier.setFullName,
                ),
                const CeFieldLabel('Date of Birth', required: true),
                CeTextField(
                  fieldKey: const Key('profile.dob'),
                  controller: _dob,
                  hint: 'Select date of birth',
                  icon: 'calendar',
                  readOnly: true,
                  showChevron: true,
                  onTap: _pickDob,
                  validator: (_) => draft.dateOfBirth == null ? 'Date of birth is required' : null,
                ),
                const CeFieldLabel('Phone Number', required: true),
                CeTextField(
                  fieldKey: const Key('profile.phone'),
                  controller: _phone,
                  hint: '03XX-XXXXXXX',
                  icon: 'phone',
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  validator: CeValidators.pkPhone,
                  onChanged: notifier.setPhone,
                ),
                const CeFieldLabel('Select your role', required: true),
                CeChoiceGroup<PlayerRole>(
                  values: PlayerRole.values,
                  selected: draft.role,
                  labelOf: (r) => r.label,
                  onSelected: (r) {
                    notifier.setRole(r);
                    setState(() => _roleError = null);
                  },
                ),
                CeInlineError(_roleError),
                const SizedBox(height: 20),
                CeButton(label: 'Continue', loading: _saving, onPressed: _continue),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
