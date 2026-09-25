import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/constants/cities.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../club/club_providers.dart';
import '../booking_controller.dart';
import '../widgets/booking_widgets.dart';

/// A booking draft must exist before any setup step (deep links, restarts).
void ensureBooking(WidgetRef ref, BookingContext c) {
  if (c.booking != null && c.booking!.status != BookingStatus.expired && c.booking!.status != BookingStatus.resolved) {
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(bookingsProvider.notifier).start(c.match));
}

// ---------------------------------------------------------------------------
// 1 · Match Setup (prototype `screens.matchSetup`, :6187)
// ---------------------------------------------------------------------------

class MatchSetupScreen extends ConsumerStatefulWidget {
  const MatchSetupScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<MatchSetupScreen> createState() => _MatchSetupScreenState();
}

class _MatchSetupScreenState extends ConsumerState<MatchSetupScreen> {
  static const maxOvers = 50;
  final _overs = TextEditingController();
  final _errors = <String, String>{};
  bool _seeded = false;

  @override
  void dispose() {
    _overs.dispose();
    super.dispose();
  }

  void _continue(BookingContext c) {
    final d = c.booking?.draft ?? const BookingDraft();
    final overs = int.tryParse(_overs.text);
    setState(() {
      _errors.clear();
      if (d.format == null) _errors['format'] = 'Please select a format';
      if (d.format == MatchFormat.custom && (overs == null || overs < 1 || overs > maxOvers)) {
        _errors['overs'] = overs == null ? 'Please enter the number of overs' : 'Enter between 1 and $maxOvers overs';
      }
      if (d.city == null) _errors['city'] = 'Please select a city';
    });
    if (_errors.isNotEmpty) return;
    if (d.format == MatchFormat.custom) {
      ref.read(bookingsProvider.notifier).updateDraft(widget.matchId, (x) => x.copyWith(customOvers: overs));
    }
    context.go(Routes.bookGround(widget.matchId));
  }

  @override
  Widget build(BuildContext context) => BookingScaffold(
        matchId: widget.matchId,
        title: 'Match Setup',
        builder: (context, c) {
          ensureBooking(ref, c);
          final d = c.booking?.draft ?? const BookingDraft();
          if (!_seeded && d.customOvers != null) {
            _overs.text = '${d.customOvers}';
            _seeded = true;
          }
          void update(BookingDraft Function(BookingDraft) f) =>
              ref.read(bookingsProvider.notifier).updateDraft(widget.matchId, f);

          return GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            behavior: HitTestBehavior.translucent,
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(bottom: 24 + MediaQuery.viewInsetsOf(context).bottom),
              children: [
                const WorkflowProgress(step: 1),
                BookingHeaderCard(
                  leading: opponentBadge(c.opponent),
                  title: 'vs ${c.opponent.name}',
                  meta: '${c.opponent.city} · Setting up your match',
                ),
                const CeSectionHeader('Format', padding: EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 8)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final f in MatchFormat.standard)
                      _FormatTile(
                        format: f,
                        selected: d.format == f,
                        onTap: () {
                          update((x) => x.copyWith(format: f));
                          setState(() => _errors.remove('format'));
                        },
                      ),
                    CeInlineError(_errors['format']),
                    if (d.format == MatchFormat.custom) ...[
                      const SizedBox(height: 4),
                      CeTextField(
                        fieldKey: const Key('setup.overs'),
                        controller: _overs,
                        hint: 'Number of overs (e.g. 15)',
                        icon: 'hash',
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                        onChanged: (_) => setState(() => _errors.remove('overs')),
                      ),
                      CeInlineError(_errors['overs']),
                    ],
                  ]),
                ),
                const CeSectionHeader('Preferred City',
                    padding: EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 8)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    CeSelectField<String>(
                      fieldKey: const Key('setup.city'),
                      items: kPakistanCities,
                      value: d.city,
                      labelOf: (x) => x,
                      onChanged: (x) {
                        update((d) => d.copyWith(city: x));
                        setState(() => _errors.remove('city'));
                      },
                      sheetTitle: 'Preferred City',
                      hint: 'Select city',
                      icon: 'building-2',
                      itemIcon: 'building-2',
                    ),
                    CeInlineError(_errors['city']),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
                  child: CeButton(label: 'Continue', trailingIcon: CeIcons.of('arrow-right'), onPressed: () => _continue(c)),
                ),
              ],
            ),
          );
        },
      );
}

class _FormatTile extends StatelessWidget {
  const _FormatTile({required this.format, required this.selected, required this.onTap});
  final MatchFormat format;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : CeColors.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: format == MatchFormat.custom ? 'Custom Overs' : format.label,
        excludeSemantics: true,
        child: Material(
          color: selected ? CeColors.primaryDark : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.md),
            side: BorderSide(color: selected ? CeColors.primaryDark : CeColors.line),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.md),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Icon(CeIcons.of(formatIcon(format)), size: 17, color: fg),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: format == MatchFormat.custom ? 'Custom Overs' : format.label,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      TextSpan(
                          text: ' — ${formatBlurb(format)}',
                          style: TextStyle(fontWeight: FontWeight.w500, color: fg.withValues(alpha: 0.75))),
                    ]),
                    style: TextStyle(fontSize: 13, color: fg),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2 · Book a Ground (prototype `screens.bookGround`, :6264)
// ---------------------------------------------------------------------------

class BookGroundScreen extends ConsumerStatefulWidget {
  const BookGroundScreen({super.key, required this.matchId});
  final String matchId;

  @override
  ConsumerState<BookGroundScreen> createState() => _BookGroundScreenState();
}

class _BookGroundScreenState extends ConsumerState<BookGroundScreen> {
  String? _error;

  @override
  Widget build(BuildContext context) => BookingScaffold(
        matchId: widget.matchId,
        title: 'Book a Ground',
        builder: (context, c) {
          ensureBooking(ref, c);
          final d = c.booking?.draft ?? const BookingDraft();
          final all = (ref.watch(groundDirectoryProvider).value ?? const <String, Ground>{}).values.toList();
          final inCity = all.where((g) => g.city == d.city).toList();
          final sorted = [...inCity, ...all.where((g) => g.city != d.city)];
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            const WorkflowProgress(step: 2),
            Container(
              margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.md)),
              child: Row(children: [
                Icon(CeIcons.of('map-pin'), size: 14, color: CeColors.primaryDark),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      const TextSpan(text: 'Showing grounds for '),
                      TextSpan(text: d.city ?? 'your city', style: const TextStyle(fontWeight: FontWeight.w800)),
                      if (d.format != null) TextSpan(text: ' · ${d.format!.display(d.customOvers)}'),
                    ]),
                    style: const TextStyle(fontSize: 12.5, color: CeColors.primaryDark),
                  ),
                ),
              ]),
            ),
            if (inCity.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
                child: Text('No grounds listed in ${d.city ?? 'this city'} yet — showing nearby options.',
                    style: const TextStyle(fontSize: 12, color: CeColors.muted)),
              ),
            for (final g in sorted)
              _GroundCard(
                ground: g,
                selected: d.groundId == g.id,
                onTap: () {
                  ref.read(bookingsProvider.notifier).updateDraft(widget.matchId, (x) => x.copyWith(groundId: g.id));
                  setState(() => _error = null);
                },
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                child: CeInlineError(_error),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
              child: CeButton(
                label: 'Continue',
                trailingIcon: CeIcons.of('arrow-right'),
                onPressed: () {
                  if (d.groundId == null) {
                    setState(() => _error = 'Please select a ground');
                    return;
                  }
                  context.go(Routes.groundDetails(widget.matchId, d.groundId!));
                },
              ),
            ),
          ]);
        },
      );
}

class _GroundCard extends StatelessWidget {
  const _GroundCard({required this.ground, required this.selected, required this.onTap});
  final Ground ground;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Semantics(
          button: true,
          selected: selected,
          label: '${ground.name}, ${ground.city}',
          excludeSemantics: true,
          child: Material(
            color: selected ? CeColors.mint : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CeRadius.lg),
              side: BorderSide(color: selected ? CeColors.primary : CeColors.line, width: selected ? 1.6 : 1),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(CeRadius.lg),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  const GroundThumb(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(ground.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                      const SizedBox(height: 2),
                      Row(children: [
                        Flexible(
                          child: Text('${ground.city} · ',
                              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                        ),
                        Icon(CeIcons.of('star'), size: 12, color: CeColors.amber),
                        Text(' ${ground.rating}', style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                      ]),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  // Capped so narrow phones keep room for the ground's name and rating.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 96),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text('${CeFormat.rupees(ground.pricePerHour)} / hr',
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// 3 · Ground Details (prototype `screens.groundDetails`, :6296)
// ---------------------------------------------------------------------------

const _photoGradients = [
  [Color(0xFF105C38), Color(0xFF28A85F)],
  [Color(0xFF0B3324), Color(0xFF105C38)],
  [Color(0xFF28A85F), Color(0xFF7FCFA6)],
  [Color(0xFF07261B), Color(0xFF0B3324)],
  [Color(0xFF28A85F), Color(0xFF105C38)],
];

const _amenityIcons = {
  'Floodlights': 'lightbulb',
  'Parking': 'car',
  'Change Rooms': 'droplets',
  'Scoreboard': 'bar-chart',
  'Tuck Shop': 'store',
  'Washrooms': 'users',
  'Cafeteria': 'coffee',
};

class GroundDetailsScreen extends ConsumerStatefulWidget {
  const GroundDetailsScreen({super.key, required this.matchId, required this.groundId});
  final String matchId;
  final String groundId;

  @override
  ConsumerState<GroundDetailsScreen> createState() => _GroundDetailsScreenState();
}

class _GroundDetailsScreenState extends ConsumerState<GroundDetailsScreen> {
  final _pages = PageController();
  int _photo = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goPhoto(int i) {
    final n = (i + _photoGradients.length) % _photoGradients.length;
    _pages.animateToPage(n, duration: CeMotion.slow, curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) => BookingScaffold(
        matchId: widget.matchId,
        title: 'Ground Details',
        builder: (context, c) {
          ensureBooking(ref, c);
          final g = ref.watch(groundDirectoryProvider).value?[widget.groundId];
          if (g == null) {
            return CeEmptyState(
              icon: 'flag',
              title: 'Ground not found',
              body: 'Pick another ground.',
              primaryLabel: 'Back to grounds',
              onPrimary: () => context.go(Routes.bookGround(widget.matchId)),
            );
          }
          // Keep the draft on this ground (deep link or changed choice).
          if (c.booking != null && c.booking!.draft.groundId != g.id) {
            WidgetsBinding.instance.addPostFrameCallback((_) => ref
                .read(bookingsProvider.notifier)
                .updateDraft(widget.matchId, (x) => x.copyWith(groundId: g.id, clearSlot: true)));
          }
          final today = CeFormat.dateOnly(ref.read(clockProvider).now());
          final fullToday = ref.read(groundRepositoryProvider).dayAvailability(g.id, today) == DayAvailability.full;
          final query = '${g.name}, ${g.address}';

          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            // ---- Photo carousel ----
            SizedBox(
              height: 190,
              child: Stack(children: [
                PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _photo = i),
                  children: [
                    for (final colors in _photoGradients)
                      DecoratedBox(
                        decoration: BoxDecoration(gradient: LinearGradient(colors: colors)),
                        child: Center(child: Icon(CeIcons.of('flag'), size: 46, color: Colors.white.withValues(alpha: 0.85))),
                      ),
                  ],
                ),
                Positioned(
                  top: 10,
                  right: 12,
                  child: _Glass(child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CeIcons.of('star'), size: 12, color: Colors.white),
                    const SizedBox(width: 4),
                    Text('${g.rating} (${g.reviews})',
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
                  ])),
                ),
                Positioned(
                  left: 6,
                  top: 70,
                  child: IconButton(
                    tooltip: 'Previous photo',
                    onPressed: () => _goPhoto(_photo - 1),
                    icon: Icon(CeIcons.of('chevron-left'), color: Colors.white),
                  ),
                ),
                Positioned(
                  right: 6,
                  top: 70,
                  child: IconButton(
                    tooltip: 'Next photo',
                    onPressed: () => _goPhoto(_photo + 1),
                    icon: Icon(CeIcons.of('chevron-right'), color: Colors.white),
                  ),
                ),
                Positioned(
                  left: 12,
                  bottom: 10,
                  child: _Glass(child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CeIcons.of('camera'), size: 12, color: Colors.white),
                    const SizedBox(width: 4),
                    Text('${_photo + 1}/${_photoGradients.length}',
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
                  ])),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (var i = 0; i < _photoGradients.length; i++)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: i == _photo ? 16 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: i == _photo ? 1 : 0.5),
                          borderRadius: BorderRadius.circular(CeRadius.pill),
                        ),
                      ),
                  ]),
                ),
              ]),
            ),
            const WorkflowProgress(step: 3),

            // ---- Header ----
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${CeFormat.rupees(g.pricePerHour)} / hr',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: CeColors.primary)),
                const SizedBox(height: 2),
                Text(g.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: CeColors.ink)),
                const SizedBox(height: 4),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(CeIcons.of('map-pin'), size: 13, color: CeColors.muted),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('${g.city} · ${g.address}', style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
                  ),
                ]),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: fullToday ? CeColors.redSoft : CeColors.mint,
                    borderRadius: BorderRadius.circular(CeRadius.pill),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CeIcons.of(fullToday ? 'x' : 'check'), size: 12,
                        color: fullToday ? CeColors.red : CeColors.primaryDark),
                    const SizedBox(width: 4),
                    Text(fullToday ? 'Fully booked today' : 'Available Today',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: fullToday ? CeColors.red : CeColors.primaryDark)),
                  ]),
                ),
              ]),
            ),

            // ---- Location ----
            const CeSectionHeader('Location'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(CeRadius.lg),
                  side: const BorderSide(color: CeColors.line),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => openDirections(context, query),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      height: 110,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(colors: [CeColors.mint, CeColors.mint2]),
                      ),
                      child: Stack(children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: const BoxDecoration(color: CeColors.primaryDark, shape: BoxShape.circle),
                            child: Icon(CeIcons.of('flag'), size: 18, color: Colors.white),
                          ),
                        ),
                        Positioned(
                          left: 10,
                          top: 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(CeRadius.sm)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(CeIcons.of('map-pin'), size: 11, color: CeColors.primaryDark),
                              const SizedBox(width: 4),
                              const Text('Google Maps',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
                              const SizedBox(width: 2),
                              Icon(CeIcons.of('arrow-up-right'), size: 11, color: CeColors.primaryDark),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const CeIconWell('map-pin', size: 34, iconSize: 16),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(g.address, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: CeColors.ink)),
                            Text('${g.city}, Pakistan', style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                          ]),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
              child: CeButton.soft(
                label: 'View Location on Google Maps',
                icon: CeIcons.of('map-pin'),
                onPressed: () => openDirections(context, query),
              ),
            ),

            // ---- Specifications ----
            const CeSectionHeader('Ground Specifications'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: Row(children: [
                for (final (i, (v, l, l2)) in [
                  (g.specs.boundary, 'Boundary', 'Length'),
                  (g.specs.radius, 'Radius', 'Outfield'),
                  (g.specs.nets, 'Nets', 'Practice'),
                ].indexed) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                      decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
                      child: Column(children: [
                        Text(v, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
                        Text(l, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: CeColors.ink2)),
                        Text(l2, style: const TextStyle(fontSize: 10, color: CeColors.muted)),
                      ]),
                    ),
                  ),
                ],
              ]),
            ),

            // ---- Amenities ----
            const CeSectionHeader('Amenities'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final a in g.amenities)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(CeRadius.pill),
                      border: Border.all(color: CeColors.line),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(CeIcons.of(_amenityIcons[a] ?? 'check'), size: 13, color: CeColors.primaryDark),
                      const SizedBox(width: 5),
                      Text(a, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.ink2)),
                    ]),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 22, CeSpace.gutter, 0),
              child: CeButton(
                label: 'Continue · Pick a Date',
                trailingIcon: CeIcons.of('arrow-right'),
                onPressed: () => context.go(Routes.selectDate(widget.matchId, g.id)),
              ),
            ),
          ]);
        },
      );
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(CeRadius.pill),
        ),
        child: child,
      );
}
