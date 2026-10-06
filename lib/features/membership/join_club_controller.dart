import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';

/// Outgoing join-by-code request (membership onboarding). Kept separate from
/// club setup so a Player-side entry can reuse it later (approved decision 14).
class JoinClubController extends Notifier<ClubJoinRequest?> {
  @override
  ClubJoinRequest? build() {
    ref.watch(sessionProvider.select((s) => s.account?.id)); // reset on logout
    return null;
  }

  /// The club behind [code] (Join Club sheet preview), or `null` if unknown.
  Future<ClubCodePreview?> lookup(String code) => ref.read(clubRepositoryProvider).findClubByCode(code);

  Future<ClubJoinRequest> send(String code) async {
    final request = await ref.read(clubRepositoryProvider).requestToJoin(code);
    state = request;
    return request;
  }

  void cancel() => state = null;

  /// Owner approval (arrives from the owner side; simulated in Demo Mode).
  /// Adds a club membership only — never the account-level Club Owner role.
  Future<void> approve(MemberRole role) async {
    final request = state;
    if (request == null) return;
    await ref.read(sessionProvider.notifier).addMembership(ClubMembership(
          clubId: 'club_${request.clubCode.toLowerCase()}',
          clubName: request.clubName,
          clubCode: request.clubCode,
          role: role,
        ));
    state = request.copyWith(status: JoinRequestStatus.approved, approvedRole: role);
  }

  /// "Continue to Dashboard" after approval: the Player context.
  void enterPlayerContext() => ref.read(roleControllerProvider.notifier).enterPlayerContext();
}

final joinClubProvider = NotifierProvider<JoinClubController, ClubJoinRequest?>(JoinClubController.new);

/// A club's public details by code (Club sheet: the club a player joined).
final clubPreviewProvider = FutureProvider.family<ClubCodePreview?, String>(
  (ref, code) => ref.read(clubRepositoryProvider).findClubByCode(code),
);
