import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';

/// `true` when matches are the server's (Supabase with the matches switch,
/// migration 17): scheduled by proposal and confirmation, cancelled with a
/// reason. `false` in the demo, which schedules through its booking flow.
final matchesLiveProvider = Provider<bool>((ref) => !ref.watch(backendModulesProvider).isDemo);

/// Match ids with a schedule / cancel request on its way (their buttons
/// wait; a second tap does nothing).
class BusyMatches extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool begin(String id) {
    if (state.contains(id)) return false;
    state = {...state, id};
    return true;
  }

  void end(String id) => state = {...state}..remove(id);
}

final busyMatchesProvider = NotifierProvider<BusyMatches, Set<String>>(BusyMatches.new);

/// Club-side matches (Match Management). Rebuilt on login/logout because it
/// watches the signed-in account.
class ClubMatchesController extends AsyncNotifier<List<ClubMatch>> {
  @override
  Future<List<ClubMatch>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return _load();
  }

  /// The matches; on the server each confirmed (or played) match also gets
  /// its saved lineup (migration 18 — our club's only), so every lineup
  /// screen reads [ClubMatch.lineup] in both modes.
  Future<List<ClubMatch>> _load() async {
    final repo = ref.read(matchRepositoryProvider);
    final list = await repo.clubMatches();
    if (!ref.read(matchesLiveProvider)) return list;
    return Future.wait([
      for (final m in list)
        if (m.status == MatchStatus.confirmed || m.status == MatchStatus.completed)
          repo.lineup(m.id).then((l) => l == null ? m : m.copyWith(lineup: l.asLineup))
        else
          Future.value(m),
    ]);
  }

  ClubMatch? byId(String id) => state.value?.where((m) => m.id == id).firstOrNull;

  void _put(ClubMatch m) {
    final list = [...?state.value];
    final i = list.indexWhere((x) => x.id == m.id);
    i == -1 ? list.add(m) : list[i] = m;
    state = AsyncData(list);
  }

  Future<ClubMatch> save(ClubMatch match) async {
    final saved = await ref.read(matchRepositoryProvider).saveClubMatch(match);
    _put(saved);
    return saved;
  }

  Future<ClubMatch> createPending({required String opponentClubId, MatchFormat? format, String? city}) async {
    final m = await ref
        .read(matchRepositoryProvider)
        .createPendingMatch(opponentClubId: opponentClubId, format: format, city: city);
    state = AsyncData([...?state.value, m]);
    return m;
  }

  /// Reloads the list. `false` when that failed; [keepOnError] then keeps
  /// the list shown (after a change that did succeed).
  Future<bool> refresh({bool keepOnError = false}) async {
    try {
      state = AsyncData(await _load());
      return true;
    } catch (e, st) {
      if (!keepOnError) state = AsyncError(e, st);
      return false;
    }
  }

  // ---- Server matches (migration 17): the server checks who may do what ----

  /// Proposes when and where [matchId] is played (replaces any open proposal).
  Future<ClubMatch?> proposeSchedule(String matchId, {required DateTime startsAt, required String venueName, String? city}) =>
      _run(matchId, (repo) => repo.proposeSchedule(matchId, startsAt: startsAt, venueName: venueName, city: city));

  /// Answers the other club's proposal [proposalVersion]: accept → confirmed.
  Future<ClubMatch?> respondToSchedule(String matchId, {required int proposalVersion, required bool accept}) =>
      _run(matchId, (repo) => repo.respondToSchedule(matchId, proposalVersion: proposalVersion, accept: accept));

  /// Saves our club's whole lineup for a confirmed, not-started match
  /// (exactly 11 + 4, active members, none injured / unavailable on the day:
  /// the server decides). The match then carries it as [ClubMatch.lineup].
  Future<ClubMatch?> saveLineup(String matchId, Lineup lineup, {String? captainMemberId, String? viceCaptainMemberId}) async {
    final busy = ref.read(busyMatchesProvider.notifier);
    if (!busy.begin(matchId)) return null;
    try {
      final saved = await ref.read(matchRepositoryProvider).saveLineup(
            matchId,
            lineup,
            captainMemberId: captainMemberId,
            viceCaptainMemberId: viceCaptainMemberId,
          );
      final m = byId(matchId);
      if (m == null) return null;
      final updated = m.copyWith(lineup: saved.asLineup);
      _put(updated);
      return updated;
    } finally {
      busy.end(matchId);
    }
  }

  /// Cancels a pending match, or a confirmed one before it starts.
  Future<ClubMatch?> cancel(String matchId, {required String reason}) =>
      _run(matchId, (repo) => repo.cancelMatch(matchId, reason: reason));

  /// One request per match at a time (a second returns `null`). The list is
  /// reloaded afterwards — also after a refusal, so a proposal the other
  /// club just changed, or a cancellation, shows at once — and the refusal
  /// is passed on.
  Future<ClubMatch?> _run(String matchId, Future<ClubMatch> Function(MatchRepository repo) op) async {
    final busy = ref.read(busyMatchesProvider.notifier);
    if (!busy.begin(matchId)) return null;
    try {
      final result = await op(ref.read(matchRepositoryProvider));
      // The list rows carry the opponent's name; the function's row doesn't.
      if (!await refresh(keepOnError: true)) _put(result);
      return byId(matchId) ?? result;
    } catch (_) {
      await refresh(keepOnError: true);
      rethrow;
    } finally {
      busy.end(matchId);
    }
  }
}

final clubMatchesProvider =
    AsyncNotifierProvider<ClubMatchesController, List<ClubMatch>>(ClubMatchesController.new);

/// activeMatch — typed selected-context lookup by route id.
final clubMatchProvider = Provider.family<ClubMatch?, String>((ref, matchId) {
  return ref.watch(clubMatchesProvider).value?.where((m) => m.id == matchId).firstOrNull;
});
