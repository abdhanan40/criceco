import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/account_error_text.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../data/repositories/repositories.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/demo_widgets.dart';
import 'verify_email_sheet.dart' show kSignUpCodeResendCooldown;

/// How long "Resend code" waits after a reset code was sent — the same as
/// the sign-up code (the backend's minimum interval between two emails).
const kResetCodeResendCooldown = kSignUpCodeResendCooldown;

/// The last reset-code request to an address: when, and its ticket — `null`
/// when the backend refused it as too soon (rate limited: no code is known,
/// so Send Code waits instead of showing the code step).
typedef PasswordResetSend = ({DateTime sentAt, PasswordResetTicket? ticket});

/// Reset codes sent while the app runs, by phone number / email (trimmed,
/// case-insensitive), so a reopened Forgot Password sheet continues the
/// [kResetCodeResendCooldown] instead of sending again (which the backend
/// would refuse).
class PasswordResetCooldowns extends Notifier<Map<String, PasswordResetSend>> {
  @override
  Map<String, PasswordResetSend> build() => const {};

  static String keyOf(String identifier) => identifier.trim().toLowerCase();

  void sent(String identifier, PasswordResetSend send) => state = {...state, keyOf(identifier): send};

  void clear(String identifier) => state = {...state}..remove(keyOf(identifier));

  /// The send to [identifier] still inside the cooldown at [now], if any.
  PasswordResetSend? recent(String identifier, DateTime now) {
    final send = state[keyOf(identifier)];
    if (send == null || now.difference(send.sentAt) >= kResetCodeResendCooldown) return null;
    return send;
  }
}

final passwordResetCooldownsProvider =
    NotifierProvider<PasswordResetCooldowns, Map<String, PasswordResetSend>>(PasswordResetCooldowns.new);

/// "Forgot password?" (Login, and Settings → Password & security): one sheet,
/// three steps — phone number or email → 6-digit code → new password.
/// Resolves to the identifier once the password is reset (Login prefills it),
/// or `null` when cancelled. Signed in, [lockIdentifier] keeps the reset on the
/// account's own phone number / email. The new password follows the shared
/// strong-password rules ([CeValidators.password]).
///
/// AUTH-04, a remote backend ([emailOnly]: email only): the email carries
/// the code and a link, and the backend never says whether the address has
/// an account. An accepted code opens a recovery session: the sheet closes
/// (`null`) and the router shows Reset Password for the new password.
Future<String?> showForgotPasswordSheet(
  BuildContext context, {
  String? initialIdentifier,
  bool lockIdentifier = false,
  bool emailOnly = false,
}) =>
    showCeSheet<String>(
      context,
      builder: (_) => _ForgotPasswordSheet(
        initialIdentifier: initialIdentifier,
        lockIdentifier: lockIdentifier && (initialIdentifier?.isNotEmpty ?? false),
        emailOnly: emailOnly,
      ),
    );

enum _Step { request, code, password }

class _ForgotPasswordSheet extends ConsumerStatefulWidget {
  const _ForgotPasswordSheet({this.initialIdentifier, this.lockIdentifier = false, this.emailOnly = false});
  final String? initialIdentifier;
  final bool lockIdentifier;
  final bool emailOnly;

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

  /// Seconds until a code can be requested again (0: now): "Resend code" on
  /// the code step; "Send Code" on the first step after the backend refused
  /// a request to this address as too soon.
  int _secondsLeft = 0;
  Timer? _countdown;

  SessionController get _session => ref.read(sessionProvider.notifier);
  PasswordResetCooldowns get _cooldowns => ref.read(passwordResetCooldownsProvider.notifier);
  DateTime get _now => ref.read(clockProvider).now();

  @override
  void initState() {
    super.initState();
    _syncSendCooldown(rebuild: false); // a prefilled address may still be waiting
    _identifier.addListener(_syncSendCooldown);
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _identifier.removeListener(_syncSendCooldown);
    _identifier.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? _validateIdentifier(String? v) {
    if (widget.emailOnly) return CeValidators.email(v);
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
        ResetCodeCheck.invalid => 'That code is incorrect or has expired — check it or request a new one.',
      };

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await action();
    } catch (e) {
      // Offline, rate limited, …: the app's own message, never the raw error.
      if (mounted) setState(() => _error = accountErrorText(e, fallback: "Couldn't reach the server — please try again"));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startCountdown([Duration left = kResetCodeResendCooldown]) {
    _countdown?.cancel();
    _secondsLeft = left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
    if (_secondsLeft <= 0) return;
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) t.cancel();
    });
  }

  String _countdownLabel(String label) {
    if (_secondsLeft <= 0) return label;
    final s = _secondsLeft;
    return '$label in ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// First step: "Send Code" waits while the address typed was refused as
  /// too soon ([PasswordResetSend.ticket] `null`) — per address, so another
  /// address can be sent to at once. Runs as the address is typed.
  void _syncSendCooldown({bool rebuild = true}) {
    if (_step != _Step.request) return;
    void apply(VoidCallback change) => rebuild ? setState(change) : change();
    final send = _cooldowns.recent(_identifier.text, _now);
    if (send == null || send.ticket != null) {
      if (_secondsLeft > 0) {
        apply(() {
          _countdown?.cancel();
          _secondsLeft = 0;
        });
      }
      return;
    }
    if (_secondsLeft > 0 && _countdown?.isActive == true && _waitingFor == PasswordResetCooldowns.keyOf(_identifier.text)) {
      return; // already counting down for this address
    }
    apply(() {
      _waitingFor = PasswordResetCooldowns.keyOf(_identifier.text);
      _startCountdown(kResetCodeResendCooldown - _now.difference(send.sentAt));
    });
  }

  /// The address the first step's countdown is for.
  String? _waitingFor;

  /// Step 1 (and "Resend code", after [kResetCodeResendCooldown]): send a
  /// fresh code. A code sent to this address moments ago (the sheet was
  /// closed and reopened) is not sent again: the sheet continues with it.
  /// Every answer is remembered for the address, even when the sheet was
  /// closed while the request was on its way.
  Future<void> _sendCode({bool resend = false}) async {
    if (_busy || _secondsLeft > 0) return;
    if (!resend && !(_formKey.currentState?.validate() ?? false)) return;
    final identifier = _identifier.text;
    final cooldowns = _cooldowns;
    final clock = ref.read(clockProvider);
    final recent = resend ? null : cooldowns.recent(identifier, clock.now());
    if (recent != null) {
      final ticket = recent.ticket;
      if (ticket == null) {
        _syncSendCooldown(); // still refused: wait
        return;
      }
      _code.clear();
      setState(() {
        _error = null;
        _ticket = ticket;
        _step = _Step.code;
        _note = 'A code was sent recently — check your email.';
        _startCountdown(kResetCodeResendCooldown - clock.now().difference(recent.sentAt));
      });
      return;
    }
    final previous = _ticket;
    await _run(() async {
      final PasswordResetTicket? response;
      try {
        response = await _session.requestPasswordReset(identifier);
      } on TooManyRequestsException catch (e) {
        // The backend refused another email so soon: wait out a full
        // cooldown (on Resend, the code already sent still works).
        cooldowns.sent(identifier, (sentAt: clock.now(), ticket: resend ? previous : null));
        if (!mounted) return;
        setState(() {
          _note = null;
          _error = e.message;
          _waitingFor = resend ? null : PasswordResetCooldowns.keyOf(identifier);
          _startCountdown();
        });
        return;
      }
      final ticket = response;
      if (ticket != null) cooldowns.sent(identifier, (sentAt: clock.now(), ticket: ticket));
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
        _startCountdown();
      });
    });
  }

  /// Step 2: check the code before asking for the new password.
  Future<void> _verify() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final identifier = _identifier.text;
    final cooldowns = _cooldowns; // not through ref once the sheet may be closed
    await _run(() async {
      final check = await _session.verifyResetCode(identifier, _code.text);
      // An accepted code is used up: a later reset starts with a new one.
      if (check == ResetCodeCheck.ok) cooldowns.clear(identifier);
      if (!mounted) return;
      // A remote backend opened the recovery session: Reset Password (the
      // router guard) takes the new password.
      if (check == ResetCodeCheck.ok && ref.read(sessionProvider).passwordRecovery) {
        Navigator.of(context).pop();
        return;
      }
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

  /// Back to the first step: the code step's countdown stops; each address
  /// keeps its own cooldown (going back to it continues where it was).
  void _changeIdentifier() {
    setState(() {
      _countdown?.cancel();
      _secondsLeft = 0;
      _waitingFor = null;
      _step = _Step.request;
      _ticket = null;
      _error = null;
      _note = null;
    });
    _syncSendCooldown();
  }

  /// Neutral when the backend doesn't say whether the account exists.
  String _codeSubtitle() {
    final t = _ticket;
    if (t == null) return '';
    final expires = 'It expires at ${CeFormat.time(t.expiresAt)}.';
    return t.accountMayNotExist
        ? 'If an account uses this email, we sent a 6-digit code to ${t.destination}. $expires '
            'You can also open the link in that email on this device.'
        : 'We sent a 6-digit code to ${t.destination}. $expires';
  }

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle) = switch (_step) {
      _Step.request => (
          'key',
          'Reset your password',
          widget.emailOnly
              ? "Enter the email on your account. We'll send you a 6-digit code and a reset link."
              : "Enter the phone number or email on your account. We'll send you a 6-digit code.",
        ),
      _Step.code => (
          'shield',
          'Enter the code',
          _codeSubtitle(),
        ),
      _Step.password => (
          'lock',
          'Create a new password',
          'Use 8+ characters with upper- and lowercase letters, a number and a special character.',
        ),
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
                  hint: widget.emailOnly ? 'you@example.com' : 'Phone number or email',
                  icon: widget.emailOnly ? 'mail' : 'user',
                  readOnly: widget.lockIdentifier, // signed in: your own account only
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autofillHints: widget.emailOnly
                      ? const [AutofillHints.email]
                      : const [AutofillHints.telephoneNumber, AutofillHints.email],
                  validator: _validateIdentifier,
                  onFieldSubmitted: (_) => _sendCode(),
                ),
                CeInlineError(_error),
                const SizedBox(height: 8),
                CeButton(
                  key: const Key('reset.send'),
                  label: _countdownLabel('Send Code'),
                  loading: _busy,
                  onPressed: _busy || _secondsLeft > 0 ? null : _sendCode,
                ),
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
                    TextButton(
                      onPressed: _busy ? null : _changeIdentifier,
                      child: Text(widget.emailOnly ? 'Change email' : 'Change number or email'),
                    ),
                  TextButton(
                    key: const Key('reset.resend'),
                    onPressed: _busy || _secondsLeft > 0 ? null : () => _sendCode(resend: true),
                    child: Text(_countdownLabel('Resend code')),
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
                  validator: CeValidators.password,
                ),
                CePasswordChecklist(controller: _password),
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
                // Off until the new password meets every requirement.
                ListenableBuilder(
                  listenable: _password,
                  builder: (context, _) => CeButton(
                    label: 'Reset Password',
                    loading: _busy,
                    onPressed: _busy || !CeValidators.isStrongPassword(_password.text) ? null : _reset,
                  ),
                ),
              ],
          },
        ],
      ),
    );
  }
}
