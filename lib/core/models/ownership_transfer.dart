import '../enums/enums.dart';

/// Where a club ownership offer stands (migration 16). Only `accepted` moves
/// the club; the others leave everything as it was.
enum OwnershipTransferStatus {
  pending('Waiting for an answer'),
  accepted('Accepted'),
  rejected('Declined'),
  cancelled('Cancelled'),
  expired('Expired');

  const OwnershipTransferStatus(this.label);
  final String label;

  static OwnershipTransferStatus parse(String? value) =>
      values.where((s) => s.name == value).firstOrNull ?? OwnershipTransferStatus.expired;
}

/// A club ownership offer: the owner offers the club to a member, who
/// accepts or declines; it can be cancelled and it expires after 7 days.
/// The offers of a club are also its ownership history.
class OwnershipTransfer {
  const OwnershipTransfer({
    required this.id,
    required this.clubId,
    required this.status,
    required this.previousOwnerRole,
    required this.createdAt,
    required this.expiresAt,
    this.clubName = '',
    this.fromName = '',
    this.toName = '',
    this.toMemberId,
    this.decidedAt,
    this.fromMe = false,
  });

  /// The signed-in user made this offer (they were the owner then).
  final bool fromMe;

  final String id;
  final String clubId;
  final String clubName;

  /// The owner who made the offer, and the member it is for (names as stored
  /// on their profiles; empty when that person has since deleted their account).
  final String fromName;
  final String toName;
  final String? toMemberId;

  final OwnershipTransferStatus status;

  /// The role the offering owner takes in the club once the offer is accepted.
  final MemberRole previousOwnerRole;

  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? decidedAt;

  bool get isPending => status == OwnershipTransferStatus.pending;
}
