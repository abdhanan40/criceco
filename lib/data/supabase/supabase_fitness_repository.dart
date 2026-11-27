import 'package:clock/clock.dart';

import '../../core/models/models.dart';
import '../../core/utils/pakistan_time.dart';
import '../repositories/repositories.dart';
import 'match_row_mapper.dart';
import 'result_display_adapter.dart';
import 'supabase_error_mapper.dart' show FitnessTexts;
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart' show guardMatchCall;

/// Rows of migration 34 ↔ the app's fitness models (docs/M9_FITNESS.md).
/// Codes are exactly the Dart enum names; a row the app can't read is a
/// [MatchRowFormatException] (a generic error on screen, never a guess).
abstract final class FitnessRowMapper {
  static WorkoutType type(Object? code) => WorkoutType.values.firstWhere(
    (t) => t.name == code,
    orElse: () => throw const MatchRowFormatException('workout_type'),
  );

  static WorkoutIntensity intensity(Object? code) =>
      WorkoutIntensity.values.firstWhere(
        (i) => i.name == code,
        orElse: () => throw const MatchRowFormatException('intensity'),
      );

  static String _id(Map<String, dynamic> r, String key) => switch (r[key]) {
    final String s when s.isNotEmpty => s,
    _ => throw MatchRowFormatException(key),
  };

  static int _int(Map<String, dynamic> r, String key) =>
      _optInt(r, key) ?? (throw MatchRowFormatException(key));

  static int? _optInt(Map<String, dynamic> r, String key) => switch (r[key]) {
    null => null,
    final int n => n,
    final num n when n == n.roundToDouble() => n.toInt(),
    _ => throw MatchRowFormatException(key),
  };

  static double? _optNum(Map<String, dynamic> r, String key) =>
      switch (r[key]) {
        null => null,
        final num n => n.toDouble(),
        // PostgREST may send a numeric as text.
        final String s =>
          double.tryParse(s) ?? (throw MatchRowFormatException(key)),
        _ => throw MatchRowFormatException(key),
      };

  static DateTime _date(Map<String, dynamic> r, String key) =>
      MatchRowMapper.optDate(r, key) ?? (throw MatchRowFormatException(key));

  /// A `log_workout` / `my_workouts` row (id, workout_date, workout_type,
  /// minutes, intensity, notes, created_at).
  static WorkoutEntry workout(Map<String, dynamic> r) => WorkoutEntry(
    id: _id(r, 'id'),
    date: _date(r, 'workout_date'),
    type: type(r['workout_type']),
    minutes: _int(r, 'minutes'),
    intensity: intensity(r['intensity']),
    notes: switch (r['notes']) {
      null => '',
      final String s => s,
      _ => throw const MatchRowFormatException('notes'),
    },
  );

  /// A `club_member_workouts` row: no notes for the owner.
  static WorkoutEntry memberWorkout(Map<String, dynamic> r) => WorkoutEntry(
    id: _id(r, 'workout_id'),
    date: _date(r, 'workout_date'),
    type: type(r['workout_type']),
    minutes: _int(r, 'minutes'),
    intensity: intensity(r['intensity']),
  );

  /// A `club_member_fitness` row. A hidden member's figures are dropped
  /// whatever the row holds.
  static MemberFitnessSummary summary(Map<String, dynamic> r) {
    final visible = switch (r['fitness_visible']) {
      final bool b => b,
      _ => throw const MatchRowFormatException('fitness_visible'),
    };
    final memberId = _id(r, 'member_id');
    if (!visible) {
      return MemberFitnessSummary(memberId: memberId, visible: false);
    }
    return MemberFitnessSummary(
      memberId: memberId,
      visible: true,
      workoutSessions: _optInt(r, 'workout_sessions') ?? 0,
      workoutMinutes: _optInt(r, 'workout_minutes') ?? 0,
      trainingLoad: _optNum(r, 'training_load') ?? 0,
      lastWorkoutDate: MatchRowMapper.optDate(r, 'last_workout_date'),
      matches: _optInt(r, 'matches') ?? 0,
      lastMatchDate: MatchRowMapper.optDate(r, 'last_match_date'),
    );
  }

  static MatchResult result(Object? code) => switch (code) {
    'won' => MatchResult.won,
    'lost' => MatchResult.lost,
    'tied' => MatchResult.tied,
    'no_result' => MatchResult.noResult,
    'abandoned' => MatchResult.abandoned,
    _ => throw const MatchRowFormatException('result'),
  };

  /// A `club_member_match_activity` row → the meter's [MatchLogEntry]
  /// (overs written from the balls bowled).
  static MatchLogEntry matchEntry(Map<String, dynamic> r) {
    final opponent = switch (r['opponent_name']) {
      final String s => s,
      _ => throw const MatchRowFormatException('opponent_name'),
    };
    return MatchLogEntry(
      opponentAbbr: ResultDisplayAdapter.abbr(opponent),
      opponentName: opponent,
      date: MatchRowMapper.time(r, 'starts_at'),
      result: result(r['result']),
      runs: _optInt(r, 'bat_runs') ?? 0,
      balls: _optInt(r, 'bat_balls') ?? 0,
      wickets: _optInt(r, 'bowl_wickets') ?? 0,
      overs: oversOf(_optInt(r, 'bowl_balls') ?? 0),
    );
  }

  /// `log_workout`'s parameters. Notes are trimmed; blank is sent as null.
  static Map<String, Object?> logParams({
    required DateTime date,
    required WorkoutType type,
    required int minutes,
    required WorkoutIntensity intensity,
    String notes = '',
  }) {
    final n = notes.trim();
    return {
      'p_workout_date': MatchRowMapper.dateCode(date),
      'p_workout_type': type.name,
      'p_minutes': minutes,
      'p_intensity': intensity.name,
      'p_notes': n.isEmpty ? null : n,
    };
  }
}

/// [FitnessRepository] on Supabase (migration 34, the fitness switch).
///
/// Who may read what is checked by the database functions: the player's own
/// workouts only, and the owner's view for the owner of the club only. This
/// class validates a workout as the server does (so a refusal is rare),
/// maps rows, and maps refusals ([guardMatchCall]; `fitness: …` texts in
/// [SupabaseErrorMapper]).
class SupabaseFitnessRepository implements FitnessRepository {
  SupabaseFitnessRepository({required this.db, this.clock = const Clock()});

  final FitnessGateway db;
  final Clock clock;

  /// Today in Pakistan — the server's "today" (`Asia/Karachi`).
  DateTime get _today => PakistanTime.dateOf(clock.now());

  /// The Fitness Meter's window for the owner views: today − 6 … today.
  ({String from, String to}) get _window {
    final today = _today;
    return (
      from: MatchRowMapper.dateCode(
        DateTime(
          today.year,
          today.month,
          today.day - (FitnessReport.window - 1),
        ),
      ),
      to: MatchRowMapper.dateCode(today),
    );
  }

  @override
  Future<List<WorkoutEntry>> myWorkouts() => guardMatchCall(() async {
    final today = _today;
    final rows = await db.myWorkouts(
      from: MatchRowMapper.dateCode(
        DateTime(
          today.year,
          today.month,
          today.day - (FitnessRepository.historyDays - 1),
        ),
      ),
      to: MatchRowMapper.dateCode(today),
    );
    return [for (final r in rows) FitnessRowMapper.workout(r)];
  });

  @override
  Future<WorkoutEntry> logWorkout({
    required DateTime date,
    required WorkoutType type,
    required int minutes,
    required WorkoutIntensity intensity,
    String notes = '',
  }) => guardMatchCall(() async {
    final day = DateTime(date.year, date.month, date.day);
    final today = _today;
    if (day.isAfter(today)) {
      throw const FitnessRuleException(FitnessTexts.futureDate);
    }
    if (day.isBefore(DateTime(today.year, today.month, today.day - 365))) {
      throw const FitnessRuleException(FitnessTexts.tooOld);
    }
    if (minutes < 1 || minutes > WorkoutEntry.maxMinutes) {
      throw const FitnessRuleException(FitnessTexts.minutes);
    }
    if (notes.trim().length > WorkoutEntry.notesMaxLength) {
      throw const FitnessRuleException(FitnessTexts.notes);
    }
    final row = await db.logWorkout(
      FitnessRowMapper.logParams(
        date: day,
        type: type,
        minutes: minutes,
        intensity: intensity,
        notes: notes,
      ),
    );
    return FitnessRowMapper.workout(row);
  });

  @override
  Future<void> deleteWorkout(String id) =>
      guardMatchCall(() => db.deleteWorkout(id));

  @override
  Future<List<MemberFitnessSummary>> clubMemberFitness(String clubId) =>
      guardMatchCall(() async {
        final w = _window;
        return [
          for (final r in await db.clubMemberFitness(
            clubId,
            from: w.from,
            to: w.to,
          ))
            FitnessRowMapper.summary(r),
        ];
      });

  @override
  Future<Map<String, List<WorkoutEntry>>> clubMemberWorkouts(String clubId) =>
      guardMatchCall(() async {
        final w = _window;
        final byMember = <String, List<WorkoutEntry>>{};
        for (final r in await db.clubMemberWorkouts(
          clubId,
          from: w.from,
          to: w.to,
        )) {
          final memberId = FitnessRowMapper._id(r, 'member_id');
          (byMember[memberId] ??= []).add(FitnessRowMapper.memberWorkout(r));
        }
        return byMember;
      });

  @override
  Future<Map<String, List<MatchLogEntry>>> clubMemberMatchActivity(
    String clubId,
  ) => guardMatchCall(() async {
    final w = _window;
    final byMember = <String, List<MatchLogEntry>>{};
    for (final r in await db.clubMemberMatchActivity(
      clubId,
      from: w.from,
      to: w.to,
    )) {
      final memberId = FitnessRowMapper._id(r, 'member_id');
      (byMember[memberId] ??= []).add(FitnessRowMapper.matchEntry(r));
    }
    for (final list in byMember.values) {
      list.sort((a, b) => b.date.compareTo(a.date)); // newest first
    }
    return byMember;
  });
}
