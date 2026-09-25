import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../../matches/club_matches_controller.dart';
import '../booking_controller.dart';

/// Everything a booking screen needs about one match, resolved by id.
class BookingContext {
  const BookingContext({required this.match, required this.opponent, required this.booking, this.ground});
  final ClubMatch match;
  final ClubSummary opponent;
  final Booking? booking;
  final Ground? ground;
}

/// `null` while loading or when the match / opponent no longer exists.
final bookingContextProvider = Provider.family<BookingContext?, String>((ref, matchId) {
  final match = ref.watch(clubMatchProvider(matchId));
  final opponent = match == null ? null : ref.watch(clubDirectoryProvider).value?[match.opponentClubId];
  if (match == null || opponent == null) return null;
  final booking = ref.watch(bookingProvider(matchId));
  final groundId = booking?.draft.groundId ?? booking?.hold?.groundId ?? match.groundId;
  final ground = groundId == null ? null : ref.watch(groundDirectoryProvider).value?[groundId];
  return BookingContext(match: match, opponent: opponent, booking: booking, ground: ground);
});

/// Loading / not-found wrapper shared by every booking step.
class BookingScaffold extends ConsumerWidget {
  const BookingScaffold({
    super.key,
    required this.matchId,
    required this.title,
    required this.builder,
    this.showBack = true,
    this.fallbackLocation,
    this.onBack,
    this.actions = const [],
  });

  final String matchId;
  final String title;
  final bool showBack;
  final String? fallbackLocation;

  /// Explicit Back target (overrides pop / [fallbackLocation]).
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Widget Function(BuildContext context, BookingContext ctx) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(clubMatchesProvider).isLoading ||
        ref.watch(clubDirectoryProvider).isLoading ||
        ref.watch(groundDirectoryProvider).isLoading;
    final ctx = ref.watch(bookingContextProvider(matchId));
    final bar = CeTopBar(
      title: title,
      showBack: showBack,
      fallbackLocation: fallbackLocation ?? Routes.matchManagement(),
      onBack: onBack,
      actions: actions,
    );
    if (loading) return Scaffold(appBar: bar, body: const Center(child: CircularProgressIndicator()));
    if (ctx == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'calendar',
          title: 'Match not found',
          body: 'This match is no longer available.',
          primaryLabel: 'Back to Upcoming Matches',
          onPrimary: () => context.go(Routes.matchManagement()),
        ),
      );
    }
    return Scaffold(appBar: bar, body: builder(context, ctx));
  }
}

/// `wfProgress(step, 7)`: the 7-step booking progress dots.
class WorkflowProgress extends StatelessWidget {
  const WorkflowProgress({super.key, required this.step, this.total = 7});
  final int step;
  final int total;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Step $step of $total',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: Row(children: [
            for (var i = 1; i <= total; i++) ...[
              if (i > 1) const SizedBox(width: 5),
              Expanded(
                child: AnimatedContainer(
                  duration: CeMotion.base,
                  height: 5,
                  decoration: BoxDecoration(
                    color: i < step ? CeColors.primary : (i == step ? CeColors.primaryDark : CeColors.line),
                    borderRadius: BorderRadius.circular(CeRadius.pill),
                  ),
                ),
              ),
            ],
          ]),
        ),
      );
}

/// `.cp-card` header: a badge or ground thumb, a title and a meta line.
class BookingHeaderCard extends StatelessWidget {
  const BookingHeaderCard({super.key, required this.leading, required this.title, required this.meta});
  final Widget leading;
  final String title;
  final String meta;

  @override
  Widget build(BuildContext context) => CeCard(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        child: Row(children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: CeColors.ink)),
              const SizedBox(height: 2),
              Text(meta, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
            ]),
          ),
        ]),
      );
}

/// Green ground thumbnail (`.ground-thumb`).
class GroundThumb extends StatelessWidget {
  const GroundThumb({super.key, this.size = 46});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [CeColors.primary600, CeColors.fresh]),
          borderRadius: BorderRadius.circular(CeRadius.md),
        ),
        child: Icon(CeIcons.of('flag'), size: size * 0.42, color: Colors.white),
      );
}

/// "mm:ss" left on the hold — always `expiresAt − now` from app state
/// (`holdRemainingProvider`), never a screen-local timer.
class HoldCountdownText extends ConsumerWidget {
  const HoldCountdownText({super.key, required this.matchId, this.style});
  final String matchId;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(holdRemainingProvider(matchId));
    return Text(CeFormat.mmss(remaining ?? Duration.zero),
        style: (style ?? const TextStyle()).copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

/// `.split-row`: your share vs the opponent's share.
class PaymentSplitRow extends StatelessWidget {
  const PaymentSplitRow({super.key, required this.booking, required this.opponentName, this.margin});
  final Booking? booking;
  final String opponentName;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final myPaid = b?.myShareSettled ?? false;
    final oppPaid = b?.opponentPayment?.status == PaymentStatus.paid;
    Widget cell({required bool paid, required String value, required String label}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: paid ? CeColors.mint : Colors.white,
              borderRadius: BorderRadius.circular(CeRadius.md),
              border: Border.all(color: paid ? CeColors.mint2 : CeColors.line),
            ),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (paid) ...[Icon(CeIcons.of('check'), size: 13, color: CeColors.primaryDark), const SizedBox(width: 4)],
                if (!paid && value == 'Pending') ...[
                  Icon(CeIcons.of('hourglass'), size: 13, color: CeColors.amberInk),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(paid ? 'Paid' : value,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: paid ? CeColors.primaryDark : CeColors.ink)),
                ),
              ]),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: CeColors.muted)),
            ]),
          ),
        );
    return Padding(
      padding: margin ?? const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
      child: Row(children: [
        cell(paid: myPaid, value: CeFormat.rupees(b?.shareAmount ?? 0), label: 'You'),
        const SizedBox(width: 10),
        cell(paid: oppPaid, value: 'Pending', label: opponentName),
      ]),
    );
  }
}

/// Screens for a live booking follow the app-wide expiry: when the hold
/// expires (on any tick, wherever the user is), a paid booking goes to
/// Reservation Expired; an unpaid one returns to Match Management (P13 —
/// the root messenger explains why).
class BookingExpiryGuard extends ConsumerWidget {
  const BookingExpiryGuard({super.key, required this.matchId, required this.child});
  final String matchId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<BookingStatus?>(bookingProvider(matchId).select((b) => b?.status), (prev, next) {
      if (next != BookingStatus.expired || prev == BookingStatus.expired) return;
      final paid = ref.read(bookingProvider(matchId))?.myShareSettled ?? false;
      context.go(paid ? Routes.reservationExpired(matchId) : Routes.matchManagement(MatchTab.waiting));
    });
    return child;
  }
}

/// Booking details rows (Summary / Confirmed).
List<(String, Widget)> bookingDetailRows(BuildContext context, BookingContext c, {bool withOpponent = true}) {
  final d = c.booking?.draft;
  final date = d?.date ?? c.match.startsAt;
  final slot = d?.slot;
  return [
    if (withOpponent) ('Opponent', CeSummaryCard.value(context, c.opponent.name)),
    ('Format', CeSummaryCard.value(context, (d?.format ?? c.match.format)?.display(d?.customOvers ?? c.match.customOvers) ?? '—')),
    ('Ground', CeSummaryCard.value(context, c.ground?.name ?? '—')),
    ('City', CeSummaryCard.value(context, d?.city ?? c.match.city ?? '—')),
    ('Date', CeSummaryCard.value(context, date == null ? '—' : CeFormat.dayDate(date))),
    ('Time Slot', CeSummaryCard.value(context, slot?.label ?? (c.match.startsAt == null ? '—' : CeFormat.time(c.match.startsAt!)))),
  ];
}

/// Opponent badge used across the booking flow.
Widget opponentBadge(ClubSummary c, {double size = 46}) => CeTeamBadge(c.abbr, color: c.color, size: size);
