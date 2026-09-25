import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/config/demo_mode.dart';
import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_expandable.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/demo_widgets.dart';
import '../booking_controller.dart';
import '../booking_demo_actions.dart';
import '../widgets/booking_widgets.dart';

String _when(BookingContext c) {
  final d = c.booking?.draft;
  final date = d?.date ?? c.match.startsAt;
  return [
    if (date != null) CeFormat.dayDate(date),
    if (d?.slot != null) d!.slot!.label,
  ].join(' · ');
}

/// No live reservation for this step (deep link / already handled).
Widget _noReservation(BuildContext context, {String title = 'No active reservation'}) => CeEmptyState(
      icon: 'calendar',
      title: title,
      body: 'Open the match from Upcoming Matches to continue.',
      primaryLabel: 'Back to Upcoming Matches',
      onPrimary: () => context.go(Routes.matchManagement(MatchTab.waiting)),
    );

/// Redirect after the current frame (never navigate during build).
void _redirect(BuildContext context, String location) =>
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) context.go(location);
    });

// ---------------------------------------------------------------------------
// 6 · Pay Your Share (prototype `screens.payment`, :6522)
// ---------------------------------------------------------------------------

enum _PayStage { choose, processing, success, failed }

class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  PaymentMethodType _method = PaymentMethodType.easypaisa; // prototype default
  _PayStage _stage = _PayStage.choose;

  Future<void> _pay() async {
    setState(() => _stage = _PayStage.processing);
    final outcome = await ref.read(bookingsProvider.notifier).pay(widget.matchId, _method);
    if (!mounted) return;
    switch (outcome) {
      case PaymentOutcome.success:
        setState(() => _stage = _PayStage.success);
        // Prototype: show "Payment Successful!" briefly, then continue.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) context.go(Routes.waitingForOpponent(widget.matchId));
      case PaymentOutcome.failed:
        setState(() => _stage = _PayStage.failed);
      case PaymentOutcome.insufficientFunds:
        setState(() => _stage = _PayStage.choose);
        showCeToast(context, 'Insufficient wallet balance — choose another method');
      case PaymentOutcome.holdExpired:
        // The expiry guard / root messenger handle the navigation and notice.
        setState(() => _stage = _PayStage.choose);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _PayStage.processing || _stage == _PayStage.success;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !busy) context.go(Routes.matchManagement(MatchTab.waiting));
      },
      child: BookingExpiryGuard(
        matchId: widget.matchId,
        child: BookingScaffold(
          matchId: widget.matchId,
          title: switch (_stage) {
            _PayStage.processing => 'Processing Payment',
            _PayStage.success || _PayStage.failed => 'Payment Status',
            _PayStage.choose => 'Pay Your Share',
          },
          showBack: _stage == _PayStage.choose || _stage == _PayStage.failed,
          // Back keeps the hold: the match stays reserved in Match Management.
          fallbackLocation: Routes.matchManagement(MatchTab.waiting),
          builder: (context, c) {
            final b = c.booking;
            if (b == null || b.hold == null) return _noReservation(context);
            if (b.myShareSettled && _stage == _PayStage.choose) {
              _redirect(context, Routes.waitingForOpponent(widget.matchId));
              return const Center(child: CircularProgressIndicator());
            }
            if (b.hold!.status != HoldStatus.active && _stage == _PayStage.choose) {
              return _noReservation(context, title: 'Reservation expired');
            }
            return switch (_stage) {
              _PayStage.processing => _Processing(
                  title: 'Processing via ${_method.label}…',
                  sub: 'Simulated payment — please wait a moment.',
                ),
              _PayStage.success => ListView(children: [
                  const WorkflowProgress(step: 6),
                  CeSuccessPanel(
                    title: 'Payment Successful!',
                    body: Text(
                      '${CeFormat.rupees(b.shareAmount)} paid via ${_method.label} into your CricEco Wallet escrow. Redirecting…',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ]),
              _PayStage.failed => ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                  const WorkflowProgress(step: 6),
                  CeSuccessPanel(
                    danger: true,
                    icon: 'x',
                    title: 'Payment Failed',
                    body: Text(
                      "Your ${_method.label} payment didn't go through. No money was taken, and your "
                      'ground is still held until the reservation timer runs out.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  _HoldLine(matchId: widget.matchId),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
                    child: Column(children: [
                      CeButton(label: 'Try Again', icon: CeIcons.of('repeat'), onPressed: _pay),
                      const SizedBox(height: 10),
                      CeButton.soft(
                        label: 'Choose Another Method',
                        onPressed: () => setState(() => _stage = _PayStage.choose),
                      ),
                    ]),
                  ),
                ]),
              _PayStage.choose => _chooseMethod(context, c, b),
            };
          },
        ),
      ),
    );
  }

  Widget _chooseMethod(BuildContext context, BookingContext c, Booking b) {
    final balance = ref.read(walletRepositoryProvider).clubWalletBalance;
    final demo = ref.watch(demoModeProvider);
    final failArmed = ref.watch(paymentFailureArmedProvider);
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      const WorkflowProgress(step: 6),
      BookingHeaderCard(leading: const GroundThumb(), title: c.ground?.name ?? 'Ground', meta: _when(c)),
      _HoldLine(matchId: widget.matchId),
      const SizedBox(height: 10),
      CeSummaryCard(
        rows: [('Total Ground Cost', CeSummaryCard.value(context, CeFormat.rupees(b.groundCost)))],
        total: ('Your Share (50%)', CeSummaryCard.value(context, CeFormat.rupees(b.shareAmount), color: CeColors.primaryDark)),
      ),
      // Everything that was agreed, one tap away (no Back through the flow).
      CeExpandableCard(
        title: 'Booking details',
        icon: 'clipboard-list',
        summary: c.opponent.name,
        child: CeSummaryCard(margin: EdgeInsets.zero, rows: bookingDetailRows(context, c)),
      ),
      const CeSectionHeader('Payment Method'),
      for (final m in PaymentMethodType.values)
        _MethodCard(
          method: m,
          selected: _method == m,
          subtitle: m == PaymentMethodType.wallet
              ? 'Balance: ${CeFormat.rupees(balance)}${balance < b.shareAmount ? ' · Insufficient' : ''}'
              : m.subtitle,
          disabled: m == PaymentMethodType.wallet && balance < b.shareAmount,
          onTap: () {
            if (m == PaymentMethodType.wallet && balance < b.shareAmount) {
              showCeToast(context, 'Insufficient wallet balance');
              return;
            }
            setState(() => _method = m);
          },
        ),
      // §11: the "payments are simulated" note is a Demo Mode thing only.
      if (demo)
        const CeInfoNote(
          margin: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          icon: 'flask-conical',
          text: 'This is a Final Year Project — payments are simulated. In production this screen plugs straight '
              'into JazzCash, EasyPaisa, Stripe, or PayFast without any workflow changes.',
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
        child: CeButton(
          label: 'Pay ${CeFormat.rupees(b.shareAmount)} via ${_method.label}',
          trailingIcon: CeIcons.of('arrow-right'),
          onPressed: _pay,
        ),
      ),
      DemoOnly(
        child: DemoPanel(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
          note: failArmed ? 'The next payment will fail.' : 'Payment gateway response',
          actions: [
            DemoAction(failArmed ? 'Cancel failure simulation' : 'Simulate a failed payment',
                () => ref.read(bookingDemoActionsProvider).armPaymentFailure(!failArmed)),
          ],
        ),
      ),
    ]);
  }
}

class _HoldLine extends StatelessWidget {
  const _HoldLine({required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(CeIcons.of('timer'), size: 13, color: CeColors.amberInk),
          const SizedBox(width: 5),
          const Text('Ground held for ', style: TextStyle(fontSize: 12, color: CeColors.amberInk)),
          HoldCountdownText(
            matchId: matchId,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: CeColors.amberInk),
          ),
        ]),
      );
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({
    required this.method,
    required this.selected,
    required this.subtitle,
    required this.disabled,
    required this.onTap,
  });
  final PaymentMethodType method;
  final bool selected;
  final String subtitle;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (method) {
      PaymentMethodType.wallet => 'wallet',
      PaymentMethodType.easypaisa || PaymentMethodType.jazzcash => 'smartphone',
      PaymentMethodType.card => 'credit-card',
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 8),
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: Semantics(
          button: true,
          selected: selected,
          enabled: !disabled,
          label: '${method.label}, $subtitle',
          excludeSemantics: true,
          child: Material(
            color: selected ? CeColors.mint : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CeRadius.row),
              side: BorderSide(color: selected ? CeColors.primary : CeColors.line, width: selected ? 1.6 : 1),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(CeRadius.row),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  CeIconWell(icon, size: 38, iconSize: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(method.label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                      Text(subtitle, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                    ]),
                  ),
                  Icon(CeIcons.of(selected ? 'check-circle' : 'circle'),
                      size: 20, color: selected ? CeColors.primary : CeColors.muted2),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Processing extends StatelessWidget {
  const _Processing({required this.title, required this.sub});
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) => ListView(children: [
        const WorkflowProgress(step: 6),
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 60, 30, 0),
          child: Column(children: [
            const SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 18),
            Text(title,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(sub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
          ]),
        ),
      ]);
}

// ---------------------------------------------------------------------------
// 7 · Waiting for Opponent (prototype `screens.waitingForOpponent`, :6589).
// Terminal: system Back → Match Management (Waiting). The countdown is
// `expiresAt − now` from app state; expiry is handled by the app-wide watcher.
// ---------------------------------------------------------------------------

class WaitingForOpponentScreen extends ConsumerWidget {
  const WaitingForOpponentScreen({super.key, required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<BookingStatus?>(bookingProvider(matchId).select((b) => b?.status), (prev, next) {
      // The opponent's payment arrived (demo action today, backend event later).
      if (next == BookingStatus.confirmed && prev != BookingStatus.confirmed) {
        context.go(Routes.bookingConfirmed(matchId));
      }
    });
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(Routes.matchManagement(MatchTab.waiting));
      },
      child: BookingExpiryGuard(
        matchId: matchId,
        child: BookingScaffold(
          matchId: matchId,
          title: 'Waiting for Opponent',
          showBack: false,
          builder: (context, c) {
            final b = c.booking;
            if (b == null || b.hold == null) return _noReservation(context);
            if (b.status == BookingStatus.confirmed) {
              _redirect(context, Routes.bookingConfirmed(matchId));
              return const Center(child: CircularProgressIndicator());
            }
            if (!b.myShareSettled) {
              _redirect(context, Routes.payment(matchId));
              return const Center(child: CircularProgressIndicator());
            }
            final name = c.opponent.name;
            return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              const WorkflowProgress(step: 7),
              Padding(
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 22, CeSpace.gutter, 0),
                child: Column(children: [
                  _PulseBadge(child: opponentBadge(c.opponent, size: 62)),
                  const SizedBox(height: 14),
                  Text('Waiting for $name to pay',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(
                    'Your ground is reserved and your share is paid. The booking auto-confirms the moment '
                    '$name pays their 50%.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, color: CeColors.muted, height: 1.4),
                  ),
                ]),
              ),
              Container(
                margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [CeColors.countdownTop, CeColors.countdownBottom],
                  ),
                  borderRadius: BorderRadius.circular(CeRadius.lg),
                  border: Border.all(color: CeColors.countdownBorder),
                ),
                child: Column(children: [
                  const Text('Reservation expires in',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.countdownInk)),
                  const SizedBox(height: 4),
                  HoldCountdownText(
                    matchId: matchId,
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: CeColors.countdownInk),
                  ),
                  const SizedBox(height: 4),
                  const Text('If time runs out before they pay, the slot is released automatically.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: CeColors.countdownInk)),
                ]),
              ),
              PaymentSplitRow(booking: b, opponentName: name),
              CeExpandableCard(
                title: 'Booking details',
                icon: 'clipboard-list',
                summary: CeFormat.rupees(b.groundCost),
                child: CeSummaryCard(
                  margin: EdgeInsets.zero,
                  rows: [
                    ...bookingDetailRows(context, c, withOpponent: false),
                    ('Total Ground Cost', CeSummaryCard.value(context, CeFormat.rupees(b.groundCost))),
                    ('Your Share (50%)', CeSummaryCard.value(context, CeFormat.rupees(b.shareAmount))),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
                child: Column(children: [
                  const _CheckItem(done: true, label: 'Ground reserved'),
                  const _CheckItem(done: true, label: 'Your payment received'),
                  _CheckItem(done: false, label: "Awaiting $name's payment"),
                ]),
              ),
              DemoOnly(
                child: DemoPanel(
                  margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
                  note: "Opponent's side",
                  actions: [
                    DemoAction('Opponent Pays Now', () => context.go(Routes.opponentPayment(matchId))),
                    DemoAction('Force reservation to expire now',
                        () => ref.read(bookingsProvider.notifier).forceExpire(matchId)),
                  ],
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _PulseBadge extends StatefulWidget {
  const _PulseBadge({required this.child});
  final Widget child;

  @override
  State<_PulseBadge> createState() => _PulseBadgeState();
}

class _PulseBadgeState extends State<_PulseBadge> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 96,
        height: 96,
        child: Stack(alignment: Alignment.center, children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, _) => Container(
              width: 62 + 34 * _c.value,
              height: 62 + 34 * _c.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: CeColors.amber.withValues(alpha: 0.25 * (1 - _c.value)),
              ),
            ),
          ),
          widget.child,
        ]),
      );
}

class _CheckItem extends StatelessWidget {
  const _CheckItem({required this.done, required this.label});
  final bool done;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? CeColors.primary : CeColors.amberSoft,
              border: done ? null : Border.all(color: CeColors.amber),
            ),
            child: done
                ? Icon(CeIcons.of('check'), size: 13, color: Colors.white)
                : const Padding(padding: EdgeInsets.all(5), child: CircularProgressIndicator(strokeWidth: 1.6)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: done ? CeColors.ink : CeColors.amberInk)),
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Opponent Payment (prototype `screens.opponentPayment`, :6626) — Demo only.
// ---------------------------------------------------------------------------

class OpponentPaymentScreen extends ConsumerStatefulWidget {
  const OpponentPaymentScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<OpponentPaymentScreen> createState() => _OpponentPaymentScreenState();
}

class _OpponentPaymentScreenState extends ConsumerState<OpponentPaymentScreen> {
  bool _started = false;
  bool _paid = false;

  Future<void> _run() async {
    _started = true;
    final ok = await ref.read(bookingDemoActionsProvider).opponentPays(widget.matchId);
    if (!mounted) return;
    if (!ok) {
      context.go(Routes.waitingForOpponent(widget.matchId));
      return;
    }
    setState(() => _paid = true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) context.go(Routes.bookingConfirmed(widget.matchId));
  }

  @override
  Widget build(BuildContext context) {
    final demo = ref.watch(demoModeProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_started) context.go(Routes.waitingForOpponent(widget.matchId));
      },
      child: BookingScaffold(
        matchId: widget.matchId,
        title: 'Opponent Payment',
        showBack: false,
        builder: (context, c) {
          if (!demo) {
            // Demo OFF: the opponent's payment only arrives from their side.
            return _noReservation(context, title: "Waiting for the opponent's payment");
          }
          final b = c.booking;
          if (b == null || (b.status != BookingStatus.awaitingOpponent && !_paid)) {
            if (b?.status == BookingStatus.confirmed) {
              _redirect(context, Routes.bookingConfirmed(widget.matchId));
              return const Center(child: CircularProgressIndicator());
            }
            return _noReservation(context);
          }
          if (!_started) WidgetsBinding.instance.addPostFrameCallback((_) => _run());
          if (_paid) {
            return ListView(children: [
              CeSuccessPanel(
                title: '${c.opponent.name} Paid Their Share!',
                body: Text('${CeFormat.rupees(b.shareAmount)} received. Finalizing your booking…',
                    textAlign: TextAlign.center),
              ),
            ]);
          }
          return _Processing(
            title: "Processing ${c.opponent.name}'s payment…",
            sub: 'Processing the opponent share.',
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Booking Confirmed (prototype `screens.bookingConfirmed`, :6654). Terminal:
// Back → Scheduled (never back into the payment flow — no Back loop).
// ---------------------------------------------------------------------------

class BookingConfirmedScreen extends ConsumerWidget {
  const BookingConfirmedScreen({super.key, required this.matchId});
  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduled = Routes.matchManagement(MatchTab.scheduled);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(scheduled);
      },
      child: BookingScaffold(
        matchId: matchId,
        title: 'Booking Confirmed',
        showBack: false,
        builder: (context, c) {
          final b = c.booking;
          final confirmed = c.match.status == MatchStatus.confirmed || b?.status == BookingStatus.confirmed;
          if (!confirmed) return _noReservation(context, title: 'Booking not confirmed yet');
          final settlement = b?.settlement;
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            CeSuccessPanel(
              icon: 'flag',
              title: 'Booking Confirmed!',
              body: Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Both clubs have paid. Your match vs '),
                  TextSpan(text: c.opponent.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const TextSpan(text: ' is locked in.'),
                ]),
                textAlign: TextAlign.center,
              ),
            ),
            CeSummaryCard(rows: [
              ('Ground', CeSummaryCard.value(context, c.ground?.name ?? '—')),
              ('Date', CeSummaryCard.value(context, c.match.startsAt == null ? '—' : CeFormat.dayDate(c.match.startsAt!))),
              ('Time', CeSummaryCard.value(context, b?.draft.slot?.label ?? (c.match.startsAt == null ? '—' : CeFormat.time(c.match.startsAt!)))),
              ('Format', CeSummaryCard.value(context, c.match.format?.display(c.match.customOvers) ?? '—')),
            ]),
            if (b != null && settlement != null) ...[
              const CeSectionHeader('Settlement (CricEco Wallet)'),
              CeSummaryCard(
                rows: [
                  ('Total Ground Cost', CeSummaryCard.value(context, CeFormat.rupees(b.groundCost))),
                  (
                    'CricEco Commission (${(Settlement.commissionRate * 100).round()}%)',
                    CeSummaryCard.value(context, CeFormat.rupees(settlement.commission)),
                  ),
                ],
                total: (
                  'Paid to Ground Owner',
                  CeSummaryCard.value(context, CeFormat.rupees(settlement.toGround), color: CeColors.primaryDark),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
              child: Column(children: [
                CeButton(
                  label: 'Select Your Playing XI',
                  icon: CeIcons.of('circle-dot'),
                  onPressed: () => context.go(Routes.matchLineup(matchId)),
                ),
                const SizedBox(height: 10),
                CeButton.soft(
                  label: 'View in Upcoming Matches',
                  trailingIcon: CeIcons.of('arrow-right'),
                  onPressed: () => context.go(scheduled),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reservation Expired (prototype `screens.reservationExpired`, :6682).
// Terminal: Back → Waiting. Only reached when you had already paid.
// ---------------------------------------------------------------------------

class ReservationExpiredScreen extends ConsumerStatefulWidget {
  const ReservationExpiredScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<ReservationExpiredScreen> createState() => _ReservationExpiredScreenState();
}

class _ReservationExpiredScreenState extends ConsumerState<ReservationExpiredScreen> {
  bool _busy = false;

  Future<void> _resolve(Booking b, ReservationResolution r) async {
    final amount = b.myPayment?.amount ?? b.shareAmount;
    // Money moves once and can't be undone: confirm the destination first.
    final ok = await showCeConfirmSheet(
      context,
      title: r == ReservationResolution.wallet ? 'Move to CricEco Wallet?' : 'Refund to original method?',
      body: r == ReservationResolution.wallet
          ? '${CeFormat.rupees(amount)} will be added to your CricEco Wallet and can be used for your next booking.'
          : '${CeFormat.rupees(amount)} will be sent back to the payment method you used.',
      confirmLabel: r == ReservationResolution.wallet ? 'Move ${CeFormat.rupees(amount)}' : 'Refund ${CeFormat.rupees(amount)}',
      icon: r == ReservationResolution.wallet ? 'wallet' : 'corner-up-left',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await ref.read(bookingsProvider.notifier).resolveExpired(widget.matchId, r);
    if (!mounted) return;
    showCeToast(
      context,
      r == ReservationResolution.wallet
          ? '${CeFormat.rupees(amount)} added to your CricEco Wallet'
          : '${CeFormat.rupees(amount)} refunded to your original payment method',
    );
    context.go(Routes.matchManagement(MatchTab.waiting));
  }

  @override
  Widget build(BuildContext context) {
    final waiting = Routes.matchManagement(MatchTab.waiting);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) context.go(waiting);
      },
      child: BookingScaffold(
        matchId: widget.matchId,
        title: 'Reservation Expired',
        showBack: false,
        builder: (context, c) {
          final b = c.booking;
          if (b == null || b.status != BookingStatus.expired) {
            return _noReservation(context, title: 'Nothing to resolve');
          }
          final d = b.draft;
          final amount = b.myPayment?.amount ?? 0;
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            CeSuccessPanel(
              danger: true,
              icon: 'timer',
              title: 'Reservation Expired',
              body: Text(
                "${c.opponent.name} didn't complete their payment within 30 minutes, so "
                '${c.ground?.name ?? 'the ground'} at ${d.slot?.label ?? 'your slot'} on '
                '${d.date == null ? 'that day' : CeFormat.dayDate(d.date!)} has been released back to other clubs.',
                textAlign: TextAlign.center,
              ),
            ),
            CeSummaryCard(rows: [('Amount You Paid', CeSummaryCard.value(context, CeFormat.rupees(amount)))]),
            const CeSectionHeader('What Would You Like to Do?'),
            _RefundOption(
              icon: 'corner-up-left',
              title: 'Refund to Original Method',
              body: 'Sent back to the payment method you used',
              onTap: _busy ? null : () => _resolve(b, ReservationResolution.refund),
            ),
            _RefundOption(
              icon: 'wallet',
              title: 'Move to CricEco Wallet',
              body: 'Use it instantly for your next ground booking',
              onTap: _busy ? null : () => _resolve(b, ReservationResolution.wallet),
            ),
          ]);
        },
      ),
    );
  }
}

class _RefundOption extends StatelessWidget {
  const _RefundOption({required this.icon, required this.title, required this.body, required this.onTap});
  final String icon;
  final String title;
  final String body;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CeCard(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 10),
        onTap: onTap,
        child: Row(children: [
          CeIconWell(icon, size: 42, iconSize: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(body, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
            ]),
          ),
          Icon(CeIcons.of('chevron-right'), size: 18, color: CeColors.muted),
        ]),
      );
}
