import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'onboarding_controller.dart';
import 'widgets/auth_widgets.dart';

/// User Profile Setup — the common CricEco profile of the account: Full Name,
/// Phone Number, Date of Birth and Profile Picture. No cricket-role questions
/// here; Role Selection comes next.
class UserProfileSetupScreen extends ConsumerStatefulWidget {
  const UserProfileSetupScreen({super.key});

  @override
  ConsumerState<UserProfileSetupScreen> createState() => _UserProfileSetupScreenState();
}

class _UserProfileSetupScreenState extends ConsumerState<UserProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _dob;
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
    FocusScope.of(context).unfocus();
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
    _formKey.currentState?.validate();
  }

  Future<void> _continue() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    // Stored in the account's display form ("0312 9020000"), as Edit Profile does.
    final phone = formatPkPhone(CeValidators.normalizePkPhone(_phone.text)!);
    await ref.read(onboardingProvider.notifier).saveProfile(phone: phone);
    if (!mounted) return;
    setState(() => _saving = false);
    // A returning user with a set-up role enters it; everyone else chooses.
    final role = ref.read(activeRoleProvider);
    context.go(role == null ? Routes.roleSelection : Routes.home(role));
  }

  /// Back → the auth flow: the sign-up step if it's underneath, else Login.
  void _back() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    ref.read(sessionProvider.notifier).logout();
    context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(onboardingProvider);
    final notifier = ref.read(onboardingProvider.notifier);
    return PopScope(
      canPop: context.canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: CeTopBar(title: 'Your Profile', onBack: _back),
        body: Column(children: [
          const CeStepProgress(value: 0.66, label: 'Step 2 of 3 — Your Profile'),
          Expanded(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                  CeSpace.form, 14, CeSpace.form, CeSpace.form + MediaQuery.viewInsetsOf(context).bottom),
              child: Form(
                key: _formKey,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const AuthHeading(
                    title: 'Set up your profile',
                    subtitle: 'This is your CricEco account — you choose Player or Club Owner next.',
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: CePhotoPicker(
                      placeholderIcon: 'user',
                      caption: 'Profile picture (optional)',
                      hasPhoto: draft.hasPhoto,
                      initial: draft.fullName.trim().isEmpty ? null : draft.fullName.trim()[0].toUpperCase(),
                      semanticLabel: draft.hasPhoto ? 'Remove profile picture' : 'Add profile picture',
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
                  const SizedBox(height: 20),
                  CeButton(label: 'Continue', loading: _saving, onPressed: _saving ? null : _continue),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
