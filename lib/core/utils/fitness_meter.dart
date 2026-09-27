import '../models/models.dart';
import 'formatters.dart';

/// Fitness Meter rules (approved). Workload from the last 7 days of matches:
///
/// * Start at 10; −2 per match, −1 per 4 overs bowled, −0.5 per 30 balls
///   faced, −1 per back-to-back match day; +1 per rest day since the last
///   match. Rounded and kept within 0–10.
/// * 8–10 Fresh · 6–7 Moderate · 4–5 Fatigued · 0–3 Overloaded.
/// * Injured / Unavailable (Availability) always means "Avoid playing".
abstract final class FitnessMeter {
  /// Balls in an overs figure: "3.4" = 3 overs 4 balls = 22.
  static int ballsIn(String overs) {
    final parts = overs.trim().split('.');
    final whole = int.tryParse(parts.first) ?? 0;
    final extra = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return whole * 6 + extra.clamp(0, 5);
  }

  static FitnessReport evaluate(
    List<MatchLogEntry> log, {
    required DateTime now,
    PlayerAvailability availability = PlayerAvailability.available,
  }) {
    final today = CeFormat.dateOnly(now);
    final from = today.subtract(const Duration(days: FitnessReport.window - 1));
    final recent = [
      for (final m in log)
        if (!CeFormat.dateOnly(m.date).isBefore(from) && !CeFormat.dateOnly(m.date).isAfter(today)) m,
    ];
    final days = {for (final m in recent) CeFormat.dateOnly(m.date)}.toList()..sort();

    final matches = recent.length;
    final balls = recent.fold<int>(0, (s, m) => s + ballsIn(m.overs));
    final faced = recent.fold<int>(0, (s, m) => s + m.balls);
    var backToBack = 0;
    for (var i = 1; i < days.length; i++) {
      if (days[i].difference(days[i - 1]).inDays == 1) backToBack++;
    }
    final sinceLast = days.isEmpty ? null : today.difference(days.last).inDays;

    final load = 2.0 * matches + (balls ~/ 24) + 0.5 * (faced ~/ 30) + backToBack;
    final recovery = sinceLast ?? 0;
    final score = matches == 0 ? FitnessReport.max : (10 - load + recovery).round().clamp(0, FitnessReport.max);
    final level = FitnessLevel.ofScore(score);
    final restDays = level.index >= FitnessLevel.fatigued.index ? (7 - score).clamp(1, 7) : 0;
    final blocked = availability.locksSelection;

    final overs = '${balls ~/ 6}${balls % 6 == 0 ? '' : '.${balls % 6}'}';
    final alerts = <String>[
      if (blocked) 'Marked ${availability.label.toLowerCase()} on Availability',
      if (matches >= 3) '$matches matches in the last 7 days',
      if (balls >= 12 * 6) '$overs overs bowled this week',
      if (backToBack > 0) 'Played on consecutive days',
    ];
    final rest = '$restDays rest day${restDays == 1 ? '' : 's'}';
    final recommendation = blocked
        ? 'Avoid playing — marked ${availability.label.toLowerCase()}'
        : switch (level) {
            FitnessLevel.fresh => 'Good to play',
            FitnessLevel.moderate => 'Can safely play one more match, then rest',
            FitnessLevel.fatigued => 'Take $rest before the next match',
            FitnessLevel.overloaded => 'Avoid playing — take $rest',
          };
    return FitnessReport(
      score: score,
      level: level,
      recommendation: recommendation,
      restDays: restDays,
      alerts: alerts,
      matches: matches,
      oversBowled: overs,
      ballsFaced: faced,
      backToBack: backToBack,
      daysSinceLastMatch: sinceLast,
      avoidPlaying: blocked || level == FitnessLevel.overloaded,
    );
  }
}
