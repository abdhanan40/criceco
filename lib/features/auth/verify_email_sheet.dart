import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/account_error_text.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/demo_widgets.dart';

/// How long "Resend code" waits after a code was sent — the backend's
/// minimum interval between two sign-up emails (and the demo's).
const kSignUpCodeResendCooldown = Duration(seconds: 60);

/// How the sign-up code sheet ended (`null`: closed without one of these).
enum VerifyEmailOutcome {
  /// The code was accepted: the session is in onboarding.
  verified,

  /// "Change email": the caller lets the user edit the address.
  changeEmail,

  /// The code was accepted but the account couldn't be read: the email is
  /// confirmed, nothing is signed in — the caller goes to Login.
  confirmedPleaseLogIn,
}

/// AUTH-02D: "Verify your email" — the 6-digit sign-up code for [email]
/// (shown masked). Verify signs in through
/// [SessionController.verifySignUpCode]; "Resend code" uses
/// [SessionController.resendSignUpCode] after a [kSignUpCodeResendCooldown]
/// counted from [sentAt]. [sendCode]: send a fresh code first (Login, an
/// account not verified yet). [demoCode]: the demo's code (nothing is sent
/// there); [onCodeSent] reports every code sent from the sheet, so a reopened
/// sheet continues with the newest one.
Future<VerifyEmailOutcome?> showVerifyEmailSheet(
  BuildContext context, {
  required String email,
  DateTime? sentAt,
  String? demoCode,
  bool sendCode = false,
  void Function(SignUpCodeTicket ticket, DateTime at)? onCodeSent,
}) => showCeSheet<VerifyEmailOutcome>(
  context,
  builder: (_) => _VerifyEmailSheet(
    email: email,
    sentAt: sentAt,
    demoCode: demoCode,
    sendCode: sendCode,
    onCodeSent: onCodeSent,
  ),
);

class _VerifyEmailSheet extends ConsumerStatefulWidget {
  const _VerifyEmailSheet({
    required this.email,
    required this.sentAt,
    required this.demoCode,
    required this.sendCode,
    required this.onCodeSent,
  });

  final String email;
  final DateTime? sentAt;
  final String? demoCode;
  final bool sendCode;
  final void Function(SignUpCodeTicket ticket, DateTime at)? onCodeSent;

  @override
  ConsumerState<_VerifyEmailSheet> createState() => _VerifyEmailSheetState();
}

class _VerifyEmailSheetState extends ConsumerState<_VerifyEmailSheet> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  late String? _demoCode = widget.demoCode;
  String? _error;
  String? _note;
  bool _busy = false;

  /// The code was accepted but the account couldn't be read.
  bool _confirmedNeedsLogin = false;

  int _secondsLeft = 0;
  Timer? _countdown;

  SessionController get _session => ref.read(sessionProvider.notifier);
  DateTime get _now => ref.read(clockProvider).now();

  @override
  void initState() {
    super.initState();
    if (widget.sendCode) {
      // Not from inside build: the request updates this sheet's state.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resend(first: true);
      });
    } else {
      final sentAt = widget.sentAt ?? _now;
      final left = kSignUpCodeResendCooldown - _now.difference(sentAt);
      _startCountdown(
        left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil(),
      );
    }
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCountdown([int seconds = 60]) {
    _countdown?.cancel();
    _secondsLeft = seconds;
    if (seconds <= 0) return;
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) t.cancel();
    });
  }

  static String? _validateCode(String? v) =>
      RegExp(r'^\d{6}$').hasMatch(v?.trim() ?? '')
      ? null
      : 'Enter the 6-digit code';

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

  Future<void> _verify() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _run(() async {
      try {
        await _session.verifySignUpCode(
          email: widget.email,
          code: _code.text.trim(),
        );
      } on EmailConfirmedSignInRequiredException {
        if (mounted) setState(() => _confirmedNeedsLogin = true);
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _note = null;
          _error = accountErrorText(
            e,
            fallback: "Couldn't check the code — please try again",
          );
        });
        return;
      }
      if (mounted) Navigator.of(context).pop(VerifyEmailOutcome.verified);
    });
  }

  /// "Resend code" — and, with [first], the code sent when the sheet opens
  /// from Login.
  Future<void> _resend({bool first = false}) async {
    if (_busy || _secondsLeft > 0) return;
    await _run(() async {
      try {
        final ticket = await _session.resendSignUpCode(widget.email);
        final at = _now;
        widget.onCodeSent?.call(ticket, at);
        if (!mounted) return;
        _code.clear();
        setState(() {
          _demoCode = ticket.demoCode ?? (first ? _demoCode : null);
          _note = first
              ? null
              : 'A new code was sent to ${ticket.destination}.';
          _startCountdown();
        });
      } on TooManyRequestsException catch (e) {
        if (!mounted) return;
        setState(() {
          // Opening from Login right after a code went out: not an error.
          if (first) {
            _note = 'A code was sent recently — check your email.';
          } else {
            _error = e.message;
          }
          _startCountdown();
        });
      } catch (e) {
        if (!mounted) return;
        setState(
          () => _error = accountErrorText(
            e,
            fallback: "Couldn't send a new code — please try again",
          ),
        );
      }
    });
  }

  String get _resendLabel {
    if (_secondsLeft <= 0) return 'Resend code';
    final s = _secondsLeft;
    return 'Resend code in ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final masked = SignUpCodeTicket.maskEmail(widget.email);
    return Form(
      key: _formKey,
      child: Column(
        key: const Key('verify.sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: CeColors.mint,
                  borderRadius: BorderRadius.circular(CeRadius.sm),
                ),
                child: Icon(
                  CeIcons.of('mail'),
                  size: 18,
                  color: CeColors.primaryDark,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Verify your email',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_confirmedNeedsLogin) ...[
            const CeSuccessPanel(
              key: Key('verify.confirmed'),
              icon: 'check',
              title: 'Email confirmed',
              body: Text(
                'Your email is confirmed, but we couldn’t sign you in just now. '
                'Please log in with your email and password.',
              ),
            ),
            CeButton(
              key: const Key('verify.goToLogin'),
              label: 'Go to Login',
              onPressed: () =>
                  Navigator.of(context)
                      .pop(VerifyEmailOutcome.confirmedPleaseLogIn),
            ),
          ] else ...[
            // Neutral wording: never says whether the address already has an account.
            Text(
              'If this email can be used for a new account, we’ve sent a 6-digit code to $masked. '
              'It’s valid for 15 minutes — check your spam folder if you can’t find it.',
              key: const Key('verify.destination'),
              style: const TextStyle(
                fontSize: 13,
                color: CeColors.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            CeTextField(
              fieldKey: const Key('verify.code'),
              controller: _code,
              hint: '6-digit code',
              icon: 'hash',
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              validator: _validateCode,
              onFieldSubmitted: (_) => _verify(),
            ),
            CeInlineError(_error),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  _note!,
                  key: const Key('verify.note'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: CeColors.primaryDark,
                  ),
                ),
              ),
            // No email service in the demo: it shows the code.
            if (_demoCode != null)
              DemoPanel(
                margin: const EdgeInsets.only(top: 4, bottom: 8),
                note:
                    'No email is sent in this build. Your code is $_demoCode.',
                actions: [
                  DemoAction(
                    'Use code',
                    () => setState(() => _code.text = _demoCode!),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            CeButton(
              key: const Key('verify.submit'),
              label: 'Verify Email',
              loading: _busy,
              onPressed: _busy ? null : _verify,
            ),
            const SizedBox(height: 4),
            // Wraps on narrow phones instead of overflowing.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              children: [
                TextButton(
                  key: const Key('verify.changeEmail'),
                  onPressed: _busy
                      ? null
                      : () =>
                            Navigator.of(context)
                                .pop(VerifyEmailOutcome.changeEmail),
                  child: const Text('Change email'),
                ),
                TextButton(
                  key: const Key('verify.resend'),
                  onPressed: _busy || _secondsLeft > 0 ? null : () => _resend(),
                  child: Text(_resendLabel),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
