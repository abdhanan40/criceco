import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session/account_error_text.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart' show SignUpCodeTicket;
import '../../core/utils/validators.dart';
import '../../data/repositories/repositories.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_inputs.dart';
import 'widgets/auth_widgets.dart';

/// Reset Password (AUTH-04): reached only with a recovery session — the
/// 6-digit code from the Forgot Password sheet, or the link in the same
/// email (the router guard keeps it the only screen until then). New
/// password + confirm, with the shared strong-password rules. Updated → every
/// session of the account ends and Login says "Password updated". Cancel
/// ends the recovery without a change.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    if (_busy) return;
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      // Success or an expired recovery ends it: the router goes to Login,
      // which shows the outcome.
      await ref
          .read(sessionProvider.notifier)
          .completePasswordRecovery(_password.text);
    } on RecoverySessionMissingException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = accountErrorText(
          e,
          fallback: "Couldn't update your password — please try again",
        );
      });
    }
  }

  Future<void> _cancel() async {
    if (_busy) return;
    await ref.read(sessionProvider.notifier).cancelPasswordRecovery();
  }

  @override
  Widget build(BuildContext context) {
    final email = ref.watch(sessionProvider.select((s) => s.recoveryEmail));
    return PopScope(
      // Back leaves only through Cancel, which ends the recovery session.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: CeColors.bg,
        body: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthBanner(
                title: 'Reset password',
                subtitle: 'Choose a new password for your account',
                stadiumPhoto: true,
                showLogo: false,
              ),
              AuthPanel(
                child: Form(
                  key: _formKey,
                  child: AutofillGroup(
                    child: Column(
                      key: const Key('resetPassword.form'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AuthHeading(
                          title: 'Create a new password',
                          subtitle: email == null
                              ? 'Use 8+ characters with upper- and lowercase letters, a number and a special character.'
                              : 'For ${SignUpCodeTicket.maskEmail(email)}. Use 8+ characters with upper- and '
                                    'lowercase letters, a number and a special character.',
                        ),
                        const SizedBox(height: 18),
                        const CeFieldLabel('New password', required: true),
                        CeTextField(
                          fieldKey: const Key('resetPassword.password'),
                          controller: _password,
                          hint: 'e.g. Cricket@123',
                          icon: 'lock',
                          obscure: true,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.newPassword],
                          validator: CeValidators.password,
                        ),
                        CePasswordChecklist(controller: _password),
                        const CeFieldLabel(
                          'Confirm new password',
                          required: true,
                        ),
                        CeTextField(
                          fieldKey: const Key('resetPassword.confirm'),
                          controller: _confirm,
                          hint: 'Re-enter new password',
                          icon: 'lock',
                          obscure: true,
                          textInputAction: TextInputAction.done,
                          validator: (v) =>
                              CeValidators.confirmPassword(v, _password.text),
                          onFieldSubmitted: (_) => _update(),
                        ),
                        if (_error != null) CeErrorBanner(_error!),
                        const SizedBox(height: 4),
                        // Off until the new password meets every requirement.
                        ListenableBuilder(
                          listenable: _password,
                          builder: (context, _) => CeButton(
                            key: const Key('resetPassword.submit'),
                            label: 'Update Password',
                            loading: _busy,
                            onPressed:
                                _busy ||
                                    !CeValidators.isStrongPassword(
                                      _password.text,
                                    )
                                ? null
                                : _update,
                          ),
                        ),
                        const SizedBox(height: 10),
                        CeButton.soft(
                          key: const Key('resetPassword.cancel'),
                          label: 'Cancel',
                          onPressed: _busy ? null : _cancel,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
