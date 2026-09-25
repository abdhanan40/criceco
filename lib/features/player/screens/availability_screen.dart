import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../player_providers.dart';

/// Resolves a quick "Unavailable Until" option to a date (prototype
/// `availUntilResolvedDate`). "This Weekend" = the coming Saturday (a week
/// ahead when today is Saturday).
DateTime? resolveUntil(AvailabilityUntil option, DateTime today, DateTime? custom) {
  final d = CeFormat.dateOnly(today);
  final toSaturday = (DateTime.saturday - d.weekday + 7) % 7;
  return switch (option) {
    AvailabilityUntil.today => d,
    AvailabilityUntil.tomorrow => DateTime(d.year, d.month, d.day + 1),
    AvailabilityUntil.weekend => DateTime(d.year, d.month, d.day + (toSaturday == 0 ? 7 : toSaturday)),
    AvailabilityUntil.custom => custom,
  };
}

/// Availability (prototype `screens.availability`, :3673). The committed
/// record lives in [playerAvailabilityProvider]; this screen edits a draft
/// and commits it with "Update Availability".
class AvailabilityScreen extends ConsumerStatefulWidget {
  const AvailabilityScreen({super.key});

  @override
  ConsumerState<AvailabilityScreen> createState() => _AvailabilityScreenState();
}

class _AvailabilityScreenState extends ConsumerState<AvailabilityScreen> {
  final _chooseKey = GlobalKey();
  late PlayerAvailability _status;
  AvailabilityReason? _reason;
  late AvailabilityUntil _until;
  DateTime? _customDate;
  bool _pickerOpen = false;
  late DateTime _pickerMonth;
  late final TextEditingController _notes;
  String? _dateError;

  DateTime get _today => CeFormat.dateOnly(ref.read(clockProvider).now());

  @override
  void initState() {
    super.initState();
    final r = ref.read(playerAvailabilityProvider);
    _status = r.status;
    _reason = r.reason;
    _until = r.until;
    _customDate = r.until == AvailabilityUntil.custom ? r.untilDate : null;
    _pickerMonth = _customDate ?? _today;
    _notes = TextEditingController(text: r.notes);
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  bool get _needsUntil => _status != PlayerAvailability.available;

  void _scrollToChoose() {
    final ctx = _chooseKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: CeMotion.slow, curve: Curves.easeOut, alignment: 0.02);
    }
  }

  Future<void> _toggleListed(bool listed) async {
    await ref.read(playerAvailabilityProvider.notifier).setOpenToOffers(listed);
    if (!mounted) return;
    showCeToast(
      context,
      listed
          ? "You're now listed — other clubs can see you in Available Players"
          : "You're no longer listed as available to other clubs",
    );
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    final untilDate = _needsUntil ? resolveUntil(_until, _today, _customDate) : null;
    if (_needsUntil && untilDate == null) {
      setState(() {
        _dateError = 'Select a date';
        _pickerOpen = true;
      });
      return;
    }
    ref.read(playerAvailabilityProvider.notifier).update(
          status: _status,
          reason: _reason,
          until: _until,
          untilDate: untilDate,
          notes: _notes.text.trim(),
        );
    setState(() => _dateError = null);
    showCeToast(context, 'Availability updated');
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(playerAvailabilityProvider);
    final (curColor, curIcon) = availabilityStyle(record.status);
    final resolved = resolveUntil(_until, _today, _customDate);

    return Scaffold(
      appBar: CeTopBar(
        title: 'Availability',
        onBack: () => context.go(Routes.playerHome),
        actions: [
          IconButton(
            tooltip: 'About availability',
            icon: Icon(CeIcons.of('info'), size: 19),
            onPressed: () => showCeSheet<void>(context, builder: (ctx) => const _AboutAvailability()),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(bottom: 24 + MediaQuery.viewInsetsOf(context).bottom),
          children: [
            // ---- Current status ----
            Container(
              margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: CeColors.mint,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: CeColors.mint2),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: curColor.withValues(alpha: 0.13), shape: BoxShape.circle),
                    child: _StatusDot(color: curColor, icon: curIcon, size: 38),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Current Status',
                          style: TextStyle(fontSize: 11, color: CeColors.muted, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 1),
                      Text(record.status.label,
                          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: curColor)),
                      const SizedBox(height: 3),
                      Text(record.status.description,
                          style: const TextStyle(fontSize: 12, color: Color(0xFF4E5A53))),
                      if (record.reason != null || record.untilDate != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          [
                            if (record.reason != null) record.reason!.label,
                            if (record.untilDate != null) 'Until ${CeFormat.date(record.untilDate!)}',
                          ].join(' · '),
                          style: const TextStyle(fontSize: 11.5, color: Color(0xFF4E5A53), fontWeight: FontWeight.w600),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(children: [
                        Icon(CeIcons.of('calendar'), size: 12, color: CeColors.muted),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text('Since ${CeFormat.date(record.since)}',
                              style: const TextStyle(fontSize: 11, color: CeColors.muted)),
                        ),
                      ]),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                CeButton(label: 'Change Status', icon: CeIcons.of('edit-3'), onPressed: _scrollToChoose),
              ]),
            ),

            CeToggleCard(
              icon: 'circle-dot',
              title: 'Available for Open Matches',
              subtitle: record.openToOffers
                  ? "You're visible in other clubs' Available Players list"
                  : "Turn this on to appear in other clubs' Available Players list",
              value: record.openToOffers,
              onChanged: _toggleListed,
            ),

            // ---- Choose status ----
            _SectionTitle('Choose your Status', key: _chooseKey),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: LayoutBuilder(builder: (context, c) {
                const gap = 8.0;
                final w = (c.maxWidth - gap * 2) / 3;
                return Wrap(spacing: gap, runSpacing: gap, children: [
                  for (final s in PlayerAvailability.values)
                    SizedBox(
                      width: w,
                      child: _StatusCard(
                        status: s,
                        selected: s == _status,
                        onTap: () => setState(() {
                          _status = s;
                          _dateError = null;
                        }),
                      ),
                    ),
                ]);
              }),
            ),

            // Reason / Until only apply when not Available (fix: the prototype
            // showed them for every status).
            if (_needsUntil) ...[
              const _SectionTitle('Reason', optional: true),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                child: CeSelectField<AvailabilityReason>(
                  items: AvailabilityReason.values,
                  value: _reason,
                  labelOf: (r) => r.label,
                  onChanged: (r) => setState(() => _reason = r),
                  sheetTitle: 'Select a reason',
                  hint: 'Select a reason',
                  icon: 'file-text',
                ),
              ),
              const _SectionTitle('Unavailable Until'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                child: LayoutBuilder(builder: (context, c) {
                  final w = (c.maxWidth - 8) / 2;
                  return Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final o in AvailabilityUntil.values)
                      SizedBox(
                        width: w,
                        child: _QuickButton(
                          label: o.label,
                          selected: o == _until,
                          onTap: () => setState(() {
                            _until = o;
                            _dateError = null;
                            _pickerOpen = o == AvailabilityUntil.custom && _customDate == null;
                          }),
                        ),
                      ),
                  ]);
                }),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
                child: Semantics(
                  button: true,
                  label: 'Unavailable until ${resolved == null ? 'not set' : CeFormat.date(resolved)}',
                  excludeSemantics: true,
                  child: Material(
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(CeRadius.md),
                      side: BorderSide(color: _dateError != null ? CeColors.red : CeColors.line2),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(CeRadius.md),
                      onTap: () => setState(() {
                        _pickerOpen = !_pickerOpen;
                        if (_pickerOpen) _pickerMonth = resolved ?? _today;
                      }),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: CeSize.inputMinHeight),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(children: [
                          Icon(CeIcons.of('calendar'), size: 17, color: CeColors.muted),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(resolved == null ? 'Select a date' : CeFormat.date(resolved),
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: resolved == null ? CeColors.muted2 : CeColors.ink)),
                          ),
                          Icon(CeIcons.of(_pickerOpen ? 'chevron-up' : 'chevron-down'),
                              size: 17, color: CeColors.muted),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
              if (_dateError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                  child: CeInlineError(_dateError),
                ),
              if (_pickerOpen)
                CeMonthCalendar(
                  visibleMonth: _pickerMonth,
                  today: _today,
                  selected: resolved,
                  isEnabled: (d) => !d.isBefore(_today),
                  onMonthChanged: (m) => setState(() => _pickerMonth = m),
                  onSelected: (d) => setState(() {
                    _customDate = d;
                    _until = AvailabilityUntil.custom;
                    _pickerOpen = false;
                    _dateError = null;
                  }),
                ),
            ],

            // ---- Notes ----
            const _SectionTitle('Notes', optional: true),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: CeTextField(
                controller: _notes,
                hint: 'Add any notes for your coach…',
                maxLines: 3,
                maxLength: PlayerAvailabilityRecord.notesMaxLength,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
              ),
            ),

            // ---- Tip ----
            Container(
              margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(color: CeColors.amberSoft, borderRadius: BorderRadius.circular(CeRadius.md)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(CeIcons.of('lightbulb'), size: 16, color: CeColors.amber),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'Tip: ', style: TextStyle(fontWeight: FontWeight.w800)),
                      TextSpan(text: 'Keeping your availability updated helps your coach plan better for upcoming matches.'),
                    ]),
                    style: TextStyle(fontSize: 12, color: CeColors.amberInk, height: 1.4),
                  ),
                ),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
              child: CeButton(label: 'Update Availability', icon: CeIcons.of('check'), onPressed: _submit),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {super.key, this.optional = false});
  final String title;
  final bool optional;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 8),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: title),
            if (optional)
              const TextSpan(text: ' (Optional)', style: TextStyle(fontWeight: FontWeight.w500, color: CeColors.muted)),
          ]),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: CeColors.ink),
        ),
      );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, required this.icon, this.size = 32});
  final Color color;
  final String icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(CeIcons.of(icon), size: size * 0.5, color: Colors.white),
      );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.selected, required this.onTap});
  final PlayerAvailability status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = availabilityStyle(status);
    return Semantics(
      button: true,
      selected: selected,
      label: status.label,
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
          child: Stack(children: [
            Container(
              constraints: const BoxConstraints(minHeight: 88),
              padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
              alignment: Alignment.topCenter,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _StatusDot(color: color, icon: icon),
                const SizedBox(height: 6),
                Text(status.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: CeColors.ink2, height: 1.2)),
              ]),
            ),
            if (selected)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 17,
                  height: 17,
                  decoration: const BoxDecoration(color: CeColors.primary, shape: BoxShape.circle),
                  child: Icon(CeIcons.of('check'), size: 11, color: Colors.white),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : CeColors.ink2;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: selected ? CeColors.primaryDark : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.md),
          side: BorderSide(color: selected ? CeColors.primaryDark : CeColors.line2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.md),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(CeIcons.of('calendar'), size: 14, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: fg)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "About availability" sheet (was a toast): what the status does and who
/// sees it.
class _AboutAvailability extends StatelessWidget {
  const _AboutAvailability();

  @override
  Widget build(BuildContext context) {
    Widget point(String icon, String text) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(CeIcons.of(icon), size: 16, color: CeColors.primaryDark),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: CeColors.ink2, height: 1.4))),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('About availability', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      const Text('Set your status so your coach can plan squads around you',
          style: TextStyle(fontSize: 12.5, color: CeColors.muted)),
      point('users', 'Your club sees it when picking the Playing XI; injured or unavailable players can\'t be selected.'),
      point('calendar', 'For any status other than Available, set how long it applies with Unavailable Until.'),
      point('eye', 'Clubs outside yours only see you under Player Hunt when you list yourself and your profile is public.'),
      const SizedBox(height: 18),
      CeButton(label: 'Got it', onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}
