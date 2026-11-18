import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'supabase_error_mapper.dart';
import 'supabase_gateways.dart';

/// [OwnershipTransferRepository] on Supabase (migration 16): every change is
/// a database function that checks the caller (owner for offer / cancel,
/// recipient for accept / decline) and the eligibility rules; this class
/// only maps rows and errors.
class SupabaseOwnershipTransferRepository implements OwnershipTransferRepository {
  SupabaseOwnershipTransferRepository({required this.db});

  final OwnershipGateway db;

  @override
  Future<OwnershipTransfer> offer({
    required String clubId,
    required String memberId,
    required MemberRole previousOwnerRole,
  }) async {
    if (previousOwnerRole == MemberRole.owner) {
      throw const OwnershipTransferException('Choose Player, Coach or Manager as your new role.');
    }
    final row = await _call(
      () => db.offer({'p_club_id': clubId, 'p_member_id': memberId, 'p_previous_owner_role': previousOwnerRole.name}),
    );
    return transferFromRow(row);
  }

  @override
  Future<OwnershipTransfer> cancel(String transferId) async =>
      transferFromRow(await _call(() => db.cancel(transferId)));

  @override
  Future<OwnershipTransfer> reject(String transferId) async =>
      transferFromRow(await _call(() => db.reject(transferId)));

  /// `accepted`, or `expired` when the offer ran out (nothing changed then).
  @override
  Future<OwnershipTransfer> accept(String transferId) async =>
      transferFromRow(await _call(() => db.accept(transferId)));

  @override
  Future<List<OwnershipTransfer>> clubTransfers(String clubId) async => [
    for (final r in await _call(() => db.clubTransfers(clubId))) transferFromRow(r),
  ];

  @override
  Future<List<OwnershipTransfer>> myOffers() async => [for (final r in await _call(db.myOffers)) transferFromRow(r)];

  /// A transfer row: the table's columns (`id`, …) from the write functions,
  /// or the read functions' (`transfer_id`, names, …).
  static OwnershipTransfer transferFromRow(Map<String, dynamic> row) {
    String text(Object? v) => v is String ? v : '';
    DateTime time(Object? v) =>
        (v is String ? DateTime.tryParse(v) : null)?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
    final role = MemberRole.values.where((r) => r.name == row['previous_owner_role']).firstOrNull ?? MemberRole.manager;
    return OwnershipTransfer(
      id: text(row['transfer_id'] ?? row['id']),
      clubId: text(row['club_id']),
      clubName: text(row['club_name']),
      fromName: text(row['from_name']),
      toName: text(row['to_name']),
      toMemberId: row['to_member_id'] as String?,
      status: OwnershipTransferStatus.parse(row['status'] as String?),
      previousOwnerRole: role,
      createdAt: time(row['created_at']),
      expiresAt: time(row['expires_at']),
      decidedAt: row['decided_at'] == null ? null : time(row['decided_at']),
      fromMe: row['from_me'] == true,
    );
  }

  static Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on GatewayException catch (e) {
      throw SupabaseErrorMapper.map(e);
    }
  }
}
