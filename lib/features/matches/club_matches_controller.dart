import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';

/// Club-side matches (Match Management). Rebuilt on login/logout because it
/// watches the signed-in account.
class ClubMatchesController extends AsyncNotifier<List<ClubMatch>> {
  @override
  Future<List<ClubMatch>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return ref.read(matchRepositoryProvider).clubMatches();
  }

  ClubMatch? byId(String id) => state.value?.where((m) => m.id == id).firstOrNull;

  Future<ClubMatch> save(ClubMatch match) async {
    final saved = await ref.read(matchRepositoryProvider).saveClubMatch(match);
    final list = [...?state.value];
    final i = list.indexWhere((m) => m.id == saved.id);
    i == -1 ? list.add(saved) : list[i] = saved;
    state = AsyncData(list);
    return saved;
  }

  Future<ClubMatch> createPending({required String opponentClubId, MatchFormat? format, String? city}) async {
    final m = await ref
        .read(matchRepositoryProvider)
        .createPendingMatch(opponentClubId: opponentClubId, format: format, city: city);
    state = AsyncData([...?state.value, m]);
    return m;
  }
}

final clubMatchesProvider =
    AsyncNotifierProvider<ClubMatchesController, List<ClubMatch>>(ClubMatchesController.new);

/// activeMatch — typed selected-context lookup by route id.
final clubMatchProvider = Provider.family<ClubMatch?, String>((ref, matchId) {
  return ref.watch(clubMatchesProvider).value?.where((m) => m.id == matchId).firstOrNull;
});
