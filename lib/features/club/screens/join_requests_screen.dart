import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_segmented.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../requests/join_requests_controller.dart';

/// Toast after a review (prototype `approveJoinRequest` / `declineJoinRequest`).
String joinRequestToast(JoinRequest r) => r.review == JoinRequestReview.approved
    ? '${r.name} added to the club as ${r.assignedRole?.label ?? MemberRole.player.label}'
    : 'Request from ${r.name} declined';

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
    // Declining can't be undone: confirm first. Accepting stays one tap.
    if (!approve) {
      final ok = await showCeConfirmSheet(
        context,
        title: 'Decline ${r.name}?',
        body: '${r.name} will be told the request was declined. They can apply again with your club code.',
        confirmLabel: 'Decline Request',
        destructive: true,
        icon: 'x-circle',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy.add(r.id));
    final ctrl = ref.read(joinRequestsProvider.notifier);
    // Row "Accept" approves as Player, exactly as in the prototype.
    final decided = approve ? await ctrl.approve(r.id) : await ctrl.decline(r.id);
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
