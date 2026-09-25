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
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';
import '../widgets/challenge_widgets.dart';

/// "Challenge" / "Send Match Request" button; shows "Challenge Sent" while a
/// sent challenge to that club is still awaiting a reply (no duplicates).
class _SendButton extends ConsumerStatefulWidget {
  const _SendButton({required this.club, required this.label, this.format});
  final ClubSummary club;
  final String label;
  final MatchFormat? format;

  @override
  ConsumerState<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends ConsumerState<_SendButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final waiting = ref.watch(pendingSentClubIdsProvider).contains(widget.club.id);
    if (waiting) {
      return CeButton.soft(label: 'Challenge Sent', icon: CeIcons.of('hourglass'));
    }
    return CeButton(
      label: widget.label,
      loading: _busy,
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              await sendChallenge(context, ref, widget.club, format: widget.format);
              if (mounted) setState(() => _busy = false);
            },
    );
  }
}

/// Challenges hub (prototype `screens.challenges`, :6994).
class ChallengesHubScreen extends ConsumerWidget {
  const ChallengesHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubsAsync = ref.watch(challengeableClubsProvider);
    return Scaffold(
      appBar: const CeTopBar(title: 'Challenges', fallbackLocation: Routes.clubHome),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        const ChallengesTabs(active: ChallengesSection.challenges),
        const AvailabilitySlotCta(),
        const MySlotsList(),
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
              actions: _SendButton(club: c, label: 'Challenge'),
              onTap: () => context.push(Routes.clubProfile(c.id)),
            ),
      ]),
    );
  }
}

/// Find a Match (prototype `screens.findMatch`, :7104).
class FindMatchScreen extends ConsumerWidget {
  const FindMatchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seekersAsync = ref.watch(matchSeekersProvider);
    final dir = ref.watch(clubDirectoryProvider).value ?? const <String, ClubSummary>{};
    final seekers = [
      for (final s in seekersAsync.value ?? const <MatchSeekerListing>[])
        if (dir[s.clubId] != null) (listing: s, club: dir[s.clubId]!),
    ];
    return Scaffold(
      appBar: const CeTopBar(title: 'Find a Match', fallbackLocation: Routes.challenges),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        const ChallengesTabs(active: ChallengesSection.find),
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
              actions: _SendButton(club: e.club, label: 'Send Match Request', format: e.listing.format),
              onTap: () => context.push(Routes.clubProfile(e.club.id)),
            ),
      ]),
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
