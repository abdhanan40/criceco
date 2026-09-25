import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/repositories/repositories.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../club/club_providers.dart';
import '../booking_controller.dart';
import '../widgets/booking_widgets.dart';
import 'setup_screens.dart' show ensureBooking;

/// Why a slot can't be picked (Select Date & Time).
enum SlotAvailability {
  open('Open'),
  booked('Booked'), // by the venue
  reserved('Reserved'), // held or confirmed by another club
  passed('Passed'); // already started today

  const SlotAvailability(this.label);
  final String label;
}

SlotAvailability slotAvailability(WidgetRef ref, {required String matchId, required String groundId, required DateTime date, required TimeSlot slot}) {
  final now = ref.read(clockProvider).now();
  if (!slot.startOn(date).isAfter(now)) return SlotAvailability.passed;
  if (ref.read(groundRepositoryProvider).slotBookedByVenue(groundId, date, slot)) return SlotAvailability.booked;
  final taken = ref
      .read(reservationRepositoryProvider)
      .isSlotTaken(groundId: groundId, slotStart: slot.startOn(date), now: now, exceptMatchId: matchId);
  return taken ? SlotAvailability.reserved : SlotAvailability.open;
}

// ---------------------------------------------------------------------------
// 4 · Select Date & Time (prototype `screens.selectDate`, :6398). Every label
// comes from a real DateTime; month navigation only moves `visibleMonth`
// (fix: the prototype hard-coded August 2026).
// ---------------------------------------------------------------------------

class SelectDateScreen extends ConsumerStatefulWidget {
  const SelectDateScreen({super.key, required this.matchId, required this.groundId});
  final String matchId;
  final String groundId;

  @override
  ConsumerState<SelectDateScreen> createState() => _SelectDateScreenState();
}

class _SelectDateScreenState extends ConsumerState<SelectDateScreen> {
  DateTime? _month;
  String? _error;

  DateTime get _today => CeFormat.dateOnly(ref.read(clockProvider).now());

  void _update(BookingDraft Function(BookingDraft) f) =>
      ref.read(bookingsProvider.notifier).updateDraft(widget.matchId, f);

  @override
  Widget build(BuildContext context) => BookingScaffold(
        matchId: widget.matchId,
        title: 'Select Date & Time',
        builder: (context, c) {
          ensureBooking(ref, c);
          final g = ref.watch(groundDirectoryProvider).value?[widget.groundId];
          if (g == null) {
            return CeEmptyState(
              icon: 'flag',
              title: 'Ground not found',
              primaryLabel: 'Back to grounds',
              onPrimary: () => context.go(Routes.bookGround(widget.matchId)),
            );
          }
          final d = c.booking?.draft ?? const BookingDraft();
          final today = _today;
          final month = _month ?? d.date ?? today;
          final groundRepo = ref.read(groundRepositoryProvider);

          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            const WorkflowProgress(step: 4),
            BookingHeaderCard(
              leading: const GroundThumb(),
              title: g.name,
              meta: '${g.city} · ${CeFormat.rupees(g.pricePerHour)} / hr',
            ),
            const CeSectionHeader('Availability'),
            const _Legend(items: [
              ('Available', CeColors.fresh),
              ('Partial', CeColors.amber),
              ('Full', CeColors.red),
            ]),
            CeMonthCalendar(
              visibleMonth: month,
              today: today,
              selected: d.date,
              styleOf: (day) => switch (groundRepo.dayAvailability(g.id, day)) {
                DayAvailability.available => CeDayStyle.available,
                DayAvailability.partial => CeDayStyle.partial,
                DayAvailability.full => CeDayStyle.full,
              },
              isEnabled: (day) => !day.isBefore(today),
              onMonthChanged: (m) => setState(() => _month = m),
              onSelected: (day) {
                if (groundRepo.dayAvailability(g.id, day) == DayAvailability.full) {
                  showCeToast(context, 'This ground is fully booked that day');
                  return;
                }
                // A new date invalidates the previous slot choice.
                _update((x) => x.copyWith(date: day, clearSlot: true));
                setState(() => _error = null);
              },
            ),
            CeSectionHeader(d.date == null ? 'Available Slots' : 'Available Slots · ${CeFormat.dayDate(d.date!)}'),
            if (d.date == null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: CeSpace.gutter, vertical: 8),
                child: Text('Pick a date above to see available time slots.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: CeColors.muted)),
              )
            else ...[
              const _Legend(items: [
                ('Open', CeColors.mint2),
                ('Booked', CeColors.line2),
                ('Reserved', CeColors.redBorder),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 4, CeSpace.gutter, 0),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final s in TimeSlot.standard)
                    _SlotChip(
                      slot: s,
                      availability:
                          slotAvailability(ref, matchId: widget.matchId, groundId: g.id, date: d.date!, slot: s),
                      selected: d.slot == s,
                      onTap: () {
                        _update((x) => x.copyWith(slot: s));
                        setState(() => _error = null);
                      },
                    ),
                ]),
              ),
              const CeInfoNote(
                margin: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                icon: 'lock',
                text: "Once you reserve a slot, it's held for your club only for 30 minutes — "
                    'no other club can double-book it during that window.',
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                child: CeInlineError(_error),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
              child: CeButton(
                label: 'Continue · Booking Summary',
                trailingIcon: CeIcons.of('arrow-right'),
                onPressed: () {
                  final err = d.date == null
                      ? 'Please pick a date'
                      : d.slot == null
                          ? 'Please pick a time slot'
                          : null;
                  if (err != null) {
                    setState(() => _error = err);
                    return;
                  }
                  context.go(Routes.bookingSummary(widget.matchId, g.id));
                },
              ),
            ),
          ]);
        },
      );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.items});
  final List<(String, Color)> items;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        child: Wrap(spacing: 14, runSpacing: 4, children: [
          for (final (label, color) in items)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(label, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
            ]),
        ]),
      );
}

class _SlotChip extends StatelessWidget {
  const _SlotChip({required this.slot, required this.availability, required this.selected, required this.onTap});
  final TimeSlot slot;
  final SlotAvailability availability;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = availability == SlotAvailability.open;
    final state = selected ? 'Selected' : availability.label;
    final (bg, fg, border) = selected
        ? (CeColors.primaryDark, Colors.white, CeColors.primaryDark)
        : switch (availability) {
            SlotAvailability.open => (CeColors.mint, CeColors.primaryDark, CeColors.mint2),
            SlotAvailability.booked || SlotAvailability.passed => (CeColors.historySoft, CeColors.muted2, CeColors.line),
            SlotAvailability.reserved => (CeColors.redSoft, CeColors.red, CeColors.redBorder),
          };
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: '${slot.label}, $state',
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.md), side: BorderSide(color: border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.md),
          onTap: enabled ? onTap : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Text('${slot.label} · $state',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: fg)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5 · Booking Summary (prototype `screens.bookingSummary`, :6490)
// ---------------------------------------------------------------------------

class BookingSummaryScreen extends ConsumerStatefulWidget {
  const BookingSummaryScreen({super.key, required this.matchId, required this.groundId});
  final String matchId;
  final String groundId;

  @override
  ConsumerState<BookingSummaryScreen> createState() => _BookingSummaryScreenState();
}

class _BookingSummaryScreenState extends ConsumerState<BookingSummaryScreen> {
  bool _busy = false;

  Future<void> _reserve(BookingContext c) async {
    final d = c.booking?.draft;
    if (d?.date == null || d?.slot == null) {
      context.go(Routes.selectDate(widget.matchId, widget.groundId));
      return;
    }
    // Re-check just before reserving: the slot may have passed or been taken.
    final avail = slotAvailability(ref, matchId: widget.matchId, groundId: widget.groundId, date: d!.date!, slot: d.slot!);
    if (avail != SlotAvailability.open && avail != SlotAvailability.reserved) {
      ref.read(bookingsProvider.notifier).updateDraft(widget.matchId, (x) => x.copyWith(clearSlot: true));
      showCeToast(context, 'That time slot is no longer available — pick another time');
      context.go(Routes.selectDate(widget.matchId, widget.groundId));
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(bookingsProvider.notifier).reserve(widget.matchId);
      if (!mounted) return;
      showCeToast(context, 'Ground reserved for 30 minutes!');
      context.go(Routes.payment(widget.matchId));
    } on SlotTakenException {
      // Conflict: another club holds this slot. The controller cleared it.
      if (!mounted) return;
      setState(() => _busy = false);
      showCeToast(context, 'That slot was just taken by another club — pick another time');
      context.go(Routes.selectDate(widget.matchId, widget.groundId));
    }
  }

  @override
  Widget build(BuildContext context) => BookingScaffold(
        matchId: widget.matchId,
        title: 'Booking Summary',
        builder: (context, c) {
          ensureBooking(ref, c);
          final g = ref.watch(groundDirectoryProvider).value?[widget.groundId];
          final cost = g?.matchCost ?? 0;
          final share = (cost / 2).round();
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            const WorkflowProgress(step: 5),
            const Padding(
              padding: EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 10),
              child: Text('Review everything before reserving the ground.',
                  style: TextStyle(fontSize: 13, color: CeColors.muted)),
            ),
            CeSummaryCard(rows: bookingDetailRows(context, c)),
            const CeSectionHeader('Payment Split'),
            CeSummaryCard(rows: [
              ('Total Ground Cost (2 hrs)', CeSummaryCard.value(context, CeFormat.rupees(cost))),
              ('Your Share (50%)', CeSummaryCard.value(context, CeFormat.rupees(share), color: CeColors.primaryDark)),
              ("${c.opponent.name}'s Share (50%)", CeSummaryCard.value(context, CeFormat.rupees(share))),
            ]),
            const CeInfoNote(
              margin: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
              icon: 'credit-card',
              text: 'Both clubs pay their 50% share into the secure CricEco Wallet. The ground owner is paid '
                  'automatically once both payments are in, minus a small CricEco service fee.',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
              child: CeButton(
                label: 'Reserve Ground for 30 Minutes',
                icon: CeIcons.of('lock'),
                loading: _busy,
                onPressed: _busy ? null : () => _reserve(c),
              ),
            ),
          ]);
        },
      );
}
