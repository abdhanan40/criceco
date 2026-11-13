import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config/auth_features.dart';
import '../../app/router/routes.dart';
import '../../app/session/account_error_text.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../core/utils/validators.dart';
import '../../data/repositories/account_errors.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'widgets/auth_widgets.dart';

/// Create Account (prototype `screens.createAccount`, :2953) — the Sign Up
/// credentials: Phone-or-Email (email only in Supabase builds), Password,
/// Confirm Password → User Profile Setup, or "Check your email" when the
/// backend wants the address confirmed first.
class CreateAccountScreen extends ConsumerStatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  ConsumerState<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends ConsumerState<CreateAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  ContactMethod _method = ContactMethod.phone;
  bool _submitting = false;

  /// Set when the account was created but its email must be confirmed first
  /// (Supabase): the screen shows "Check your email" instead of the form.
  String? _confirmEmail;

  @override
  void dispose() {
    for (final c in [_phone, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The chosen method; email only when phone sign-in is off (Supabase).
  ContactMethod _methodIn(AuthFeatures features) => features.phoneSignIn ? _method : ContactMethod.email;

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    final method = _methodIn(ref.read(authFeaturesProvider));
    final identifier = method == ContactMethod.phone
        ? (CeValidators.normalizePkPhone(_phone.text) ?? _phone.text.trim())
        : _email.text.trim();
    try {
      await ref.read(sessionProvider.notifier).signUp(
            fullName: '',
            method: method,
            identifier: identifier,
            password: _password.text,
          );
    } on EmailConfirmationRequiredException {
      // Not a failure: the account exists, the email link comes next.
      if (mounted) {
        setState(() {
          _submitting = false;
          _confirmEmail = identifier;
        });
      }
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // Weak password, an existing account, offline, … — the app's own text.
      showCeToast(context, accountErrorText(e, fallback: "Couldn't create your account — please try again"));
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    // Onboarding session → User Profile Setup (pushed, so Back returns here).
    unawaited(context.push(Routes.completeProfile));
  }

  /// After sign-up when the email must be confirmed before the first login.
  Widget _checkEmail(String email) => Column(
        key: const Key('signup.checkEmail'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CeSuccessPanel(
            icon: 'mail',
            title: 'Check your email',
            body: Text('We sent a confirmation link to $email. Confirm your account, then log in.'),
          ),
          CeButton(label: 'Go to Login', onPressed: () => context.go(Routes.login)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final features = ref.watch(authFeaturesProvider);
    final method = _methodIn(features);
    final confirmEmail = _confirmEmail;
    return Scaffold(
      backgroundColor: CeColors.bg,
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Stadium header (as Login / Sign Up) with Back → Sign Up.
          AuthBanner(
            title: 'Join Criceco',
            subtitle: 'Create your profile to get started',
            stadiumPhoto: true,
            showLogo: false,
            onBack: () => CeTopBar.goBack(context, Routes.signup),
          ),
          if (confirmEmail != null)
            AuthPanel(child: _checkEmail(confirmEmail))
          else
            AuthPanel(
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // Credentials only: name, phone, date of birth and picture are
                    // the common profile, collected once on User Profile Setup.
                    // Phone or Email — email only when phone sign-in is off.
                    if (features.phoneSignIn) ...[
                      const CeFieldLabel('Sign up with'),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: CeChoiceGroup<ContactMethod>(
                          columns: 2,
                          values: const [ContactMethod.phone, ContactMethod.email],
                          selected: _method,
                          labelOf: (m) => m == ContactMethod.phone ? 'Phone Number' : 'Email',
                          onSelected: (m) => setState(() => _method = m),
                        ),
                      ),
                    ],
                    if (method == ContactMethod.phone) ...[
                      const CeFieldLabel('Phone Number'),
                      CeTextField(
                        key: const ValueKey('phone-field'),
                        fieldKey: const Key('signup.phone'),
                        controller: _phone,
                        hint: '03XX-XXXXXXX',
                        icon: 'phone',
                        keyboardType: TextInputType.phone,
                        inputFormatters: kPhoneInputFormatters,
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
                      hint: 'e.g. Cricket@123',
                      icon: 'lock',
                      obscure: true,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newPassword],
                      validator: CeValidators.password,
                    ),
                    // Live requirements; Create Account stays off until all are met.
                    CePasswordChecklist(controller: _password),
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
                    ListenableBuilder(
                      listenable: _password,
                      builder: (context, _) => CeButton(
                        label: 'Create Account',
                        loading: _submitting,
                        onPressed: CeValidators.isStrongPassword(_password.text) ? _submit : null,
                      ),
                    ),
                    CeSwitchLine(
                      prompt: 'Already have an account?',
                      action: 'Login',
                      onTap: () => context.go(Routes.login),
                    ),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
