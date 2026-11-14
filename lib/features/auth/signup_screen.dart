import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config/auth_features.dart';
import '../../app/router/routes.dart';
import '../../app/session/account_error_text.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import 'widgets/auth_widgets.dart';

/// Sign Up landing (prototype `screens.signup`, :2919): Create New Account or
/// Continue with Google (memory mode only — [AuthFeatures.googleSignIn]).
/// System Back returns to Login (sibling tab).
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  bool _googleLoading = false;

  Future<void> _google() async {
    if (_googleLoading) return;
    setState(() => _googleLoading = true);
    // Google → Complete Profile (prototype skips Create Account). Pushed so
    // Back returns to Sign Up.
    try {
      await ref.read(sessionProvider.notifier).signInWithGoogle();
    } catch (e) {
      if (!mounted) return;
      setState(() => _googleLoading = false);
      showCeToast(context, accountErrorText(e, fallback: "Couldn't sign in with Google — please try again"));
      return;
    }
    if (!mounted) return;
    setState(() => _googleLoading = false);
    unawaited(context.push(Routes.completeProfile));
  }

  @override
  Widget build(BuildContext context) {
    // Google sign-in isn't configured on the Supabase backend.
    final google = ref.watch(authFeaturesProvider).googleSignIn;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(Routes.login);
      },
      child: Scaffold(
        backgroundColor: CeColors.bg,
        body: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const AuthBanner(title: 'Criceco', subtitle: 'Your cricket club, organized.', stadiumPhoto: true),
            AuthPanel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AuthTabs(active: AuthTab.signUp, onSelected: (_) => context.go(Routes.login)),
                const SizedBox(height: 18),
                const AuthHeading(
                  title: 'Create account',
                  subtitle: 'Join thousands of cricket clubs across Pakistan',
                ),
                const SizedBox(height: 22),
                CeButton(label: 'Create New Account', onPressed: () => context.go(Routes.createAccount)),
                if (google) ...[
                  const AuthDivider(),
                  GoogleButton(onPressed: _google, loading: _googleLoading),
                ],
                CeSwitchLine(
                  prompt: 'Already have an account?',
                  action: 'Login',
                  onTap: () => context.go(Routes.login),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
