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
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../requests/join_requests_controller.dart';
import 'join_requests_screen.dart' show JoinRequestsScreen, joinRequestToast;

/// Join Request → Player Profile (prototype `screens.joinRequestProfile`,
/// :5290). Keyed by request id (the prototype used an array index).
class JoinRequestProfileScreen extends ConsumerStatefulWidget {
  const JoinRequestProfileScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<JoinRequestProfileScreen> createState() => _JoinRequestProfileScreenState();
}

class _JoinRequestProfileScreenState extends ConsumerState<JoinRequestProfileScreen> {
  MemberRole _role = MemberRole.player; // prototype default
  bool _busy = false;

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.joinRequests);
    }
  }

  Future<void> _decide({required bool approve}) async {
    setState(() => _busy = true);
    final ctrl = ref.read(joinRequestsProvider.notifier);
    final decided = approve ? await ctrl.approve(widget.requestId, role: _role) : await ctrl.decline(widget.requestId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (decided == null) return;
    showCeToast(context, joinRequestToast(decided));
    _back(); // prototype: back() to Requests
  }

  @override
  Widget build(BuildContext context) {
    final loading = ref.watch(joinRequestsProvider).isLoading;
    final r = ref.watch(joinRequestProvider(widget.requestId));
    final bar = CeTopBar(title: 'Player Profile', onBack: _back);

    if (loading) return Scaffold(appBar: bar, body: const Center(child: CircularProgressIndicator()));
    if (r == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'search',
          title: 'Request not found',
          body: 'This join request is no longer available.',
          primaryLabel: 'Back to Requests',
          onPrimary: () => context.go(Routes.joinRequests),
        ),
      );
    }

    final perf = r.performance;
    return Scaffold(
      appBar: bar,
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        // ---- Identity ----
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
          child: Column(children: [
            CeAvatar(r.name, size: 72, background: CeColors.primary, foreground: Colors.white),
            const SizedBox(height: 10),
            Text(r.name,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('${r.role.label} · ${r.city}',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: CeColors.muted)),
            if (!r.isPending) ...[
              const SizedBox(height: 8),
              r.review == JoinRequestReview.approved
                  ? const CeStatusChip('Approved', icon: 'check')
                  : const CeStatusChip('Declined', tone: CeTone.red, icon: 'x'),
            ],
          ]),
        ),

        // ---- Details ----
        const SizedBox(height: 16),
        CeSummaryCard(rows: [
          ('Age', CeSummaryCard.value(context, '${r.age}')),
          ('City', CeSummaryCard.value(context, r.city)),
          ('Batting Style', CeSummaryCard.value(context, r.battingStyle.label)),
          ('Bowling Style', CeSummaryCard.value(context, r.bowlingStyle.label)),
          ('Playing Role', CeSummaryCard.value(context, r.role.label)),
          ('Phone Number', CeSummaryCard.value(context, r.phone)),
        ]),

        // ---- Performance ----
        const CeSectionHeader('Performance'),
        if (perf != null)
          CeStatsRow(children: [
            CeStatCard(value: '${perf.matches}', label: 'Matches'),
            CeStatCard(value: '${perf.runs}', label: 'Runs'),
            CeStatCard(value: '${perf.wickets}', label: 'Wickets'),
            CeStatCard(value: perf.average, label: 'Batting Avg'),
          ])
        else
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: CeSpace.gutter),
            child: Text('No performance data available yet.', style: TextStyle(fontSize: 12.5, color: CeColors.muted)),
          ),

        // ---- Review ----
        if (r.isPending)
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.form, 20, CeSpace.form, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const CeFieldLabel('Role Assignment'),
              CeSelectField<MemberRole>(
                fieldKey: const Key('joinRequest.role'),
                items: assignableMemberRoles,
                value: _role,
                labelOf: (m) => m.label,
                onChanged: (m) => setState(() => _role = m),
                sheetTitle: 'Role Assignment',
                icon: 'tag',
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Coach and Manager are club roles. They do not give club-owner access.',
                  style: TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.35),
                ),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: CeButton.danger(label: 'Reject', onPressed: _busy ? null : () => _decide(approve: false)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: CeButton(label: 'Approve', loading: _busy, onPressed: _busy ? null : () => _decide(approve: true)),
                ),
              ]),
            ]),
          )
        else
          _Outcome(request: r),
      ]),
    );
  }
}

/// Reviewed request: what was decided, plus the way to the updated list.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.request});
  final JoinRequest request;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final approved = r.review == JoinRequestReview.approved;
    final date = r.decidedAt == null ? '' : ' on ${CeFormat.date(r.decidedAt!)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: approved ? CeColors.mint : CeColors.redSoft,
            borderRadius: BorderRadius.circular(CeRadius.row),
            border: Border.all(color: approved ? CeColors.mint2 : CeColors.redBorder),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(CeIcons.of(approved ? 'check-circle' : 'x-circle'),
                size: 18, color: approved ? CeColors.primaryDark : CeColors.red),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                approved
                    ? 'Approved as ${r.assignedRole?.label ?? 'Player'}$date. ${r.name} is now a club member.'
                    : 'Request declined$date.',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    color: approved ? CeColors.primaryDark : CeColors.red),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        if (approved)
          CeButton.soft(label: 'View Members', icon: CeIcons.of('users'), onPressed: () => context.go(Routes.members))
        else
          CeButton.soft(
            label: 'Back to Requests',
            onPressed: () => context.go(JoinRequestsScreen.location(JoinRequestReview.declined)),
          ),
      ]),
    );
  }
}
