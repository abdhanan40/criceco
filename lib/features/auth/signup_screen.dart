import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/session_controller.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import 'widgets/auth_widgets.dart';

/// Sign Up landing (prototype `screens.signup`, :2919): Create New Account or
/// Continue with Google. System Back returns to Login (sibling tab).
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  bool _googleLoading = false;

  Future<void> _google() async {
    setState(() => _googleLoading = true);
    // Google → Complete Profile (prototype skips Create Account). Pushed so
    // Back returns to Sign Up.
    await ref.read(sessionProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    setState(() => _googleLoading = false);
    unawaited(context.push(Routes.completeProfile));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(Routes.login);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SingleChildScrollView(
          child: Column(children: [
            AuthBanner(
              title: 'Criceco',
              subtitle: 'Your cricket club, organized.',
              activeTab: AuthTab.signUp,
              onTabSelected: (_) => context.go(Routes.login),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const AuthHeading(
                  title: 'Create account',
                  subtitle: 'Join thousands of cricket clubs across Pakistan',
                  center: true,
                ),
                const SizedBox(height: 20),
                CeButton(label: 'Create New Account', onPressed: () => context.go(Routes.createAccount)),
                const AuthDivider(),
                GoogleButton(onPressed: _google, loading: _googleLoading),
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
