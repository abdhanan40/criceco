import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
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
  const _SendButton({required this.club, required this.label, this.listing, this.expand = true});
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
                  date: widget.listing?.startsAt,
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
    // Server challenges: search the opponent directory. Availability slots
    // and "Teams Looking for Opponents" have no server side yet (decision 7).
    if (ref.watch(challengesLiveProvider)) return const OpponentDirectoryView(searchable: true);
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
  const OpponentDirectoryView({super.key, required this.searchable});
  final bool searchable;

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
                  ),
              ],
      ),
    ]);
  }
}
