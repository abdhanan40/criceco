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
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
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
      appBar: CeTopBar(title: 'Open Matches', onBack: () => context.go(Routes.playerHome)),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
              child: Text("Clubs looking for players — tap a slot to let them know you're interested.",
                  style: TextStyle(fontSize: 12, color: CeColors.muted, height: 1.4)),
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
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 4),
              child: Text(
                role == null
                    ? 'Select a role above to see open requests'
                    : '${visible.length} open request${visible.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: CeColors.muted, fontWeight: FontWeight.w600),
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
    final roleWord = '${p.role.label}${p.playersNeeded > 1 ? 's' : ''}';
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.lg),
        border: Border.all(color: const Color(0xFFF1F5F2)),
        boxShadow: const [BoxShadow(color: Color(0x0F1B4332), blurRadius: 10, offset: Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CeTeamBadge(p.clubAbbr, color: clubBadgeColor(p.clubAbbr), size: 42),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.clubName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, height: 1.25)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(CeIcons.of('map-pin'), size: 11, color: CeColors.muted),
                const SizedBox(width: 3),
                Flexible(
                  child: Text('${p.location ?? 'Any location'} · ${p.format.display()}',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: CeColors.muted)),
                ),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          const CeStatusChip('Open'),
        ]),
        const SizedBox(height: 11),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CeIcons.of(_roleIcons[p.role] ?? 'target'), size: 13, color: CeColors.primaryDark),
              const SizedBox(width: 6),
              Flexible(
                child: Text('${p.playersNeeded} $roleWord needed',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
              ),
            ]),
          ),
        ),
        const Padding(padding: EdgeInsets.only(top: 11), child: Divider(height: 1, color: Color(0xFFF1F5F2))),
        const SizedBox(height: 11),
        Wrap(spacing: 14, runSpacing: 6, children: [
          _Info(icon: 'calendar', text: p.date == null ? 'Flexible' : CeFormat.date(p.date!)),
          _Info(icon: 'clock', text: p.time == null ? 'Anytime' : _niceTime(p.time!)),
          _Info(icon: 'banknote', text: p.budget == HuntBudget.any ? 'Any budget' : p.budget.label),
        ]),
        if (p.notes.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 9),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(color: CeColors.bg, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(CeIcons.of('file-text'), size: 13, color: const Color(0xFF4E5A53)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(p.notes, style: const TextStyle(fontSize: 11.5, color: Color(0xFF4E5A53), height: 1.4)),
              ),
            ]),
          ),
        const SizedBox(height: 12),
        if (interested)
          CeButton.soft(label: 'Interest Sent', icon: CeIcons.of('check'))
        else
          CeButton(label: "I'm Interested", onPressed: onInterested),
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
        Icon(CeIcons.of(icon), size: 12, color: CeColors.ink2),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: CeColors.ink2)),
      ]);
}
