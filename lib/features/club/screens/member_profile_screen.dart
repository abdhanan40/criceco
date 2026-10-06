import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/fitness_meter.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_list_sheet.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../fitness/fitness_providers.dart';
import '../../fitness/fitness_widgets.dart';
import '../../player/player_providers.dart';
import '../club_providers.dart';
import '../teams/teams_controller.dart';
import '../widgets/squad_widgets.dart';

/// Member Profile (Club Owner → Members → member): the member's identity and
/// details, and for players the Fitness Meter (score, recommendation,
/// 7-day breakdown), recent matches and scouting stats, so the owner can
/// judge the player. Back → Members.
class MemberProfileScreen extends ConsumerWidget {
  const MemberProfileScreen({super.key, required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const bar = CeTopBar(title: 'Member Profile', fallbackLocation: Routes.members);
    final async = ref.watch(clubMembersProvider);
    final m = ref.watch(clubMemberProvider(memberId));
    if (async.isLoading && m == null) {
      return const Scaffold(appBar: bar, body: Center(child: CircularProgressIndicator()));
    }
    if (m == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'users',
          title: 'Member not found',
          body: 'This member is no longer in your club.',
          primaryLabel: 'Back to Members',
          onPrimary: () => context.go(Routes.members),
        ),
      );
    }
    return Scaffold(
      appBar: bar,
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: memberProfileChildren(context, ref, m)),
    );
  }
}

/// Member Profile content (screen and sheet): identity, details and, for
/// players, the Fitness Meter, recent matches and scouting stats.
List<Widget> memberProfileChildren(BuildContext context, WidgetRef ref, ClubMember m) {
  final memberId = m.id;
  final fitness = ref.watch(memberFitnessProvider(memberId));
  final isOwner = m.role == MemberRole.owner;
  return [
    _Identity(member: m),
    const CeSectionHeader('Details', padding: EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 8)),
    CeSummaryCard(rows: [
      ('Club role', CeSummaryCard.value(context, m.role.label)),
      if (m.plays) ('Playing role', CeSummaryCard.value(context, m.playingRole!.label)),
      if (m.plays) ('Wicket Keeper', CeSummaryCard.value(context, m.isWicketkeeper ? 'Yes' : 'No')),
      if (m.battingStyle != null) ('Batting', CeSummaryCard.value(context, m.battingStyle!.label)),
      if (m.bowlingStyle != null) ('Bowling', CeSummaryCard.value(context, m.bowlingStyle!.label)),
      if (m.phone.isNotEmpty) ('Phone', CeSummaryCard.value(context, m.phone)),
    ]),
    if (fitness != null) ...[
      FitnessMeterView(
        report: fitness,
        log: ref.watch(memberRecentMatchesProvider(memberId)),
        now: ref.read(clockProvider).now(),
      ),
      _RecentMatches(memberId: memberId),
      if (isOwner) const _OwnCareer() else _Scouting(member: m),
    ],
  ];
}

/// Members sheet → a member: their profile in a sheet on top (no new screen).
Future<void> showMemberProfileSheet(BuildContext context, String memberId) =>
    showCeListSheet<void>(context, builder: (_) => _MemberProfileSheet(memberId: memberId));

class _MemberProfileSheet extends ConsumerWidget {
  const _MemberProfileSheet({required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(clubMemberProvider(memberId));
    return CeListSheetFrame(
      key: const Key('memberProfile.sheet'),
      title: 'Member Profile',
      children: m == null
          ? const [
              CeEmptyState(icon: 'users', title: 'Member not found', body: 'This member is no longer in your club.'),
            ]
          : memberProfileChildren(context, ref, m),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.member});
  final ClubMember member;

  @override
  Widget build(BuildContext context) {
    final m = member;
    return CeBrandHero(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
      radius: CeRadius.lg,
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2),
          ),
          child: Text(m.name.trim().isEmpty ? '?' : m.name.trim()[0].toUpperCase(),
              style: const TextStyle(fontFamily: CeType.display, fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: CeType.display, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
            const SizedBox(height: 2),
            Text(m.roleLine, style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
            const SizedBox(height: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.pill)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(CeIcons.of(m.role == MemberRole.owner ? 'crown' : (m.plays ? 'user' : 'shield')),
                    size: 12, color: Colors.white),
                const SizedBox(width: 5),
                Text('Club ${m.role.label}',
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Matches inside the Fitness Meter's 7-day window.
class _RecentMatches extends ConsumerWidget {
  const _RecentMatches({required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = CeFormat.dateOnly(ref.read(clockProvider).now());
    final from = today.subtract(const Duration(days: FitnessReport.window - 1));
    final recent = [
      for (final e in ref.watch(memberRecentMatchesProvider(memberId)))
        if (!CeFormat.dateOnly(e.date).isBefore(from) && !CeFormat.dateOnly(e.date).isAfter(today)) e,
    ]..sort((a, b) => b.date.compareTo(a.date));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CeSectionHeader('Last 7 days · ${recent.length} match${recent.length == 1 ? '' : 'es'}',
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 8)),
      if (recent.isEmpty)
        const CeInfoNote(text: 'No matches in the last 7 days.')
      else
        CeCard(
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          padding: const EdgeInsets.symmetric(horizontal: CeSpace.card, vertical: 4),
          child: Column(children: [
            for (final (i, e) in recent.indexed)
              Container(
                constraints: const BoxConstraints(minHeight: 46),
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: i == recent.length - 1
                    ? null
                    : const BoxDecoration(border: Border(bottom: BorderSide(color: CeColors.hairline))),
                child: Row(children: [
                  CeTeamBadge(e.opponentAbbr, color: clubBadgeColor(e.opponentAbbr), size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('vs ${e.opponentName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
                      Text(CeFormat.dayDate(e.date), style: const TextStyle(fontSize: 11, color: CeColors.muted)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  // Flexible: wraps instead of overflowing at 320 px.
                  Flexible(
                    child: Text(
                      [
                        if (e.balls > 0) '${e.runs} (${e.balls}b)',
                        if (FitnessMeter.ballsIn(e.overs) > 0) '${e.overs} ov',
                      ].join(' · '),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2),
                    ),
                  ),
                ]),
              ),
          ]),
        ),
    ]);
  }
}

/// Scouting stats for a club player (the same numbers as the squad's Player
/// Stats sheet).
class _Scouting extends ConsumerWidget {
  const _Scouting({required this.member});
  final ClubMember member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = member;
    final pool = ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
    final linked = pool.where((p) => p.id == m.poolPlayerId).firstOrNull;
    final player = linked ??
        SquadPlayer(
          id: m.id,
          name: m.name,
          position: m.isWicketkeeper ? 'Wicketkeeper' : m.playingRole!.label,
          availability: PlayerAvailability.available,
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const CeSectionHeader('Player Stats', padding: EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 8)),
      CeCard(
        margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        child: PlayerScoutingDetails(player: player, stats: readSquadPlayerStats(ref, player)),
      ),
    ]);
  }
}

/// The Owner's own Player career (one account, both roles).
class _OwnCareer extends ConsumerWidget {
  const _OwnCareer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perf = ref.watch(performanceProvider).value;
    if (perf == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const CeSectionHeader('Player Stats', padding: EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 8)),
      CeStatGroup(cells: [
        CeStatCell(value: '${perf.matches}', label: 'Matches'),
        CeStatCell(value: '${perf.runs}', label: 'Runs'),
        CeStatCell(value: perf.battingAverage, label: 'Average'),
        CeStatCell(value: perf.rating, label: 'Rating'),
      ]),
    ]);
  }
}
