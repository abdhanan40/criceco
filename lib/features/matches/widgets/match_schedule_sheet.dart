import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/repositories/repositories.dart' show AccountException;
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../club_matches_controller.dart';

/// Server matches (migration 17): what a proposal or a cancellation needs,
/// checked before the server checks it again.
abstract final class MatchScheduleRules {
  static const venueMax = 100;
  static const cityMax = 60;
  static const reasonMax = 200;

  /// What's wrong with a proposal, or `null`.
  static String? proposal({
    required DateTime? startsAt,
    required String venue,
    required String city,
    required DateTime now,
  }) {
    if (startsAt == null) return 'Choose a date and a start time.';
    if (!startsAt.isAfter(now)) return 'Choose a start time in the future.';
    if (startsAt.isAfter(now.add(const Duration(days: 365)))) {
      return 'Choose a start time within a year.';
    }
    final v = venue.trim();
    if (v.isEmpty) return 'Enter a venue.';
    if (v.length > venueMax) return 'Keep the venue to $venueMax characters.';
    if (city.trim().length > cityMax) {
      return 'Keep the city to $cityMax characters.';
    }
    return null;
  }

  static String? reason(String reason) {
    final r = reason.trim();
    if (r.isEmpty) return 'Give a reason for cancelling.';
    if (r.length > reasonMax) {
      return 'Keep the reason to $reasonMax characters.';
    }
    return null;
  }

  /// A confirmed match that has started can't be rescheduled or cancelled.
  static bool started(ClubMatch m, DateTime now) =>
      m.status == MatchStatus.confirmed &&
      m.startsAt != null &&
      !m.startsAt!.isAfter(now);

  static bool open(ClubMatch m) =>
      m.status == MatchStatus.pending || m.status == MatchStatus.confirmed;
}

/// The opponent's name for a server match (the list rows carry it).
String matchOpponentName(ClubMatch m) => m.opponentName ?? 'the other club';

/// "Sat, 23 Nov · 10:00".
String matchWhen(DateTime t) => '${CeFormat.dayDate(t)} · ${CeFormat.time(t)}';

/// "Gaddafi Stadium, Lahore".
String matchWhere(String venue, String? city) =>
    [venue, if (city != null && city.isNotEmpty) city].join(', ');

/// Match Management → a server match: its schedule in a sheet. Shows the
/// agreed time and the open proposal; the other club's proposal is
/// accepted or declined here; either club proposes (or re-proposes) a time
/// and venue, or cancels with a reason. Success closes the sheet with a
/// toast; a refusal is shown in the sheet (the match is re-read, so a
/// proposal changed meanwhile appears at once).
Future<void> showMatchScheduleSheet(
  BuildContext context,
  String matchId,
) async {
  final message = await showCeSheet<String>(
    context,
    builder: (_) => _MatchScheduleSheet(matchId: matchId),
  );
  if (message != null && context.mounted) showCeToast(context, message);
}

enum _Step { overview, propose, cancel }

class _MatchScheduleSheet extends ConsumerStatefulWidget {
  const _MatchScheduleSheet({required this.matchId});
  final String matchId;

  @override
  ConsumerState<_MatchScheduleSheet> createState() =>
      _MatchScheduleSheetState();
}

class _MatchScheduleSheetState extends ConsumerState<_MatchScheduleSheet> {
  _Step _step = _Step.overview;
  String? _error;

  // Proposal form.
  DateTime? _date;
  TimeOfDay? _time;
  late DateTime _month = _today;
  bool _pickerOpen = false;
  final _venue = TextEditingController();
  final _city = TextEditingController();

  // Cancellation.
  final _reason = TextEditingController();

  DateTime get _now => ref.read(clockProvider).now();
  DateTime get _today => CeFormat.dateOnly(_now);
  DateTime? get _startsAt {
    final d = _date, t = _time;
    return d == null || t == null
        ? null
        : DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  @override
  void dispose() {
    _venue.dispose();
    _city.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _startProposal(ClubMatch m) {
    final base = m.proposal?.startsAt ?? m.startsAt;
    setState(() {
      _step = _Step.propose;
      _error = null;
      _venue.text = m.proposal?.venueName ?? m.venueName ?? '';
      _city.text = m.proposal?.city ?? m.city ?? '';
      _date = base == null || !base.isAfter(_now)
          ? null
          : CeFormat.dateOnly(base);
      _time = base == null
          ? null
          : TimeOfDay(hour: base.hour, minute: base.minute);
      _month = _date ?? _today;
      _pickerOpen = false;
    });
  }

  void _go(_Step step) => setState(() {
    _step = step;
    _error = null;
  });

  /// Runs a request; success closes the sheet with [done], a refusal stays.
  Future<void> _submit(
    Future<ClubMatch?> Function(ClubMatchesController c) run,
    String done,
  ) async {
    setState(() => _error = null);
    try {
      final result = await run(ref.read(clubMatchesProvider.notifier));
      if (result == null || !mounted) return; // a second tap: nothing sent
      Navigator.of(context).pop(done);
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = ref.watch(clubMatchProvider(widget.matchId));
    if (m == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'This match is no longer available.',
          textAlign: TextAlign.center,
        ),
      );
    }
    final busy = ref.watch(busyMatchesProvider).contains(m.id);
    return Column(
      key: const Key('schedule.sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'vs ${matchOpponentName(m)}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 2),
        Text(
          m.format?.display(m.customOvers) ?? 'Format not set',
          style: const TextStyle(fontSize: 12.5, color: CeColors.muted),
        ),
        const SizedBox(height: 12),
        ...switch (_step) {
          _Step.overview => _overview(m, busy),
          _Step.propose => _proposeForm(m, busy),
          _Step.cancel => _cancelForm(m, busy),
        },
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            key: const Key('schedule.error'),
            style: const TextStyle(fontSize: 12.5, color: CeColors.red),
          ),
        ],
      ],
    );
  }

  Widget _block({
    Key? key,
    required String title,
    required List<Widget> children,
    Color tint = CeColors.mint,
  }) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: tint,
      borderRadius: BorderRadius.circular(CeRadius.row),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: CeColors.ink2,
          ),
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );

  Widget _line(String icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(CeIcons.of(icon), size: 13, color: CeColors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: CeColors.ink),
          ),
        ),
      ],
    ),
  );

  List<Widget> _overview(ClubMatch m, bool busy) {
    final now = _now;
    final opponent = matchOpponentName(m);
    final p = m.proposal;
    final started = MatchScheduleRules.started(m, now);
    final open = MatchScheduleRules.open(m) && !started;
    return [
      if (m.status == MatchStatus.cancelled && m.cancellation != null)
        _block(
          title: 'Cancelled',
          tint: CeColors.redSoft,
          children: [
            _line(
              'x-circle',
              m.cancellation!.byMe
                  ? 'Cancelled by your club'
                  : 'Cancelled by $opponent',
            ),
            _line('file-text', m.cancellation!.reason),
            _line('calendar', CeFormat.dayDate(m.cancellation!.at)),
          ],
        ),
      if (m.startsAt != null && m.venueName != null)
        _block(
          title: m.status == MatchStatus.confirmed
              ? 'Agreed schedule'
              : 'Schedule',
          children: [
            _line('calendar', matchWhen(m.startsAt!)),
            _line('flag', matchWhere(m.venueName!, m.city)),
          ],
        ),
      if (started)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'This match has started — its schedule can no longer change.',
            style: TextStyle(fontSize: 12.5, color: CeColors.muted),
          ),
        ),
      if (open && p == null && m.status == MatchStatus.pending)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'No time proposed yet. Propose one — the other club then accepts or declines it.',
            style: TextStyle(
              fontSize: 12.5,
              color: CeColors.muted,
              height: 1.4,
            ),
          ),
        ),
      if (open && p != null)
        _block(
          key: const Key('schedule.proposal'),
          title: p.byMe
              ? (m.status == MatchStatus.confirmed
                    ? 'Your new time — waiting for $opponent'
                    : 'Your proposal — waiting for $opponent')
              : (m.status == MatchStatus.confirmed
                    ? '$opponent proposes a new time'
                    : '$opponent proposes'),
          tint: p.byMe ? CeColors.historySoft : CeColors.amberSoft,
          children: [
            _line('calendar', matchWhen(p.startsAt)),
            _line('flag', matchWhere(p.venueName, p.city)),
          ],
        ),
      if (open && p != null && !p.byMe) ...[
        Row(
          children: [
            Expanded(
              child: CeButton.danger(
                key: const Key('schedule.decline'),
                label: 'Decline',
                icon: CeIcons.of('x'),
                onPressed: busy
                    ? null
                    : () => _submit(
                        (c) => c.respondToSchedule(
                          m.id,
                          proposalVersion: p.version,
                          accept: false,
                        ),
                        'Proposal declined',
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CeButton(
                key: const Key('schedule.accept'),
                label: 'Accept',
                icon: CeIcons.of('check'),
                loading: busy,
                onPressed: busy
                    ? null
                    : () => _submit(
                        (c) => c.respondToSchedule(
                          m.id,
                          proposalVersion: p.version,
                          accept: true,
                        ),
                        'Match confirmed for ${matchWhen(p.startsAt)}',
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
      if (open) ...[
        CeButton.soft(
          key: const Key('schedule.propose'),
          label: p == null && m.status == MatchStatus.pending
              ? 'Propose a Time'
              : (m.status == MatchStatus.confirmed
                    ? 'Propose a New Time'
                    : 'Propose a Different Time'),
          icon: CeIcons.of('calendar'),
          onPressed: busy ? null : () => _startProposal(m),
        ),
        const SizedBox(height: 8),
        CeButton.soft(
          key: const Key('schedule.cancel'),
          label: 'Cancel Match',
          icon: CeIcons.of('x-circle'),
          onPressed: busy ? null : () => _go(_Step.cancel),
        ),
      ],
    ];
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 10, minute: 0),
      helpText: 'Start time',
    );
    if (picked != null && mounted) setState(() => _time = picked);
  }

  List<Widget> _proposeForm(ClubMatch m, bool busy) {
    final problem = MatchScheduleRules.proposal(
      startsAt: _startsAt,
      venue: _venue.text,
      city: _city.text,
      now: _now,
    );
    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: CeColors.ink2,
        ),
      ),
    );
    return [
      Text(
        m.status == MatchStatus.confirmed
            ? 'The match stays confirmed at its agreed time until ${matchOpponentName(m)} accepts the new one.'
            : '${matchOpponentName(m)} accepts or declines your proposal.',
        style: const TextStyle(
          fontSize: 12.5,
          color: CeColors.muted,
          height: 1.4,
        ),
      ),
      label('Date'),
      CeDateRow(
        key: const Key('schedule.date'),
        date: _date,
        open: _pickerOpen,
        hasError: false,
        onTap: () => setState(() {
          _pickerOpen = !_pickerOpen;
          if (_pickerOpen) _month = _date ?? _today;
        }),
      ),
      if (_pickerOpen)
        CeMonthCalendar(
          margin: const EdgeInsets.only(top: 8),
          visibleMonth: _month,
          today: _today,
          selected: _date,
          isEnabled: (d) =>
              !d.isBefore(_today) &&
              !d.isAfter(_today.add(const Duration(days: 365))),
          onMonthChanged: (mo) => setState(() => _month = mo),
          onSelected: (d) => setState(() {
            _date = d;
            _pickerOpen = false;
          }),
        ),
      label('Start time'),
      CeButton.soft(
        key: const Key('schedule.time'),
        label: _time == null ? 'Choose a start time' : _time!.format(context),
        icon: CeIcons.of('clock'),
        onPressed: _pickTime,
      ),
      label('Venue'),
      CeTextField(
        fieldKey: const Key('schedule.venue'),
        controller: _venue,
        hint: 'Ground or venue name',
        icon: 'flag',
        textCapitalization: TextCapitalization.words,
        inputFormatters: [
          LengthLimitingTextInputFormatter(MatchScheduleRules.venueMax),
        ],
        onChanged: (_) => setState(() {}),
      ),
      label('City (optional)'),
      CeTextField(
        fieldKey: const Key('schedule.city'),
        controller: _city,
        hint: 'City',
        icon: 'map-pin',
        textCapitalization: TextCapitalization.words,
        inputFormatters: [
          LengthLimitingTextInputFormatter(MatchScheduleRules.cityMax),
        ],
        onChanged: (_) => setState(() {}),
      ),
      if (problem != null && _startsAt != null)
        Text(
          problem,
          key: const Key('schedule.problem'),
          style: const TextStyle(fontSize: 12, color: CeColors.red),
        ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: CeButton.soft(
              label: 'Back',
              onPressed: busy ? null : () => _go(_Step.overview),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CeButton(
              key: const Key('schedule.send'),
              label: 'Send Proposal',
              loading: busy,
              onPressed: problem != null || busy
                  ? null
                  : () {
                      final city = _city.text.trim();
                      _submit(
                        (c) => c.proposeSchedule(
                          m.id,
                          startsAt: _startsAt!,
                          venueName: _venue.text.trim(),
                          city: city.isEmpty ? null : city,
                        ),
                        'Proposal sent to ${matchOpponentName(m)}',
                      );
                    },
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _cancelForm(ClubMatch m, bool busy) {
    final problem = MatchScheduleRules.reason(_reason.text);
    return [
      Text(
        '${matchOpponentName(m)} will see that your club cancelled, with your reason. This can\'t be undone.',
        style: const TextStyle(
          fontSize: 12.5,
          color: CeColors.muted,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 10),
      CeTextField(
        fieldKey: const Key('schedule.reason'),
        controller: _reason,
        hint: 'Reason (e.g. ground unavailable)',
        icon: 'file-text',
        maxLines: 3,
        maxLength: MatchScheduleRules.reasonMax,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: CeButton.soft(
              label: 'Back',
              onPressed: busy ? null : () => _go(_Step.overview),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CeButton.danger(
              key: const Key('schedule.confirmCancel'),
              label: 'Cancel Match',
              onPressed: problem != null || busy
                  ? null
                  : () => _submit(
                      (c) => c.cancel(m.id, reason: _reason.text.trim()),
                      'Match cancelled',
                    ),
            ),
          ),
        ],
      ),
    ];
  }
}

/// Status chip of a server match card.
Widget liveMatchChip(ClubMatch m, DateTime now) {
  final p = m.proposal;
  return switch (m.status) {
    MatchStatus.cancelled => const CeStatusChip(
      'Cancelled',
      tone: CeTone.red,
      icon: 'x',
    ),
    MatchStatus.completed => const CeStatusChip('Played', tone: CeTone.neutral),
    MatchStatus.confirmed when p != null && !p.byMe => const CeStatusChip(
      'New time proposed',
      tone: CeTone.amber,
      icon: 'hourglass',
    ),
    MatchStatus.confirmed => const CeStatusChip('Confirmed', icon: 'check'),
    _ when p == null => const CeStatusChip('Time needed', tone: CeTone.amber),
    _ when p.byMe => const CeStatusChip(
      'Awaiting reply',
      tone: CeTone.amber,
      icon: 'hourglass',
    ),
    _ => const CeStatusChip(
      'Reply needed',
      tone: CeTone.blue,
      icon: 'hourglass',
    ),
  };
}
