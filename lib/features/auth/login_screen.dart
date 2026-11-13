import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config/auth_features.dart';
import '../../app/router/routes.dart';
import '../../app/session/account_error_text.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_inputs.dart';
import 'forgot_password_sheet.dart';
import 'widgets/auth_widgets.dart';

/// Login (prototype `screens.login`, criceco-app.js :2898).
/// Phone + password, as in the prototype; email + password in Supabase builds
/// ([AuthFeatures.phoneSignIn] off). After a successful sign-in the router
/// guard takes the user to Continue As (or the remembered role home).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return; // keyboard "done" can't double-submit either
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    // Supabase builds sign in by email only (no phone sign-in there).
    final byPhone = ref.read(authFeaturesProvider).phoneSignIn;
    String? error;
    try {
      final ok = await ref.read(sessionProvider.notifier).signIn(
            identifier: byPhone ? (CeValidators.normalizePkPhone(_phone.text) ?? _phone.text.trim()) : _email.text.trim(),
            password: _password.text,
          );
      if (!ok) {
        error = byPhone
            ? 'Incorrect phone number or password. Please try again.'
            : 'Incorrect email or password. Please try again.';
      }
    } catch (e) {
      // Unexpected failure, not wrong credentials: offline, email not yet
      // confirmed, … — the app's own message, never the raw error.
      error = accountErrorText(e, fallback: "Couldn't log in right now. Please try again.");
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error;
    });
    // On success the router redirect moves to Continue As / role home. The
    // redirect leaves an incomplete profile on the auth screens (so Back from
    // Profile Setup works), so that case — e.g. the first login after email
    // confirmation — goes to User Profile Setup here.
    if (error == null && ref.read(sessionProvider).status == SessionStatus.onboarding) {
      context.go(Routes.profileSetup);
    }
  }

  /// Reset by phone number or email (bottom sheet), then log in with the new
  /// password: a phone number is prefilled, the old password cleared.
  Future<void> _forgotPassword() async {
    FocusScope.of(context).unfocus();
    final identifier = await showForgotPasswordSheet(context, initialIdentifier: _phone.text.trim());
    if (identifier == null || !mounted) return;
    setState(() {
      _error = null;
      if (!identifier.contains('@')) _phone.text = identifier;
      _password.clear();
    });
    showCeToast(context, 'Password reset. Log in with your new password.');
  }

  @override
  Widget build(BuildContext context) {
    final features = ref.watch(authFeaturesProvider);
    return Scaffold(
      backgroundColor: CeColors.bg,
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const AuthBanner(title: 'Criceco', subtitle: 'Your cricket club, organized.', stadiumPhoto: true),
          AuthPanel(
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  AuthTabs(active: AuthTab.login, onSelected: (_) => context.go(Routes.signup)),
                  const SizedBox(height: 18),
                  const AuthHeading(title: 'Welcome back', subtitle: 'Login to manage your cricket club'),
                  const SizedBox(height: 18),
                  if (features.phoneSignIn) ...[
                    const CeFieldLabel('Phone number'),
                    CeTextField(
                      fieldKey: const Key('login.phone'),
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
                    const CeFieldLabel('Email address'),
                    CeTextField(
                      fieldKey: const Key('login.email'),
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
                    fieldKey: const Key('login.password'),
                    controller: _password,
                    hint: 'Enter your password',
                    icon: 'lock',
                    obscure: true,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    validator: (v) => (v == null || v.isEmpty) ? 'Password is required' : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  // Password reset isn't configured on the Supabase backend.
                  if (features.passwordReset)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('login.forgot'),
                        onPressed: _forgotPassword,
                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 36)),
                        child: Text('Forgot password?', style: CeType.buttonSmall.copyWith(color: CeColors.primary)),
                      ),
                    )
                  else
                    const SizedBox(height: 14),
                  const SizedBox(height: 2),
                  if (_error != null) CeErrorBanner(_error!),
                  CeButton(label: 'Login', loading: _submitting, onPressed: _submit),
                  CeSwitchLine(
                    prompt: "Don't have an account?",
                    action: 'Sign Up',
                    onTap: () => context.go(Routes.signup),
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
