import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/fitness_meter.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_indicators.dart';
import '../../shared/widgets/ce_surfaces.dart';

const fitnessNote = 'Workload indication from the last 7 days of matches — not a medical assessment.';

CeTone fitnessTone(FitnessLevel l) => switch (l) {
      FitnessLevel.fresh => CeTone.green,
      FitnessLevel.moderate => CeTone.blue,
      FitnessLevel.fatigued => CeTone.amber,
      FitnessLevel.overloaded => CeTone.red,
    };

/// "7/10 · MODERATE" pill (member cards, suggestion rows).
class FitnessBadge extends StatelessWidget {
  const FitnessBadge(this.report, {super.key});
  final FitnessReport report;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Fitness ${report.score} out of 10, ${report.level.label}',
        excludeSemantics: true,
        child: CeStatusChip('${report.score}/10 · ${report.level.label}',
            tone: report.avoidPlaying ? CeTone.red : fitnessTone(report.level), icon: 'activity'),
      );
}

/// Workload points for one match, with the same weights as
/// [FitnessMeter.evaluate]: 2 per match, 1 per 4 overs bowled, 0.5 per 30
/// balls faced. Presentation only (the score itself comes from the report).
double fitnessMatchLoad(MatchLogEntry m) => 2 + FitnessMeter.ballsIn(m.overs) / 24 + 0.5 * m.balls / 30;

/// One day of the 7-day window.
class _Day {
  _Day(this.date, this.matches);
  final DateTime date;
  final List<MatchLogEntry> matches;
  bool get played => matches.isNotEmpty;
  double get load => matches.fold(0.0, (s, m) => s + fitnessMatchLoad(m));
}

String _loadLabel(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
String _plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// The Fitness Meter (Player Dashboard, Member Profile). Presentation of an
/// existing [FitnessReport] — score, level, recommendation, rest days and
/// alerts are all the report's; this only lays them out:
///
/// 1. header · 2. score gauge + status · 3. Matches / Balls faced / Overs
/// 4. 7-day workload bars · 5. tapped-day detail · 6. recommendation (with
/// reasons) · 7. recovery plan when rest is advised · 8. next match status
/// · 9. "shared with your club owner" when the player is in a club.
class FitnessMeterView extends StatefulWidget {
  const FitnessMeterView({
    super.key,
    required this.report,
    required this.log,
    required this.now,
    this.nextMatch,
    this.sharedWithClub,
  });

  final FitnessReport report;

  /// The match log the report was computed from (for the daily bars).
  final List<MatchLogEntry> log;
  final DateTime now;

  /// The player's next match, if there is one.
  final ({DateTime startsAt, String opponent})? nextMatch;

  /// The club whose owner can see this player's fitness, if any.
  final String? sharedWithClub;

  @override
  State<FitnessMeterView> createState() => _FitnessMeterViewState();
}

class _FitnessMeterViewState extends State<FitnessMeterView> {
  int? _selected;

  List<_Day> _days() {
    final today = CeFormat.dateOnly(widget.now);
    return [
      for (var i = FitnessReport.window - 1; i >= 0; i--)
        () {
          final d = today.subtract(Duration(days: i));
          return _Day(d, [for (final m in widget.log) if (CeFormat.dateOnly(m.date) == d) m]);
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final days = _days();
    // Default selection: the latest day with a match, else today.
    final latest = days.lastIndexWhere((d) => d.played);
    final selectedIndex = _selected ?? (latest == -1 ? days.length - 1 : latest);
    final blocked = r.alerts.isNotEmpty && r.alerts.first.startsWith('Marked ');
    final restThisWeek = days.where((d) => !d.played).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ---- 1. Header ----
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 8),
        child: Row(children: [
          Expanded(child: Text('Fitness Meter', style: Theme.of(context).textTheme.titleMedium)),
          const Text('Last 7 days', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.muted)),
        ]),
      ),
      // ---- 2–5. Score, metrics, workload, day detail ----
      Semantics(
        label: 'Fitness Meter, ${r.score} out of 10, ${r.level.label}. ${r.recommendation}',
        child: CeCard(
          key: const Key('fitness.card'),
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _ScoreRow(report: r, blocked: blocked, restThisWeek: restThisWeek),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _Metric(value: '${r.matches}', label: 'Matches')),
              const SizedBox(width: 8),
              Expanded(child: _Metric(value: '${r.ballsFaced}', label: 'Balls faced')),
              const SizedBox(width: 8),
              Expanded(child: _Metric(value: r.oversBowled, label: 'Overs bowled')),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              const Expanded(child: _Caps('Daily workload')),
              Text('Tap a day', style: TextStyle(fontSize: 11, color: CeColors.muted.withValues(alpha: 0.9))),
            ]),
            const SizedBox(height: 10),
            _WorkloadBars(days: days, selected: selectedIndex, onSelect: (i) => setState(() => _selected = i)),
            const SizedBox(height: 8),
            const _Legend(),
            const SizedBox(height: 10),
            _DayDetail(day: days[selectedIndex]),
          ]),
        ),
      ),
      // ---- 6–8. Recommendation, recovery plan, next match ----
      _Recommendation(
        report: r,
        blocked: blocked,
        restThisWeek: restThisWeek,
        today: CeFormat.dateOnly(widget.now),
        playedToday: days.last.played,
        nextMatch: widget.nextMatch,
      ),
      // ---- 9. Shared note + disclaimer ----
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.sharedWithClub != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Icon(CeIcons.of('users'), size: 12, color: CeColors.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Shared with your club owner at ${widget.sharedWithClub}',
                      key: const Key('fitness.shared'),
                      style: const TextStyle(fontSize: 11, color: CeColors.muted)),
                ),
              ]),
            ),
          const Text(fitnessNote, style: TextStyle(fontSize: 10.5, color: CeColors.muted2, height: 1.35)),
        ]),
      ),
    ]);
  }
}

class _Caps extends StatelessWidget {
  const _Caps(this.text, {this.color = CeColors.muted});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: color));
}

/// Gauge + status chip + headline + one-line summary of the week.
class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.report, required this.blocked, required this.restThisWeek});
  final FitnessReport report;
  final bool blocked;
  final int restThisWeek;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final tone = r.avoidPlaying ? CeTone.red : fitnessTone(r.level);
    final (_, fg) = CeStatusChip.colors(tone);
    final headline = blocked
        ? 'Not available to play'
        : switch (r.level) {
            FitnessLevel.fresh => 'Fresh · ready to play',
            FitnessLevel.moderate => 'Moderate load',
            FitnessLevel.fatigued => 'High fatigue',
            FitnessLevel.overloaded => 'Overloaded',
          };
    final summary = r.matches == 0
        ? 'No matches in the last 7 days.'
        : '${_plural(r.matches, 'match', 'matches')} and ${_plural(restThisWeek, 'rest day')} this week.';
    return Row(children: [
      _Gauge(score: r.score, color: fg),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CeStatusChip(blocked ? 'Unavailable' : r.level.label, tone: tone),
          const SizedBox(height: 6),
          Text(headline,
              key: const Key('fitness.headline'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: CeColors.ink, height: 1.2)),
          const SizedBox(height: 3),
          Text(summary, style: const TextStyle(fontSize: 12, color: CeColors.muted, height: 1.35)),
        ]),
      ),
    ]);
  }
}

/// Circular score gauge on the report's 0–10 scale.
class _Gauge extends StatelessWidget {
  const _Gauge({required this.score, required this.color});
  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const Key('fitness.gauge'),
        width: 76,
        height: 76,
        child: CustomPaint(
          painter: _GaugePainter(fraction: score / FitnessReport.max, color: color),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('$score',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, height: 1, color: color)),
              const SizedBox(height: 2),
              const Text('of ${FitnessReport.max}', style: TextStyle(fontSize: 10, color: CeColors.muted)),
            ]),
          ),
        ),
      );
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 7.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(rect, 0, 2 * math.pi, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = CeColors.line);
    if (fraction > 0) {
      canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * fraction.clamp(0.0, 1.0), false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..color = color);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.fraction != fraction || old.color != color;
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: CeColors.bg,
          borderRadius: BorderRadius.circular(CeRadius.md),
          border: Border.all(color: CeColors.hairline),
        ),
        child: Column(children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800, color: CeColors.ink, fontFeatures: [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: CeColors.muted)),
        ]),
      );
}

/// Seven tappable workload bars (match days filled, rest days a stub).
class _WorkloadBars extends StatelessWidget {
  const _WorkloadBars({required this.days, required this.selected, required this.onSelect});
  final List<_Day> days;
  final int selected;
  final ValueChanged<int> onSelect;

  static const _barArea = 58.0;

  @override
  Widget build(BuildContext context) {
    final scale = math.max(4.0, days.fold<double>(0, (m, d) => math.max(m, d.load)));
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (final (i, d) in days.indexed) ...[
        if (i > 0) const SizedBox(width: 4),
        Expanded(
          child: Semantics(
            button: true,
            selected: i == selected,
            onTap: () => onSelect(i),
            label: '${DateFormat('EEEE d').format(d.date)}, '
                '${d.played ? 'load ${_loadLabel(d.load)}' : 'rest day'}',
            excludeSemantics: true,
            child: InkWell(
              key: Key('fitness.day.$i'),
              borderRadius: BorderRadius.circular(CeRadius.md),
              onTap: () => onSelect(i),
              child: AnimatedContainer(
                duration: CeMotion.base,
                padding: const EdgeInsets.fromLTRB(3, 6, 3, 6),
                decoration: BoxDecoration(
                  color: i == selected ? CeColors.mint : Colors.transparent,
                  borderRadius: BorderRadius.circular(CeRadius.md),
                ),
                child: Column(children: [
                  SizedBox(
                    height: _barArea,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        widthFactor: 0.62,
                        child: d.played
                            ? Container(
                                height: math.max(8, _barArea * (d.load / scale)),
                                decoration: BoxDecoration(
                                  color: i == selected ? CeColors.primaryDark : CeColors.primary,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              )
                            : Container(
                                height: 6,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(color: CeColors.line2),
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(DateFormat('E').format(d.date)[0],
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: i == selected ? FontWeight.w800 : FontWeight.w600,
                          color: i == selected ? CeColors.primaryDark : CeColors.muted)),
                ]),
              ),
            ),
          ),
        ),
      ],
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    Widget item(Widget swatch, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          swatch,
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 11, color: CeColors.muted)),
        ]);
    return Wrap(spacing: 14, runSpacing: 4, children: [
      item(Container(width: 8, height: 8, decoration: const BoxDecoration(color: CeColors.primary, shape: BoxShape.circle)),
          'Match'),
      item(
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(2), border: Border.all(color: CeColors.line2)),
          ),
          'Rest'),
    ]);
  }
}

/// The tapped day: date, load and what happened.
class _DayDetail extends StatelessWidget {
  const _DayDetail({required this.day});
  final _Day day;

  @override
  Widget build(BuildContext context) {
    final lines = day.played
        ? [
            for (final m in day.matches)
              [
                'Match vs ${m.opponentAbbr}',
                '${m.balls} balls faced',
                if (FitnessMeter.ballsIn(m.overs) > 0) '${m.overs} overs bowled',
              ].join(' · '),
          ]
        : ['Rest day · recovery'];
    return Container(
      key: const Key('fitness.dayDetail'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: CeColors.bg,
        borderRadius: BorderRadius.circular(CeRadius.md),
        border: Border.all(color: CeColors.hairline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(DateFormat('EEE d MMM').format(day.date),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: CeColors.ink)),
          ),
          Text('Load ${_loadLabel(day.load)}',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: day.played ? CeColors.primaryDark : CeColors.muted)),
        ]),
        const SizedBox(height: 3),
        for (final l in lines) Text(l, style: const TextStyle(fontSize: 12, color: CeColors.ink2, height: 1.35)),
      ]),
    );
  }
}

/// Recommendation card: the report's recommendation, its reasons, a recovery
/// plan when rest is advised, and the next-match status.
class _Recommendation extends StatelessWidget {
  const _Recommendation({
    required this.report,
    required this.blocked,
    required this.restThisWeek,
    required this.today,
    required this.playedToday,
    required this.nextMatch,
  });

  final FitnessReport report;
  final bool blocked;
  final int restThisWeek;
  final DateTime today;
  final bool playedToday;
  final ({DateTime startsAt, String opponent})? nextMatch;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final caution = blocked || r.level.index >= FitnessLevel.fatigued.index;
    final (bg, border, accent) =
        caution ? (CeColors.redSoft, CeColors.redBorder, CeColors.red) : (CeColors.mint, CeColors.mint2, CeColors.primaryDark);
    final rest = _plural(r.restDays, 'rest day');
    final body = blocked
        ? 'Update your Availability when you’re ready to play again.'
        : switch (r.level) {
            FitnessLevel.fresh => 'Your workload is well balanced.',
            FitnessLevel.moderate => 'Your load is building — keep a rest day after your next match.',
            FitnessLevel.fatigued => 'Your recent workload is high. Take $rest before your next match.',
            FitnessLevel.overloaded => 'Your recent workload is very high. Skip matches and take $rest.',
          };
    // The report's own signals; with none, the week's facts from the same data.
    final since = r.daysSinceLastMatch;
    final reasons = r.alerts.isNotEmpty
        ? r.alerts
        : [
            if (r.matches == 0)
              'No matches in the last 7 days'
            else if (caution) ...[
              '${_plural(r.matches, 'match', 'matches')} in the last 7 days',
              if (since != null) since == 0 ? 'Last played today' : 'Last played ${_plural(since, 'day')} ago',
            ] else
              '${_plural(restThisWeek, 'rest day')} in the last 7 days',
          ];

    return Container(
      key: const Key('fitness.recommendationCard'),
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(CeRadius.lg),
        border: Border.all(color: border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Caps('Recommendation', color: accent),
        const SizedBox(height: 6),
        Text(r.recommendation,
            key: const Key('fitness.recommendation'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: CeColors.ink, height: 1.25)),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(fontSize: 12.5, color: CeColors.ink2, height: 1.4)),
        const SizedBox(height: 10),
        for (final reason in reasons)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(CeRadius.md)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(CeIcons.of(caution ? 'info' : 'check-circle'), size: 13, color: accent),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(reason, style: const TextStyle(fontSize: 12, color: CeColors.ink2, height: 1.3))),
            ]),
          ),
        if (r.restDays > 0) ...[
          const SizedBox(height: 6),
          _RecoveryPlan(restDays: r.restDays, from: playedToday ? today.add(const Duration(days: 1)) : today, accent: accent),
        ],
        if (nextMatch case final next?) ...[
          const SizedBox(height: 10),
          Container(height: 1, color: border),
          const SizedBox(height: 10),
          Row(key: const Key('fitness.nextMatch'), children: [
            Expanded(
              child: Text('Next: ${DateFormat('EEE d').format(next.startsAt)} · vs ${next.opponent}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
            ),
            const SizedBox(width: 8),
            caution
                ? const CeStatusChip('Sit out', tone: CeTone.red, icon: 'x')
                : const CeStatusChip('OK to play', icon: 'check'),
          ]),
        ],
      ]),
    );
  }
}

/// "Rest · Rest · Rest · Ready" from the report's suggested rest days.
class _RecoveryPlan extends StatelessWidget {
  const _RecoveryPlan({required this.restDays, required this.from, required this.accent});
  final int restDays;
  final DateTime from;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (var i = 0; i <= restDays; i++) (from.add(Duration(days: i)), i < restDays),
    ];
    Widget tile((DateTime, bool) item) {
      final (date, rest) = item;
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: rest ? Colors.white : CeColors.mint,
          borderRadius: BorderRadius.circular(CeRadius.md),
          border: Border.all(color: rest ? CeColors.redBorder : CeColors.mint2),
        ),
        child: Column(children: [
          Text(DateFormat('EEE d').format(date).toUpperCase(),
              maxLines: 1, style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: CeColors.muted)),
          const SizedBox(height: 3),
          Text(rest ? 'Rest' : 'Ready',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w800, color: rest ? accent : CeColors.primaryDark)),
        ]),
      );
    }

    return Column(key: const Key('fitness.recoveryPlan'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Caps('Recovery plan', color: accent),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, c) {
        const gap = 6.0;
        const minTile = 52.0;
        final fits = (c.maxWidth - gap * (items.length - 1)) / items.length >= minTile;
        if (fits) {
          return Row(children: [
            for (final (i, item) in items.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              Expanded(child: tile(item)),
            ],
          ]);
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (i, item) in items.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              SizedBox(width: minTile + 4, child: tile(item)),
            ],
          ]),
        );
      }),
    ]);
  }
}
