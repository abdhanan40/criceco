import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/config/account_privacy.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/account_error_text.dart';
import '../../../app/session/role_controller.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../club_providers.dart';
import 'ownership_controller.dart';

/// My Club → Transfer ownership (Club Owner). Offer the club to a member —
/// it changes owner only when that member accepts — see the open offer
/// (cancel it), and the club's ownership history. Once an offer was accepted
/// the former owner continues as a member.
class TransferOwnershipScreen extends ConsumerStatefulWidget {
  const TransferOwnershipScreen({super.key});

  @override
  ConsumerState<TransferOwnershipScreen> createState() => _TransferOwnershipScreenState();
}

class _TransferOwnershipScreenState extends ConsumerState<TransferOwnershipScreen> {
  String? _memberId;
  MemberRole _formerRole = MemberRole.manager;
  bool _busy = false;

  Future<void> _send(ClubMember member) async {
    final club = ref.read(currentClubProvider);
    final ok = await showCeConfirmSheet(
      context,
      title: 'Offer ${club?.name ?? 'your club'} to ${member.name}?',
      body:
          'Nothing changes until ${member.name} accepts. Then they become the owner and you stay in the club as '
          '${_formerRole.label}. Members, teams and squads stay as they are. You can cancel the offer until they answer; '
          'it expires after 7 days.',
      confirmLabel: 'Send Offer',
      icon: 'shield',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(ownershipActionsProvider.notifier).offer(member: member, formerOwnerRole: _formerRole);
      if (!mounted) return;
      showCeToast(context, 'Offer sent to ${member.name}');
      setState(() => _memberId = null);
    } catch (e) {
      if (mounted) showCeToast(context, accountErrorText(e, fallback: "Couldn't send the offer — please try again"));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(OwnershipTransfer offer) async {
    final ok = await showCeConfirmSheet(
      context,
      title: 'Cancel the offer to ${offer.toName}?',
      body: 'They won’t be able to accept it any more. You stay the owner.',
      confirmLabel: 'Cancel Offer',
      destructive: true,
      icon: 'x-circle',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(ownershipActionsProvider.notifier).cancel(offer.id);
      if (mounted) showCeToast(context, 'Offer cancelled');
    } catch (e) {
      if (mounted) showCeToast(context, accountErrorText(e, fallback: "Couldn't cancel the offer — please try again"));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The offer was accepted: continue as a player (the role first, so the
  /// router leaves the owner screens for the Player home), then re-read the
  /// session — the Club Owner profile is gone.
  Future<void> _continueAsMember() async {
    setState(() => _busy = true);
    final router = GoRouter.of(context);
    final actions = ref.read(ownershipActionsProvider.notifier);
    final nav = ref.read(roleControllerProvider.notifier).continueAs(UserRole.player);
    router.go(switch (nav) {
      GoToLocation(:final location) => location,
      NeedsClubSetup() => Routes.roleSelection,
    });
    try {
      await actions.leaveTransferredClub();
    } catch (_) {
      // Offline: the next start reads the account again.
    }
  }

  @override
  Widget build(BuildContext context) {
    const bar = CeTopBar(title: 'Transfer Ownership', fallbackLocation: Routes.myClub);
    if (!ref.watch(ownershipTransferAvailableProvider)) {
      return const Scaffold(
        appBar: bar,
        body: CeEmptyState(
          key: Key('ownership.unavailable'),
          icon: 'shield',
          title: 'Not available yet',
          body: 'Transferring club ownership isn’t available in this version of the app yet.',
        ),
      );
    }
    final club = ref.watch(currentClubProvider);
    final transfersAsync = ref.watch(clubOwnershipTransfersProvider);
    final membersAsync = ref.watch(clubMembersProvider);

    // The newest offer was this user's and has been accepted: the club has
    // moved (this session still shows it until it is re-read). Decided from
    // the history alone — the member list is the new owner's now.
    final latest = transfersAsync.value?.firstOrNull;
    final moved = latest != null && latest.fromMe && latest.status == OwnershipTransferStatus.accepted;

    Widget body;
    if (club == null) {
      body = const CeEmptyState(icon: 'shield', title: 'No club', body: 'You don’t own a club.');
    } else if (moved) {
      body = ListView(
        children: [_MovedCard(transfer: latest, busy: _busy, onContinue: _continueAsMember)],
      );
    } else if (transfersAsync.isLoading || membersAsync.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (transfersAsync.hasError || membersAsync.hasError) {
      body = CeErrorState(
        title: 'Couldn’t load ownership details',
        onRetry: () {
          ref.invalidate(clubOwnershipTransfersProvider);
          ref.invalidate(clubMembersProvider);
        },
      );
    } else {
      final transfers = transfersAsync.value!;
      final pending = transfers.where((t) => t.isPending).firstOrNull;
      final candidates = ownershipCandidates(membersAsync.value!);
      body = ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          if (pending != null)
            _PendingCard(offer: pending, busy: _busy, onCancel: () => _cancel(pending))
          else ...[
            const CeInfoNote(
              margin: EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
              icon: 'shield',
              text:
                  'Choose a member to offer your club to. Ownership changes only when they accept. '
                  'Members, teams and squads stay as they are.',
            ),
            const CeSectionHeader('New owner'),
            if (candidates.isEmpty)
              const CeEmptyState(
                key: Key('ownership.noCandidates'),
                icon: 'users',
                title: 'No members yet',
                body: 'Only a member of your club can become its owner. Approve join requests first.',
              )
            else
              for (final m in candidates)
                _CandidateRow(
                  member: m,
                  selected: m.id == _memberId,
                  onTap: _busy ? null : () => setState(() => _memberId = m.id),
                ),
            if (candidates.isNotEmpty) ...[
              const CeSectionHeader('Your role afterwards'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final r in ownershipFormerOwnerRoles)
                      CeChip(
                        key: Key('ownership.role.${r.name}'),
                        label: r.label,
                        selected: r == _formerRole,
                        onTap: _busy ? null : () => setState(() => _formerRole = r),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
                child: CeButton(
                  key: const Key('ownership.send'),
                  label: 'Send Offer',
                  loading: _busy,
                  onPressed: _busy || _memberId == null
                      ? null
                      : () => _send(candidates.firstWhere((m) => m.id == _memberId)),
                ),
              ),
            ],
          ],
          if (transfers.isNotEmpty) ...[
            const CeSectionHeader('History'),
            for (final t in transfers) _HistoryRow(transfer: t),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: bar,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(clubOwnershipTransfersProvider);
          await ref.read(clubOwnershipTransfersProvider.future).catchError((Object _) => const <OwnershipTransfer>[]);
        },
        child: body,
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({required this.member, required this.selected, required this.onTap});
  final ClubMember member;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '${member.name}, ${member.role.label}',
    excludeSemantics: true,
    child: Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
      child: Material(
        color: selected ? CeColors.mint : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.row),
          side: BorderSide(color: selected ? CeColors.sage : CeColors.line),
        ),
        child: InkWell(
          key: Key('ownership.member.${member.id}'),
          borderRadius: BorderRadius.circular(CeRadius.row),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CeAvatar(member.name, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(member.name, style: CeType.listTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(member.role.label, style: CeType.bodySmall),
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: selected ? CeColors.primary : CeColors.muted2,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.offer, required this.busy, required this.onCancel});
  final OwnershipTransfer offer;
  final bool busy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => CeCard(
    key: const Key('ownership.pending'),
    margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Offer to ${offer.toName}', style: CeType.listTitle)),
            const CeStatusChip('Pending', tone: CeTone.amber),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Waiting for ${offer.toName} to accept. You become ${offer.previousOwnerRole.label} when they do. '
          'Expires ${CeFormat.date(offer.expiresAt)}.',
          style: CeType.bodySmall,
        ),
        const SizedBox(height: 12),
        CeButton.soft(
          key: const Key('ownership.cancel'),
          label: busy ? 'Please wait…' : 'Cancel Offer',
          onPressed: busy ? null : onCancel,
        ),
      ],
    ),
  );
}

class _MovedCard extends StatelessWidget {
  const _MovedCard({required this.transfer, required this.busy, required this.onContinue});
  final OwnershipTransfer transfer;
  final bool busy;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => CeCard(
    key: const Key('ownership.moved'),
    margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${transfer.toName} is now the owner', style: CeType.listTitle),
        const SizedBox(height: 8),
        Text(
          'They accepted your offer for ${transfer.clubName}. You’re a ${transfer.previousOwnerRole.label} of the '
          'club now, so the owner screens are no longer yours.',
          style: CeType.bodySmall,
        ),
        const SizedBox(height: 12),
        CeButton(
          key: const Key('ownership.continue'),
          label: 'Continue',
          loading: busy,
          onPressed: busy ? null : onContinue,
        ),
      ],
    ),
  );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.transfer});
  final OwnershipTransfer transfer;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final tone = switch (t.status) {
      OwnershipTransferStatus.accepted => CeTone.green,
      OwnershipTransferStatus.pending => CeTone.amber,
      OwnershipTransferStatus.rejected || OwnershipTransferStatus.cancelled => CeTone.neutral,
      OwnershipTransferStatus.expired => CeTone.neutral,
    };
    return Container(
      key: Key('ownership.history.${t.id}'),
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.row),
        border: Border.all(color: CeColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${t.fromName.isEmpty ? 'A former member' : t.fromName} → ${t.toName.isEmpty ? 'a former member' : t.toName}',
                  style: CeType.listTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(CeFormat.date(t.decidedAt ?? t.createdAt), style: CeType.bodySmall),
              ],
            ),
          ),
          CeStatusChip(t.status.label, tone: tone),
        ],
      ),
    );
  }
}
