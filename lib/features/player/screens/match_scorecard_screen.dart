import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../player_providers.dart';

/// Scorecard tab of the Player Match workspace — the former Scorecard screen
/// (prototype `screens.matchScorecard`, :3345), keyed by match id (revised
/// architecture §3). Only shown for a past match with a scorecard.
class MatchScorecardView extends ConsumerWidget {
  const MatchScorecardView({super.key, required this.match});
  final PlayerMatch match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scId = match.scorecardId;
    final scAsync = scId == null ? null : ref.watch(scorecardProvider(scId));
    if (scAsync?.isLoading ?? false) return const Center(child: CircularProgressIndicator());
    final sc = scAsync?.value;
    if (sc == null || sc.innings.isEmpty) {
      return const CeEmptyState(
        icon: 'file-text',
        title: 'Scorecard not available',
        body: 'A scorecard has not been published for this match.',
      );
    }
    final top = sc.topScorer;
    final wk = sc.topWicketTaker;
    final white85 = Colors.white.withValues(alpha: 0.85);
    return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        CeBrandHero(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          radius: 18,
          padding: const EdgeInsets.all(18),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              CeTeamBadge(sc.innings.first.abbr, size: 46, onDark: true),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('VS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: white85)),
              ),
              CeTeamBadge(sc.innings.last.abbr, size: 46, onDark: true),
            ]),
            const SizedBox(height: 10),
            Text('${sc.innings.first.team} vs ${sc.innings.last.team}',
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(CeIcons.of('trophy'), size: 14, color: Colors.white),
              const SizedBox(width: 6),
              Flexible(
                child: Text(sc.result,
                    textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              ),
            ]),
            const SizedBox(height: 4),
            Text('${CeFormat.dayDate(match.startsAt)} · ${match.format.display()} · ${match.ground}',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: white85)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _StatBox(label: 'Top Scorer', value: top == null ? '—' : '${top.name}\n${top.runs} runs')),
              const SizedBox(width: 10),
              Expanded(
                child: _StatBox(label: 'Top Wicket-Taker', value: wk == null ? '—' : '${wk.name}\n${wk.wickets} wkts'),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
          child: _StatBox(label: 'Player of the Match', value: sc.playerOfMatch, icon: 'award'),
        ),
        for (final inn in sc.innings) _InningsCard(innings: inn),
      ]);
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({required this.label, required this.value, this.icon});
  final String label;
  final String value;
  final String? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.row),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 10, color: CeColors.muted)),
          const SizedBox(height: 5),
          Text.rich(
            TextSpan(children: [
              if (icon != null)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Icon(CeIcons.of(icon!), size: 14, color: CeColors.primaryDark),
                  ),
                ),
              TextSpan(text: value),
            ]),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, height: 1.25, color: CeColors.ink),
          ),
        ]),
      );
}

class _InningsCard extends StatelessWidget {
  const _InningsCard({required this.innings});
  final Innings innings;

  static const _head = TextStyle(
      fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.45, color: CeColors.muted);
  static const _num = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);

  Widget _row(List<Widget> cells, {bool header = false, bool last = false}) => Container(
        padding: EdgeInsets.symmetric(horizontal: 2, vertical: header ? 0 : 7).copyWith(bottom: header ? 6 : 7),
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: header ? CeColors.hairline : CeColors.bg)),
        ),
        child: Row(children: [
          Expanded(flex: 23, child: cells.first),
          for (final c in cells.skip(1)) ...[const SizedBox(width: 6), Expanded(flex: 7, child: Center(child: c))],
        ]),
      );

  Widget _sub(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4, color: CeColors.muted)),
      );

  @override
  Widget build(BuildContext context) {
    final inn = innings;
    return CeCard(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(inn.team, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        const SizedBox(height: 2),
        Text.rich(TextSpan(children: [
          TextSpan(text: '${inn.total}/${inn.wickets} '),
          TextSpan(text: '(${inn.overs} overs)', style: const TextStyle(color: CeColors.muted2)),
        ]), style: const TextStyle(fontSize: 12, color: CeColors.muted)),
        _sub('Batting'),
        _row(header: true, [
          for (final h in ['BATTER', 'R', 'B', '4S', '6S']) Text(h, style: _head),
        ]),
        for (var i = 0; i < inn.batting.length; i++)
          _row(last: i == inn.batting.length - 1, [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(inn.batting[i].name,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.ink)),
              const SizedBox(height: 1),
              Text(inn.batting[i].dismissal, style: const TextStyle(fontSize: 9.5, color: CeColors.muted)),
            ]),
            Text('${inn.batting[i].runs}', style: _num.copyWith(fontWeight: FontWeight.w800)),
            Text('${inn.batting[i].balls}', style: _num),
            Text('${inn.batting[i].fours}', style: _num),
            Text('${inn.batting[i].sixes}', style: _num),
          ]),
        _sub('Bowling'),
        _row(header: true, [
          for (final h in ['BOWLER', 'O', 'M', 'R', 'W']) Text(h, style: _head),
        ]),
        for (var i = 0; i < inn.bowling.length; i++)
          _row(last: i == inn.bowling.length - 1, [
            Text(inn.bowling[i].name,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.ink)),
            Text('${inn.bowling[i].overs}', style: _num),
            Text('${inn.bowling[i].maidens}', style: _num),
            Text('${inn.bowling[i].runs}', style: _num),
            Text('${inn.bowling[i].wickets}', style: _num.copyWith(fontWeight: FontWeight.w800)),
          ]),
      ]),
    );
  }
}
