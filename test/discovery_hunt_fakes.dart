// Stand-ins for migrations 32 (club discovery, availability slots, player
// rankings, applicant statistics) and 33 (Player Hunt): the database
// functions' main rules, with their messages and SQLSTATEs, on in-memory rows
// shaped like the real responses (docs/M7_CLUB_DISCOVERY.md,
// docs/M8_PLAYER_HUNT.md). The SQL itself is verified by
// supabase/tests/local/27 and 28 on a disposable Postgres.
import 'package:criceco/data/supabase/supabase_gateways.dart';

import 'supabase_fakes.dart';

typedef FakeCall = ({String fn, Map<String, Object?> params});

GatewayConstraintException _err(String sqlState, String message) =>
    GatewayConstraintException(sqlState: sqlState, message: message);

/// A club row of `club_public_profile` / `club_directory` (without `is_own`).
Map<String, dynamic> publicClubRow(
  String id,
  String name, {
  String city = 'Lahore',
  String? shortName,
  String type = 'corporate',
  int? established,
  int members = 12,
  int played = 0,
  int won = 0,
  int lost = 0,
  int tied = 0,
  List<String> form = const [],
  List<String> formats = const [],
  String? homeGround,
}) => {
  'club_id': id,
  'name': name,
  'short_name': shortName,
  'city': city,
  'club_type': type,
  'established_year': established,
  'home_ground_id': homeGround,
  'logo_path': null,
  'member_count': members,
  'played': played,
  'won': won,
  'lost': lost,
  'tied': tied,
  'no_result': played - won - lost - tied,
  'abandoned': 0,
  'recent_form': form,
  'played_formats': formats,
};

class FakeDiscoveryDb implements DiscoveryGateway {
  FakeDiscoveryDb(this.auth, {this.owners = const {}});

  final FakeAuth auth;

  /// club id → owner user id (who may post / list the club's slots).
  Map<String, String> owners;

  final calls = <FakeCall>[];
  final failOn = <String, GatewayException>{};

  /// The server's clock: 2026-11-20 11:00 in Pakistan ("tomorrow" = 21st).
  DateTime now = DateTime.utc(2026, 11, 20, 6);

  /// Every club's public row by id.
  final clubs = <String, Map<String, dynamic>>{};
  final slots = <Map<String, dynamic>>[];
  final openSlots = <Map<String, dynamic>>[];
  final rankings = <Map<String, dynamic>>[];
  final applicants = <String, Map<String, dynamic>>{};
  var _seq = 0;

  void _call(String fn, Map<String, Object?> params) {
    calls.add((fn: fn, params: params));
    if (failOn[fn] case final e?) throw e;
    if (auth.currentUser == null) {
      throw _err('42501', '${_prefix(fn)}: not authenticated');
    }
  }

  static String _prefix(String fn) => switch (fn) {
    'club_public_profile' || 'club_directory' => 'club',
    'player_rankings' => 'ranking',
    'club_applicant_stats' => 'club_join',
    _ => 'slot',
  };

  String? get _me => auth.currentUser?.id;

  @override
  Future<Map<String, dynamic>> clubPublicProfile(String clubId) async {
    _call('club_public_profile', {'p_club_id': clubId});
    final row = clubs[clubId];
    if (row == null) throw _err('P0002', 'club: not found');
    return {...row, 'is_own': owners[clubId] == _me};
  }

  @override
  Future<List<Map<String, dynamic>>> clubDirectory({
    String? search,
    String? city,
    int limit = 50,
    int offset = 0,
  }) async {
    _call('club_directory', {
      'p_search': search,
      'p_city': city,
      'p_limit': limit,
      'p_offset': offset,
    });
    final all =
        [
          for (final r in clubs.values)
            if (owners[r['club_id']] != _me) Map<String, dynamic>.of(r),
        ]..sort(
          (a, b) => (a['name'] as String).toLowerCase().compareTo(
            (b['name'] as String).toLowerCase(),
          ),
        );
    return all.skip(offset).take(limit).toList();
  }

  bool _owns(String clubId) => owners[clubId] == _me;

  @override
  Future<Map<String, dynamic>> postMatchSlot(
    Map<String, Object?> params,
  ) async {
    _call('post_match_slot', params);
    final clubId = params['p_club_id'] as String;
    if (!owners.containsKey(clubId)) {
      throw _err('P0002', 'slot: club not found');
    }
    if (!_owns(clubId)) throw _err('42501', 'slot: not allowed');
    final date = DateTime.parse(params['p_slot_date'] as String);
    final pk = now.toUtc().add(const Duration(hours: 5));
    final tomorrow = DateTime(pk.year, pk.month, pk.day + 1);
    if (date.isBefore(tomorrow)) throw _err('22023', 'slot: invalid date');
    final start = params['p_start_time'] as String;
    final end = params['p_end_time'] as String;
    if (start.compareTo(end) >= 0) throw _err('22023', 'slot: invalid time');
    final mine = slots
        .where((s) => s['club_id'] == clubId && s['status'] == 'open')
        .toList();
    if (mine.any(
      (s) =>
          s['slot_date'] == params['p_slot_date'] &&
          (s['start_time'] as String).compareTo('$end:00') < 0 &&
          '$start:00'.compareTo(s['end_time'] as String) < 0,
    )) {
      throw _err('23P01', 'slot: overlaps');
    }
    if (mine.length >= 10) throw _err('P0001', 'slot: too many open');
    final row = <String, dynamic>{
      'slot_id': 'slot-${++_seq}',
      'club_id': clubId,
      'format': params['p_format'],
      'custom_overs': params['p_format'] == 'custom'
          ? params['p_custom_overs']
          : null,
      'city': params['p_city'],
      'ground_id': params['p_ground_id'],
      'venue_name': params['p_venue_name'],
      'slot_date': params['p_slot_date'],
      'start_time': '$start:00',
      'end_time': '$end:00',
      'starts_at': DateTime.parse('${params['p_slot_date']}T$start:00+05:00')
          .toUtc()
          .toIso8601String(),
      'ends_at': DateTime.parse('${params['p_slot_date']}T$end:00+05:00')
          .toUtc()
          .toIso8601String(),
      'notes': params['p_notes'],
      'status': 'open',
      'created_at': now.toIso8601String(),
      'closed_at': null,
    };
    slots.add(row);
    return Map.of(row);
  }

  @override
  Future<Map<String, dynamic>> withdrawMatchSlot(String slotId) async {
    _call('withdraw_match_slot', {'p_slot_id': slotId});
    final row = slots.where((s) => s['slot_id'] == slotId).firstOrNull;
    if (row == null) throw _err('P0002', 'slot: not found');
    if (!_owns(row['club_id'] as String)) {
      throw _err('42501', 'slot: not allowed');
    }
    row['status'] = 'withdrawn';
    return Map.of(row);
  }

  @override
  Future<List<Map<String, dynamic>>> myClubSlots(
    String clubId, {
    bool includeClosed = false,
  }) async {
    _call('my_club_slots', {
      'p_club_id': clubId,
      'p_include_closed': includeClosed,
    });
    if (!_owns(clubId)) throw _err('42501', 'slot: not allowed');
    return [
      for (final s in slots)
        if (s['club_id'] == clubId && (includeClosed || s['status'] == 'open'))
          Map<String, dynamic>.of(s),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> openMatchSlots(
    Map<String, Object?> params,
  ) async {
    _call('open_match_slots', params);
    if (!owners.values.contains(_me)) throw _err('42501', 'slot: not allowed');
    return [
      for (final s in openSlots)
        if (!_owns(s['club_id'] as String)) Map<String, dynamic>.of(s),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> playerRankings(
    Map<String, Object?> params,
  ) async {
    _call('player_rankings', params);
    return [
      for (final r in rankings) {...r, 'is_me': r['user_id'] == _me},
    ];
  }

  @override
  Future<Map<String, dynamic>> clubApplicantStats(String requestId) async {
    _call('club_applicant_stats', {'p_request_id': requestId});
    final row = applicants[requestId];
    if (row == null) throw _err('P0002', 'club_join: not found');
    return Map.of(row);
  }

  int count(String fn) => calls.where((c) => c.fn == fn).length;
}

/// An `open_match_slots` row.
Map<String, dynamic> openSlotRow(
  String slotId,
  String clubId,
  String clubName, {
  String date = '2026-11-22',
  String start = '14:00',
  String end = '16:00',
  String format = 't20',
  String city = 'Karachi',
  String? venue,
  int won = 3,
  int lost = 1,
}) => {
  'slot_id': slotId,
  'club_id': clubId,
  'club_name': clubName,
  'club_short_name': null,
  'club_city': city,
  'club_type': 'corporate',
  'club_logo_path': null,
  'club_played': won + lost,
  'club_won': won,
  'club_lost': lost,
  'format': format,
  'custom_overs': null,
  'city': city,
  'ground_id': null,
  'venue_name': venue,
  'slot_date': date,
  'start_time': '$start:00',
  'end_time': '$end:00',
  'starts_at': DateTime.parse('${date}T$start:00+05:00')
      .toUtc()
      .toIso8601String(),
  'ends_at': DateTime.parse('${date}T$end:00+05:00').toUtc().toIso8601String(),
  'notes': null,
  'created_at': '2026-11-19T10:00:00+00:00',
};

/// A `player_rankings` row.
Map<String, dynamic> rankingRow(
  String userId,
  String name, {
  String role = 'batsman',
  String club = 'Karachi Kings',
  int matches = 5,
  int runs = 200,
  int wickets = 0,
  num? average = 40,
}) => {
  'user_id': userId,
  'full_name': name,
  'avatar_path': null,
  'club_id': 'club-x',
  'club_name': club,
  'club_short_name': null,
  'player_role': role,
  'is_wicketkeeper': false,
  'matches': matches,
  'bat_innings': matches,
  'not_outs': 0,
  'runs': runs,
  'balls_faced': runs,
  'batting_average': average,
  'strike_rate': 100,
  'highest': 80,
  'highest_not_out': false,
  'fifties': 1,
  'hundreds': 0,
  'wickets': wickets,
  'balls_bowled': 0,
  'runs_conceded': 0,
  'bowling_average': null,
  'economy': null,
  'best_wickets': null,
  'best_runs': null,
  'catches': 0,
  'stumpings': 0,
  'player_of_match': 0,
  'recent_played': matches > 5 ? 5 : matches,
  'recent_wins': 2,
  'rating': null,
};

// ---------------------------------------------------------------------------
// Migration 33
// ---------------------------------------------------------------------------

/// A post row (identical for every post function).
Map<String, dynamic> huntPostRow(
  String id,
  String clubId,
  String clubName, {
  String role = 'bowler',
  String format = 't20',
  int players = 2,
  String? city = 'Lahore',
  String? date = '2026-11-25',
  String? time = '14:00',
  String budget = 'any',
  String status = 'open',
  bool mine = false,
  bool interested = false,
  int? interestCount,
}) => {
  'post_id': id,
  'club_id': clubId,
  'club_name': clubName,
  'club_short_name': null,
  'club_city': 'Lahore',
  'club_logo_path': null,
  'role': role,
  'format': format,
  'players_needed': players,
  'city': city,
  'match_date': date,
  'match_time': time,
  'budget': budget,
  'notes': null,
  'status': status,
  'created_at': '2026-11-19T10:00:00+00:00',
  'expires_at': '2026-11-25T18:59:59+00:00',
  'is_my_club': mine,
  'interested': interested,
  'interest_count': interestCount,
};

class FakeHuntDb implements HuntGateway {
  FakeHuntDb(this.auth, {this.owners = const {}});

  final FakeAuth auth;

  /// club id → owner user id.
  Map<String, String> owners;
  final calls = <FakeCall>[];
  final failOn = <String, GatewayException>{};

  /// The caller's listing (`my_hunt_listing`), per user id.
  final listings = <String, Map<String, dynamic>>{};
  final posts = <Map<String, dynamic>>[];

  /// post id → interested user ids.
  final interests = <String, Set<String>>{};
  final interestRows = <Map<String, dynamic>>[];
  final players = <Map<String, dynamic>>[];
  final invites = <Map<String, dynamic>>[];
  final myInviteRows = <Map<String, dynamic>>[];
  var _seq = 0;

  String? get _me => auth.currentUser?.id;
  bool _owns(String clubId) => owners[clubId] == _me;

  void _call(String fn, Map<String, Object?> params) {
    calls.add((fn: fn, params: params));
    if (failOn[fn] case final e?) throw e;
    if (_me == null) throw _err('42501', 'hunt: not authenticated');
  }

  int count(String fn) => calls.where((c) => c.fn == fn).length;

  Map<String, dynamic> _listing() => listings[_me!] ??= {
    'listed': false,
    'role': 'batsman',
    'city': 'Lahore',
    'listed_at': null,
    'updated_at': null,
    'visible': false,
  };

  @override
  Future<Map<String, dynamic>> myListing() async {
    _call('my_hunt_listing', const {});
    return Map.of(_listing());
  }

  @override
  Future<Map<String, dynamic>> setListing({
    required bool listed,
    String? role,
    String? city,
  }) async {
    _call('set_my_hunt_listing', {
      'p_listed': listed,
      'p_role': role,
      'p_city': city,
    });
    final l = _listing();
    l['listed'] = listed;
    if (role != null) l['role'] = role;
    if (city != null) l['city'] = city;
    l['visible'] = listed;
    return Map.of(l);
  }

  @override
  Future<Map<String, dynamic>> publishPost(Map<String, Object?> params) async {
    _call('publish_hunt_post', params);
    final clubId = params['p_club_id'] as String;
    if (!_owns(clubId)) throw _err('42501', 'hunt: not allowed');
    final dup = posts.any(
      (p) =>
          p['club_id'] == clubId &&
          p['status'] == 'open' &&
          p['role'] == params['p_role'] &&
          p['format'] == params['p_format'] &&
          p['players_needed'] == params['p_players_needed'] &&
          p['city'] == params['p_city'] &&
          p['match_date'] == params['p_match_date'] &&
          p['match_time'] == params['p_match_time'] &&
          p['budget'] == params['p_budget'],
    );
    if (dup) throw _err('P0001', 'hunt: duplicate post');
    final row = huntPostRow(
      'post-${++_seq}',
      clubId,
      'Lahore Lions',
      role: params['p_role'] as String,
      format: params['p_format'] as String,
      players: params['p_players_needed'] as int,
      city: params['p_city'] as String?,
      date: params['p_match_date'] as String?,
      time: params['p_match_time'] as String?,
      budget: params['p_budget'] as String,
      mine: true,
      interestCount: 0,
    );
    posts.insert(0, row);
    return Map.of(row);
  }

  @override
  Future<void> closePost(String postId) async {
    _call('close_hunt_post', {'p_post_id': postId});
    final p = posts.where((x) => x['post_id'] == postId).firstOrNull;
    if (p == null || !_owns(p['club_id'] as String)) {
      throw _err('42501', 'hunt: not allowed');
    }
    p['status'] = 'closed';
  }

  @override
  Future<List<Map<String, dynamic>>> clubPosts(String clubId) async {
    _call('club_hunt_posts', {'p_club_id': clubId});
    if (!_owns(clubId)) throw _err('42501', 'hunt: not allowed');
    return [
      for (final p in posts)
        if (p['club_id'] == clubId) Map<String, dynamic>.of(p),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> openPosts({
    String? role,
    String? city,
  }) async {
    _call('hunt_open_posts', {'p_role': role, 'p_city': city});
    return [
      for (final p in posts)
        if (p['status'] == 'open')
          {
            ...p,
            'is_my_club': _owns(p['club_id'] as String),
            'interested': interests[p['post_id']]?.contains(_me) ?? false,
          },
    ];
  }

  @override
  Future<void> expressInterest(String postId) async {
    _call('express_hunt_interest', {'p_post_id': postId});
    final p = posts.where((x) => x['post_id'] == postId).firstOrNull;
    if (p == null) throw _err('P0002', 'hunt: post not found');
    if (_owns(p['club_id'] as String)) throw _err('P0001', 'hunt: own club');
    if (p['status'] != 'open') throw _err('P0001', 'hunt: post closed');
    (interests[postId] ??= {}).add(_me!);
  }

  @override
  Future<void> withdrawInterest(String postId) async {
    _call('withdraw_hunt_interest', {'p_post_id': postId});
    interests[postId]?.remove(_me);
  }

  @override
  Future<List<Map<String, dynamic>>> clubInterests(
    String clubId, {
    String? postId,
  }) async {
    _call('club_hunt_interests', {'p_club_id': clubId, 'p_post_id': postId});
    if (!_owns(clubId)) throw _err('42501', 'hunt: not allowed');
    return [for (final r in interestRows) Map<String, dynamic>.of(r)];
  }

  @override
  Future<List<Map<String, dynamic>>> openPlayers({
    String? city,
    String? role,
  }) async {
    _call('hunt_open_players', {'p_city': city, 'p_role': role});
    if (!owners.values.contains(_me)) throw _err('42501', 'hunt: not allowed');
    return [for (final r in players) Map<String, dynamic>.of(r)];
  }

  @override
  Future<Map<String, dynamic>> invitePlayer({
    required String clubId,
    required String userId,
    String? postId,
  }) async {
    _call('invite_hunt_player', {
      'p_club_id': clubId,
      'p_user_id': userId,
      'p_post_id': postId,
    });
    if (!_owns(clubId)) throw _err('42501', 'hunt: not allowed');
    if (invites.any(
      (i) =>
          i['club_id'] == clubId &&
          i['user_id'] == userId &&
          i['status'] == 'pending',
    )) {
      throw _err('P0001', 'hunt: already invited');
    }
    if (!players.any((p) => p['user_id'] == userId)) {
      throw _err('P0001', 'hunt: player not available');
    }
    final row = {
      'invite_id': 'inv-${++_seq}',
      'club_id': clubId,
      'user_id': userId,
      'status': 'pending',
      'created_at': '2026-11-20T06:00:00+00:00',
      'expires_at': '2026-12-04T06:00:00+00:00',
    };
    invites.add(row);
    return {
      for (final k in ['invite_id', 'status', 'created_at', 'expires_at'])
        k: row[k],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> clubInvites(String clubId) async {
    _call('club_hunt_invites', {'p_club_id': clubId});
    if (!_owns(clubId)) throw _err('42501', 'hunt: not allowed');
    return [
      for (final i in invites)
        if (i['club_id'] == clubId)
          {
            'invite_id': i['invite_id'],
            'user_id': i['user_id'],
            'full_name': i['full_name'] ?? 'Player ${i['user_id']}',
            'avatar_path': null,
            'role': 'bowler',
            'city': 'Lahore',
            'post_id': null,
            'status': i['status'],
            'created_at': i['created_at'],
            'expires_at': i['expires_at'],
            'responded_at': null,
            'phone': i['status'] == 'accepted' ? i['phone'] : null,
          },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> myInvites() async {
    _call('my_hunt_invites', const {});
    return [for (final r in myInviteRows) Map<String, dynamic>.of(r)];
  }

  @override
  Future<Map<String, dynamic>> respondInvite(
    String inviteId, {
    required bool accept,
  }) async {
    _call('respond_hunt_invite', {'p_invite_id': inviteId, 'p_accept': accept});
    final row = myInviteRows
        .where((r) => r['invite_id'] == inviteId)
        .firstOrNull;
    if (row == null) throw _err('P0002', 'hunt: invite not found');
    if (row['status'] != 'pending') {
      throw _err('P0001', 'hunt: invite not pending');
    }
    row['status'] = accept ? 'accepted' : 'declined';
    row['responded_at'] = '2026-11-20T06:30:00+00:00';
    return {
      'invite_id': inviteId,
      'status': row['status'],
      'responded_at': row['responded_at'],
    };
  }
}

/// A `my_hunt_invites` row.
Map<String, dynamic> myInviteRow(
  String id,
  String clubName, {
  String status = 'pending',
}) => {
  'invite_id': id,
  'club_id': 'club-k',
  'club_name': clubName,
  'club_short_name': null,
  'club_city': 'Karachi',
  'club_logo_path': null,
  'post_id': 'post-k',
  'post_role': 'all_rounder',
  'post_format': 'odi',
  'post_match_date': '2026-11-28',
  'status': status,
  'created_at': '2026-11-20T05:00:00+00:00',
  'expires_at': '2026-12-04T05:00:00+00:00',
  'responded_at': null,
};

/// A `hunt_open_players` row.
Map<String, dynamic> openPlayerRow(
  String userId,
  String name, {
  String role = 'bowler',
  String city = 'Lahore',
  String? inviteStatus,
  bool member = false,
  bool statsVisible = true,
}) => {
  'user_id': userId,
  'full_name': name,
  'avatar_path': null,
  'role': role,
  'city': city,
  'listed_at': '2026-11-19T10:00:00+00:00',
  'is_me': false,
  'is_member': member,
  'invite_id': inviteStatus == null ? null : 'inv-$userId',
  'invite_status': inviteStatus,
  'stats_visible': statsVisible,
  'matches': statsVisible ? 7 : null,
  'runs': statsVisible ? 120 : null,
  'batting_average': statsVisible ? 20.5 : null,
  'strike_rate': statsVisible ? 98.4 : null,
  'wickets': statsVisible ? 9 : null,
  'economy': statsVisible ? 6.1 : null,
};
