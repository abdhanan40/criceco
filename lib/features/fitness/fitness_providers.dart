import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../core/utils/fitness_meter.dart';
import '../club/club_providers.dart';
import '../club/teams/teams_controller.dart';
import '../player/player_providers.dart';

/// Workouts the signed-in player logged (Add Workout). Kept for the session,
/// per account; newest last.
class PlayerWorkoutsController extends Notifier<List<WorkoutEntry>> {
  @override
  List<WorkoutEntry> build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return const [];
  }

  int _seq = 0;

  WorkoutEntry add({
    required DateTime date,
    required WorkoutType type,
    required int minutes,
    required WorkoutIntensity intensity,
    String notes = '',
  }) {
    // Same rules as the sheet, enforced here too: no future workouts, and
    // 1–[WorkoutEntry.maxMinutes] minutes.
    final now = ref.read(clockProvider).now();
    if (DateTime(date.year, date.month, date.day).isAfter(DateTime(now.year, now.month, now.day))) {
      throw ArgumentError.value(date, 'date', "A workout can't be in the future");
    }
    if (minutes <= 0 || minutes > WorkoutEntry.maxMinutes) {
      throw ArgumentError.value(minutes, 'minutes', 'Enter minutes between 1 and ${WorkoutEntry.maxMinutes}');
    }
    final entry = WorkoutEntry(
      id: 'wk_${date.millisecondsSinceEpoch}_${_seq++}',
      date: date,
      type: type,
      minutes: minutes,
      intensity: intensity,
      notes: notes.trim(),
    );
    state = [...state, entry];
    return entry;
  }
}

final playerWorkoutsProvider =
    NotifierProvider<PlayerWorkoutsController, List<WorkoutEntry>>(PlayerWorkoutsController.new);

/// The signed-in player's Fitness Meter: their own match log, logged
/// workouts and availability. `null` while performance loads.
final playerFitnessProvider = Provider<FitnessReport?>((ref) {
  final log = ref.watch(performanceProvider).value?.matchLog;
  if (log == null) return null;
  return FitnessMeter.evaluate(
    log,
    now: ref.read(clockProvider).now(),
    availability: ref.watch(playerAvailabilityProvider.select((a) => a.status)),
    workouts: ref.watch(playerWorkoutsProvider),
  );
});

/// Recent match activity per club member id.
final memberActivityProvider = FutureProvider<Map<String, List<MatchLogEntry>>>((ref) async {
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null) return const {};
  return ref.read(clubRepositoryProvider).memberActivity(clubId);
});

/// A club member's recent matches (the Owner row uses the account's own log).
final memberRecentMatchesProvider = Provider.family<List<MatchLogEntry>, String>((ref, memberId) {
  final member = ref.watch(clubMemberProvider(memberId));
  if (member?.role == MemberRole.owner) return ref.watch(performanceProvider).value?.matchLog ?? const [];
  return ref.watch(memberActivityProvider).value?[memberId] ?? const [];
});

/// Fitness for a club member who plays; `null` for non-playing staff.
final memberFitnessProvider = Provider.family<FitnessReport?, String>((ref, memberId) {
  final member = ref.watch(clubMemberProvider(memberId));
  if (member == null || !member.plays) return null;
  if (member.role == MemberRole.owner) return ref.watch(playerFitnessProvider);
  final pool = ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
  final availability =
      pool.where((p) => p.id == member.poolPlayerId).firstOrNull?.availability ?? PlayerAvailability.available;
  return FitnessMeter.evaluate(
    ref.watch(memberRecentMatchesProvider(memberId)),
    now: ref.read(clockProvider).now(),
    availability: availability,
  );
});

/// Fitness by club-pool player id (Suggest Team ranking). Pool players with
/// no linked member have no recorded recent matches.
final poolFitnessProvider = Provider<Map<String, FitnessReport>>((ref) {
  final pool = ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
  final members = ref.watch(clubMembersProvider).value ?? const <ClubMember>[];
  final activity = ref.watch(memberActivityProvider).value ?? const {};
  final now = ref.read(clockProvider).now();
  return {
    for (final p in pool)
      p.id: FitnessMeter.evaluate(
        activity[members.where((m) => m.poolPlayerId == p.id).firstOrNull?.id] ?? const [],
        now: now,
        availability: p.availability,
      ),
  };
});
