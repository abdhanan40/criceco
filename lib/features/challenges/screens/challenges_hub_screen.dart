import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/config/backend_modules.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/pakistan_time.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';
import '../widgets/challenge_widgets.dart';
import 'my_challenges_screen.dart';

/// "Challenge" / "Send Match Request" button; shows "Challenge Sent" while a
/// sent challenge to that club is still awaiting a reply (no duplicates).
/// Either way nothing is sent before the setup sheet (format, ground, date)
/// is reviewed and confirmed.
class _SendButton extends ConsumerStatefulWidget {
  const _SendButton({required this.club, required this.label, this.listing, this.expand = true, this.date});

  /// The proposed date to prefill (else the listing's start).
  final DateTime? date;
  final ChallengeOpponent club;
  final String label;

  /// Find Opponent listing: a match request, prefilled with its format/date.
  final MatchSeekerListing? listing;

  /// false = a compact inline action sized to its label.
  final bool expand;

  @override
  ConsumerState<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends ConsumerState<_SendButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final waiting = ref.watch(pendingSentClubIdsProvider).contains(widget.club.id);
    if (waiting) {
      return CeButton.soft(
          label: 'Challenge Sent', icon: CeIcons.of('hourglass'), dense: true, expand: widget.expand);
    }
    return CeButton(
      label: widget.label,
      dense: true,
      expand: widget.expand,
      loading: _busy,
      onPressed: _busy
          ? null
          : () async {
              await sendChallenge(context, ref, widget.club,
                  matchRequest: widget.listing != null,
                  format: widget.listing?.format,
                  date: widget.date ?? widget.listing?.startsAt,
                  groundName: widget.listing?.venue,
                  onSending: () => setState(() => _busy = true));
              if (mounted) setState(() => _busy = false);
            },
    );
  }
}

/// Challenges workspace: Challenges (clubs to challenge) | My Challenges |
/// Find Opponent in one screen, the tab in `?tab=` (former three screens;
/// `/club/challenges/mine` and `/find` redirect here).
///
/// Back: from My Challenges / Find Opponent → the Challenges tab (as Back from
/// those screens did); from Challenges → the Club Dashboard. Switching tabs
/// replaces the location, so it adds no history entries.
class ChallengesWorkspace extends StatelessWidget {
  const ChallengesWorkspace({super.key, this.tab = ChallengesSection.challenges});
  final ChallengesSection tab;

  @override
  Widget build(BuildContext context) {
    final home = tab == ChallengesSection.challenges;
    void back() => home ? CeTopBar.goBack(context, Routes.clubHome) : context.go(Routes.challenges);
    return PopScope(
      canPop: home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: Scaffold(
        appBar: CeTopBar(title: 'Challenges', onBack: back),
        body: Column(children: [
          ChallengesTabs(active: tab),
          Expanded(
            child: switch (tab) {
              ChallengesSection.challenges => const ChallengeClubsView(),
              ChallengesSection.mine => const MyChallengesView(),
              ChallengesSection.find => const FindOpponentView(),
            },
          ),
        ]),
      ),
    );
  }
}

/// Challenges tab (prototype `screens.challenges`, :6994): clubs to challenge.
class ChallengeClubsView extends ConsumerWidget {
  const ChallengeClubsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Server challenges: the opponent directory (public fields only).
    if (ref.watch(challengesLiveProvider)) return const OpponentDirectoryView(searchable: false);
    final clubsAsync = ref.watch(challengeableClubsProvider);
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        if (clubsAsync.isLoading)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else
          for (final c in clubsAsync.value ?? const <ClubSummary>[])
            ChallengeCard(
              abbr: c.abbr,
              color: c.color,
              name: c.name,
              meta: Text('${c.meta} · ${c.formats}'),
              trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('W${c.wins}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: CeColors.primary)),
                Text('L${c.losses}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: CeColors.red)),
              ]),
              details: [InlineInfo(icon: 'map-pin', text: c.homeGround)],
              actions: _SendButton(club: ChallengeOpponent.fromSummary(c), label: 'Challenge', expand: false),
              inlineActions: true,
              onTap: () => context.push(Routes.clubProfile(c.id)),
            ),
    ]);
  }
}

/// Find Opponent tab (prototype `screens.findMatch`, :7104): discover clubs
/// and start a match request. Create Availability Slot lives here only.
class FindOpponentView extends ConsumerWidget {
  const FindOpponentView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Server challenges: search the opponent directory. With club discovery
    // (M7, migration 32) the availability slots and "Teams Looking for
    // Opponents" come first; without it they have no server side.
    if (ref.watch(challengesLiveProvider)) {
      if (!ref.watch(discoveryBackendLiveProvider)) return const OpponentDirectoryView(searchable: true);
      return const OpponentDirectoryView(searchable: true, leading: [
        AvailabilitySlotCta(),
        MySlotsList(),
        _LiveSeekers(),
      ]);
    }
    final seekersAsync = ref.watch(matchSeekersProvider);
    final dir = ref.watch(clubDirectoryProvider).value ?? const <String, ClubSummary>{};
    final seekers = [
      for (final s in seekersAsync.value ?? const <MatchSeekerListing>[])
        if (dir[s.clubId] != null) (listing: s, club: dir[s.clubId]!),
    ];
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        const AvailabilitySlotCta(),
        const MySlotsList(),
        // Count derived from the list (fix: prototype said "5 Teams" for 2).
        CeSectionHeader(
          'Teams Looking for Opponents · ${seekers.length} Team${seekers.length == 1 ? '' : 's'}',
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
        ),
        if (seekersAsync.isLoading)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (seekers.isEmpty)
          const CeEmptyState(
            icon: 'search',
            title: 'No teams looking right now',
            body: 'Post an availability slot so clubs can send you requests.',
          )
        else
          for (final e in seekers)
            ChallengeCard(
              abbr: e.club.abbr,
              color: e.club.color,
              name: e.club.name,
              nameTrailing: _FormatTag(e.listing.format.display()),
              meta: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Icon(CeIcons.of('map-pin'), size: 11, color: CeColors.muted),
                Text('${e.club.city} · W${e.club.wins} L${e.club.losses} ·'),
                Icon(CeIcons.of('star'), size: 11, color: CeColors.amber),
                Text(e.listing.rating),
              ]),
              details: [
                InlineInfo(
                    icon: 'calendar',
                    text: '${CeFormat.date(e.listing.startsAt)} · ${CeFormat.time(e.listing.startsAt)}'),
                InlineInfo(icon: 'map-pin', text: e.listing.venue),
              ],
              actions: _SendButton(club: ChallengeOpponent.fromSummary(e.club), label: 'Send Match Request', listing: e.listing),
              onTap: () => context.push(Routes.clubProfile(e.club.id, fromFind: true)),
            ),
    ]);
  }
}

/// Find Opponent with club discovery (M7): other clubs' open slots, soonest
/// first — the club's public name and official record come with the slot.
/// The server stores no rating ("—").
class _LiveSeekers extends ConsumerWidget {
  const _LiveSeekers();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(matchSeekersProvider);
    final dir = ref.watch(clubDirectoryProvider).value ?? const <String, ClubSummary>{};
    final seekers = async.value ?? const <MatchSeekerListing>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CeSectionHeader(
        'Teams Looking for Opponents · ${seekers.length} Team${seekers.length == 1 ? '' : 's'}',
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 20, CeSpace.gutter, 0),
      ),
      if (async.isLoading)
        const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
      else if (async.hasError)
        CeErrorState(
          key: const Key('seekers.error'),
          title: 'Couldn’t load open slots',
          onRetry: () => ref.invalidate(matchSeekersProvider),
        )
      else if (seekers.isEmpty)
        const CeEmptyState(
          key: Key('seekers.empty'),
          icon: 'search',
          title: 'No teams looking right now',
          body: 'Post an availability slot so clubs can send you requests.',
        )
      else
        for (final s in seekers)
          _seekerCard(context, s, ChallengeOpponent.forSeeker(s, dir[s.clubId])),
    ]);
  }

  Widget _seekerCard(BuildContext context, MatchSeekerListing s, ChallengeOpponent club) {
    final at = s.startsAt.inPakistan;
    return ChallengeCard(
      key: Key('seeker.${s.slotId ?? s.clubId}'),
      abbr: club.abbr,
      color: opponentColor(club),
      name: club.name,
      nameTrailing: _FormatTag(s.format.display(s.customOvers)),
      meta: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Icon(CeIcons.of('map-pin'), size: 11, color: CeColors.muted),
        Text('${s.clubCity ?? club.city ?? ''} · W${s.clubWins} L${s.clubLosses} ·'),
        Icon(CeIcons.of('star'), size: 11, color: CeColors.amber),
        Text(s.rating),
      ]),
      details: [
        InlineInfo(icon: 'calendar', text: '${CeFormat.date(at)} · ${CeFormat.time(at)}'),
        InlineInfo(icon: 'map-pin', text: s.venue),
        if (s.notes.isNotEmpty) InlineInfo(icon: 'file-text', text: s.notes, maxLines: 2),
      ],
      actions: _SendButton(
        club: club,
        label: 'Send Match Request',
        listing: s,
        // The slot's day in Pakistan (the server's calendar).
        date: PakistanTime.dateOf(s.startsAt),
      ),
      onTap: () => context.push(Routes.clubProfile(s.clubId, fromFind: true)),
    );
  }
}

class _FormatTag extends StatelessWidget {
  const _FormatTag(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.xs)),
        child: Text(label, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
      );
}

/// How long the opponent search waits after the last keystroke.
const kOpponentSearchDebounce = Duration(milliseconds: 250);

/// Server challenges: other clubs from the opponent directory (migration
/// 17) — name, short name, city and type only; no records, ratings or
/// statistics (none are stored). [searchable]: a name search and a city
/// filter (Find Opponent); otherwise the first clubs listed (Challenges).
class OpponentDirectoryView extends ConsumerStatefulWidget {
  const OpponentDirectoryView({super.key, required this.searchable, this.leading = const []});
  final bool searchable;

  /// Shown above the search (Find Opponent with club discovery: the slots
  /// and the clubs looking for opponents).
  final List<Widget> leading;

  @override
  ConsumerState<OpponentDirectoryView> createState() => _OpponentDirectoryViewState();
}

class _OpponentDirectoryViewState extends ConsumerState<OpponentDirectoryView> {
  final _search = TextEditingController();
  final _city = TextEditingController();
  Timer? _debounce;
  OpponentQuery _query = (search: '', city: '');

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _city.dispose();
    super.dispose();
  }

  /// A keystroke: search once typing pauses (one request per settled query).
  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(kOpponentSearchDebounce, () {
      final next = (search: _search.text.trim(), city: _city.text.trim());
      if (mounted && next != _query) setState(() => _query = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(opponentDirectoryProvider(_query));
    final filtered = _query.search.isNotEmpty || _query.city.isNotEmpty;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      ...widget.leading,
      if (widget.searchable)
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: Column(children: [
            CeTextField(
              fieldKey: const Key('opponents.search'),
              controller: _search,
              hint: 'Search clubs by name',
              icon: 'search',
              textInputAction: TextInputAction.search,
              onChanged: _changed,
            ),
            const SizedBox(height: 8),
            CeTextField(
              fieldKey: const Key('opponents.city'),
              controller: _city,
              hint: 'City (optional)',
              icon: 'map-pin',
              textCapitalization: TextCapitalization.words,
              onChanged: _changed,
            ),
          ]),
        ),
      CeSectionHeader(
        widget.searchable ? 'Clubs' : 'Clubs to Challenge',
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
      ),
      ...async.when(
        skipLoadingOnReload: false,
        loading: () => const [
          Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        ],
        error: (_, _) => [
          CeErrorState(
            key: const Key('opponents.error'),
            title: 'Couldn\'t load clubs',
            onRetry: () => ref.invalidate(opponentDirectoryProvider(_query)),
          ),
        ],
        data: (clubs) => clubs.isEmpty
            ? [
                CeEmptyState(
                  key: const Key('opponents.empty'),
                  icon: 'search',
                  title: filtered ? 'No clubs found' : 'No other clubs yet',
                  body: filtered
                      ? 'Try another name, or clear the city.'
                      : 'Clubs appear here once other owners create them on CricEco.',
                ),
              ]
            : [
                for (final c in clubs)
                  ChallengeCard(
                    key: Key('opponent.${c.id}'),
                    abbr: c.abbr,
                    color: opponentColor(c),
                    name: c.name,
                    meta: Text(c.meta),
                    actions: _SendButton(club: c, label: 'Challenge', expand: false),
                    inlineActions: true,
                    // A known club profile opens (M7: every listed club).
                    onTap: c.summary == null ? null : () => context.push(Routes.clubProfile(c.id, fromFind: widget.searchable)),
                  ),
              ],
      ),
    ]);
  }
}
