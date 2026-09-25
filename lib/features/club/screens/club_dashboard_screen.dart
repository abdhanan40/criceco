import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_quick_actions.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../club_providers.dart';
import '../teams/teams_controller.dart';

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
    final requests = ref.watch(clubJoinRequestsProvider).value?.length;
    final next = ref.watch(nextClubMatchProvider);
    final top = MediaQuery.paddingOf(context).top;
    String n(int? v) => v == null ? '–' : '$v';

    return Scaffold(
      body: CeStatusBarScrim(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          // ---- Hero ----
          AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: CeBrandHero(
              padding: EdgeInsets.fromLTRB(8, top + 4, CeSpace.gutter, 22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Builder(
                    builder: (ctx) => IconButton(
                      tooltip: 'Open menu',
                      icon: Icon(CeIcons.of('menu'), color: Colors.white, size: 20),
                      onPressed: () => CeTopBar.openDrawer(ctx),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.md)),
                    child: Icon(CeIcons.of('shield'), size: 18, color: Colors.white),
                  ),
                ]),
                Padding(
                  padding: const EdgeInsets.only(left: 10, top: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.pill)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(CeIcons.of('crown'), size: 12, color: Colors.white),
                        const SizedBox(width: 5),
                        const Text('Club Owner',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    Text(club?.name ?? 'My Club',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800, height: 1.2, letterSpacing: -0.6, color: Colors.white)),
                    const SizedBox(height: 1),
                    Text(club?.city ?? '', style: const TextStyle(fontSize: 12.5, color: CeColors.mint2)),
                    const SizedBox(height: 14),
                    if (club != null) _CodeRow(code: club.code, onShare: () => _shareCode(context, club.code)),
                  ]),
                ),
              ]),
            ),
          ),

          // ---- Stats ----
          Transform.translate(
            offset: const Offset(0, -6),
            child: CeStatsRow(children: [
              CeStatCard(value: n(members), label: 'Members'),
              CeStatCard(value: n(teams), label: 'Teams'),
              CeStatCard(value: n(requests), label: 'Requests'),
            ]),
          ),

          // ---- Quick actions (out-of-phase destinations keep their routes) ----
          const CeSectionHeader('Quick Actions',
              padding: EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 8)),
          CeQuickActionGrid(actions: [
            CeQuickAction(icon: 'user-plus', label: 'Requests', onTap: () => context.go(Routes.joinRequests)),
            CeQuickAction(icon: 'users', label: 'Members', onTap: () => context.go(Routes.members)),
            CeQuickAction(icon: 'trophy', label: 'Teams', onTap: () => context.go(Routes.teams)),
            CeQuickAction(icon: 'swords', label: 'Challenges', onTap: () => context.go(Routes.challenges)),
            CeQuickAction(icon: 'user', label: 'Open Player', onTap: () => context.go(Routes.playerHunt)),
            CeQuickAction(
                icon: 'calendar', label: 'Upcoming Matches', onTap: () => context.go(Routes.matchManagement())),
            CeQuickAction(icon: 'trophy', label: 'Tournament', onTap: () => context.go(Routes.tournamentHub)),
          ]),

          // ---- Next match (only when one is confirmed, as in the prototype) ----
          if (next != null) ...[
            CeSectionHeader('Next Match',
                actionLabel: 'View All',
                onAction: () => context.go(Routes.matchManagement(MatchTab.scheduled)),
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0)),
            _NextMatch(match: next, clubShortName: club?.displayShortName ?? 'My Club'),
          ],
        ]),
      ),
    );
  }
}

class _CodeRow extends StatelessWidget {
  const _CodeRow({required this.code, required this.onShare});
  final String code;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(CeRadius.md),
        ),
        child: Row(children: [
          Icon(CeIcons.of('key'), size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Club Code: '),
                TextSpan(text: code, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          // Narrow phones: the pill scales down rather than overflowing.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Material(
                color: Colors.white,
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onShare,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text('Share with players',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
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
      homeAbbr: _abbr(clubShortName),
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
    );
  }
}

/// "Shalimar CC" → "SC" (prototype badge).
String _abbr(String name) {
  final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length == 1) return words.first.substring(0, words.first.length.clamp(0, 2)).toUpperCase();
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}
