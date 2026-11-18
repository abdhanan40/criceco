import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config/account_privacy.dart';
import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../core/models/models.dart';
import '../../../data/repositories/repositories.dart';
import '../club_providers.dart';

/// The owner's club's ownership offers, newest first (its ownership history).
final clubOwnershipTransfersProvider = FutureProvider<List<OwnershipTransfer>>((ref) async {
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null || !ref.watch(ownershipTransferAvailableProvider)) return const [];
  return ref.read(ownershipTransferRepositoryProvider).clubTransfers(clubId);
});

/// Open ownership offers to the signed-in user (a member being offered a club).
final myOwnershipOffersProvider = FutureProvider<List<OwnershipTransfer>>((ref) async {
  final accountId = ref.watch(currentAccountProvider.select((a) => a?.id));
  if (accountId == null || !ref.watch(ownershipTransferAvailableProvider)) return const [];
  return ref.read(ownershipTransferRepositoryProvider).myOffers();
});

/// Members the owner may offer the club to: everyone listed except the
/// owner. The database checks the rest (active, owns no club, completed
/// profile) and says why when one isn't eligible.
List<ClubMember> ownershipCandidates(List<ClubMember> members) => [
  for (final m in members)
    if (m.role != MemberRole.owner) m,
];

/// Roles the owner can choose to keep in the club once the offer is accepted.
const ownershipFormerOwnerRoles = [MemberRole.manager, MemberRole.coach, MemberRole.player];

/// Offer, cancel, accept, decline — each through
/// [ownershipTransferRepositoryProvider], refreshing what they change.
class OwnershipActions extends Notifier<void> {
  @override
  void build() {}

  OwnershipTransferRepository get _repo => ref.read(ownershipTransferRepositoryProvider);

  /// The owner offers their club to [member]; nothing changes until they accept.
  Future<OwnershipTransfer> offer({required ClubMember member, required MemberRole formerOwnerRole}) async {
    final club = ref.read(currentClubProvider);
    if (club == null) throw const PermissionDeniedException();
    final offer = await _repo.offer(clubId: club.id, memberId: member.id, previousOwnerRole: formerOwnerRole);
    ref.invalidate(clubOwnershipTransfersProvider);
    return offer;
  }

  /// The owner withdraws the open offer.
  Future<OwnershipTransfer> cancel(String transferId) async {
    try {
      return await _repo.cancel(transferId);
    } finally {
      ref.invalidate(clubOwnershipTransfersProvider);
    }
  }

  /// The member declines.
  Future<OwnershipTransfer> decline(String transferId) async {
    try {
      return await _repo.reject(transferId);
    } finally {
      ref.invalidate(myOwnershipOffersProvider);
    }
  }

  /// The member accepts: the club becomes theirs (or the offer had expired —
  /// the returned status says which). The session is re-read so the Club
  /// Owner profile appears.
  Future<OwnershipTransfer> accept(String transferId) async {
    final OwnershipTransfer result;
    try {
      result = await _repo.accept(transferId);
    } finally {
      ref.invalidate(myOwnershipOffersProvider);
    }
    if (result.status == OwnershipTransferStatus.accepted) {
      await ref.read(sessionProvider.notifier).reloadAccount();
      ref.invalidate(clubMembersProvider);
    }
    return result;
  }

  /// The former owner, once their offer was accepted: the session is re-read
  /// (no Club Owner profile any more).
  Future<void> leaveTransferredClub() async {
    await ref.read(sessionProvider.notifier).reloadAccount();
    ref.invalidate(clubOwnershipTransfersProvider);
  }
}

final ownershipActionsProvider = NotifierProvider<OwnershipActions, void>(OwnershipActions.new);
