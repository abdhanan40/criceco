// Stand-in for migration 16 (club ownership transfer), on the membership and
// club fakes: the same rules as the database functions — owner-only offers to
// an eligible active member, one pending offer per club, recipient-only
// accept / decline, owner-only cancel, 7-day expiry, and an atomic move of
// clubs.owner_id and both membership roles on accept. No network.
import 'package:criceco/data/supabase/supabase_gateways.dart';

import 'membership_fakes.dart';

class FakeOwnershipDb implements OwnershipGateway {
  FakeOwnershipDb(this.memberships);
  final FakeMembershipDb memberships;
  final transfers = <Map<String, dynamic>>[];
  final calls = <String>[];
  DateTime now = DateTime.utc(2026, 11, 18, 12);
  var _seq = 0;

  static GatewayConstraintException _err(String sqlState, String message) =>
      GatewayConstraintException(sqlState: sqlState, message: message);

  String _uid(String call) {
    calls.add(call);
    final uid = memberships.db.auth.current?.id;
    if (uid == null) throw _err('42501', 'ownership: not authenticated');
    return uid;
  }

  Map<String, dynamic>? _club(Object? id) => memberships.clubs.clubs.values.where((c) => c['id'] == id).firstOrNull;
  Map<String, dynamic>? _member(Object? id) => memberships.members.where((m) => m['id'] == id).firstOrNull;
  String _name(Object? userId) => (memberships.db.profiles['$userId']?['full_name'] as String?) ?? '';
  bool _expired(Map<String, dynamic> t) => !now.isBefore(DateTime.parse(t['expires_at'] as String));

  String? _problem(Map<String, dynamic> club, Map<String, dynamic>? m) {
    if (m == null || m['club_id'] != club['id'] || m['status'] != 'active') return 'not a member';
    if (m['user_id'] == club['owner_id']) return 'self transfer';
    if (memberships.clubs.clubs.containsKey(m['user_id'])) return 'recipient owns a club';
    if (memberships.db.profiles[m['user_id']]?['profile_completed'] != true) return 'recipient profile incomplete';
    return null;
  }

  Map<String, dynamic> _decide(Map<String, dynamic> t, String status) {
    t['status'] = _expired(t) ? 'expired' : status;
    t['decided_at'] = now.toIso8601String();
    return Map.of(t);
  }

  Map<String, dynamic> _transfer(Object? id) {
    final t = transfers.where((x) => x['id'] == id).firstOrNull;
    if (t == null) throw _err('P0002', 'ownership: not found');
    return t;
  }

  @override
  Future<Map<String, dynamic>> offer(Map<String, Object?> params) async {
    final uid = _uid('offer');
    final club = _club(params['p_club_id']);
    if (club == null) throw _err('P0002', 'ownership: club not found');
    if (club['owner_id'] != uid) throw _err('42501', 'ownership: not allowed');
    final role = '${params['p_previous_owner_role'] ?? 'manager'}';
    if (!const {'player', 'coach', 'manager'}.contains(role)) throw _err('22023', 'ownership: invalid');
    for (final t in transfers) {
      if (t['club_id'] == club['id'] && t['status'] == 'pending' && _expired(t)) _decide(t, 'expired');
    }
    final member = _member(params['p_member_id']);
    final problem = _problem(club, member);
    if (problem != null) throw _err(problem == 'not a member' ? '23514' : 'P0001', 'ownership: $problem');
    if (transfers.any((t) => t['club_id'] == club['id'] && t['status'] == 'pending')) {
      throw _err('23505', 'ownership: already pending');
    }
    final row = {
      'id': 'ot-${++_seq}',
      'club_id': club['id'],
      'from_user_id': uid,
      'to_user_id': member!['user_id'],
      'to_member_id': member['id'],
      'previous_owner_role': role,
      'status': 'pending',
      'created_at': now.toIso8601String(),
      'expires_at': now.add(const Duration(days: 7)).toIso8601String(),
      'decided_at': null,
    };
    transfers.add(row);
    return Map.of(row);
  }

  @override
  Future<Map<String, dynamic>> cancel(String transferId) async {
    final uid = _uid('cancel');
    final t = _transfer(transferId);
    if (t['from_user_id'] != uid || _club(t['club_id'])?['owner_id'] != uid) {
      throw _err('42501', 'ownership: not allowed');
    }
    if (t['status'] != 'pending') throw _err('P0001', 'ownership: not pending');
    return _decide(t, 'cancelled');
  }

  @override
  Future<Map<String, dynamic>> reject(String transferId) async {
    final uid = _uid('reject');
    final t = _transfer(transferId);
    if (t['to_user_id'] != uid) throw _err('42501', 'ownership: not allowed');
    if (t['status'] != 'pending') throw _err('P0001', 'ownership: not pending');
    return _decide(t, 'rejected');
  }

  @override
  Future<Map<String, dynamic>> accept(String transferId) async {
    final uid = _uid('accept');
    final t = _transfer(transferId);
    if (t['to_user_id'] != uid) throw _err('42501', 'ownership: not allowed');
    if (t['status'] != 'pending') throw _err('P0001', 'ownership: not pending');
    if (_expired(t)) return _decide(t, 'expired');
    final club = _club(t['club_id']);
    if (club == null) throw _err('P0002', 'ownership: club not found');
    if (club['owner_id'] != t['from_user_id']) throw _err('P0001', 'ownership: no longer valid');
    final member = _member(t['to_member_id']);
    final problem = _problem(club, member);
    if (problem != null) throw _err(problem == 'not a member' ? '23514' : 'P0001', 'ownership: $problem');
    // One transaction in the database: roles, then the club.
    for (final m in memberships.members) {
      if (m['club_id'] == club['id'] && m['user_id'] == t['from_user_id'] && m['member_role'] == 'owner') {
        m['member_role'] = t['previous_owner_role'];
      }
    }
    member!['member_role'] = 'owner';
    memberships.clubs.clubs.remove(t['from_user_id']);
    club['owner_id'] = uid;
    club['owner_name'] = _name(uid);
    memberships.clubs.clubs[uid] = club;
    t['status'] = 'accepted';
    t['decided_at'] = now.toIso8601String();
    return Map.of(t);
  }

  Map<String, dynamic> _read(Map<String, dynamic> t, String uid) => {
    'transfer_id': t['id'],
    'club_id': t['club_id'],
    'club_name': _club(t['club_id'])?['name'] ?? '',
    'status': t['status'] == 'pending' && _expired(t) ? 'expired' : t['status'],
    'previous_owner_role': t['previous_owner_role'],
    'to_member_id': t['to_member_id'],
    'from_name': _name(t['from_user_id']),
    'to_name': _name(t['to_user_id']),
    'from_me': t['from_user_id'] == uid,
    'created_at': t['created_at'],
    'expires_at': t['expires_at'],
    'decided_at': t['decided_at'],
  };

  @override
  Future<List<Map<String, dynamic>>> clubTransfers(String clubId) async {
    final uid = _uid('clubTransfers');
    final owner = _club(clubId)?['owner_id'] == uid;
    return [
      for (final t in transfers.reversed)
        if (t['club_id'] == clubId && (owner || t['from_user_id'] == uid || t['to_user_id'] == uid)) _read(t, uid),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> myOffers() async {
    final uid = _uid('myOffers');
    return [
      for (final t in transfers.reversed)
        if (t['to_user_id'] == uid && t['status'] == 'pending' && !_expired(t)) _read(t, uid),
    ];
  }
}
