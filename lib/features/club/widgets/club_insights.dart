import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_surfaces.dart';

// ---------------------------------------------------------------------------
// Club Dashboard insights: Member Growth (bars) and Match Results (donut).
// Both are derived from the club's own data — nothing is stored for them.
// ---------------------------------------------------------------------------

/// Members at the end of each of the last [months] months (the current month
/// counts up to now), from each member's join date. A member with no join date
/// is a founding member and counts in every month.
class MemberGrowth {
  const MemberGrowth({required this.bars, required this.before});

  /// (first day of the month, members by the end of it), oldest first.
  final List<(DateTime, int)> bars;

  /// Members before the first month of the chart.
  final int before;

  int get current => bars.isEmpty ? before : bars.last.$2;

  /// Joined since the start of the first month shown.
  int get gained => current - before;

  static MemberGrowth of(List<ClubMember> members, DateTime now, {int months = 6}) {
    int countBefore(DateTime end) => members.where((m) => m.joinedAt == null || m.joinedAt!.isBefore(end)).length;
    final first = DateTime(now.year, now.month - (months - 1));
    return MemberGrowth(
      before: countBefore(first),
      bars: [
        for (var i = 0; i < months; i++)
          (DateTime(first.year, first.month + i), countBefore(DateTime(first.year, first.month + i + 1))),
      ],
    );
  }
}

/// Completed club matches by outcome, read from the recorded result
/// ("Won by 18 runs" / "Lost by 6 wickets"; anything else — tie, draw, no
/// result — is Draw / NR).
class MatchResultsSummary {
  const MatchResultsSummary({required this.won, required this.lost, required this.drawn});
  final int won;
  final int lost;
  final int drawn; // draw / tie / no result
  int get total => won + lost + drawn;

  static MatchResultsSummary of(Iterable<ClubMatch> matches) {
    var won = 0, lost = 0, drawn = 0;
    for (final m in matches) {
      if (m.status != MatchStatus.completed) continue;
      final r = (m.resultText ?? '').trim().toLowerCase();
      if (r.startsWith('won')) {
        won++;
      } else if (r.startsWith('lost')) {
        lost++;
      } else {
        drawn++;
      }
    }
    return MatchResultsSummary(won: won, lost: lost, drawn: drawn);
  }
}

/// Compact vertical bar chart: "+N since April" and members per month.
class MemberGrowthChart extends StatelessWidget {
  const MemberGrowthChart({super.key, required this.growth});
  final MemberGrowth growth;

  static const _barArea = 78.0;

  @override
  Widget build(BuildContext context) {
    final g = growth;
    final maxCount = g.bars.fold<int>(1, (m, b) => math.max(m, b.$2));
    final since = g.bars.isEmpty ? '' : DateFormat('MMMM').format(g.bars.first.$1);
    final gainedLabel = g.gained > 0 ? '+${g.gained}' : '${g.gained}';
    final summary = [
      for (final (month, n) in g.bars) '${DateFormat('MMMM').format(month)} $n',
    ].join(', ');
    return CeCard(
      key: const Key('club.memberGrowth'),
      margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Semantics(
        container: true,
        label: 'Member growth: ${g.current} members, $gainedLabel since $since. $summary',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(gainedLabel,
                key: const Key('club.memberGrowth.gained'),
                style: TextStyle(fontFamily: CeType.display, 
                    fontSize: 22,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: g.gained > 0 ? CeColors.primary : CeColors.ink)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('since $since',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.muted)),
            ),
            Text('${g.current} members',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final (i, (month, n)) in g.bars.indexed)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(key: Key('club.memberGrowth.bar.$i'), children: [
                    Text('$n',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: i == g.bars.length - 1 ? CeColors.primaryDark : CeColors.muted)),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: _barArea,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          height: math.max(4, _barArea * n / maxCount),
                          constraints: const BoxConstraints(maxWidth: 26),
                          decoration: BoxDecoration(
                            // The current month in the signature green.
                            color: i == g.bars.length - 1 ? CeColors.primary : CeColors.sage.withValues(alpha: 0.55),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(DateFormat('MMM').format(month),
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: CeColors.muted)),
                  ]),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Compact donut: Won / Lost / Draw-NR with the total in the centre and each
/// outcome's count and share alongside.
class MatchResultsChart extends StatelessWidget {
  const MatchResultsChart({super.key, required this.summary});
  final MatchResultsSummary summary;

  static const wonColor = CeColors.primary;
  static const lostColor = CeColors.red;
  static const drawColor = CeColors.amber;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    String pct(int n) => s.total == 0 ? '0%' : '${(100 * n / s.total).round()}%';
    final rows = [
      ('Won', s.won, wonColor),
      ('Lost', s.lost, lostColor),
      ('Draw / NR', s.drawn, drawColor),
    ];
    return CeCard(
      key: const Key('club.matchResults'),
      margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Semantics(
        container: true,
        label: s.total == 0
            ? 'Match results: no completed matches yet'
            : 'Match results: ${s.total} played. '
                '${[for (final (l, n, _) in rows) '$l $n, ${pct(n)}'].join('; ')}',
        excludeSemantics: true,
        child: Row(children: [
          SizedBox.square(
            dimension: 96,
            child: CustomPaint(
              painter: _DonutPainter([for (final (_, n, c) in rows) (n, c)]),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${s.total}',
                      key: const Key('club.matchResults.total'),
                      style: const TextStyle(fontFamily: CeType.display, fontSize: 22, height: 1.1, fontWeight: FontWeight.w700, color: CeColors.ink)),
                  const Text('Played', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: CeColors.muted)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, (label, n, color)) in rows.indexed) ...[
                if (i > 0) const SizedBox(height: 9),
                Row(key: Key('club.matchResults.$label'), children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: CeColors.ink2)),
                  ),
                  Text('$n',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
                  SizedBox(
                    width: 42,
                    child: Text(pct(n),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.muted)),
                  ),
                ]),
              ],
              if (s.total == 0) ...[
                const SizedBox(height: 10),
                const Text('No completed matches yet',
                    style: TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.segments);
  final List<(int, Color)> segments;

  static const _stroke = 13.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(_stroke / 2, _stroke / 2, size.width - _stroke, size.height - _stroke);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    final total = segments.fold<int>(0, (t, s) => t + s.$1);
    if (total == 0) {
      canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = CeColors.hairline);
      return;
    }
    final present = segments.where((s) => s.$1 > 0).length;
    // A small gap between segments (none when one outcome fills the ring).
    final gap = present > 1 ? 0.05 : 0.0;
    var start = -math.pi / 2;
    for (final (n, color) in segments) {
      if (n == 0) continue;
      final sweep = 2 * math.pi * n / total;
      canvas.drawArc(rect, start + gap / 2, sweep - gap, false, paint..color = color);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.segments.length != segments.length ||
      [for (var i = 0; i < segments.length; i++) old.segments[i] != segments[i]].any((d) => d);
}
