import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/demo_widgets.dart';

/// "Forgot password?" (Login, and Settings → Password & security): one sheet,
/// three steps — phone number or email → 6-digit code → new password.
/// Resolves to the identifier once the password is reset (Login prefills it),
/// or `null` when cancelled. Signed in, [lockIdentifier] keeps the reset on the
/// account's own phone number / email; [minPasswordLength] follows the screen
/// it opens from.
Future<String?> showForgotPasswordSheet(
  BuildContext context, {
  String? initialIdentifier,
  bool lockIdentifier = false,
  int minPasswordLength = CeValidators.passwordMinLength,
}) =>
    showCeSheet<String>(
      context,
      builder: (_) => _ForgotPasswordSheet(
        initialIdentifier: initialIdentifier,
        lockIdentifier: lockIdentifier && (initialIdentifier?.isNotEmpty ?? false),
        minPasswordLength: minPasswordLength,
      ),
    );

enum _Step { request, code, password }

class _ForgotPasswordSheet extends ConsumerStatefulWidget {
  const _ForgotPasswordSheet({this.initialIdentifier, this.lockIdentifier = false, required this.minPasswordLength});
  final String? initialIdentifier;
  final bool lockIdentifier;
  final int minPasswordLength;

  @override
  ConsumerState<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends ConsumerState<_ForgotPasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _identifier = TextEditingController(text: widget.initialIdentifier ?? '');
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  _Step _step = _Step.request;
  PasswordResetTicket? _ticket;
  String? _error;
  String? _note; // "A new code was sent."
  bool _busy = false;

  SessionController get _session => ref.read(sessionProvider.notifier);

  @override
  void dispose() {
    _identifier.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  static String? _validateIdentifier(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your phone number or email';
    return v.contains('@') ? CeValidators.email(v) : CeValidators.pkPhone(v);
  }

  static String? _validateCode(String? v) =>
      RegExp(r'^\d{6}$').hasMatch(v?.trim() ?? '') ? null : 'Enter the 6-digit code';

  static String? _message(ResetCodeCheck c) => switch (c) {
        ResetCodeCheck.ok => null,
        ResetCodeCheck.wrong => 'Incorrect code. Check it and try again.',
        ResetCodeCheck.expired => 'This code has expired. Send a new one.',
        ResetCodeCheck.tooManyAttempts => 'Too many attempts. Send a new code.',
        ResetCodeCheck.noRequest => 'Send a code first.',
      };

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Step 1 (and "Resend code"): send a fresh code.
  Future<void> _sendCode({bool resend = false}) async {
    if (!resend && !(_formKey.currentState?.validate() ?? false)) return;
    await _run(() async {
      final ticket = await _session.requestPasswordReset(_identifier.text);
      if (!mounted) return;
      if (ticket == null) {
        setState(() => _error = 'No account found with this phone number or email.');
        return;
      }
      _code.clear();
      setState(() {
        _ticket = ticket;
        _step = _Step.code;
        _note = resend ? 'A new code was sent to ${ticket.destination}.' : null;
      });
    });
  }

  /// Step 2: check the code before asking for the new password.
  Future<void> _verify() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _run(() async {
      final check = await _session.verifyResetCode(_identifier.text, _code.text);
      if (!mounted) return;
      setState(() {
        _note = null;
        if (check == ResetCodeCheck.ok) {
          _step = _Step.password;
        } else {
          _error = _message(check);
        }
      });
    });
  }

  /// Step 3: set the new password, then back to Login.
  Future<void> _reset() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _run(() async {
      final check = await _session.resetPassword(_identifier.text, _code.text, _password.text);
      if (!mounted) return;
      if (check == ResetCodeCheck.ok) {
        Navigator.of(context).pop(_identifier.text.trim());
        return;
      }
      // The code ran out while choosing a password: start again from the code.
      setState(() {
        _error = _message(check);
        _step = _Step.code;
      });
    });
  }

  void _changeIdentifier() => setState(() {
        _step = _Step.request;
        _ticket = null;
        _error = null;
        _note = null;
      });

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle) = switch (_step) {
      _Step.request => (
          'key',
          'Reset your password',
          "Enter the phone number or email on your account. We'll send you a 6-digit code.",
        ),
      _Step.code => (
          'shield',
          'Enter the code',
          'We sent a 6-digit code to ${_ticket?.destination}. '
              'It expires at ${_ticket == null ? '' : CeFormat.time(_ticket!.expiresAt)}.',
        ),
      _Step.password => ('lock', 'Create a new password', 'Use at least ${widget.minPasswordLength} characters.'),
    };
    return Form(
      key: _formKey,
      child: Column(
        key: Key('reset.step.${_step.name}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
              child: Icon(CeIcons.of(icon), size: 18, color: CeColors.primaryDark),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          ]),
          const SizedBox(height: 8),
          Text(subtitle, style: const TextStyle(fontSize: 13, color: CeColors.muted, height: 1.45)),
          const SizedBox(height: 16),
          ...switch (_step) {
            _Step.request => [
                CeTextField(
                  fieldKey: const Key('reset.identifier'),
                  controller: _identifier,
                  hint: 'Phone number or email',
                  icon: 'user',
                  readOnly: widget.lockIdentifier, // signed in: your own account only
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumber, AutofillHints.email],
                  validator: _validateIdentifier,
                  onFieldSubmitted: (_) => _sendCode(),
                ),
                CeInlineError(_error),
                const SizedBox(height: 8),
                CeButton(label: 'Send Code', loading: _busy, onPressed: _busy ? null : _sendCode),
                const SizedBox(height: 10),
                CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
              ],
            _Step.code => [
                CeTextField(
                  fieldKey: const Key('reset.code'),
                  controller: _code,
                  hint: '6-digit code',
                  icon: 'hash',
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  validator: _validateCode,
                  onFieldSubmitted: (_) => _verify(),
                ),
                CeInlineError(_error),
                if (_note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 4),
                    child: Text(_note!,
                        key: const Key('reset.note'), style: const TextStyle(fontSize: 12, color: CeColors.primaryDark)),
                  ),
                // No SMS / email service in this build: the demo shows the code.
                if (_ticket?.demoCode != null)
                  DemoPanel(
                    margin: const EdgeInsets.only(top: 4, bottom: 8),
                    note: 'No SMS or email is sent in this build. Your code is ${_ticket!.demoCode}.',
                    actions: [DemoAction('Use code', () => setState(() => _code.text = _ticket!.demoCode!))],
                  ),
                const SizedBox(height: 4),
                CeButton(label: 'Verify Code', loading: _busy, onPressed: _busy ? null : _verify),
                const SizedBox(height: 4),
                // Wraps on narrow phones instead of overflowing.
                Wrap(alignment: WrapAlignment.spaceBetween, children: [
                  if (!widget.lockIdentifier)
                    TextButton(onPressed: _busy ? null : _changeIdentifier, child: const Text('Change number or email')),
                  TextButton(
                    onPressed: _busy ? null : () => _sendCode(resend: true),
                    child: const Text('Resend code'),
                  ),
                ]),
              ],
            _Step.password => [
                CeTextField(
                  fieldKey: const Key('reset.password'),
                  controller: _password,
                  hint: 'New password',
                  icon: 'lock',
                  obscure: true,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Password is required';
                    return v.length < widget.minPasswordLength
                        ? 'Password must be at least ${widget.minPasswordLength} characters'
                        : null;
                  },
                ),
                CeTextField(
                  fieldKey: const Key('reset.confirm'),
                  controller: _confirm,
                  hint: 'Re-enter new password',
                  icon: 'lock',
                  obscure: true,
                  textInputAction: TextInputAction.done,
                  validator: (v) => CeValidators.confirmPassword(v, _password.text),
                  onFieldSubmitted: (_) => _reset(),
                ),
                CeInlineError(_error),
                const SizedBox(height: 8),
                CeButton(label: 'Reset Password', loading: _busy, onPressed: _busy ? null : _reset),
              ],
          },
        ],
      ),
    );
  }
}
