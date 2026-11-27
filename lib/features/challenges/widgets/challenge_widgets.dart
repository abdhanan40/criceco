import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/validators.dart';
import '../../../data/repositories/repositories.dart' show AccountException;
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_segmented.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';

/// Tabs of the Challenges workspace, kept in `?tab=`.
enum ChallengesSection {
  challenges('Challenges', Routes.challenges),
  mine('My Challenges', Routes.myChallenges),
  find('Find Opponent', Routes.findMatch);

  const ChallengesSection(this.label, this.location);
  final String label;

  /// Canonical location (`/club/challenges[?tab=…]`).
  final String location;

  static ChallengesSection parse(String? raw) => values.where((v) => v.name == raw).firstOrNull ?? challenges;
}

/// `challengesTabRow`: the workspace tabs, switched with `go` (replaces, so
/// no history entries). My Challenges carries the number of challenges
/// awaiting your decision.
class ChallengesTabs extends ConsumerWidget {
  const ChallengesTabs({super.key, required this.active});
  final ChallengesSection active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final awaiting = ref.watch(myChallengeSectionsProvider).awaitingDecision.length;
    return CeSegmentedTabs<ChallengesSection>(
      values: ChallengesSection.values,
      selected: active,
      labelOf: (s) => s.label,
      countOf: (s) => s == ChallengesSection.mine && awaiting > 0 ? awaiting : null,
      onSelected: (s) {
        if (s != active) context.go(s.location);
      },
    );
  }
}

/// What a challenge / match request proposes. Format, place and date are
/// required before anything is sent: the demo picks a listed [ground]; a
/// server challenge names its venue ([venueName]) and may add [customOvers]
/// (Custom format) and a [message].
class ChallengeRequest {
  const ChallengeRequest({
    required this.format,
    required this.date,
    required this.venueName,
    this.ground,
    this.customOvers,
    this.message,
  });
  final MatchFormat format;
  final DateTime date;
  final String venueName;
  final Ground? ground;
  final int? customOvers;
  final String? message;
}

/// The badge colour of an opponent: the demo club's own, or the brand colour
/// for a server club (which has no colour of its own).
Color opponentColor(ChallengeOpponent o) => o.summary?.color ?? CeColors.primary;

/// Sends a challenge and routes by the resulting state: Demo Mode accepts it
/// instantly → Challenge Accepted; otherwise it stays pending → My Challenges
/// ("Sent", approved P9).
///
/// Nothing is sent until the setup sheet is completed: Match Format → Ground
/// → Date → Review → Send. [matchRequest] only changes the wording (Find
/// Opponent: "Send Match Request"); a Find Opponent listing prefills its own
/// [format], [date] and — when it names a listed ground — [groundName], all
/// of which can still be changed.
Future<void> sendChallenge(
  BuildContext context,
  WidgetRef ref,
  ChallengeOpponent club, {
  bool matchRequest = false,
  MatchFormat? format,
  DateTime? date,
  String? groundName,
  VoidCallback? onSending, // called once the request is confirmed, before sending
}) async {
  final request = await showCeSheet<ChallengeRequest>(
    context,
    builder: (_) => _ChallengeSetupSheet(
      club: club,
      matchRequest: matchRequest,
      format: format,
      date: date,
      groundName: groundName,
    ),
  );
  if (request == null || !context.mounted) return; // cancelled: nothing is sent
  onSending?.call();
  final Challenge c;
  try {
    c = await ref.read(challengesProvider.notifier).send(
          club.id,
          format: request.format,
          groundName: request.venueName,
          proposedAt: request.date,
          customOvers: request.customOvers,
          message: request.message,
        );
  } on ChallengeBlockedException catch (e) {
    if (context.mounted) showCeToast(context, e.message);
    return;
  } on AccountException catch (e) {
    // The server refused it (duplicate, pending limit, date, permission…).
    if (context.mounted) showCeToast(context, e.message);
    return;
  }
  if (!context.mounted) return;
  if (c.status == ChallengeStatus.accepted) {
    showCeToast(context, 'Challenge sent to ${club.name}!');
    context.go(Routes.challengeAccepted(c.id));
  } else {
    showCeToast(context, 'Challenge sent to ${club.name} — awaiting their reply');
    context.go(Routes.myChallenges);
  }
}

/// Formats a challenge can propose in the demo (Custom needs an overs count,
/// which a demo challenge doesn't carry; it is set later in Match Setup).
const challengeFormats = [MatchFormat.t20, MatchFormat.odi, MatchFormat.t10, MatchFormat.test];

/// Formats a server challenge can propose (migration 17): Custom too, with
/// its overs (1–50).
const serverChallengeFormats = [MatchFormat.t20, MatchFormat.odi, MatchFormat.t10, MatchFormat.test, MatchFormat.custom];

/// Challenge / match-request setup in one sheet. Step 1: Match Format, the
/// place and Date ("Review" stays disabled until all are valid). Step 2: a
/// summary and the final confirmation. Resolves to `null` on Cancel.
///
/// The demo picks one of its listed grounds. A server challenge
/// ([challengesLiveProvider]) names its venue, may be Custom (with overs)
/// and may carry a message; its date follows the server's rule (from
/// tomorrow in Pakistan, up to a year ahead).
class _ChallengeSetupSheet extends ConsumerStatefulWidget {
  const _ChallengeSetupSheet({
    required this.club,
    required this.matchRequest,
    this.format,
    this.date,
    this.groundName,
  });
  final ChallengeOpponent club;
  final bool matchRequest;
  final MatchFormat? format;
  final DateTime? date;
  final String? groundName;

  @override
  ConsumerState<_ChallengeSetupSheet> createState() => _ChallengeSetupSheetState();
}

class _ChallengeSetupSheetState extends ConsumerState<_ChallengeSetupSheet> {
  late final bool _live = ref.read(challengesLiveProvider);
  late final List<MatchFormat> _formats = _live ? serverChallengeFormats : challengeFormats;
  late MatchFormat? _format = _formats.contains(widget.format) ? widget.format : null;
  Ground? _ground;
  bool _groundSeeded = false;
  late final _venue = TextEditingController(text: _live ? (widget.groundName ?? '') : '');
  final _overs = TextEditingController();
  final _message = TextEditingController();
  // A prefilled date is kept only if it's still a valid match date.
  late DateTime? _date = widget.date == null || _dateProblem(widget.date) != null ? null : CeFormat.dateOnly(widget.date!);
  late DateTime _month = _date ?? _today;
  bool _pickerOpen = false;
  bool _review = false;

  DateTime get _now => ref.read(clockProvider).now();
  DateTime get _today => CeFormat.dateOnly(_now);
  String? _dateProblem(DateTime? d) => _live ? ChallengeRules.date(d, _now) : CeValidators.matchDate(d, _now);
  int? get _customOvers => int.tryParse(_overs.text.trim());

  /// What still keeps "Review" disabled, or `null`.
  String? get _problem {
    if (!_live) return _format != null && _ground != null && _date != null ? null : '';
    return ChallengeRules.problem(
      format: _format,
      customOvers: _customOvers,
      proposedAt: _date,
      venueName: _venue.text,
      message: _message.text,
      now: _now,
    );
  }

  @override
  void dispose() {
    _venue.dispose();
    _overs.dispose();
    _message.dispose();
    super.dispose();
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
      );

  @override
  Widget build(BuildContext context) => _review ? _buildReview(context) : _buildDetails(context);

  Widget _buildDetails(BuildContext context) {
    final club = widget.club;
    final grounds = _live
        ? const <Ground>[]
        : (ref.watch(groundDirectoryProvider).value ?? const <String, Ground>{}).values.toList();
    // A listing that names a listed ground starts with it selected.
    if (!_live && !_groundSeeded && grounds.isNotEmpty) {
      _groundSeeded = true;
      _ground = grounds.where((g) => g.name == widget.groundName).firstOrNull;
    }
    final formats = club.summary?.formats;
    final problem = _problem;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(widget.matchRequest ? 'Match request to ${club.name}' : 'Challenge ${club.name}',
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
          formats != null && formats.trim().isNotEmpty
              ? 'Choose the match format, ground and date. ${club.name} plays '
                  '${formats.trim().toLowerCase() == 'any' ? 'any format' : formats}.'
              : 'Choose the match format, venue and date. ${club.name} can accept or decline.',
          style: const TextStyle(fontSize: 12.5, color: CeColors.muted, height: 1.4)),
      _label('Match Format'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final f in _formats)
          CeChip(
            key: Key('challenge.format.${f.name}'),
            label: f.label,
            selected: f == _format,
            onTap: () => setState(() => _format = f),
          ),
      ]),
      if (_live && _format == MatchFormat.custom) ...[
        _label('Overs'),
        CeTextField(
          fieldKey: const Key('challenge.overs'),
          controller: _overs,
          hint: '1–50 overs',
          icon: 'circle-dot',
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
          onChanged: (_) => setState(() {}),
        ),
      ],
      if (_live) ...[
        _label('Venue'),
        CeTextField(
          fieldKey: const Key('challenge.venue'),
          controller: _venue,
          hint: 'Ground or venue name',
          icon: 'flag',
          textCapitalization: TextCapitalization.words,
          inputFormatters: [LengthLimitingTextInputFormatter(ChallengeRules.venueMax)],
          onChanged: (_) => setState(() {}),
        ),
      ] else ...[
        _label('Ground'),
        CeSelectField<Ground>(
          fieldKey: const Key('challenge.ground'),
          items: grounds,
          value: _ground,
          labelOf: (g) => '${g.name} — ${g.city}',
          onChanged: (g) => setState(() => _ground = g),
          sheetTitle: 'Ground',
          hint: 'Select ground',
          icon: 'flag',
          itemIcon: 'flag',
        ),
      ],
      // CeSelectField already leaves a gap below itself.
      if (_live) const SizedBox(height: 14),
      const Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
      const SizedBox(height: 8),
      CeDateRow(
        key: const Key('challenge.date'),
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
          // Same rule as Match Setup (demo) / the server: from tomorrow on.
          isEnabled: (d) => _dateProblem(d) == null,
          onMonthChanged: (m) => setState(() => _month = m),
          onSelected: (d) => setState(() {
            _date = d;
            _pickerOpen = false;
          }),
        ),
      if (_live) ...[
        _label('Message (optional)'),
        CeTextField(
          fieldKey: const Key('challenge.message'),
          controller: _message,
          hint: 'A note for ${club.name}',
          icon: 'file-text',
          maxLines: 3,
          maxLength: ChallengeRules.messageMax,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
        ),
        if (problem != null && _format != null && _date != null && _venue.text.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(problem,
                key: const Key('challenge.problem'), style: const TextStyle(fontSize: 12, color: CeColors.red)),
          ),
      ],
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(
          child: CeButton(
            key: const Key('challenge.review'),
            label: 'Review',
            trailingIcon: CeIcons.of('arrow-right'),
            onPressed: problem == null ? () => setState(() => _review = true) : null,
          ),
        ),
      ]),
    ]);
  }

  Widget _buildReview(BuildContext context) {
    final request = widget.matchRequest;
    final message = _message.text.trim();
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 84, child: Text(label, style: const TextStyle(fontSize: 12.5, color: CeColors.muted))),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
            ),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: Text(request ? 'Send Match Request?' : 'Send Challenge?', style: Theme.of(context).textTheme.titleLarge),
        ),
        TextButton(onPressed: () => setState(() => _review = false), child: const Text('Edit')),
      ]),
      const SizedBox(height: 6),
      Container(
        key: const Key('challenge.summary'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
        child: Column(children: [
          row('Opponent', widget.club.name),
          row('Format', _live ? _format!.display(_format == MatchFormat.custom ? _customOvers : null) : _format!.label),
          if (_live) row('Venue', _venue.text.trim()) else row('Ground', _ground!.name),
          row('Date', CeFormat.dayDate(_date!)),
          if (_live && message.isNotEmpty) row('Message', message),
        ]),
      ),
      const SizedBox(height: 12),
      Text(
          request
              ? 'Are you sure you want to send this match request?'
              : 'Are you sure you want to send this challenge?',
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: CeColors.muted, height: 1.45)),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(
          child: CeButton(
            key: const Key('challenge.send'),
            label: request ? 'Send Request' : 'Send Challenge',
            onPressed: () => Navigator.of(context).pop(ChallengeRequest(
              format: _format!,
              date: _date!,
              venueName: _live ? _venue.text.trim() : _ground!.name,
              ground: _live ? null : _ground,
              customOvers: _live && _format == MatchFormat.custom ? _customOvers : null,
              message: _live && message.isNotEmpty ? message : null,
            )),
          ),
        ),
      ]),
    ]);
  }
}

/// Accept / Decline a received challenge — always confirmed first. Accept
/// creates ONE pending match and hands off to Match Management (Waiting);
/// Decline resolves the challenge. Returns the updated challenge, or `null`
/// when the confirmation was cancelled.
Future<Challenge?> respondToChallenge(
  BuildContext context,
  WidgetRef ref,
  Challenge c, {
  required bool accept,
  VoidCallback? onResponding, // called once confirmed, before saving
}) async {
  final name = ref.read(clubDirectoryProvider).value?[c.opponentClubId]?.name ?? c.opponentName ?? 'this club';
  final live = ref.read(challengesLiveProvider);
  final ok = accept
      ? await showCeConfirmSheet(
          context,
          title: 'Accept Challenge?',
          body: 'Are you sure you want to accept this match challenge?',
          confirmLabel: 'Accept Challenge',
          icon: 'check-circle',
        )
      : await showCeConfirmSheet(
          context,
          title: 'Decline this challenge?',
          body: '$name will be told you declined. You can still challenge them later.',
          confirmLabel: 'Decline Challenge',
          destructive: true,
          icon: 'x-circle',
        );
  if (!ok || !context.mounted) return null;
  onResponding?.call();
  final ctrl = ref.read(challengesProvider.notifier);
  final Challenge? result;
  try {
    result = accept ? await ctrl.accept(c.id) : await ctrl.decline(c.id);
  } on AccountException catch (e) {
    // Already answered, no permission, offline… (the list was reloaded).
    if (context.mounted) showCeToast(context, e.message);
    return null;
  }
  if (!context.mounted) return result;
  switch (result?.status) {
    case ChallengeStatus.accepted when live:
      // The server created the match (pending, awaiting a schedule):
      // Match Management → Waiting, where both clubs agree a time.
      showCeToast(context, 'Challenge accepted — agree a time in Match Management');
      context.go(Routes.matchManagement(MatchTab.waiting));
    case ChallengeStatus.accepted:
      showCeToast(context, 'Challenge accepted!');
      context.go(Routes.matchManagement(MatchTab.waiting));
    case ChallengeStatus.declined:
      showCeToast(context, 'Challenge declined');
    case ChallengeStatus.expired:
      showCeToast(context, 'This challenge has expired');
    case ChallengeStatus.pending || null:
      break;
  }
  return result;
}

/// `.avail-box`: dashed mint call-to-action for Create Availability Slot.
class AvailabilitySlotCta extends StatelessWidget {
  const AvailabilitySlotCta({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        child: Material(
          color: CeColors.mint,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.row),
            side: const BorderSide(color: CeColors.mint2, width: 1.4),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: () => context.push(Routes.createAvailabilitySlot),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(CeIcons.of('plus'), size: 16, color: CeColors.primaryDark),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'Create Availability Slot', style: TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(text: ' — Post your open dates, teams will send you requests'),
                    ]),
                    style: TextStyle(fontSize: 12.5, color: CeColors.primaryDark, height: 1.4),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// `.my-slot-card` list with Remove.
class MySlotsList extends ConsumerWidget {
  const MySlotsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = ref.watch(availabilitySlotsProvider).value ?? const <AvailabilitySlot>[];
    final grounds = ref.watch(groundDirectoryProvider).value ?? const <String, Ground>{};
    return Column(children: [
      for (final s in slots)
        Container(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.rowGap, CeSpace.gutter, 0),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(CeRadius.row),
            border: Border.all(color: CeColors.mint2),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(CeIcons.of('megaphone'), size: 13, color: CeColors.primaryDark),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Your Open Slot',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: CeColors.red,
                  minimumSize: const Size(48, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
                onPressed: () async {
                  final ok = await showCeConfirmSheet(
                    context,
                    title: 'Remove this slot?',
                    body: 'Clubs will no longer see your ${CeFormat.dayDate(s.date)} slot in Find Opponent.',
                    confirmLabel: 'Remove Slot',
                    destructive: true,
                    icon: 'x-circle',
                  );
                  if (!ok) return;
                  await ref.read(availabilitySlotsProvider.notifier).remove(s.id);
                  if (context.mounted) showCeToast(context, 'Availability slot removed');
                },
                child: const Text('Remove'),
              ),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 6, children: [
              InlineInfo(icon: 'circle-dot', text: s.format.display(s.customOvers)),
              InlineInfo(icon: 'building-2', text: s.city),
              if (s.groundId != null && grounds[s.groundId] != null)
                InlineInfo(icon: 'flag', text: grounds[s.groundId]!.name),
              InlineInfo(icon: 'calendar', text: CeFormat.dayDate(s.date)),
              InlineInfo(icon: 'clock', text: s.slot.label),
            ]),
            if (s.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              InlineInfo(icon: 'file-text', text: s.notes, maxLines: 3),
            ],
          ]),
        ),
    ]);
  }
}

/// Icon + text used in challenge and slot cards (`.challenge-detail span`).
class InlineInfo extends StatelessWidget {
  const InlineInfo({super.key, required this.icon, required this.text, this.maxLines = 1});
  final String icon;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(CeIcons.of(icon), size: 12.5, color: CeColors.muted),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: CeColors.ink2, height: 1.3)),
        ),
      ]);
}

/// `.challenge-card` shell: badge, name (+ trailing), meta, optional details
/// and actions. Tap opens the opponent's Club Profile when [onTap] is set.
class ChallengeCard extends StatelessWidget {
  const ChallengeCard({
    super.key,
    required this.abbr,
    required this.color,
    required this.name,
    required this.meta,
    this.nameTrailing,
    this.trailing,
    this.details = const [],
    this.actions,
    this.inlineActions = false,
    this.onTap,
  });

  final String abbr;
  final Color color;
  final String name;
  final Widget meta;
  final Widget? nameTrailing;
  final Widget? trailing;
  final List<Widget> details;
  final Widget? actions;

  /// Dense layout: the details and a compact action share the last row
  /// (primary action on the right) instead of a full-width button below.
  final bool inlineActions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.rowGap, CeSpace.gutter, 0),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.card),
            side: const BorderSide(color: CeColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  CeTeamBadge(abbr, color: color, size: 38),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                        ?nameTrailing,
                      ]),
                      const SizedBox(height: 1),
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontSize: 11.5, color: CeColors.muted),
                        child: meta,
                      ),
                    ]),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                ]),
                if (inlineActions && actions != null) ...[
                  const SizedBox(height: 8),
                  // The action keeps its own width but never more than ~half
                  // the row, so the details always have room (320 px, large text).
                  LayoutBuilder(
                    builder: (context, box) => Row(children: [
                      Expanded(child: Wrap(spacing: 12, runSpacing: 6, children: details)),
                      const SizedBox(width: 10),
                      ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * 0.55), child: actions!),
                    ]),
                  ),
                ] else ...[
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, runSpacing: 6, children: details),
                  ],
                  if (actions != null) ...[const SizedBox(height: 10), actions!],
                ],
              ]),
            ),
          ),
        ),
      );
}

/// Small NEW pill (`.new-pill`).
class NewPill extends StatelessWidget {
  const NewPill({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: CeColors.amberSoft, borderRadius: BorderRadius.circular(CeRadius.pill)),
        child: const Text('NEW', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: CeColors.amberInk)),
      );
}

/// Chip for a challenge's (effective) status.
Widget challengeStatusChip(ChallengeStatus s, ChallengeDirection d) => switch (s) {
      ChallengeStatus.pending => CeStatusChip(
          d == ChallengeDirection.sent ? 'Awaiting reply' : 'New', tone: CeTone.amber, icon: 'hourglass'),
      ChallengeStatus.accepted => const CeStatusChip('Accepted', icon: 'check'),
      ChallengeStatus.declined => const CeStatusChip('Declined', tone: CeTone.red, icon: 'x'),
      ChallengeStatus.expired => const CeStatusChip('Expired', tone: CeTone.neutral, icon: 'timer'),
    };
