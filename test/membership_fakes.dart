import 'package:criceco/data/supabase/supabase_gateways.dart';

import 'supabase_fakes.dart';

/// Stand-ins for migration 11 (club memberships) and migration 12 (teams):
/// the same rules as the database functions — the caller is the signed-in
/// user ([FakeDb.auth]), only a club's owner may decide, remove or change
/// teams, at most one pending request per (club, person), one membership row
/// per (club, person), squads within 11 + 4 of active members, captain and
/// vice-captain two different squad players — with the same "club_join:" /
/// "team:" messages and SQLSTATEs. In memory only; no network.
///
/// These fakes test the APP against the contract. The SQL itself is
/// verified only when the migrations are run (docs/CLUB_MEMBERSHIP_…).
class FakeMembershipDb implements MembershipGateway {
  FakeMembershipDb(this.db, this.clubs);
  final FakeDb db;
  final FakeClubDb clubs;

  final members = <Map<String, dynamic>>[];
  final requests = <Map<String, dynamic>>[];
  final calls = <String>[];
  GatewayException? failNext;
  var _seq = 0;
  DateTime now = DateTime.utc(2026, 11, 16, 10);

  String _id(String p) => '$p-${++_seq}';

  static GatewayConstraintException _err(String sqlState, String message) =>
      GatewayConstraintException(sqlState: sqlState, message: message);

  String _uid(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    final uid = db.auth.current?.id;
    if (uid == null) throw _err('42501', 'club_join: not authenticated');
    _ownerRows();
    return uid;
  }

  /// The owner rows the clubs trigger / backfill create.
  void _ownerRows() {
    for (final c in clubs.clubs.values) {
      if (!members.any((m) => m['club_id'] == c['id'] && m['user_id'] == c['owner_id'])) {
        members.add({
          'id': _id('m'),
          'club_id': c['id'],
          'user_id': c['owner_id'],
          'member_role': 'owner',
          'status': 'active',
          'joined_at': now.toIso8601String(),
        });
      }
    }
  }

  Map<String, dynamic>? _club(String id) => clubs.clubs.values.where((c) => c['id'] == id).firstOrNull;
  bool _owns(String uid, Object? clubId) => _club('$clubId')?['owner_id'] == uid;

  Map<String, dynamic>? _active(Object? clubId, Object? userId) => members
      .where((m) => m['club_id'] == clubId && m['user_id'] == userId && m['status'] == 'active')
      .firstOrNull;

  // ---- Test helpers ----

  /// Failed code attempts per user (the brute-force throttle).
  final attempts = <String, List<DateTime>>{};

  bool _throttled(String uid) =>
      (attempts[uid] ?? const <DateTime>[]).where((t) => now.difference(t) < const Duration(minutes: 15)).length >= 10;

  void _failed(String uid) => (attempts[uid] ??= []).add(now);

  /// [user] asks to join the club with [code] (as that user).
  Map<String, dynamic>? requestAs(AuthUser user, String code) {
    final previous = db.auth.current;
    db.auth.current = user;
    try {
      return _request(_uid('requestAs'), code);
    } finally {
      db.auth.current = previous;
    }
  }

  // ---- MembershipGateway ----

  @override
  Future<Map<String, dynamic>?> lookupClubByCode(String code) async {
    final uid = _uid('lookupClubByCode');
    if (_throttled(uid)) throw _err('P0001', 'club_join: too many attempts');
    final c = code.trim().toUpperCase();
    final club =
        RegExp(r'^[A-Z0-9]{6}$').hasMatch(c) ? clubs.clubs.values.where((x) => x['code'] == c).firstOrNull : null;
    if (club == null) {
      _failed(uid);
      return null;
    }
    return {
      'club_id': club['id'],
      'name': club['name'],
      'city': club['city'],
      'club_type': club['club_type'],
      'member_count': members.where((m) => m['club_id'] == club['id'] && m['status'] == 'active').length,
      'is_own_club': club['owner_id'] == uid,
      'is_member': _active(club['id'], uid) != null,
      'has_pending': requests.any((r) => r['club_id'] == club['id'] && r['user_id'] == uid && r['status'] == 'pending'),
    };
  }

  @override
  Future<Map<String, dynamic>?> requestToJoin(String code) async => _request(_uid('requestToJoin'), code);

  /// `null` for an unknown code (counted), as the function returns NULL.
  Map<String, dynamic>? _request(String uid, String code) {
    if (_throttled(uid)) throw _err('P0001', 'club_join: too many attempts');
    if (db.profiles[uid]?['profile_completed'] != true) throw _err('P0001', 'club_join: profile incomplete');
    final c = code.trim().toUpperCase();
    final club = clubs.clubs.values.where((x) => x['code'] == c).firstOrNull;
    if (club == null) {
      _failed(uid);
      return null;
    }
    if (club['owner_id'] == uid) throw _err('P0001', 'club_join: own club');
    if (_active(club['id'], uid) != null) throw _err('P0001', 'club_join: already member');
    // One pending request per person, any club (the unique index on user_id).
    if (requests.any((r) => r['user_id'] == uid && r['status'] == 'pending')) {
      throw _err('P0001', 'club_join: already pending');
    }
    final row = {
      'id': _id('r'),
      'club_id': club['id'],
      'user_id': uid,
      'status': 'pending',
      'created_at': now.toIso8601String(),
      'decided_at': null,
      'assigned_role': null,
      'decline_reason': null,
    };
    requests.add(row);
    return Map.of(row);
  }

  @override
  Future<Map<String, dynamic>> cancelJoinRequest(String requestId) async {
    final uid = _uid('cancelJoinRequest');
    final r = requests.where((x) => x['id'] == requestId).firstOrNull;
    if (r == null || r['user_id'] != uid) throw _err('P0002', 'club_join: not found');
    if (r['status'] != 'pending') throw _err('P0001', 'club_join: not pending');
    r
      ..['status'] = 'cancelled'
      ..['decided_at'] = now.toIso8601String();
    return Map.of(r);
  }

  @override
  Future<List<Map<String, dynamic>>> myJoinRequests() async {
    final uid = _uid('myJoinRequests');
    final mine = requests.where((r) => r['user_id'] == uid).toList().reversed;
    return [
      for (final r in mine)
        {
          'request_id': r['id'],
          'club_id': r['club_id'],
          'club_name': _club('${r['club_id']}')?['name'],
          'club_code': _club('${r['club_id']}')?['code'],
          'status': r['status'],
          'assigned_role': r['assigned_role'],
          'decline_reason': r['decline_reason'],
          'created_at': r['created_at'],
          'decided_at': r['decided_at'],
        },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> myMemberships() async {
    final uid = _uid('myMemberships');
    return [
      for (final m in members)
        if (m['user_id'] == uid && m['status'] == 'active' && m['member_role'] != 'owner')
          {
            'member_id': m['id'],
            'club_id': m['club_id'],
            'club_name': _club('${m['club_id']}')?['name'],
            'club_code': _club('${m['club_id']}')?['code'],
            'city': _club('${m['club_id']}')?['city'],
            'member_role': m['member_role'],
            'joined_at': m['joined_at'],
          },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> clubJoinRequests(String clubId) async {
    final uid = _uid('clubJoinRequests');
    if (!_owns(uid, clubId)) throw _err('42501', 'club_join: not allowed');
    return [
      for (final r in requests)
        if (r['club_id'] == clubId && r['status'] != 'cancelled')
          {
            'request_id': r['id'],
            'status': r['status'],
            'assigned_role': r['assigned_role'],
            'decline_reason': r['decline_reason'],
            'created_at': r['created_at'],
            'decided_at': r['decided_at'],
            ..._person(r['user_id'] as String),
          },
    ];
  }

  Map<String, dynamic> _person(String userId) {
    final p = db.profiles[userId] ?? const {};
    final pp = db.players[userId];
    return {
      'full_name': p['full_name'],
      'phone': p['phone'],
      // The age only — never the date of birth (as club_join_requests).
      'applicant_age': _age(p['date_of_birth'] as String?),
      'city': db.currentAddresses[userId]?['city'],
      'player_role': pp?['player_role'],
      'batting_style': pp?['batting_style'],
      'bowling_style': pp?['bowling_style'],
      'is_wicketkeeper': pp?['is_wicketkeeper'] ?? false,
    };
  }

  int? _age(String? dob) {
    final d = dob == null ? null : DateTime.tryParse(dob);
    if (d == null) return null;
    var a = now.year - d.year;
    if (now.month < d.month || (now.month == d.month && now.day < d.day)) a--;
    return a;
  }

  @override
  Future<Map<String, dynamic>> decideJoinRequest({
    required String requestId,
    required bool approve,
    required String role,
    String? reason,
  }) async {
    final uid = _uid('decideJoinRequest');
    final r = requests.where((x) => x['id'] == requestId).firstOrNull;
    if (r == null) throw _err('P0002', 'club_join: not found');
    if (!_owns(uid, r['club_id'])) throw _err('42501', 'club_join: not allowed');
    if (r['status'] != 'pending') return Map.of(r);
    if (approve) {
      if (!const {'player', 'coach', 'manager'}.contains(role)) throw _err('22023', 'club_join: invalid role');
      final existing = members.where((m) => m['club_id'] == r['club_id'] && m['user_id'] == r['user_id']).firstOrNull;
      if (existing == null) {
        members.add({
          'id': _id('m'),
          'club_id': r['club_id'],
          'user_id': r['user_id'],
          'member_role': role,
          'status': 'active',
          'joined_at': now.toIso8601String(),
        });
      } else if (existing['member_role'] != 'owner') {
        existing
          ..['member_role'] = role
          ..['status'] = 'active'
          ..['joined_at'] = now.toIso8601String();
      }
      r
        ..['status'] = 'approved'
        ..['assigned_role'] = role;
    } else {
      r
        ..['status'] = 'rejected'
        ..['decline_reason'] = (reason ?? '').trim().isEmpty ? null : reason!.trim();
    }
    r['decided_at'] = now.toIso8601String();
    return Map.of(r);
  }

  @override
  Future<List<Map<String, dynamic>>> clubMembers(String clubId) async {
    final uid = _uid('clubMembers');
    if (!_owns(uid, clubId)) throw _err('42501', 'club_join: not allowed');
    final list = members.where((m) => m['club_id'] == clubId && m['status'] == 'active').toList()
      ..sort((a, b) => (a['member_role'] == 'owner' ? 0 : 1).compareTo(b['member_role'] == 'owner' ? 0 : 1));
    return [
      for (final m in list)
        {
          'member_id': m['id'],
          'user_id': m['user_id'],
          'member_role': m['member_role'],
          'joined_at': m['joined_at'],
          ..._person(m['user_id'] as String),
        },
    ];
  }

  /// Teams that drop a removed member (migration 12's trigger), when attached.
  FakeTeamDb? teams;

  @override
  Future<Map<String, dynamic>> removeMember(String memberId) async {
    final uid = _uid('removeMember');
    final m = members.where((x) => x['id'] == memberId).firstOrNull;
    if (m == null) throw _err('P0002', 'club_join: not found');
    if (!_owns(uid, m['club_id']) || m['member_role'] == 'owner') throw _err('42501', 'club_join: not allowed');
    if (m['status'] != 'removed') {
      m['status'] = 'removed';
      teams?.dropMember(memberId);
    }
    return Map.of(m);
  }
}

/// Stand-in for migration 12: `teams`, `team_players`, create_team / save_team
/// / archive_team (owner only, name unique among active teams, 11 + 4,
/// active members of the same club, leaders in the squad and different).
class FakeTeamDb implements TeamGateway {
  FakeTeamDb(this.memberships) {
    memberships.teams = this;
  }
  final FakeMembershipDb memberships;
  final teams = <Map<String, dynamic>>[];
  final players = <Map<String, dynamic>>[];
  final calls = <String>[];
  var _seq = 0;

  static GatewayConstraintException _err(String sqlState, String message) =>
      GatewayConstraintException(sqlState: sqlState, message: message);

  String _uid(String call) {
    calls.add(call);
    final uid = memberships.db.auth.current?.id;
    if (uid == null) throw _err('42501', 'team: not authenticated');
    return uid;
  }

  static String _key(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  void dropMember(String memberId) {
    players.removeWhere((p) => p['member_id'] == memberId);
    for (final t in teams) {
      if (t['captain_member_id'] == memberId) t['captain_member_id'] = null;
      if (t['vice_captain_member_id'] == memberId) t['vice_captain_member_id'] = null;
    }
  }

  Map<String, dynamic> _withPlayers(Map<String, dynamic> t) => {
        ...t,
        'team_players': [
          for (final p in players)
            if (p['team_id'] == t['id']) Map.of(p),
        ],
      };

  @override
  Future<List<Map<String, dynamic>>> fetchTeams(String clubId) async {
    final uid = _uid('fetchTeams');
    if (!memberships._owns(uid, clubId)) return const []; // RLS: no rows
    return [
      for (final t in teams)
        if (t['club_id'] == clubId && t['status'] == 'active') _withPlayers(t),
    ];
  }

  void _checkName(String clubId, String name, {String? exceptId}) {
    if (name.trim().isEmpty || name.trim().length > 40) throw _err('22023', 'team: invalid');
    if (teams.any((t) =>
        t['club_id'] == clubId && t['status'] == 'active' && t['id'] != exceptId && _key('${t['name']}') == _key(name))) {
      throw _err('23505', 'team: duplicate name');
    }
  }

  @override
  Future<Map<String, dynamic>> createTeam(Map<String, Object?> params) async {
    final uid = _uid('createTeam');
    final clubId = params['p_club_id'] as String;
    if (!memberships._owns(uid, clubId)) throw _err('42501', 'team: not allowed');
    final name = params['p_name'] as String;
    _checkName(clubId, name);
    final format = params['p_format'] as String;
    final overs = params['p_custom_overs'] as int?;
    if ((format == 'custom') != (overs != null) || (overs != null && (overs < 1 || overs > 50))) {
      throw _err('22023', 'team: invalid');
    }
    final row = {
      'id': '00000000-0000-4000-9000-${(++_seq).toString().padLeft(12, '0')}',
      'club_id': clubId,
      'name': name.trim(),
      'format': format,
      'custom_overs': overs,
      'captain_member_id': null,
      'vice_captain_member_id': null,
      'status': 'active',
      'created_at': DateTime.utc(2026, 11, 16, 10, _seq).toIso8601String(),
    };
    teams.add(row);
    return Map.of(row);
  }

  @override
  Future<Map<String, dynamic>> saveTeam(Map<String, Object?> params) async {
    final uid = _uid('saveTeam');
    final t = teams.where((x) => x['id'] == params['p_team_id']).firstOrNull;
    if (t == null) throw _err('P0002', 'team: not found');
    if (!memberships._owns(uid, t['club_id'])) throw _err('42501', 'team: not allowed');
    if (t['status'] != 'active') throw _err('P0001', 'team: archived');
    final list = [for (final p in params['p_players'] as List) Map<String, Object?>.from(p as Map)];
    final ids = [for (final p in list) p['member_id'] as String];
    if (ids.toSet().length != ids.length) throw _err('22023', 'team: invalid');
    if (list.where((p) => p['selection'] == 'playing').length > 11 || list.where((p) => p['selection'] == 'sub').length > 4) {
      throw _err('23514', 'team: squad full');
    }
    for (final id in ids) {
      if (!memberships.members.any((m) => m['id'] == id && m['club_id'] == t['club_id'] && m['status'] == 'active')) {
        throw _err('23514', 'team: player not in club');
      }
    }
    final captain = params['p_captain_member_id'] as String?;
    final vice = params['p_vice_member_id'] as String?;
    if ((captain != null && captain == vice) ||
        (captain != null && !ids.contains(captain)) ||
        (vice != null && !ids.contains(vice))) {
      throw _err('22023', 'team: invalid');
    }
    _checkName('${t['club_id']}', params['p_name'] as String, exceptId: '${t['id']}');
    t
      ..['name'] = (params['p_name'] as String).trim()
      ..['format'] = params['p_format']
      ..['custom_overs'] = params['p_custom_overs']
      ..['captain_member_id'] = captain
      ..['vice_captain_member_id'] = vice;
    players
      ..removeWhere((p) => p['team_id'] == t['id'])
      ..addAll([
        for (var i = 0; i < list.length; i++)
          {'team_id': t['id'], 'member_id': list[i]['member_id'], 'selection': list[i]['selection'], 'position': i + 1},
      ]);
    return Map.of(t);
  }

  @override
  Future<Map<String, dynamic>> archiveTeam(String teamId) async {
    final uid = _uid('archiveTeam');
    final t = teams.where((x) => x['id'] == teamId).firstOrNull;
    if (t == null) throw _err('P0002', 'team: not found');
    if (!memberships._owns(uid, t['club_id'])) throw _err('42501', 'team: not allowed');
    t['status'] = 'archived';
    return Map.of(t);
  }
}
