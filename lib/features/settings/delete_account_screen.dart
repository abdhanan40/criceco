import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config/account_privacy.dart';
import '../../app/router/routes.dart';
import '../../app/session/account_error_text.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/utils/validators.dart';
import '../../data/repositories/repositories.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';

/// The word typed to confirm (case-sensitive), so a stray tap can't delete.
const kDeleteConfirmWord = 'DELETE';

/// Settings → Delete Account (docs/ACCOUNT_PRIVACY_AND_DELETION.md).
///
/// A club owner is stopped first: the approved policy is to transfer the
/// club's ownership before deleting (the server enforces it as well).
/// Otherwise it says exactly what is deleted, then asks for the account
/// password — checked again on the server — and the word DELETE. Nothing
/// happens until both are right and the button is pressed; only the server's
/// confirmation leads to "deleted"; a failure leaves the account as it was (or,
/// for an incomplete deletion, asks to repeat it). Where this build can't
/// delete accounts it says so instead.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _passwordError; // wrong password, from the server
  String? _error; // anything else
  bool _deleting = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// The server refused: this account owns a club.
  bool _ownsClub = false;

  bool get _ready => _password.text.isNotEmpty && _confirm.text.trim() == kDeleteConfirmWord && !_deleting;

  Future<void> _delete() async {
    if (!_ready) return; // also a second tap while deleting
    FocusScope.of(context).unfocus();
    setState(() {
      _passwordError = null;
      _error = null;
    });
    if (!_formKey.currentState!.validate()) return;
    setState(() => _deleting = true);
    try {
      await ref.read(sessionProvider.notifier).deleteAccount(_password.text);
    } on WrongPasswordException catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _passwordError = e.message;
      });
      _formKey.currentState!.validate();
      return;
    } on ClubOwnershipTransferRequiredException {
      // The server found a club this account owns (e.g. created on another
      // device): show the same "transfer first" state. Nothing was deleted.
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _ownsClub = true;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = accountErrorText(e, fallback: "Couldn't delete your account — please try again.");
      });
      return;
    }
    if (!mounted) return;
    ref.read(roleControllerProvider.notifier).clear();
    showCeToast(context, 'Your account was deleted');
    context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context) {
    final canDelete = ref.watch(accountControlsProvider).canDeleteAccount;
    final club = ref.watch(currentClubProvider);
    const bar = CeTopBar(title: 'Delete Account', fallbackLocation: Routes.settings);

    if (!canDelete) {
      return const Scaffold(
        appBar: bar,
        body: CeEmptyState(
          key: Key('deleteAccount.unavailable'),
          icon: 'trash-2',
          title: 'Not available yet',
          body:
              'Deleting your account isn’t available in this version of the app yet. '
              'Nothing has been changed.',
        ),
      );
    }

    // Approved policy: a club owner must transfer the club to another member
    // first. The club is never deleted with the account (the server enforces
    // this too: the delete-account function and migration 15).
    if (club != null || _ownsClub) {
      final canTransfer = ref.watch(ownershipTransferAvailableProvider);
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          key: const Key('deleteAccount.ownershipRequired'),
          icon: 'shield',
          title: 'Transfer your club first',
          body:
              '${club == null ? 'You own a club' : 'You own “${club.name}”'}. Before you can delete your account, '
              'its ownership has to be transferred to another member — your club, its members and teams are never '
              'deleted with your account. '
              '${canTransfer ? 'Offer it to a member; once they accept, you can delete your account.' : 'Transferring ownership isn’t available in the app yet.'} '
              'Nothing has been changed.',
          primaryLabel: canTransfer ? 'Transfer Ownership' : null,
          onPrimary: canTransfer ? () => context.push(Routes.transferOwnership) : null,
        ),
      );
    }

    final items = <String>[
      'Your profile, personal details and addresses',
      'Your player profile',
      'Your club memberships and join requests (you leave any squads you’re in)',
    ];

    return Scaffold(
      appBar: bar,
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          CeSpace.form,
          CeSpace.form,
          CeSpace.form,
          CeSpace.form + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                key: const Key('deleteAccount.warning'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: CeColors.redSoft,
                  borderRadius: BorderRadius.circular(CeRadius.card),
                  border: Border.all(color: CeColors.redBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(CeIcons.of('trash-2'), size: 18, color: CeColors.red),
                        const SizedBox(width: 8),
                        Expanded(child: Text('This permanently deletes:', style: CeType.listTitle)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text('•  $item', style: CeType.bodySmall.copyWith(color: CeColors.ink)),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      'This can’t be undone, and you won’t be able to sign in with this account again.',
                      style: CeType.bodySmall.copyWith(color: CeColors.red, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const CeFieldLabel('Password', required: true),
              CeTextField(
                fieldKey: const Key('deleteAccount.password'),
                controller: _password,
                hint: 'Your account password',
                icon: 'lock',
                obscure: true,
                inputFormatters: [LengthLimitingTextInputFormatter(CeValidators.passwordMaxLength)],
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.password],
                onChanged: (_) => setState(() => _passwordError = null),
                validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : _passwordError,
              ),
              const CeFieldLabel('Type DELETE to confirm', required: true),
              CeTextField(
                fieldKey: const Key('deleteAccount.confirm'),
                controller: _confirm,
                hint: kDeleteConfirmWord,
                icon: 'info',
                maxLength: kDeleteConfirmWord.length,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                validator: (v) =>
                    (v ?? '').trim() == kDeleteConfirmWord ? null : 'Type $kDeleteConfirmWord in capitals',
              ),
              const SizedBox(height: 8),
              if (_error != null) CeErrorBanner(_error!),
              CeButton.danger(
                key: const Key('deleteAccount.submit'),
                label: _deleting ? 'Deleting…' : 'Delete my account',
                onPressed: _ready ? _delete : null,
              ),
              const SizedBox(height: 8),
              CeButton.soft(
                label: 'Cancel',
                onPressed: _deleting ? null : () => context.canPop() ? context.pop() : context.go(Routes.settings),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
