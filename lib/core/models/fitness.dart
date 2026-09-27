/// Fitness Meter — a lightweight workload indication from the last 7 days of
/// match activity (and the availability status). Not a medical assessment.
enum FitnessLevel {
  fresh('Fresh'),
  moderate('Moderate'),
  fatigued('Fatigued'),
  overloaded('Overloaded');

  const FitnessLevel(this.label);
  final String label;

  static FitnessLevel ofScore(int score) => score >= 8
      ? fresh
      : score >= 6
          ? moderate
          : score >= 4
              ? fatigued
              : overloaded;
}

class FitnessReport {
  const FitnessReport({
    required this.score,
    required this.level,
    required this.recommendation,
    required this.restDays,
    required this.alerts,
    required this.matches,
    required this.oversBowled,
    required this.ballsFaced,
    required this.backToBack,
    required this.daysSinceLastMatch,
    required this.avoidPlaying,
  });

  static const window = 7; // days
  static const max = 10;

  /// 0–10.
  final int score;
  final FitnessLevel level;
  final String recommendation;

  /// Suggested rest days (0 when none needed).
  final int restDays;

  /// Short factual alerts, most important first (may be empty).
  final List<String> alerts;

  // 7-day breakdown
  final int matches;
  final String oversBowled; // "18.2"
  final int ballsFaced;
  final int backToBack;

  /// `null` when no match in the window.
  final int? daysSinceLastMatch;

  /// "Avoid playing" — overloaded, or marked injured / unavailable.
  final bool avoidPlaying;
}
