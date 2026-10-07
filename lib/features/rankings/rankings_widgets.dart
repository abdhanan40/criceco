import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/domain/player_ranking.dart';
import '../../core/utils/ranked_search.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_indicators.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_surfaces.dart';
import 'rankings_providers.dart';

/// "#3 Batsman" — the role rank with the player's ranking role.
String roleRankLabel(PlayerRanking r) => '#${r.roleRank} ${r.input.role.label}';

/// My Performance → Rankings: your ranking, then the local leaderboard
/// (Overall · Batsmen · Bowlers · All-Rounders) with Search and Club filters.
class RankingsView extends ConsumerStatefulWidget {
  const RankingsView({super.key});

  @override
  ConsumerState<RankingsView> createState() => _RankingsViewState();
}

class _RankingsViewState extends ConsumerState<RankingsView> {
  RankingCategory _category = RankingCategory.overall;
  String _query = '';
  String? _club; // null = all clubs

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(rankingBoardProvider);
    final board = async.value;
    if (board == null) {
      return async.hasError
          ? ListView(children: [CeErrorState(title: "Couldn't load rankings", onRetry: () => ref.invalidate(rankingBoardProvider))])
          : const Center(child: CircularProgressIndicator());
    }
    final ranked = board.leaderboard(_category);
    final clubs = {for (final r in board.leaderboard(RankingCategory.overall)) r.input.club}.toList()..sort();
    final club = clubs.contains(_club) ? _club : null; // never an impossible filter
    final byClub = [for (final r in ranked) if (club == null || r.input.club == club) r];
    final rows = rankedSearch<PlayerRanking>(byClub, _query, fields: [
      SearchField<PlayerRanking>((r) => r.input.name),
      SearchField<PlayerRanking>((r) => r.input.club, weight: 1),
    ]);

    return ListView(key: const Key('rankings.list'), padding: const EdgeInsets.only(bottom: 24), children: [
      YourRankingCard(ranking: board.me),
      CeChipRow<RankingCategory>(
        values: RankingCategory.values,
        selected: _category,
        labelOf: (c) => c.label,
        onSelected: (c) => setState(() => _category = c),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: CeSearchField(hint: 'Search player or club…', onChanged: (v) => setState(() => _query = v)),
      ),
      if (clubs.length > 1)
        CeChipRow<String?>(
          values: [null, ...clubs],
          selected: club,
          labelOf: (c) => c ?? 'All clubs',
          onSelected: (c) => setState(() => _club = c),
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 2),
        child: Text(
          'Players on this device · ranked after ${PlayerRankingMath.minCompletedMatches} completed matches',
          style: CeType.caption,
        ),
      ),
      if (ranked.isEmpty)
        const CeEmptyState(
          icon: 'trophy',
          title: 'No ranked players yet',
          body: 'Players need at least ${PlayerRankingMath.minCompletedMatches} completed matches to enter the rankings.',
        )
      else if (rows.isEmpty)
        const CeEmptyState(icon: 'search', title: 'No players found', body: 'Try another name or club.')
      else
        for (final r in rows) RankingRow(ranking: r, category: _category),
    ]);
  }
}

/// One leaderboard row: rank, avatar, name, club · role, Ranking Score. The
/// top 3 get a quiet tint; your own row is highlighted.
class RankingRow extends StatelessWidget {
  const RankingRow({super.key, required this.ranking, required this.category});
  final PlayerRanking ranking;
  final RankingCategory category;

  @override
  Widget build(BuildContext context) {
    final r = ranking;
    final rank = RankingBoard.rankIn(r, category)!;
    final me = r.input.isMe;
    final top = rank <= 3;
    return Semantics(
      label: 'Rank $rank, ${r.input.name}${me ? ' (you)' : ''}, ${r.input.club}, ${r.input.role.label}, score ${r.score}',
      excludeSemantics: true,
      child: Container(
        key: Key('rankings.row.${r.playerId}'),
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
        padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
        decoration: BoxDecoration(
          color: me ? CeColors.mint : Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.card),
          border: Border.all(color: me ? CeColors.primary : CeColors.line, width: me ? 1.5 : 1),
        ),
        child: Row(children: [
          // Rank: always visible, never squeezed.
          Container(
            width: 38,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: top ? CeColors.primary : CeColors.bg,
              borderRadius: BorderRadius.circular(CeRadius.sm),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('#$rank', style: CeType.statValue(13.5).copyWith(color: top ? Colors.white : CeColors.ink)),
            ),
          ),
          const SizedBox(width: 10),
          CeAvatar(r.input.name, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(r.input.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: CeType.listTitle),
                ),
                if (me) ...[const SizedBox(width: 6), const CeTag('You', background: CeColors.primary, foreground: Colors.white)],
              ]),
              const SizedBox(height: 2),
              Text('${r.input.club} · ${r.input.role.label}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: CeType.bodySmall.copyWith(fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          // Score: always visible.
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${r.score}', style: CeType.statValue(17)),
            Text('Score', style: CeType.statLabel),
          ]),
        ]),
      ),
    );
  }
}

/// "Your Ranking": Overall #, role #, Score — or how close you are.
class YourRankingCard extends StatelessWidget {
  const YourRankingCard({super.key, required this.ranking, this.margin, this.onTap});
  final PlayerRanking? ranking;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = ranking;
    if (r == null) return const SizedBox.shrink();
    return CeCard(
      key: const Key('rankings.mine'),
      margin: margin ?? const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Your Ranking', style: CeType.cardTitle)),
          if (onTap != null) Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2),
        ]),
        const SizedBox(height: 10),
        if (r.eligible)
          Row(children: [
            Expanded(child: CeMiniStat(value: '#${r.overallRank}', label: 'Overall')),
            const SizedBox(width: 8),
            Expanded(child: CeMiniStat(value: '#${r.roleRank}', label: RankingCategory.forRole(r.input.role).label)),
            const SizedBox(width: 8),
            Expanded(child: CeMiniStat(value: '${r.score}', label: 'Score')),
          ])
        else
          NotYetRanked(ranking: r),
      ]),
    );
  }
}

/// "Not yet ranked · 5/7 matches completed" with a small progress bar.
class NotYetRanked extends StatelessWidget {
  const NotYetRanked({super.key, required this.ranking});
  final PlayerRanking ranking;

  @override
  Widget build(BuildContext context) {
    const min = PlayerRankingMath.minCompletedMatches;
    final done = ranking.completedMatches.clamp(0, min);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Not yet ranked', style: CeType.listTitle),
      const SizedBox(height: 2),
      Text('${ranking.progress} matches completed', style: CeType.bodySmall.copyWith(fontSize: 12)),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(value: done / min, minHeight: 4),
      ),
    ]);
  }
}

/// Player Hunt card badge: "#3 Batsman · Score 88" or "Not Ranked · 5/7 Matches".
class RankingBadge extends StatelessWidget {
  const RankingBadge({super.key, required this.ranking});
  final PlayerRanking ranking;

  @override
  Widget build(BuildContext context) {
    final r = ranking;
    return Container(
      key: const Key('rankings.badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: r.eligible ? CeColors.mint : CeColors.bg,
        borderRadius: BorderRadius.circular(CeRadius.xs),
      ),
      child: Text(
        r.eligible ? '${roleRankLabel(r)} · Score ${r.score}' : 'Not Ranked · ${r.progress} Matches',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: CeType.micro.copyWith(fontSize: 11, color: r.eligible ? CeColors.primary : CeColors.muted),
      ),
    );
  }
}

/// Ranking section of the Player Stats sheet / Member Profile.
class PlayerRankingSection extends ConsumerWidget {
  const PlayerRankingSection({super.key, required this.playerId});
  final String playerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(rankingBoardProvider).value?.byId(playerId);
    if (r == null) return const SizedBox.shrink();
    String rank(int? n) => n == null ? '—' : '#$n';
    return Column(key: const Key('rankings.section'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text('RANKING', style: CeType.label.copyWith(fontSize: 11, letterSpacing: 0.6, color: CeColors.muted)),
      ),
      Row(children: [
        Expanded(child: CeMiniStat(value: rank(r.overallRank), label: 'Overall Rank')),
        const SizedBox(width: 8),
        Expanded(child: CeMiniStat(value: rank(r.roleRank), label: '${r.input.role.label} Rank')),
        const SizedBox(width: 8),
        Expanded(child: CeMiniStat(value: r.eligible ? '${r.score}' : '—', label: 'Score')),
        const SizedBox(width: 8),
        Expanded(child: CeMiniStat(value: '${r.completedMatches}', label: 'Matches')),
      ]),
      const SizedBox(height: 8),
      Text(
        r.eligible
            ? 'Eligible · ranked on ${r.completedMatches} completed matches'
            : 'Not yet ranked · ${r.progress} matches completed',
        style: CeType.bodySmall.copyWith(fontSize: 12),
      ),
    ]);
  }
}
