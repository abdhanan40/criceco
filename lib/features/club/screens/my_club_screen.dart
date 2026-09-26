import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../club_providers.dart';
import '../teams/teams_controller.dart';
import 'members_screen.dart' show MemberRow;

/// My Club — the Club Owner's Profile tab (prototype `screens.myClub`, :3449;
/// approved P7 label "Profile", P14 "Teammates" → "Members").
class MyClubScreen extends ConsumerWidget {
  const MyClubScreen({super.key});

  static const _previewCount = 8; // prototype shows the first 8 members

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final club = ref.watch(currentClubProvider);
    final membersAsync = ref.watch(clubMembersProvider);
    final members = membersAsync.value ?? const <ClubMember>[];
    final teams = ref.watch(teamsProvider).value?.length;
    final upcoming = ref.watch(upcomingClubMatchesProvider).length;
    final white = Colors.white.withValues(alpha: 0.85);

    return Scaffold(
      appBar: CeTopBar(title: 'My Club', onBack: () => context.go(Routes.clubHome)),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        // Reference profile structure: identity → stats row → list.
        CeBrandHero(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          radius: CeRadius.lg,
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.lg)),
              child: Icon(CeIcons.of('shield'), size: 26, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(club?.name ?? 'My Club',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(height: 2),
                Text('Club ${club?.code ?? ''} · ${club?.city ?? ''}', style: TextStyle(fontSize: 12.5, color: white)),
                if (club?.establishedYear != null) ...[
                  const SizedBox(height: 2),
                  Text('Established ${club!.establishedYear}',
                      style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.75))),
                ],
              ]),
            ),
          ]),
        ),
        CeStatGroup(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
          cells: [
            CeStatCell(
              label: 'Members',
              value: membersAsync.hasValue ? '${members.length}' : '–',
              onTap: () => context.go(Routes.members),
            ),
            CeStatCell(
              label: 'Teams',
              value: teams == null ? '–' : '$teams',
              onTap: () => context.go(Routes.teams),
            ),
            CeStatCell(
              label: 'Upcoming',
              value: '$upcoming',
              onTap: () => context.go(Routes.matchManagement(MatchTab.scheduled)),
            ),
          ],
        ),
        // The preview shows the first 8; "View All" opens the full list.
        CeSectionHeader(
          'Members',
          actionLabel: members.length > _previewCount ? 'View All (${members.length})' : 'View All',
          onAction: () => context.go(Routes.members),
        ),
        if (membersAsync.isLoading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (membersAsync.hasError)
          CeErrorState(title: 'Couldn\'t load members', onRetry: () => ref.invalidate(clubMembersProvider))
        else if (members.isEmpty)
          const CeEmptyState(
            icon: 'users',
            title: 'No members listed yet',
            body: 'Share your club code so players can request to join.',
          )
        else
          for (final m in members.take(_previewCount)) MemberRow(member: m, compact: true),
      ]),
    );
  }
}
