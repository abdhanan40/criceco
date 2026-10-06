import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_list_sheet.dart';
import '../../../shared/widgets/ce_segmented.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../requests/join_requests_controller.dart';

/// Toast after a review (prototype `approveJoinRequest` / `declineJoinRequest`).
String joinRequestToast(JoinRequest r) => r.review == JoinRequestReview.approved
    ? '${r.name} added to the club as ${r.assignedRole?.label ?? MemberRole.player.label}'
    : 'Request from ${r.name} declined';

/// Quick, professional reasons offered when declining a request.
const joinDeclineReasons = [
  'Our squad is currently full.',
  'We are not recruiting for this role right now.',
  'Trials are closed for this season.',
];

/// "Approve this request?" — approval only happens after this confirmation.
Future<bool> confirmApproveRequest(BuildContext context, JoinRequest r, {MemberRole role = MemberRole.player}) =>
    showCeConfirmSheet(
      context,
      title: 'Approve this request?',
      body: 'Are you sure you want to approve this player’s request to join the club? '
          '${r.name} will be added as ${role.label}.',
      confirmLabel: 'Approve',
      icon: 'check-circle',
    );

/// "Decline Request?" with a short reason: a suggested reason (preselected)
/// or a custom message. Resolves to the reason (may be empty), or `null`
/// when cancelled — nothing is declined.
Future<String?> showDeclineRequestSheet(BuildContext context, JoinRequest r) =>
    showCeSheet<String>(context, builder: (_) => _DeclineRequestSheet(request: r));

class _DeclineRequestSheet extends StatefulWidget {
  const _DeclineRequestSheet({required this.request});
  final JoinRequest request;

  @override
  State<_DeclineRequestSheet> createState() => _DeclineRequestSheetState();
}

class _DeclineRequestSheetState extends State<_DeclineRequestSheet> {
  late final _reason = TextEditingController(text: joinDeclineReasons.first);

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: CeColors.redSoft, borderRadius: BorderRadius.circular(CeRadius.sm)),
          child: Icon(CeIcons.of('x-circle'), size: 18, color: CeColors.red),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text('Decline Request?', style: Theme.of(context).textTheme.titleLarge)),
      ]),
      const SizedBox(height: 10),
      Text('${r.name} will be told the request was declined. They can apply again with your club code.',
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: CeColors.muted, height: 1.45)),
      const SizedBox(height: 14),
      const CeFieldLabel('Reason'),
      Wrap(spacing: 7, runSpacing: 7, children: [
        for (final s in joinDeclineReasons)
          CeChip(
            label: s,
            selected: _reason.text.trim() == s,
            onTap: () => setState(() => _reason.text = s),
          ),
      ]),
      const SizedBox(height: 10),
      CeTextField(
        fieldKey: const Key('joinRequest.declineReason'),
        controller: _reason,
        hint: 'Short message (optional)',
        icon: 'file-text',
        maxLength: JoinRequest.declineReasonMaxLength,
        maxLines: 2,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 10),
      CeButton.danger(label: 'Decline Request', onPressed: () => Navigator.of(context).pop(_reason.text.trim())),
      const SizedBox(height: 10),
      CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}

/// Requests (prototype `screens.joinRequests`, :5337). Pending / Approved /
/// Declined live in `?tab=` (requests are kept after review, so the owner
/// can see decisions; the prototype deleted them).
class JoinRequestsScreen extends ConsumerStatefulWidget {
  const JoinRequestsScreen({super.key, this.tab = JoinRequestReview.pending});
  final JoinRequestReview tab;

  static JoinRequestReview parseTab(String? raw) =>
      JoinRequestReview.values.where((t) => t.name == raw).firstOrNull ?? JoinRequestReview.pending;

  static String location(JoinRequestReview tab) =>
      tab == JoinRequestReview.pending ? Routes.joinRequests : '${Routes.joinRequests}?tab=${tab.name}';

  @override
  ConsumerState<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends ConsumerState<JoinRequestsScreen> {
  final _busy = <String>{};

  Future<void> _decide(JoinRequest r, {required bool approve}) async {
    if (_busy.contains(r.id)) return;
    // Neither decision is immediate: approving is confirmed, declining asks
    // for a short reason.
    String? reason;
    if (approve) {
      if (!await confirmApproveRequest(context, r) || !mounted) return;
    } else {
      reason = await showDeclineRequestSheet(context, r);
      if (reason == null || !mounted) return;
    }
    setState(() => _busy.add(r.id));
    final ctrl = ref.read(joinRequestsProvider.notifier);
    // Row "Accept" approves as Player, exactly as in the prototype.
    final decided = approve ? await ctrl.approve(r.id) : await ctrl.decline(r.id, reason: reason);
    if (!mounted) return;
    setState(() => _busy.remove(r.id));
    if (decided != null) showCeToast(context, joinRequestToast(decided));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(joinRequestsProvider);
    final tab = widget.tab;
    final list = ref.watch(joinRequestsByReviewProvider(tab));
    final pending = ref.watch(pendingJoinRequestCountProvider);
    int countOf(JoinRequestReview t) => ref.watch(joinRequestsByReviewProvider(t)).length;

    return Scaffold(
      appBar: CeTopBar(
        title: 'Requests',
        fallbackLocation: Routes.clubHome,
        actions: [
          if (pending != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Center(
                child: Semantics(
                  label: '$pending pending requests',
                  excludeSemantics: true,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 26),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.pill)),
                    child: Text('$pending',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        CeSegmentedTabs<JoinRequestReview>(
          values: JoinRequestReview.values,
          selected: tab,
          labelOf: (t) => t.label,
          countOf: countOf,
          onSelected: (t) => context.go(JoinRequestsScreen.location(t)),
        ),
        if (async.isLoading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (list.isEmpty)
          switch (tab) {
            JoinRequestReview.pending => const CeEmptyState(
                icon: 'check-circle', title: 'No pending requests', body: 'All requests have been reviewed'),
            JoinRequestReview.approved => const CeEmptyState(
                icon: 'user-plus', title: 'No approved requests', body: 'Players you approve will show up here.'),
            JoinRequestReview.declined => const CeEmptyState(
                icon: 'x-circle', title: 'No declined requests', body: 'Requests you decline will show up here.'),
          }
        else
          for (final r in list)
            JoinRequestRow(
              request: r,
              busy: _busy.contains(r.id),
              onOpen: () => context.go(Routes.joinRequestProfile(r.id)),
              onAccept: () => _decide(r, approve: true),
              onDecline: () => _decide(r, approve: false),
            ),
      ]),
    );
  }
}

/// Club Dashboard → Requests: Pending / Approved / Declined in a sheet, with
/// the same Accept (confirmed) and Decline (reason) as the Requests screen.
/// A row opens the applicant's profile.
Future<void> showJoinRequestsSheet(BuildContext context) =>
    showCeListSheet<void>(context, builder: (_) => _JoinRequestsSheet(router: GoRouter.of(context)));

class _JoinRequestsSheet extends ConsumerStatefulWidget {
  const _JoinRequestsSheet({required this.router});
  final GoRouter router;

  @override
  ConsumerState<_JoinRequestsSheet> createState() => _JoinRequestsSheetState();
}

class _JoinRequestsSheetState extends ConsumerState<_JoinRequestsSheet> {
  JoinRequestReview _tab = JoinRequestReview.pending;
  final _busy = <String>{};

  Future<void> _decide(JoinRequest r, {required bool approve}) async {
    if (_busy.contains(r.id)) return;
    String? reason;
    if (approve) {
      if (!await confirmApproveRequest(context, r) || !mounted) return;
    } else {
      reason = await showDeclineRequestSheet(context, r);
      if (reason == null || !mounted) return;
    }
    setState(() => _busy.add(r.id));
    final ctrl = ref.read(joinRequestsProvider.notifier);
    final decided = approve ? await ctrl.approve(r.id) : await ctrl.decline(r.id, reason: reason);
    if (!mounted) return;
    setState(() => _busy.remove(r.id));
    if (decided != null) showCeToast(context, joinRequestToast(decided));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(joinRequestsProvider);
    final list = ref.watch(joinRequestsByReviewProvider(_tab));
    final pending = ref.watch(pendingJoinRequestCountProvider);
    int countOf(JoinRequestReview t) => ref.watch(joinRequestsByReviewProvider(t)).length;
    return CeListSheetFrame(
      key: const Key('requests.sheet'),
      title: 'Requests',
      titleTrailing: pending == null ? null : CeCountPill(pending),
      top: [
        CeSegmentedTabs<JoinRequestReview>(
          values: JoinRequestReview.values,
          selected: _tab,
          labelOf: (t) => t.label,
          countOf: countOf,
          onSelected: (t) => setState(() => _tab = t),
        ),
      ],
      children: [
        if (async.isLoading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (list.isEmpty)
          switch (_tab) {
            JoinRequestReview.pending => const CeEmptyState(
                icon: 'check-circle', title: 'No pending requests', body: 'All requests have been reviewed'),
            JoinRequestReview.approved => const CeEmptyState(
                icon: 'user-plus', title: 'No approved requests', body: 'Players you approve will show up here.'),
            JoinRequestReview.declined => const CeEmptyState(
                icon: 'x-circle', title: 'No declined requests', body: 'Requests you decline will show up here.'),
          }
        else
          for (final r in list)
            JoinRequestRow(
              request: r,
              busy: _busy.contains(r.id),
              onOpen: () {
                Navigator.of(context).pop();
                widget.router.go(Routes.joinRequestProfile(r.id));
              },
              onAccept: () => _decide(r, approve: true),
              onDecline: () => _decide(r, approve: false),
            ),
      ],
    );
  }
}

/// `.player-row` for a join request: pending rows get ✕ Decline / ✓ Accept;
/// reviewed rows show the outcome.
class JoinRequestRow extends StatelessWidget {
  const JoinRequestRow({
    super.key,
    required this.request,
    required this.onOpen,
    required this.onAccept,
    required this.onDecline,
    this.busy = false,
  });

  final JoinRequest request;
  final VoidCallback onOpen;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final subtitle = switch (r.review) {
      JoinRequestReview.pending => '${r.role.label} · ${r.appliedLabel}',
      JoinRequestReview.approved =>
        'Approved as ${r.assignedRole?.label ?? 'Player'}${r.decidedAt == null ? '' : ' · ${CeFormat.dayMonth(r.decidedAt!)}'}',
      JoinRequestReview.declined => 'Declined${r.decidedAt == null ? '' : ' · ${CeFormat.dayMonth(r.decidedAt!)}'}',
    };
    return CeCard(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      onTap: onOpen,
      child: Row(children: [
        CeAvatar(r.name, size: 42, background: CeColors.primary, foreground: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(fontSize: 12, color: CeColors.muted, height: 1.3)),
          ]),
        ),
        const SizedBox(width: 8),
        switch (r.review) {
          JoinRequestReview.pending => busy
              ? const SizedBox(
                  width: 84, height: 40, child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  _SquareAction(
                    icon: 'x',
                    tooltip: 'Decline ${r.name}',
                    background: CeColors.redSoft,
                    foreground: CeColors.red,
                    onTap: onDecline,
                  ),
                  const SizedBox(width: 6),
                  _SquareAction(
                    icon: 'check',
                    tooltip: 'Accept ${r.name}',
                    background: CeColors.primary,
                    foreground: Colors.white,
                    onTap: onAccept,
                  ),
                ]),
          JoinRequestReview.approved => CeStatusChip(r.assignedRole?.label ?? 'Player', icon: 'check'),
          JoinRequestReview.declined => const CeStatusChip('Declined', tone: CeTone.red, icon: 'x'),
        },
      ]),
    );
  }
}

/// `.decline-btn` / `.accept-btn`: 40 px square icon buttons.
class _SquareAction extends StatelessWidget {
  const _SquareAction({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(CeRadius.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.sm),
            onTap: onTap,
            child: SizedBox(width: 40, height: 40, child: Icon(CeIcons.of(icon), size: 19, color: foreground)),
          ),
        ),
      );
}
