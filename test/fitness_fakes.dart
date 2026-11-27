// Stand-in for the fitness gateway (migration 34): canned responses per
// database function, every call recorded. Rows are shaped like the real
// functions' (docs/M9_FITNESS.md and supabase/tests/local/29).
import 'package:criceco/data/supabase/supabase_gateways.dart';

class FakeFitnessDb implements FitnessGateway {
  final calls = <({String fn, Map<String, Object?> params})>[];
  final many = <String, List<Map<String, dynamic>>>{};

  /// Every call of a function fails with this while it's set.
  final failOn = <String, GatewayException>{};

  /// `log_workout`'s stored row; by default the parameters echoed back.
  Map<String, dynamic>? Function(Map<String, Object?> params)? logRow;
  int _seq = 0;

  Iterable<String> get fns => calls.map((c) => c.fn);

  void _record(String fn, Map<String, Object?> p) {
    calls.add((fn: fn, params: p));
    if (failOn[fn] case final e?) throw e;
  }

  @override
  Future<Map<String, dynamic>> logWorkout(Map<String, Object?> params) async {
    _record('log_workout', params);
    final custom = logRow;
    if (custom != null) {
      return custom(params) ??
          (throw const GatewayUnexpectedException('log_workout-no-row'));
    }
    return workoutRow(
      'wk-server-${++_seq}',
      params['p_workout_date']! as String,
      type: params['p_workout_type']! as String,
      minutes: params['p_minutes']! as int,
      intensity: params['p_intensity']! as String,
      notes: params['p_notes'] as String?,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> myWorkouts({
    required String from,
    required String to,
  }) async {
    _record('my_workouts', {'p_from': from, 'p_to': to});
    return many['my_workouts'] ?? const [];
  }

  @override
  Future<void> deleteWorkout(String id) async =>
      _record('delete_workout', {'p_id': id});

  Future<List<Map<String, dynamic>>> _owner(
    String fn,
    String clubId,
    String from,
    String to,
  ) async {
    _record(fn, {'p_club_id': clubId, 'p_from': from, 'p_to': to});
    return many[fn] ?? const [];
  }

  @override
  Future<List<Map<String, dynamic>>> clubMemberFitness(
    String clubId, {
    required String from,
    required String to,
  }) => _owner('club_member_fitness', clubId, from, to);

  @override
  Future<List<Map<String, dynamic>>> clubMemberWorkouts(
    String clubId, {
    required String from,
    required String to,
  }) => _owner('club_member_workouts', clubId, from, to);

  @override
  Future<List<Map<String, dynamic>>> clubMemberMatchActivity(
    String clubId, {
    required String from,
    required String to,
  }) => _owner('club_member_match_activity', clubId, from, to);
}

/// A `log_workout` / `my_workouts` row.
Map<String, dynamic> workoutRow(
  String id,
  String date, {
  String type = 'gym',
  int minutes = 60,
  String intensity = 'moderate',
  String? notes,
}) => {
  'id': id,
  'workout_date': date,
  'workout_type': type,
  'minutes': minutes,
  'intensity': intensity,
  'notes': notes,
  'created_at': '${date}T08:00:00+00:00',
};

/// A `club_member_fitness` row.
Map<String, dynamic> fitnessRow(
  String memberId, {
  bool visible = true,
  String role = 'player',
  int sessions = 0,
  int minutes = 0,
  Object? load = 0,
  String? lastWorkout,
  int matches = 0,
  String? lastMatch,
}) => {
  'member_id': memberId,
  'user_id': 'u-$memberId',
  'member_role': role,
  'fitness_visible': visible,
  'workout_sessions': visible ? sessions : null,
  'workout_minutes': visible ? minutes : null,
  'training_load': visible ? load : null,
  'last_workout_date': visible ? lastWorkout : null,
  'matches': visible ? matches : null,
  'last_match_date': visible ? lastMatch : null,
};

/// A `club_member_workouts` row.
Map<String, dynamic> memberWorkoutRow(
  String memberId,
  String id,
  String date, {
  String type = 'running',
  int minutes = 60,
  String intensity = 'high',
}) => {
  'member_id': memberId,
  'workout_id': id,
  'workout_date': date,
  'workout_type': type,
  'minutes': minutes,
  'intensity': intensity,
};

/// A `club_member_match_activity` row.
Map<String, dynamic> activityRow(
  String memberId,
  String matchId,
  String startsAt, {
  String result = 'won',
  String opponent = 'Karachi Kings',
  int batRuns = 0,
  int batBalls = 0,
  int bowlBalls = 0,
  int bowlRuns = 0,
  int bowlWickets = 0,
}) => {
  'member_id': memberId,
  'match_id': matchId,
  'starts_at': startsAt,
  'club_id': 'club-a',
  'club_name': 'Lahore Lions',
  'opponent_club_id': 'club-b',
  'opponent_name': opponent,
  'result': result,
  'bat_runs': batRuns,
  'bat_balls': batBalls,
  'bowl_balls': bowlBalls,
  'bowl_runs': bowlRuns,
  'bowl_wickets': bowlWickets,
};
