import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_indicators.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'widgets/auth_widgets.dart';

/// Create Account (prototype `screens.createAccount`, :2953): Full Name,
/// Phone-or-Email, Password, Confirm Password → Complete Profile.
class CreateAccountScreen extends ConsumerStatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  ConsumerState<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends ConsumerState<CreateAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  ContactMethod _method = ContactMethod.phone;
  bool _submitting = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    final identifier = _method == ContactMethod.phone
        ? (CeValidators.normalizePkPhone(_phone.text) ?? _phone.text.trim())
        : _email.text.trim();
    await ref.read(sessionProvider.notifier).signUp(
          fullName: _name.text.trim(),
          method: _method,
          identifier: identifier,
          password: _password.text,
        );
    if (!mounted) return;
    setState(() => _submitting = false);
    // Onboarding session → Complete Profile (pushed, so Back returns here).
    unawaited(context.push(Routes.completeProfile));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: const CeTopBar(title: 'Create Account', fallbackLocation: Routes.signup),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(CeSpace.form),
        child: Form(
          key: _formKey,
          child: AutofillGroup(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const CenterBlock(
                icon: 'circle-dot',
                title: 'Join Criceco',
                subtitle: 'Create your player profile to get started',
              ),
              const CeFieldLabel('Full Name'),
              CeTextField(
                fieldKey: const Key('signup.name'),
                controller: _name,
                hint: 'Muhammad Ali',
                icon: 'user',
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                validator: CeValidators.personName,
              ),
              const CeFieldLabel('Sign up with'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  CeChip(
                    label: 'Phone Number',
                    icon: 'phone',
                    selected: _method == ContactMethod.phone,
                    onTap: () => setState(() => _method = ContactMethod.phone),
                  ),
                  CeChip(
                    label: 'Email',
                    icon: 'mail',
                    selected: _method == ContactMethod.email,
                    onTap: () => setState(() => _method = ContactMethod.email),
                  ),
                ]),
              ),
              if (_method == ContactMethod.phone) ...[
                const CeFieldLabel('Phone Number'),
                CeTextField(
                  key: const ValueKey('phone-field'),
                  fieldKey: const Key('signup.phone'),
                  controller: _phone,
                  hint: '03XX-XXXXXXX',
                  icon: 'phone',
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  validator: CeValidators.pkPhone,
                ),
              ] else ...[
                const CeFieldLabel('Email Address'),
                CeTextField(
                  key: const ValueKey('email-field'),
                  fieldKey: const Key('signup.email'),
                  controller: _email,
                  hint: 'you@example.com',
                  icon: 'mail',
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  validator: CeValidators.email,
                ),
              ],
              const CeFieldLabel('Password'),
              CeTextField(
                fieldKey: const Key('signup.password'),
                controller: _password,
                hint: 'Min 6 characters',
                icon: 'lock',
                obscure: true,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                validator: CeValidators.password,
              ),
              const CeFieldLabel('Confirm Password'),
              CeTextField(
                fieldKey: const Key('signup.confirm'),
                controller: _confirm,
                hint: 'Re-enter password',
                icon: 'lock',
                obscure: true,
                textInputAction: TextInputAction.done,
                validator: (v) => CeValidators.confirmPassword(v, _password.text),
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 4),
              CeButton(label: 'Create Account', loading: _submitting, onPressed: _submit),
              CeSwitchLine(
                prompt: 'Already have an account?',
                action: 'Login',
                onTap: () => context.go(Routes.login),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
