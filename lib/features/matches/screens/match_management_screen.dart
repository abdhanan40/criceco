import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../booking/booking_controller.dart';
import '../../booking/widgets/booking_widgets.dart';
import '../../club/club_providers.dart';
import '../club_matches_controller.dart';

/// Match Management / Upcoming Matches (prototype `screens.upcomingMatches`,
/// :6863). Tabs Waiting / Scheduled / History live in `?tab=`. Accepted
/// challenges hand off here (Waiting).
class MatchManagementScreen extends ConsumerWidget {
  const MatchManagementScreen({super.key, this.tab = MatchTab.waiting});
  final MatchTab tab;

  static MatchTab parseTab(String? raw) =>
      MatchTab.values.where((t) => t.name == raw).firstOrNull ?? MatchTab.waiting;

  /// Where a card goes (prototype `openMatchSetup`): pending → setup,
  /// reserved → payment or payment status, expired (paid) → refund choice.
  static void open(BuildContext context, WidgetRef ref, ClubMatch m) {
    final booking = ref.read(bookingProvider(m.id));
    switch (m.status) {
      case MatchStatus.confirmed || MatchStatus.completed:
        showCeToast(context, 'This match is already scheduled');
      case MatchStatus.reserved:
        if (booking?.status == BookingStatus.expired && booking!.myShareSettled) {
          context.go(Routes.reservationExpired(m.id));
        } else if (booking?.myShareSettled ?? false) {
          context.go(Routes.waitingForOpponent(m.id));
        } else {
          context.go(Routes.payment(m.id));
        }
      case MatchStatus.pending:
        ref.read(bookingsProvider.notifier).start(m);
        context.go(Routes.matchSetup(m.id));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(clubMatchesProvider);
    final all = async.value ?? const <ClubMatch>[];
    final dir = ref.watch(clubDirectoryProvider).value ?? const <String, ClubSummary>{};
    int count(MatchTab t) => all.where((m) => t.includes(m.status)).length;
    final list = all.where((m) => tab.includes(m.status)).toList()
      ..sort((a, b) {
        final x = a.startsAt, y = b.startsAt;
        if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
        return tab == MatchTab.history ? y.compareTo(x) : x.compareTo(y);
      });

    return Scaffold(
      appBar: CeTopBar(title: 'Upcoming Matches', onBack: () => context.go(Routes.clubHome)),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        CeChipRow<MatchTab>(
          values: MatchTab.values,
          selected: tab,
          labelOf: (t) => count(t) == 0 ? t.label : '${t.label} (${count(t)})',
          onSelected: (t) => context.go(Routes.matchManagement(t)),
        ),
        if (async.isLoading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (list.isEmpty)
          CeEmptyState(
            icon: 'calendar',
            title: 'No ${tab.label.toLowerCase()} matches',
            body: switch (tab) {
              MatchTab.waiting => 'Accept a challenge or finish paying to see it here',
              MatchTab.scheduled => 'Complete a booking and payment to see it here',
              MatchTab.history => "Matches you've played will show up here",
            },
          )
        else
          for (final m in list)
            if (dir[m.opponentClubId] case final opp?)
              switch (tab) {
                MatchTab.waiting => _WaitingCard(match: m, opponent: opp),
                MatchTab.scheduled => _ScheduledCard(match: m, opponent: opp),
                MatchTab.history => _HistoryCard(match: m, opponent: opp),
              },
      ]),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.lg),
            side: const BorderSide(color: CeColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(14), child: child)),
        ),
      );
}

class _CardTop extends StatelessWidget {
  const _CardTop({required this.opponent, required this.meta, required this.chip});
  final ClubSummary opponent;
  final String meta;
  final Widget chip;

  @override
  Widget build(BuildContext context) => Row(children: [
        opponentBadge(opponent, size: 40),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('vs ${opponent.name}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
            const SizedBox(height: 1),
            Text(meta, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        chip,
      ]);
}

class _Cta extends StatelessWidget {
  const _Cta({required this.icon, required this.label, this.color = CeColors.primaryDark});
  final String icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(children: [
          Icon(CeIcons.of(icon), size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color))),
          Icon(CeIcons.of('arrow-right'), size: 15, color: color),
        ]),
      );
}

/// Pending ("SETUP NEEDED") or reserved ("RESERVED" + split + countdown) card.
class _WaitingCard extends ConsumerWidget {
  const _WaitingCard({required this.match, required this.opponent});
  final ClubMatch match;
  final ClubSummary opponent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = match;
    final booking = ref.watch(bookingProvider(m.id));
    void open() => MatchManagementScreen.open(context, ref, m);

    if (m.status == MatchStatus.pending) {
      final meta = [if (m.format != null) m.format!.display(m.customOvers), m.city ?? 'City TBD'].join(' · ');
      return _CardShell(
        onTap: open,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _CardTop(opponent: opponent, meta: meta, chip: const CeStatusChip('Setup needed', tone: CeTone.amber)),
          const _Cta(icon: 'sliders', label: 'Set Up Match'),
        ]),
      );
    }

    // Reserved: ground held and payment(s) in progress, or expired awaiting a refund choice.
    final ground = m.groundId == null ? null : ref.watch(groundDirectoryProvider).value?[m.groundId];
    final start = m.startsAt;
    final slot = booking?.draft.slot;
    final meta = [
      ground?.name ?? 'Ground',
      if (start != null) CeFormat.dayMonth(start),
      slot?.label ?? (start == null ? '' : CeFormat.time(start)),
    ].where((s) => s.isNotEmpty).join(' · ');
    final expired = booking?.status == BookingStatus.expired;
    final myPaid = booking?.myShareSettled ?? false;

    return _CardShell(
      onTap: open,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _CardTop(
          opponent: opponent,
          meta: meta,
          chip: expired
              ? const CeStatusChip('Expired', tone: CeTone.red, icon: 'timer')
              : const CeStatusChip('Reserved', tone: CeTone.blue, icon: 'lock'),
        ),
        PaymentSplitRow(booking: booking, opponentName: opponent.name, margin: const EdgeInsets.only(top: 10)),
        const SizedBox(height: 8),
        if (expired)
          const Text('Reservation expired — the slot was released.',
              style: TextStyle(fontSize: 11.5, color: CeColors.red, fontWeight: FontWeight.w600))
        else
          Row(children: [
            Icon(CeIcons.of('timer'), size: 12, color: CeColors.muted),
            const SizedBox(width: 4),
            HoldCountdownText(matchId: m.id, style: const TextStyle(fontSize: 11.5, color: CeColors.muted, fontWeight: FontWeight.w700)),
            const Flexible(
              child: Text(' left on this reservation',
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: CeColors.muted)),
            ),
          ]),
        if (expired)
          const _Cta(icon: 'corner-up-left', label: 'Choose Refund Option', color: CeColors.red)
        else if (myPaid)
          const _Cta(icon: 'hourglass', label: 'View Payment Status')
        else
          const _Cta(icon: 'credit-card', label: 'Pay Your Share'),
      ]),
    );
  }
}

/// `.confirmed-match-card` for a scheduled match.
class _ScheduledCard extends ConsumerWidget {
  const _ScheduledCard({required this.match, required this.opponent});
  final ClubMatch match;
  final ClubSummary opponent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = match;
    final club = ref.watch(currentClubProvider);
    final home = club?.displayShortName ?? 'My Club';
    final ground = m.groundId == null ? null : ref.watch(groundDirectoryProvider).value?[m.groundId];
    final start = m.startsAt;
    return CeMatchCard(
      homeAbbr: clubAbbr(home),
      awayAbbr: opponent.abbr,
      awayColor: opponent.color,
      title: '$home vs ${opponent.name}',
      status: const CeStatusChip('Confirmed', icon: 'check'),
      infoChips: [
        CeInfoChip(icon: 'calendar', label: start == null ? 'Date TBD' : CeFormat.dayDate(start)),
        CeInfoChip(icon: 'clock', label: start == null ? 'Time TBD' : CeFormat.time(start)),
        CeInfoChip(icon: 'circle-dot', label: m.format?.display(m.customOvers) ?? 'Format TBD'),
      ],
      ground: ground == null ? 'Ground TBD' : '${ground.name}, ${ground.city}',
      groundDirections: ground != null,
      playingTeam: m.lineup?.name,
      footer: Semantics(
        button: true,
        label: m.lineup == null ? 'Select Your Playing XI' : 'View or edit line-up',
        excludeSemantics: true,
        child: InkWell(
          onTap: () => context.go(Routes.matchLineup(m.id)),
          child: m.lineup == null
              ? const _Cta(icon: 'circle-dot', label: 'Select Your Playing XI')
              : const _Cta(icon: 'users', label: 'View / Edit Line-up'),
        ),
      ),
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  const _HistoryCard({required this.match, required this.opponent});
  final ClubMatch match;
  final ClubSummary opponent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = match;
    final ground = m.groundId == null ? null : ref.watch(groundDirectoryProvider).value?[m.groundId];
    return _CardShell(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('vs ${opponent.name}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
          ),
          const CeStatusChip('Played', tone: CeTone.neutral),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 10, runSpacing: 4, children: [
          _Meta(icon: 'calendar', text: m.startsAt == null ? 'Date TBD' : CeFormat.date(m.startsAt!)),
          _Meta(icon: 'flag', text: [ground?.name ?? 'Ground TBD', ?m.city].join(', ')),
        ]),
        if (m.resultText != null) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(CeIcons.of('trophy'), size: 13, color: CeColors.primaryDark),
            const SizedBox(width: 5),
            Text(m.resultText!,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
          ]),
        ],
      ]),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 12, color: CeColors.muted),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: const TextStyle(fontSize: 12, color: CeColors.muted))),
      ]);
}
