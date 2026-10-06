import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../player_providers.dart';

const _roleIcons = {
  HuntRole.batsman: 'circle-dot',
  HuntRole.bowler: 'radio',
  HuntRole.allRounder: 'footprints',
  HuntRole.wicketKeeper: 'hand',
};

/// "14:00" → "2:00 PM"; unparsable values are shown as-is.
String _niceTime(String raw) {
  final parts = raw.split(':');
  final h = int.tryParse(parts.first);
  final m = parts.length > 1 ? int.tryParse(parts[1]) : 0;
  if (h == null || m == null) return raw;
  return CeFormat.time(DateTime(2000, 1, 1, h, m));
}

/// Open Matches (prototype `screens.openMatches`, :3528): clubs' player
/// requests, filtered by role and ranked search.
class OpenMatchesScreen extends ConsumerStatefulWidget {
  const OpenMatchesScreen({super.key});

  @override
  ConsumerState<OpenMatchesScreen> createState() => _OpenMatchesScreenState();
}

class _OpenMatchesScreenState extends ConsumerState<OpenMatchesScreen> {
  late final _search = TextEditingController(text: ref.read(openMatchesQueryProvider));

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(openMatchesRoleProvider);
    final query = ref.watch(openMatchesQueryProvider);
    final listed = ref.watch(playerAvailabilityProvider.select((a) => a.openToOffers));
    final loading = ref.watch(huntPostsProvider).isLoading;
    final visible = ref.watch(visibleHuntPostsProvider);
    final interest = ref.watch(huntInterestProvider);

    Widget empty() {
      if (role == null) {
        return const CeEmptyState(
          icon: 'circle-dot',
          title: 'Choose a role to get started',
          body: 'Tap Batsman, Bowler, All-Rounder or Wicket-Keeper above to browse requests for that role.',
        );
      }
      return CeEmptyState(
        icon: 'circle-dot',
        title: 'No open requests',
        body: query.trim().isNotEmpty
            ? 'No results for "${query.trim()}".'
            : "Clubs haven't posted any ${role.label} requests right now.",
      );
    }

    return Scaffold(
      appBar: CeTopBar(title: 'Playing Opportunities', onBack: () => context.go(Routes.playerHome)),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 4, CeSpace.gutter, 0),
              child: Text("Clubs looking for players — tap a slot to let them know you're interested.",
                  style: CeType.body.copyWith(color: CeColors.muted)),
            ),
            CeToggleCard(
              icon: 'users',
              title: 'List me as available to other clubs',
              subtitle: listed
                  ? "You're visible in every club's Available Players list"
                  : "Turn this on to appear in other clubs' Available Players list",
              value: listed,
              onChanged: _toggleListed,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
              child: CeSearchField(
                hint: 'Search by club or location…',
                controller: _search,
                onChanged: ref.read(openMatchesQueryProvider.notifier).select,
              ),
            ),
            CeChipRow<HuntRole?>(
              values: const [null, ...HuntRole.values],
              selected: role,
              labelOf: (r) => r?.label ?? 'All',
              onSelected: ref.read(openMatchesRoleProvider.notifier).select,
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 2),
              child: Text(
                role == null
                    ? 'Select a role above to see open requests'
                    : '${visible.length} open request${visible.length == 1 ? '' : 's'}',
                style: CeType.sectionTitle,
              ),
            ),
            if (loading)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
            else if (visible.isEmpty)
              empty()
            else
              for (final p in visible)
                _HuntCard(
                  post: p,
                  interested: interest.contains(p.id),
                  onInterested: () {
                    ref.read(huntInterestProvider.notifier).express(p.id);
                    showCeToast(context, "You're on the list — the club will be notified");
                  },
                ),
          ],
        ),
      ),
    );
  }
}

class _HuntCard extends StatelessWidget {
  const _HuntCard({required this.post, required this.interested, required this.onInterested});
  final PlayerHuntPost post;
  final bool interested;
  final VoidCallback onInterested;

  @override
  Widget build(BuildContext context) {
    final p = post;
    final roleWord = p.role.countLabel(p.playersNeeded);
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
      padding: const EdgeInsets.all(CeSpace.card),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.card),
        border: Border.all(color: CeColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CeTeamBadge(p.clubAbbr, color: clubBadgeColor(p.clubAbbr), size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.clubName, maxLines: 2, overflow: TextOverflow.ellipsis, style: CeType.listTitle.copyWith(fontSize: 14.5)),
              const SizedBox(height: 3),
              Row(children: [
                Icon(CeIcons.of('map-pin'), size: 12, color: CeColors.muted),
                const SizedBox(width: 3),
                Flexible(
                  child: Text('${p.location ?? 'Any location'} · ${p.format.display()}',
                      overflow: TextOverflow.ellipsis, style: CeType.bodySmall.copyWith(fontSize: 12)),
                ),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          const CeStatusChip('Open'),
        ]),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.xs)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CeIcons.of(_roleIcons[p.role] ?? 'target'), size: 13, color: CeColors.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text('${p.playersNeeded} $roleWord needed',
                    style: CeType.chip.copyWith(fontSize: 12, color: CeColors.primary)),
              ),
            ]),
          ),
        ),
        const CeDashedDivider(padding: EdgeInsets.symmetric(vertical: 12)),
        Wrap(spacing: 14, runSpacing: 6, children: [
          _Info(icon: 'calendar', text: p.date == null ? 'Flexible' : CeFormat.date(p.date!)),
          _Info(icon: 'clock', text: p.time == null ? 'Anytime' : _niceTime(p.time!)),
          _Info(icon: 'banknote', text: p.budget == HuntBudget.any ? 'Any budget' : p.budget.label),
        ]),
        if (p.notes.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: CeColors.bg, borderRadius: BorderRadius.circular(CeRadius.md)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(CeIcons.of('file-text'), size: 13, color: CeColors.inkSoft),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(p.notes, style: CeType.bodySmall.copyWith(fontSize: 12, color: CeColors.ink2)),
              ),
            ]),
          ),
        const SizedBox(height: 12),
        if (interested)
          CeButton.soft(label: 'Interest Sent', icon: CeIcons.of('check'), dense: true)
        else
          CeButton(label: "I'm Interested", onPressed: onInterested, dense: true),
      ]),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.text});
  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 13, color: CeColors.primary),
        const SizedBox(width: 5),
        Text(text, style: CeType.caption.copyWith(fontSize: 12, color: CeColors.ink2)),
      ]);
}
