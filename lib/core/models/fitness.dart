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

/// A self-logged workout (Player Dashboard → Add Workout). Training load for
/// the Fitness Meter; matches are still read from the match log.
enum WorkoutType {
  training('Training'),
  gym('Gym / Strength'),
  running('Running / Cardio'),
  nets('Nets / Practice'),
  other('Other');

  const WorkoutType(this.label);
  final String label;
}

enum WorkoutIntensity {
  light('Light', 0.5),
  moderate('Moderate', 1.0),
  high('High', 1.5);

  const WorkoutIntensity(this.label, this.pointsPerHour);
  final String label;

  /// Fitness Meter workload points per hour of this intensity (a match = 2).
  final double pointsPerHour;
}

class WorkoutEntry {
  const WorkoutEntry({
    required this.id,
    required this.date,
    required this.type,
    required this.minutes,
    required this.intensity,
    this.notes = '',
  });

  static const maxMinutes = 600;
  static const notesMaxLength = 120;

  final String id;
  final DateTime date;
  final WorkoutType type;
  final int minutes;
  final WorkoutIntensity intensity;
  final String notes;
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
    this.trainingSessions = 0,
    this.trainingLoad = 0,
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

  /// Logged workouts in the window and the load they added (0 without any).
  final int trainingSessions;
  final double trainingLoad;
}
