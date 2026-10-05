import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/media/photo_picker.dart';
import '../../../shared/widgets/ce_dashboard_hero.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_quick_actions.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../matches/club_matches_controller.dart';
import '../../notifications/notifications_controller.dart';
import '../announcements/announcements.dart';
import '../club_providers.dart';
import '../requests/join_requests_controller.dart';
import '../teams/teams_controller.dart';
import '../widgets/club_insights.dart';

/// Club Owner Dashboard (prototype `screens.clubHome`, :4199).
class ClubDashboardScreen extends ConsumerWidget {
  const ClubDashboardScreen({super.key});

  Future<void> _shareCode(BuildContext context, String code) async {
    // Fix (approved list): "Share with players" really copies the code.
    await Clipboard.setData(ClipboardData(text: code));
    if (context.mounted) showCeToast(context, 'Club code copied!');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final club = ref.watch(currentClubProvider);
    final members = ref.watch(clubMembersProvider).value?.length;
    final teams = ref.watch(teamsProvider).value?.length;
    final requests = ref.watch(pendingJoinRequestCountProvider);
    final next = ref.watch(nextClubMatchProvider);
    final upcoming = ref.watch(upcomingClubMatchesProvider).length;
    final memberList = ref.watch(clubMembersProvider).value;
    final matchList = ref.watch(clubMatchesProvider).value;
    final notifCount = ref.watch(unreadNotificationCountProvider(UserRole.clubOwner));
    final ownerName = ref.watch(currentAccountProvider)?.fullName.trim() ?? '';
    final ownerFirstName = ownerName.isEmpty ? 'Club Owner' : ownerName.split(RegExp(r'\s+')).first;
    String n(int? v) => v == null ? '–' : '$v';

    // Structure: hero (greeting, glass club card with club stats) → the
    // pending action → quick actions → next match → member growth → results.
    return Scaffold(
      body: CeStatusBarScrim(
        child: ListView(padding: const EdgeInsets.only(bottom: 20), children: [
          // ---- Hero: greeting + glass club card (identity, chips, club stats) ----
          CeDashboardHero(
            keyPrefix: 'club',
            greeting: ceGreeting(ref.read(clockProvider).now()),
            name: ownerFirstName,
            notificationCount: notifCount,
            onNotifications: () => context.push(Routes.notifications),
            card: CeHeroGlassCard(
              keyPrefix: 'club',
              semanticLabel: 'Open My Club, ${club?.name ?? 'My Club'}',
              onTap: () => context.go(Routes.myClub),
              // The club picture when one is set (My Club), else the badge.
              leading: CePhotoImage(
                path: club?.logoPath,
                size: 54,
                fallback: Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.2),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2.5),
                  ),
                  child: Icon(CeIcons.of('shield'), size: 22, color: Colors.white),
                ),
              ),
              title: club?.name ?? 'My Club',
              subtitle: [
                if (club != null) club.city,
                if (club != null) club.type.label,
                if (club?.establishedYear != null) 'Est. ${club!.establishedYear}',
              ].join(' · '),
              chips: [
                const CeHeroPill(icon: 'crown', label: 'Club Owner'),
                if (club != null)
                  // Same as before: copies the code to share with players.
                  Semantics(
                    container: true,
                    button: true,
                    label: 'Share club code ${club.code} with players',
                    excludeSemantics: true,
                    child: GestureDetector(
                      key: const Key('club.code'),
                      onTap: () => _shareCode(context, club.code),
                      child: CeHeroPill(icon: 'key', label: 'Code ${club.code}', trailingIcon: 'share-2'),
                    ),
                  ),
              ],
              // Information only — Members / Teams / Matches are tabs and
              // Requests has its banner and Quick Action.
              stats: [
                (n(members), 'Members'),
                (n(teams), 'Teams'),
                ('$upcoming', 'Upcoming'),
                (n(requests), 'Requests'),
              ],
            ),
          ),

          // ---- Pending join requests: the one thing waiting on the owner ----
          if ((requests ?? 0) > 0) _PendingRequestsBanner(count: requests!),

          // ---- Quick actions: secondary actions only (no bottom-nav tabs) ----
          const CeSectionHeader('Quick Actions'),
          CeQuickActionGrid(key: const Key('club.quickActions'), actions: [
            CeQuickAction(icon: 'user-plus', label: 'Requests', onTap: () => context.go(Routes.joinRequests)),
            CeQuickAction(icon: 'swords', label: 'Challenges', onTap: () => context.go(Routes.challenges)),
            CeQuickAction(icon: 'user', label: 'Find Player', onTap: () => context.go(Routes.playerHunt)),
            CeQuickAction(icon: 'trophy', label: 'Tournament', onTap: () => context.go(Routes.tournamentHub)),
            CeQuickAction(icon: 'megaphone', label: 'Announcement', onTap: () => showCreateAnnouncementSheet(context)),
          ]),

          // ---- Next match (only when one is confirmed, as in the prototype) ----
          if (next != null) ...[
            CeSectionHeader('Next Match',
                actionLabel: 'View All',
                onAction: () => context.go(Routes.matchManagement(MatchTab.scheduled)),
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 0)),
            _NextMatch(match: next, clubShortName: club?.displayShortName ?? 'My Club'),
          ],

          // ---- Insights: member growth (bars) and match results (donut) ----
          if (memberList != null) ...[
            const CeSectionHeader('Member Growth'),
            MemberGrowthChart(growth: MemberGrowth.of(memberList, ref.read(clockProvider).now())),
          ],
          if (matchList != null) ...[
            const CeSectionHeader('Match Results'),
            MatchResultsChart(summary: MatchResultsSummary.of(matchList)),
          ],
        ]),
      ),
    );
  }
}

/// "N join requests waiting · Review" — shown only while requests are pending.
class _PendingRequestsBanner extends StatelessWidget {
  const _PendingRequestsBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count == 1 ? '1 join request waiting' : '$count join requests waiting';
    return Padding(
      padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      child: Semantics(
        button: true,
        label: '$label. Review',
        excludeSemantics: true,
        child: Material(
          color: CeColors.amberSoft,
          borderRadius: BorderRadius.circular(CeRadius.row),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: () => context.go(Routes.joinRequests),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: CeSize.touchTarget + 8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(CeRadius.sm)),
                    child: Icon(CeIcons.of('user-plus'), size: 16, color: CeColors.amberInk),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
                      const Text('Players are waiting to join your club',
                          style: TextStyle(fontSize: 11.5, color: CeColors.muted)),
                    ]),
                  ),
                  const Text('Review',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: CeColors.amberInk)),
                  Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.amberInk),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NextMatch extends ConsumerWidget {
  const _NextMatch({required this.match, required this.clubShortName});
  final ClubMatch match;
  final String clubShortName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opponent = ref.watch(clubDirectoryProvider).value?[match.opponentClubId];
    final ground = match.groundId == null ? null : ref.watch(groundDirectoryProvider).value?[match.groundId];
    final startsAt = match.startsAt;
    final groundLabel = ground == null ? 'Ground TBD' : '${ground.name}, ${ground.city}';
    return CeMatchCard(
      homeAbbr: clubAbbr(clubShortName),
      awayAbbr: opponent?.abbr ?? '?',
      awayColor: opponent?.color ?? CeColors.primary,
      title: '$clubShortName vs ${opponent?.name ?? 'Opponent'}',
      status: const CeStatusChip('Confirmed', icon: 'check'),
      infoChips: [
        CeInfoChip(icon: 'calendar', label: startsAt == null ? 'Date TBD' : CeFormat.dayDate(startsAt)),
        CeInfoChip(icon: 'clock', label: startsAt == null ? 'Time TBD' : CeFormat.time(startsAt)),
        CeInfoChip(icon: 'circle-dot', label: match.format?.display(match.customOvers) ?? 'Format TBD'),
      ],
      ground: groundLabel,
      groundDirections: ground != null,
      playingTeam: match.lineup?.name,
      onTap: () => context.go(Routes.matchManagement(MatchTab.scheduled)),
    );
  }
}
