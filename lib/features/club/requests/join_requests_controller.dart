import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../core/models/models.dart';
import '../club_providers.dart';

/// Club roles an owner can give when approving a request. Never
/// [MemberRole.owner]: approval creates a club membership only and does not
/// grant the account-level Club Owner role (approved fix C).
const assignableMemberRoles = [MemberRole.player, MemberRole.coach, MemberRole.manager];

/// Incoming requests to join the owner's club — the single source for the
/// Requests screen, the requester profile and the dashboard count.
class JoinRequestsController extends AsyncNotifier<List<JoinRequest>> {
  @override
  Future<List<JoinRequest>> build() async {
    final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
    if (clubId == null) return const [];
    return ref.read(clubRepositoryProvider).joinRequests(clubId);
  }

  /// Approve with a club role (prototype default: Player). Returns the
  /// decided request, or `null` if it no longer exists.
  Future<JoinRequest?> approve(String requestId, {MemberRole role = MemberRole.player}) =>
      _decide(requestId, approve: true, role: role);

  Future<JoinRequest?> decline(String requestId) => _decide(requestId, approve: false);

  Future<JoinRequest?> _decide(String requestId, {required bool approve, MemberRole role = MemberRole.player}) async {
    final clubId = ref.read(currentClubProvider)?.id;
    final current = state.value?.where((r) => r.id == requestId).firstOrNull;
    if (clubId == null || current == null) return null;
    if (!current.isPending) return current; // already reviewed (double tap)
    final decided = await ref.read(clubRepositoryProvider).decideJoinRequest(
          clubId,
          requestId,
          approve: approve,
          role: role,
          at: ref.read(clockProvider).now(),
        );
    state = AsyncData([for (final r in state.value ?? const <JoinRequest>[]) r.id == requestId ? decided : r]);
    // The new member appears in Members, My Club and the dashboard count.
    if (approve) ref.invalidate(clubMembersProvider);
    return decided;
  }
}

final joinRequestsProvider =
    AsyncNotifierProvider<JoinRequestsController, List<JoinRequest>>(JoinRequestsController.new);

/// Selected request — typed lookup by route id (no array indices).
final joinRequestProvider = Provider.family<JoinRequest?, String>(
  (ref, requestId) => ref.watch(joinRequestsProvider).value?.where((r) => r.id == requestId).firstOrNull,
);

/// One Requests tab. Pending keeps arrival order; reviewed tabs show the most
/// recent decision first.
final joinRequestsByReviewProvider = Provider.family<List<JoinRequest>, JoinRequestReview>((ref, review) {
  final list = (ref.watch(joinRequestsProvider).value ?? const <JoinRequest>[]).where((r) => r.review == review).toList();
  if (review != JoinRequestReview.pending) {
    list.sort((a, b) => (b.decidedAt ?? DateTime(0)).compareTo(a.decidedAt ?? DateTime(0)));
  }
  return list;
});

/// Dashboard "Requests" stat and header badge: pending only (`null` while loading).
final pendingJoinRequestCountProvider = Provider<int?>((ref) {
  final async = ref.watch(joinRequestsProvider);
  if (!async.hasValue) return null;
  return async.value!.where((r) => r.isPending).length;
});
