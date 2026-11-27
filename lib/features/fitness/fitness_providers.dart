import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../core/utils/fitness_meter.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/pakistan_time.dart';
import '../../data/repositories/repositories.dart';
import '../club/club_providers.dart';
import '../club/teams/teams_controller.dart';
import '../player/player_providers.dart';

/// "Today" for a workout: the date in Pakistan when workouts are saved on
/// the server (migration 34 checks `Asia/Karachi`), the device's date in the
/// demo. A function, so it is read at the moment it is needed.
final workoutTodayProvider = Provider<DateTime Function()>((ref) {
  final clock = ref.watch(clockProvider);
  final live = ref.watch(fitnessBackendLiveProvider);
  return () => live ? PakistanTime.dateOf(clock.now()) : CeFormat.dateOnly(clock.now());
});

/// The signed-in player's workouts on the server (migration 34, the
/// fitness switch): the last [FitnessRepository.historyDays] days, oldest
/// first. Empty without the server side (no network call).
final serverWorkoutsProvider = FutureProvider<List<WorkoutEntry>>((ref) async {
  final accountId = ref.watch(currentAccountProvider.select((a) => a?.id));
  if (accountId == null || !ref.watch(fitnessBackendLiveProvider)) return const [];
  return ref.watch(fitnessRepositoryProvider).myWorkouts();
});

/// Workouts the signed-in player logged (Add Workout), newest last. Per
/// account. Demo: kept for the session. With the fitness switch: the
/// server's ([serverWorkoutsProvider]), and [save] / [delete] go to the
/// server first.
class PlayerWorkoutsController extends Notifier<List<WorkoutEntry>> {
  @override
  List<WorkoutEntry> build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    if (ref.watch(fitnessBackendLiveProvider)) {
      return ref.watch(serverWorkoutsProvider).value ?? const [];
    }
    return const [];
  }

  int _seq = 0;

  /// The sheet's rules, enforced here too: no future workouts (today in
  /// Pakistan with the server), 1–[WorkoutEntry.maxMinutes] minutes and at
  /// most [WorkoutEntry.notesMaxLength] characters of notes.
  void _check(DateTime date, int minutes, String notes) {
    final today = ref.read(workoutTodayProvider)();
    if (DateTime(date.year, date.month, date.day).isAfter(today)) {
      throw ArgumentError.value(date, 'date', "A workout can't be in the future");
    }
    if (minutes <= 0 || minutes > WorkoutEntry.maxMinutes) {
      throw ArgumentError.value(minutes, 'minutes', 'Enter minutes between 1 and ${WorkoutEntry.maxMinutes}');
    }
    if (notes.trim().length > WorkoutEntry.notesMaxLength) {
      throw ArgumentError.value(notes, 'notes', 'Keep the notes to ${WorkoutEntry.notesMaxLength} characters');
    }
  }

  /// Logs a workout for this session only (the demo).
  WorkoutEntry add({
    required DateTime date,
    required WorkoutType type,
    required int minutes,
    required WorkoutIntensity intensity,
    String notes = '',
  }) {
    _check(date, minutes, notes);
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

  /// Add Workout's save: on the server with the fitness switch (the stored
  /// workout is added to the list), otherwise [add]. A refusal throws (an
  /// [AccountException] from the server, [ArgumentError] for the app's own
  /// checks) and nothing changes.
  Future<WorkoutEntry> save({
    required DateTime date,
    required WorkoutType type,
    required int minutes,
    required WorkoutIntensity intensity,
    String notes = '',
  }) async {
    if (!ref.read(fitnessBackendLiveProvider)) {
      return add(date: date, type: type, minutes: minutes, intensity: intensity, notes: notes);
    }
    _check(date, minutes, notes);
    final stored = await ref.read(fitnessRepositoryProvider).logWorkout(
          date: date,
          type: type,
          minutes: minutes,
          intensity: intensity,
          notes: notes,
        );
    if (ref.mounted) state = [...state.where((w) => w.id != stored.id), stored];
    return stored;
  }

  /// Deletes one of the player's workouts (on the server first, with the
  /// fitness switch). A refusal throws and the list is unchanged.
  Future<void> delete(String id) async {
    if (ref.read(fitnessBackendLiveProvider)) {
      await ref.read(fitnessRepositoryProvider).deleteWorkout(id);
    }
    if (ref.mounted) state = [for (final w in state) if (w.id != id) w];
  }
}

final playerWorkoutsProvider =
    NotifierProvider<PlayerWorkoutsController, List<WorkoutEntry>>(PlayerWorkoutsController.new);

/// Whether this build records the data the Fitness Meter is worked out from
/// (the match statistics, availability and workouts — the
/// [BackendModule.playerStats] module: the demo, or Supabase with the fitness
/// switch). Without it there is no fitness to show: "not recorded", never a
/// perfect 10 from an empty log.
final fitnessRecordedProvider = Provider<bool>((ref) => ref.watch(backendModulesProvider).has(BackendModule.playerStats));

/// The signed-in player's Fitness Meter: their own match log, logged
/// workouts and availability. `null` while performance (or, with the
/// server, the workouts) loads or couldn't be loaded.
final playerFitnessProvider = Provider<FitnessReport?>((ref) {
  if (!ref.watch(fitnessRecordedProvider)) return null;
  final log = ref.watch(performanceProvider).value?.matchLog;
  if (log == null) return null;
  if (ref.watch(fitnessBackendLiveProvider) && !ref.watch(serverWorkoutsProvider).hasValue) return null;
  return FitnessMeter.evaluate(
    log,
    now: ref.read(clockProvider).now(),
    availability: ref.watch(playerAvailabilityProvider.select((a) => a.status)),
    workouts: ref.watch(playerWorkoutsProvider),
  );
});

/// The owner's inputs for the squad's Fitness Meters: recent match activity
/// per club member id and — with the fitness switch (migration 34) — which
/// members share their stats and their workouts in the window.
class OwnerFitnessData {
  const OwnerFitnessData({
    this.activity = const {},
    this.summaries,
    this.workouts = const {},
  });

  final Map<String, List<MatchLogEntry>> activity;

  /// `club_member_fitness` by member id; `null` without the server side
  /// (every member's fitness is worked out from [activity], as in the demo).
  final Map<String, MemberFitnessSummary>? summaries;
  final Map<String, List<WorkoutEntry>> workouts;
}

final ownerFitnessDataProvider = FutureProvider<OwnerFitnessData>((ref) async {
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null) return const OwnerFitnessData();
  final clubs = ref.read(clubRepositoryProvider);
  if (!ref.watch(fitnessBackendLiveProvider)) {
    return OwnerFitnessData(activity: await clubs.memberActivity(clubId));
  }
  final fitness = ref.read(fitnessRepositoryProvider);
  try {
    final rows = await Future.wait<Object>([
      clubs.memberActivity(clubId),
      fitness.clubMemberFitness(clubId),
      fitness.clubMemberWorkouts(clubId),
    ]);
    return OwnerFitnessData(
      activity: rows[0] as Map<String, List<MatchLogEntry>>,
      summaries: {for (final s in rows[1] as List<MemberFitnessSummary>) s.memberId: s},
      workouts: rows[2] as Map<String, List<WorkoutEntry>>,
    );
  } on AccountException {
    // Not readable now (no connection, no longer the owner…): no member's
    // fitness is shown — never a score from missing data.
    return const OwnerFitnessData(summaries: {});
  }
});

/// Recent match activity per club member id.
final memberActivityProvider = FutureProvider<Map<String, List<MatchLogEntry>>>(
  (ref) async => (await ref.watch(ownerFitnessDataProvider.future)).activity,
);

/// With the server side: [memberId] doesn't share their stats ("not
/// shared"). `false` in the demo, while loading, and when nothing could be
/// read (then no fitness is shown at all, see [memberFitnessProvider]).
final memberFitnessHiddenProvider = Provider.family<bool, String>((ref, memberId) {
  final member = ref.watch(clubMemberProvider(memberId));
  if (member == null || member.role == MemberRole.owner) return false;
  final summary = ref.watch(ownerFitnessDataProvider).value?.summaries?[memberId];
  return summary != null && !summary.visible;
});

/// A club member's recent matches (the Owner row uses the account's own log).
final memberRecentMatchesProvider = Provider.family<List<MatchLogEntry>, String>((ref, memberId) {
  final member = ref.watch(clubMemberProvider(memberId));
  if (member?.role == MemberRole.owner) return ref.watch(performanceProvider).value?.matchLog ?? const [];
  return ref.watch(memberActivityProvider).value?[memberId] ?? const [];
});

/// A club member's logged workouts in the window (the Owner row uses the
/// account's own). Empty in the demo.
final memberWorkoutsProvider = Provider.family<List<WorkoutEntry>, String>((ref, memberId) {
  final member = ref.watch(clubMemberProvider(memberId));
  if (member?.role == MemberRole.owner) return ref.watch(playerWorkoutsProvider);
  return ref.watch(ownerFitnessDataProvider).value?.workouts[memberId] ?? const [];
});

/// Fitness for a club member who plays; `null` for non-playing staff, when
/// fitness isn't recorded in this build, while the squad's data loads, and
/// for a member who doesn't share their stats.
final memberFitnessProvider = Provider.family<FitnessReport?, String>((ref, memberId) {
  if (!ref.watch(fitnessRecordedProvider)) return null;
  final member = ref.watch(clubMemberProvider(memberId));
  if (member == null || !member.plays) return null;
  if (member.role == MemberRole.owner) return ref.watch(playerFitnessProvider);
  if (ref.watch(fitnessBackendLiveProvider)) {
    // Only a member the server lists as sharing: hidden, not listed, still
    // loading or not readable → no score.
    final summary = ref.watch(ownerFitnessDataProvider).value?.summaries?[memberId];
    if (summary == null || !summary.visible) return null;
  }
  final pool = ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
  final availability =
      pool.where((p) => p.id == member.poolPlayerId).firstOrNull?.availability ?? PlayerAvailability.available;
  return FitnessMeter.evaluate(
    ref.watch(memberRecentMatchesProvider(memberId)),
    now: ref.read(clockProvider).now(),
    availability: availability,
    workouts: ref.watch(memberWorkoutsProvider(memberId)),
  );
});

/// Fitness by club-pool player id (Suggest Team ranking). Pool players with
/// no linked member have no recorded recent matches. Empty when fitness isn't
/// recorded in this build; with the server side, a member who doesn't share
/// their stats has no entry (it counts nothing — never a perfect score).
final poolFitnessProvider = Provider<Map<String, FitnessReport>>((ref) {
  if (!ref.watch(fitnessRecordedProvider)) return const {};
  final pool = ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[];
  final members = ref.watch(clubMembersProvider).value ?? const <ClubMember>[];
  final data = ref.watch(ownerFitnessDataProvider).value ?? const OwnerFitnessData();
  final live = ref.watch(fitnessBackendLiveProvider);
  if (live && data.summaries == null) return const {};
  final now = ref.read(clockProvider).now();
  return {
    for (final p in pool)
      if (members.where((m) => m.poolPlayerId == p.id).firstOrNull?.id case final memberId)
        if (!live || (memberId != null && (data.summaries![memberId]?.visible ?? false)))
          p.id: FitnessMeter.evaluate(
            data.activity[memberId] ?? const [],
            now: now,
            availability: p.availability,
            workouts: data.workouts[memberId] ?? const [],
          ),
  };
});
