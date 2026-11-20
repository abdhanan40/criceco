// Stand-in for migrations 17–19 (challenges, matches, lineups, player
// availability): the database functions' main rules, with their messages
// and SQLSTATEs, on in-memory rows shaped like the real responses. The SQL
// itself is verified by supabase/tests/local/14–16 on a disposable Postgres.
import 'package:criceco/data/supabase/supabase_gateways.dart';

import 'supabase_fakes.dart';

class FakeMatchDb implements MatchGateway {
  FakeMatchDb(this.auth, this.clubDb);

  final FakeAuth auth;
  final FakeClubDb clubDb;

  /// Every call: the function name and its parameters, in order.
  final calls = <({String fn, Map<String, Object?> params})>[];

  /// The next call fails with this (then it's cleared).
  GatewayException? failNext;

  /// The next single-row call returns this instead (malformed responses).
  Map<String, dynamic>? rowNext;

  /// The next list call returns these instead.
  List<Map<String, dynamic>>? rowsNext;

  /// The server's clock.
  DateTime now = DateTime.utc(2026, 11, 20, 6); // 11:00 in Pakistan

  final clubs =
      <String, Map<String, dynamic>>{}; // id → club row (with owner_id)
  final members = <Map<String, dynamic>>[];
  final challenges = <Map<String, dynamic>>[];
  final matches = <Map<String, dynamic>>[];
  final lineups = <Map<String, dynamic>>[];
  final lineupPlayers = <Map<String, dynamic>>[];
  final availability = <String, Map<String, dynamic>>{}; // user id → row
  var _seq = 0;

  String _id(String p) => '$p-${++_seq}';
  static GatewayConstraintException err(String sqlState, String message) =>
      GatewayConstraintException(sqlState: sqlState, message: message);

  // ---- Fixture helpers ----

  /// A club owned by [ownerId] (also visible to [OwnClubLookup]).
  String addClub(
    String ownerId,
    String name, {
    String city = 'Lahore',
    String? shortName,
  }) {
    final id = _id('club');
    final row = {
      'id': id,
      'owner_id': ownerId,
      'name': name,
      'short_name': shortName,
      'city': city,
      'club_type': 'corporate',
      'code': 'ABC${_seq.toString().padLeft(3, '0')}',
    };
    clubs[id] = row;
    clubDb.clubs[ownerId] = Map.of(row);
    addMember(id, ownerId, 'Owner of $name', role: 'owner');
    return id;
  }

  String addMember(
    String clubId,
    String userId,
    String name, {
    String role = 'player',
    String status = 'active',
  }) {
    final id = _id('mem');
    members.add({
      'id': id,
      'club_id': clubId,
      'user_id': userId,
      'member_role': role,
      'status': status,
      'full_name': name,
    });
    return id;
  }

  // ---- Internals ----

  String _uid(String fn, Map<String, Object?> params, String prefix) {
    calls.add((fn: fn, params: params));
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    final uid = auth.current?.id;
    if (uid == null) throw err('42501', '$prefix: not authenticated');
    return uid;
  }

  bool _owns(String uid, Object? clubId) => clubs[clubId]?['owner_id'] == uid;
  bool _active(String uid, Object? clubId) => members.any(
    (m) =>
        m['club_id'] == clubId &&
        m['user_id'] == uid &&
        m['status'] == 'active',
  );
  String? _ownedBy(String uid) =>
      clubs.values.where((c) => c['owner_id'] == uid).firstOrNull?['id']
          as String?;

  DateTime get _pkToday {
    final pk = now.add(const Duration(hours: 5));
    return DateTime.utc(pk.year, pk.month, pk.day);
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> _one(Map<String, dynamic> row) {
    final r = rowNext;
    rowNext = null;
    return r ?? Map.of(row);
  }

  List<Map<String, dynamic>> _list(List<Map<String, dynamic>> rows) {
    final r = rowsNext;
    rowsNext = null;
    return r ?? rows;
  }

  // ---- Directory ----

  @override
  Future<List<Map<String, dynamic>>> clubDirectory({
    String? search,
    String? city,
  }) async {
    final uid = _uid('match_club_directory', {
      'p_search': search,
      'p_city': city,
    }, 'match');
    if (_ownedBy(uid) == null) throw err('42501', 'match: not allowed');
    final q = search?.toLowerCase();
    return _list(
      [
        for (final c in clubs.values)
          if (c['owner_id'] != uid &&
              (q == null ||
                  '${c['name']}'.toLowerCase().contains(q) ||
                  '${c['short_name'] ?? ''}'.toLowerCase().contains(q)) &&
              (city == null ||
                  '${c['city']}'.toLowerCase() == city.toLowerCase()))
            {
              'club_id': c['id'],
              'name': c['name'],
              'short_name': c['short_name'],
              'city': c['city'],
              'club_type': c['club_type'],
            },
      ].take(50).toList(),
    );
  }

  // ---- Challenges ----

  @override
  Future<Map<String, dynamic>> sendChallenge(
    Map<String, Object?> params,
  ) async {
    final uid = _uid('send_challenge', params, 'challenge');
    final from = params['p_from_club_id'], to = params['p_to_club_id'];
    if (!clubs.containsKey(from)) {
      throw err('P0002', 'challenge: club not found');
    }
    if (!_owns(uid, from)) throw err('42501', 'challenge: not allowed');
    if (!clubs.containsKey(to)) throw err('P0002', 'challenge: club not found');
    if (from == to) throw err('P0001', 'challenge: own club');
    final format = params['p_format'];
    final overs = params['p_custom_overs'] as int?;
    if (!['test', 't20', 'odi', 't10', 'custom'].contains(format) ||
        (format == 'custom' && (overs == null || overs < 1 || overs > 50))) {
      throw err('22023', 'challenge: invalid');
    }
    final date = DateTime.tryParse('${params['p_proposed_date']}');
    if (date == null ||
        !date.isAfter(_pkToday) ||
        date.isAfter(_pkToday.add(const Duration(days: 365)))) {
      throw err('22023', 'challenge: invalid date');
    }
    final venue = '${params['p_venue_name'] ?? ''}'.trim();
    if (venue.isEmpty || venue.length > 100) {
      throw err('22023', 'challenge: invalid venue');
    }
    final message = params['p_message'] as String?;
    if (message != null && message.length > 280) {
      throw err('22023', 'challenge: invalid message');
    }
    if (challenges.any(
      (c) =>
          c['status'] == 'pending' &&
          {c['from_club_id'], c['to_club_id']}.containsAll({from, to}),
    )) {
      throw err('23505', 'challenge: already pending');
    }
    if (challenges
            .where((c) => c['from_club_id'] == from && c['status'] == 'pending')
            .length >=
        20) {
      throw err('P0001', 'challenge: too many pending');
    }
    final startOfDay = date.subtract(
      const Duration(hours: 5),
    ); // 00:00 in Pakistan, as UTC
    final week = now.add(const Duration(days: 7));
    final row = <String, dynamic>{
      'id': _id('ch'),
      'from_club_id': from,
      'to_club_id': to,
      'format': format,
      'custom_overs': format == 'custom' ? overs : null,
      'proposed_date': _date(date),
      'venue_name': venue,
      'message': message,
      'status': 'pending',
      'expires_at': (week.isBefore(startOfDay) ? week : startOfDay)
          .toIso8601String(),
      'decided_at': null,
      'decided_by': null,
      'match_id': null,
      'created_at': now.toIso8601String(),
    };
    challenges.add(row);
    return _one(row);
  }

  @override
  Future<Map<String, dynamic>> respondToChallenge(
    String challengeId, {
    required bool accept,
  }) async {
    final uid = _uid('respond_to_challenge', {
      'p_challenge_id': challengeId,
      'p_accept': accept,
    }, 'challenge');
    final c = challenges.where((x) => x['id'] == challengeId).firstOrNull;
    if (c == null) throw err('P0002', 'challenge: not found');
    if (!_owns(uid, c['to_club_id'])) {
      throw err('42501', 'challenge: not allowed');
    }
    if (c['status'] != 'pending') throw err('P0001', 'challenge: not pending');
    if (!DateTime.parse(c['expires_at'] as String).isAfter(now)) {
      c['status'] = 'expired';
      c['decided_at'] = now.toIso8601String();
      return _one(c);
    }
    c['decided_at'] = now.toIso8601String();
    c['decided_by'] = uid;
    if (!accept) {
      c['status'] = 'declined';
      return _one(c);
    }
    final date = DateTime.parse('${c['proposed_date']}');
    final m = <String, dynamic>{
      'id': _id('match'),
      'challenge_id': c['id'],
      'club_a_id': c['from_club_id'],
      'club_b_id': c['to_club_id'],
      'format': c['format'],
      'custom_overs': c['custom_overs'],
      'status': 'pending',
      'starts_at': null,
      'venue_name': null,
      'city': null,
      'proposed_starts_at': DateTime.utc(
        date.year,
        date.month,
        date.day,
        5,
      ).toIso8601String(), // 10:00 PKT
      'proposed_venue_name': c['venue_name'],
      'proposed_city': null,
      'proposed_by_club_id': c['from_club_id'],
      'proposal_version': 1,
      'cancelled_at': null,
      'cancelled_by_club_id': null,
      'cancel_reason': null,
      'created_at': now.toIso8601String(),
      'last_updated_at': now.toIso8601String(),
    };
    matches.add(m);
    c['status'] = 'accepted';
    c['match_id'] = m['id'];
    return _one(c);
  }

  @override
  Future<List<Map<String, dynamic>>> clubChallenges(String clubId) async {
    final uid = _uid('club_challenges', {'p_club_id': clubId}, 'challenge');
    if (!_owns(uid, clubId)) throw err('42501', 'challenge: not allowed');
    return _list([
      for (final c in challenges.reversed)
        if (c['from_club_id'] == clubId || c['to_club_id'] == clubId)
          () {
            final sent = c['from_club_id'] == clubId;
            final o = clubs[sent ? c['to_club_id'] : c['from_club_id']]!;
            final expired =
                c['status'] == 'pending' &&
                !DateTime.parse(c['expires_at'] as String).isAfter(now);
            return <String, dynamic>{
              'challenge_id': c['id'],
              'direction': sent ? 'sent' : 'received',
              'opponent_club_id': o['id'],
              'opponent_name': o['name'],
              'opponent_short_name': o['short_name'],
              'opponent_city': o['city'],
              'format': c['format'],
              'custom_overs': c['custom_overs'],
              'proposed_date': c['proposed_date'],
              'venue_name': c['venue_name'],
              'message': c['message'],
              'status': expired ? 'expired' : c['status'],
              'created_at': c['created_at'],
              'expires_at': c['expires_at'],
              'decided_at': c['decided_at'],
              'match_id': c['match_id'],
            };
          }(),
    ]);
  }

  // ---- Matches ----

  @override
  Future<List<Map<String, dynamic>>> clubMatches(String clubId) async {
    final uid = _uid('club_matches', {'p_club_id': clubId}, 'match');
    if (!_owns(uid, clubId)) throw err('42501', 'match: not allowed');
    bool? mine(Object? v) => v == null ? null : v == clubId;
    return _list([
      for (final m in matches)
        if (m['club_a_id'] == clubId || m['club_b_id'] == clubId)
          {
            'match_id': m['id'],
            'challenge_id': m['challenge_id'],
            'opponent_club_id': m['club_a_id'] == clubId
                ? m['club_b_id']
                : m['club_a_id'],
            'opponent_name':
                clubs[m['club_a_id'] == clubId
                    ? m['club_b_id']
                    : m['club_a_id']]!['name'],
            'opponent_short_name': null,
            'opponent_city': 'Lahore',
            'challenged_by_me': m['club_a_id'] == clubId,
            'format': m['format'],
            'custom_overs': m['custom_overs'],
            'status': m['status'],
            'starts_at': m['starts_at'],
            'venue_name': m['venue_name'],
            'city': m['city'],
            'proposed_starts_at': m['proposed_starts_at'],
            'proposed_venue_name': m['proposed_venue_name'],
            'proposed_city': m['proposed_city'],
            'proposed_by_me': mine(m['proposed_by_club_id']),
            'proposal_version': m['proposal_version'],
            'cancelled_at': m['cancelled_at'],
            'cancelled_by_me': mine(m['cancelled_by_club_id']),
            'cancel_reason': m['cancel_reason'],
            'created_at': m['created_at'],
            'last_updated_at': m['last_updated_at'],
          },
    ]);
  }

  ({Map<String, dynamic> match, String club}) _openMatch(
    String uid,
    Object? matchId,
  ) {
    final m = matches.where((x) => x['id'] == matchId).firstOrNull;
    if (m == null) throw err('P0002', 'match: not found');
    final club = [
      m['club_a_id'],
      m['club_b_id'],
    ].firstWhere((c) => _owns(uid, c), orElse: () => null);
    if (club == null) throw err('42501', 'match: not allowed');
    if (m['status'] != 'pending' && m['status'] != 'confirmed') {
      throw err('P0001', 'match: not open');
    }
    return (match: m, club: club as String);
  }

  @override
  Future<Map<String, dynamic>> proposeSchedule(
    Map<String, Object?> params,
  ) async {
    final uid = _uid('propose_match_schedule', params, 'match');
    final (:match, :club) = _openMatch(uid, params['p_match_id']);
    final at = DateTime.tryParse('${params['p_starts_at']}');
    if (at == null || !at.isAfter(now)) {
      throw err('22023', 'match: invalid time');
    }
    final venue = '${params['p_venue_name'] ?? ''}'.trim();
    if (venue.isEmpty || venue.length > 100) {
      throw err('22023', 'match: invalid venue');
    }
    match
      ..['proposed_starts_at'] = at.toUtc().toIso8601String()
      ..['proposed_venue_name'] = venue
      ..['proposed_city'] = params['p_city']
      ..['proposed_by_club_id'] = club
      ..['proposal_version'] = (match['proposal_version'] as int) + 1;
    return _one(match);
  }

  @override
  Future<Map<String, dynamic>> respondToSchedule(
    String matchId, {
    required int proposalVersion,
    required bool accept,
  }) async {
    final uid = _uid('respond_to_match_schedule', {
      'p_match_id': matchId,
      'p_proposal_version': proposalVersion,
      'p_accept': accept,
    }, 'match');
    final (:match, :club) = _openMatch(uid, matchId);
    if (match['proposed_starts_at'] == null) {
      throw err('P0001', 'match: no proposal');
    }
    if (match['proposed_by_club_id'] == club) {
      throw err('42501', 'match: not allowed');
    }
    if (match['proposal_version'] != proposalVersion) {
      throw err('P0001', 'match: proposal changed');
    }
    if (accept) {
      match
        ..['status'] = 'confirmed'
        ..['starts_at'] = match['proposed_starts_at']
        ..['venue_name'] = match['proposed_venue_name']
        ..['city'] = match['proposed_city'];
    }
    match
      ..['proposed_starts_at'] = null
      ..['proposed_venue_name'] = null
      ..['proposed_city'] = null
      ..['proposed_by_club_id'] = null;
    return _one(match);
  }

  @override
  Future<Map<String, dynamic>> cancelMatch(
    String matchId,
    String reason,
  ) async {
    final uid = _uid('cancel_match', {
      'p_match_id': matchId,
      'p_reason': reason,
    }, 'match');
    final (:match, :club) = _openMatch(uid, matchId);
    if (reason.trim().isEmpty || reason.trim().length > 200) {
      throw err('22023', 'match: invalid reason');
    }
    match
      ..['status'] = 'cancelled'
      ..['cancelled_at'] = now.toIso8601String()
      ..['cancelled_by_club_id'] = club
      ..['cancel_reason'] = reason.trim()
      ..['proposed_starts_at'] = null
      ..['proposed_venue_name'] = null
      ..['proposed_city'] = null
      ..['proposed_by_club_id'] = null;
    return _one(match);
  }

  // ---- Lineups ----

  @override
  Future<Map<String, dynamic>> saveLineup(Map<String, Object?> params) async {
    final uid = _uid('save_match_lineup', params, 'lineup');
    final m = matches.where((x) => x['id'] == params['p_match_id']).firstOrNull;
    if (m == null) throw err('P0002', 'lineup: not found');
    final club = [
      m['club_a_id'],
      m['club_b_id'],
    ].firstWhere((c) => _owns(uid, c), orElse: () => null);
    if (club == null) throw err('42501', 'lineup: not allowed');
    if (m['status'] != 'confirmed') {
      throw err('P0001', 'lineup: match not confirmed');
    }
    if (!DateTime.parse(m['starts_at'] as String).isAfter(now)) {
      throw err('P0001', 'lineup: match started');
    }
    final players = [
      for (final p in params['p_players'] as List)
        Map<String, Object?>.from(p as Map),
    ];
    if (players.map((p) => p['member_id']).toSet().length != players.length) {
      throw err('22023', 'lineup: invalid');
    }
    final playing = players.where((p) => p['selection'] == 'playing').length;
    if (playing != 11 || players.length - playing != 4) {
      throw err('23514', 'lineup: invalid squad');
    }
    for (final p in players) {
      if (!members.any(
        (x) =>
            x['id'] == p['member_id'] &&
            x['club_id'] == club &&
            x['status'] == 'active',
      )) {
        throw err('23514', 'lineup: player not in club');
      }
    }
    lineups.removeWhere(
      (l) => l['match_id'] == m['id'] && l['club_id'] == club,
    );
    lineupPlayers.removeWhere(
      (l) => l['match_id'] == m['id'] && l['club_id'] == club,
    );
    final header = <String, dynamic>{
      'match_id': m['id'],
      'club_id': club,
      'name': params['p_name'],
      'source_team_id': params['p_source_team_id'],
      'captain_member_id': params['p_captain_member_id'],
      'vice_captain_member_id': params['p_vice_member_id'],
      'saved_at': now.toIso8601String(),
      'saved_by': uid,
    };
    lineups.add(header);
    for (final (i, p) in players.indexed) {
      lineupPlayers.add({
        'match_id': m['id'],
        'club_id': club,
        ...p,
        'position': i + 1,
      });
    }
    return _one(header);
  }

  @override
  Future<List<Map<String, dynamic>>> matchLineup(String matchId) async {
    final uid = _uid('match_lineup', {'p_match_id': matchId}, 'lineup');
    final m = matches.where((x) => x['id'] == matchId).firstOrNull;
    if (m == null) throw err('P0002', 'lineup: not found');
    bool sees(Object? club) => _owns(uid, club) || _active(uid, club);
    if (!sees(m['club_a_id']) && !sees(m['club_b_id'])) {
      throw err('42501', 'lineup: not allowed');
    }
    return _list([
      for (final l in lineups)
        if (l['match_id'] == matchId && sees(l['club_id']))
          for (final p in lineupPlayers.where(
            (p) => p['match_id'] == matchId && p['club_id'] == l['club_id'],
          ))
            {
              'club_id': l['club_id'],
              'lineup_name': l['name'],
              'source_team_id': l['source_team_id'],
              'captain_member_id': l['captain_member_id'],
              'vice_captain_member_id': l['vice_captain_member_id'],
              'saved_at': l['saved_at'],
              'member_id': p['member_id'],
              'full_name': members.firstWhere(
                (x) => x['id'] == p['member_id'],
              )['full_name'],
              'member_role': members.firstWhere(
                (x) => x['id'] == p['member_id'],
              )['member_role'],
              'selection': p['selection'],
              'position': p['position'],
            },
    ]);
  }

  // ---- Availability ----

  @override
  Future<Map<String, dynamic>> setMyAvailability(
    Map<String, Object?> params,
  ) async {
    final uid = _uid('set_my_availability', params, 'availability');
    final status = params['p_status'];
    if (![
      'available',
      'limited',
      'unavailable',
      'injured',
      'other',
    ].contains(status)) {
      throw err('22023', 'availability: invalid status');
    }
    final notes = params['p_notes'] as String?;
    if (notes != null && notes.length > 200) {
      throw err('22023', 'availability: invalid notes');
    }
    final available = status == 'available';
    final row = availability[uid] = {
      'user_id': uid,
      'status': status,
      'reason': available ? null : params['p_reason'],
      'until_date': available ? null : params['p_until_date'],
      'notes': notes,
      'updated_at': now.toIso8601String(),
    };
    return _one(row);
  }

  @override
  Future<Map<String, dynamic>?> myAvailability() async {
    final uid = _uid('my_availability', const {}, 'availability');
    final r = rowNext;
    rowNext = null;
    return r ?? (availability[uid] == null ? null : Map.of(availability[uid]!));
  }

  @override
  Future<List<Map<String, dynamic>>> clubAvailability(String clubId) async {
    final uid = _uid('club_player_availability', {
      'p_club_id': clubId,
    }, 'availability');
    if (!_owns(uid, clubId)) throw err('42501', 'availability: not allowed');
    return _list([
      for (final m in members)
        if (m['club_id'] == clubId && m['status'] == 'active')
          {
            'member_id': m['id'],
            'user_id': m['user_id'],
            'full_name': m['full_name'],
            'member_role': m['member_role'],
            'status': availability[m['user_id']]?['status'] ?? 'available',
            'reason': availability[m['user_id']]?['reason'],
            'until_date': availability[m['user_id']]?['until_date'],
            'notes': availability[m['user_id']]?['notes'],
            'updated_at': availability[m['user_id']]?['updated_at'],
            'locks_selection': [
              'injured',
              'unavailable',
            ].contains(availability[m['user_id']]?['status']),
          },
    ]);
  }
}
