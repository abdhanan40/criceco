import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/session_controller.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_inputs.dart';
import 'widgets/auth_widgets.dart';

/// Login (prototype `screens.login`, criceco-app.js :2898).
/// Phone + password, as in the prototype. After a successful sign-in the
/// router guard takes the user to Continue As (or the remembered role home).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    final ok = await ref.read(sessionProvider.notifier).signIn(
          identifier: CeValidators.normalizePkPhone(_phone.text) ?? _phone.text.trim(),
          password: _password.text,
        );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!ok) _error = 'Incorrect phone number or password. Please try again.';
    });
    // On success the router redirect moves to Continue As / role home.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(children: [
          AuthBanner(
            title: 'Criceco',
            subtitle: 'Your cricket club, organized.',
            activeTab: AuthTab.login,
            onTabSelected: (_) => context.go(Routes.signup),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const AuthHeading(title: 'Welcome back', subtitle: 'Login to manage your cricket club'),
                  const SizedBox(height: 20),
                  CeTextField(
                    fieldKey: const Key('login.phone'),
                    controller: _phone,
                    hint: 'Phone number',
                    icon: 'phone',
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    validator: CeValidators.pkPhone,
                  ),
                  CeTextField(
                    fieldKey: const Key('login.password'),
                    controller: _password,
                    hint: 'Password',
                    icon: 'lock',
                    obscure: true,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    validator: (v) => (v == null || v.isEmpty) ? 'Password is required' : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
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
