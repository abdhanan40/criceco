import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_surfaces.dart';
import '../../shared/widgets/ce_top_bar.dart';
import '../../shared/widgets/demo_widgets.dart';
import 'join_club_controller.dart';

String _exitLocation(WidgetRef ref) {
  final role = ref.read(activeRoleProvider);
  return role == null ? Routes.continueAs : Routes.home(role);
}

/// Waiting for Approval (prototype `screens.waitingApproval`, :3190).
class WaitingApprovalScreen extends ConsumerWidget {
  const WaitingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(joinClubProvider);
    if (request == null) {
      return Scaffold(
        appBar: CeTopBar(title: 'Join Request', onBack: () => context.go(Routes.chooseOption)),
        body: CeEmptyState(
          icon: 'search',
          title: 'No join request',
          body: 'There is no pending join request. Enter a club code to send one.',
          primaryLabel: 'Enter Club Code',
          onPrimary: () => context.go(Routes.enterClubCode),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(_exitLocation(ref));
      },
      child: Scaffold(
        appBar: const CeTopBar(title: 'Join Request', showBack: false),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Container(
            margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.xl)),
            child: Column(children: [
              const _PulseBadge(),
              const SizedBox(height: 14),
              const Text('Waiting for Approval', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Your request to join '),
                    TextSpan(text: request.clubName, style: const TextStyle(fontWeight: FontWeight.w700, color: CeColors.ink)),
                    const TextSpan(text: " is with the club owner. We'll notify you the moment it's reviewed."),
                  ]),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: CeColors.muted, height: 1.5),
                ),
              ),
            ]),
          ),
          const _Checklist(),
          const SizedBox(height: 16),
          CeSummaryCard(rows: [
            ('Club', CeSummaryCard.value(context, request.clubName)),
            ('Club Code', CeSummaryCard.value(context, request.clubCode)),
            ('Status', CeSummaryCard.value(context, 'Pending', color: CeColors.amber)),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.form, 20, CeSpace.form, 0),
            child: Column(children: [
              CeButton.danger(
                label: 'Cancel Request',
                onPressed: () {
                  ref.read(joinClubProvider.notifier).cancel();
                  showCeToast(context, 'Join request cancelled');
                  context.go(Routes.chooseOption);
                },
              ),
              const SizedBox(height: 10),
              CeButton.soft(label: 'Back to Home', onPressed: () => context.go(_exitLocation(ref))),
            ]),
          ),
          DemoPanel(
            note: 'Club owner response',
            actions: [
              for (final r in const [MemberRole.player, MemberRole.coach, MemberRole.manager])
                DemoAction('As ${r.label}', () async {
                  await ref.read(joinClubProvider.notifier).approve(r);
                  if (context.mounted) context.go(Routes.joinApproved);
                }),
            ],
          ),
        ]),
      ),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist();

  @override
  Widget build(BuildContext context) {
    Widget item(Widget dot, String text, {Color color = CeColors.muted, bool last = false}) => Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: last ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: CeColors.mint2))),
          child: Row(children: [
            SizedBox(width: 20, height: 20, child: dot),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color))),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.lg)),
      child: Column(children: [
        item(
          Container(
            decoration: const BoxDecoration(color: CeColors.primaryDark, shape: BoxShape.circle),
            child: Icon(CeIcons.of('check'), size: 11, color: Colors.white),
          ),
          'Join request sent',
          color: CeColors.ink,
        ),
        item(
          const CircularProgressIndicator(strokeWidth: 2, color: CeColors.primaryDark, backgroundColor: CeColors.mint2),
          'Under review by club owner',
          color: CeColors.primaryDark,
        ),
        item(
          Container(
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: const Text('3', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: CeColors.muted)),
          ),
          'Approved & added to club',
          last: true,
        ),
      ]),
    );
  }
}

/// Amber hourglass badge with two expanding pulse rings (`.oc-pulse-ring`).
class _PulseBadge extends StatefulWidget {
  const _PulseBadge();

  @override
  State<_PulseBadge> createState() => _PulseBadgeState();
}

class _PulseBadgeState extends State<_PulseBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget ring(double offset) => AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = (_c.value + offset) % 1;
            return Transform.scale(
              scale: 1 + 0.6 * t,
              child: Opacity(
                opacity: 0.7 * (1 - t),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: CeColors.primaryDark, width: 3),
                  ),
                ),
              ),
            );
          },
        );
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(fit: StackFit.expand, children: [
        ring(0),
        ring(0.33),
        Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Color(0xFFD9962A), CeColors.amber]),
            boxShadow: [BoxShadow(color: Color(0x401B4332), blurRadius: 14, offset: Offset(0, 4))],
          ),
          child: Icon(CeIcons.of('hourglass'), color: Colors.white, size: 26),
        ),
      ]),
    );
  }
}

/// Join Approved (prototype `screens.joinApproved`, :3233). Membership only:
/// every role continues to the Player dashboard (approved fix C, default P3).
class JoinApprovedScreen extends ConsumerWidget {
  const JoinApprovedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(joinClubProvider);
    final role = request?.approvedRole;
    if (request == null || role == null) {
      return Scaffold(
        appBar: CeTopBar(title: 'Join Request', onBack: () => context.go(Routes.chooseOption)),
        body: CeEmptyState(
          icon: 'search',
          title: 'Request not found',
          body: 'This join request is no longer available.',
          primaryLabel: 'Go back',
          onPrimary: () => context.go(Routes.chooseOption),
        ),
      );
    }
    void continueToDashboard() {
      ref.read(joinClubProvider.notifier).enterPlayerContext();
      context.go(Routes.playerHome);
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) continueToDashboard();
      },
      child: Scaffold(
        appBar: const CeTopBar(title: 'Join Request', showBack: false),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          CeSuccessPanel(
            title: "You're In!",
            body: Text.rich(TextSpan(children: [
              const TextSpan(text: 'Your request to join '),
              TextSpan(text: request.clubName, style: const TextStyle(fontWeight: FontWeight.w700, color: CeColors.ink)),
              const TextSpan(text: " was approved. You've been added as a "),
              TextSpan(text: role.label, style: const TextStyle(fontWeight: FontWeight.w700, color: CeColors.ink)),
              const TextSpan(text: '.'),
            ])),
          ),
          CeSummaryCard(rows: [
            ('Club', CeSummaryCard.value(context, request.clubName)),
            ('Role Assigned', CeSummaryCard.value(context, role.label)),
            ('Status', CeSummaryCard.value(context, 'Approved', color: CeColors.primaryDark)),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
            child: CeButton(label: 'Continue to Dashboard', onPressed: continueToDashboard),
          ),
        ]),
      ),
    );
  }
}
