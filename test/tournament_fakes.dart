// Stand-in for migration 35 (tournaments): the database functions' main
// rules, with their messages and SQLSTATEs, on in-memory rows shaped like the
// real responses (docs/M10_TOURNAMENTS.md). The SQL itself is verified by
// supabase/tests/local/30 on a disposable Postgres.
import 'package:criceco/data/supabase/supabase_gateways.dart';

import 'supabase_fakes.dart';

typedef TournamentCall = ({String fn, Map<String, Object?> params});

GatewayConstraintException _err(String sqlState, String message) =>
    GatewayConstraintException(sqlState: sqlState, message: message);

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _parse(Object? v) => DateTime.parse(v! as String);

/// A stored tournament as the fake keeps it (the T row is derived).
class FakeTournament {
  FakeTournament({
    required this.id,
    required this.organizerClubId,
    required this.name,
    required this.city,
    required this.ground,
    required this.format,
    required this.type,
    required this.startDate,
    required this.endDate,
    required this.deadline,
    required this.maxTeams,
    this.customOvers,
    this.entryFee,
    this.prize,
    this.description,
    this.rules,
    this.status = 'registration_open',
    required this.createdAt,
  });

  final String id;
  final String organizerClubId;
  final String name, city, ground, format, type;
  final DateTime startDate, endDate, deadline;
  final int maxTeams;
  final int? customOvers, entryFee, prize;
  final String? description;
  final List<String>? rules;
  String status;
  DateTime? fixturesAt;
  String? winner;
  final DateTime createdAt;
}

class FakeTournamentDb implements TournamentGateway {
  FakeTournamentDb(
    this.auth, {
    required this.owners,
    required this.clubNames,
    required this.today,
  });

  final FakeAuth auth;

  /// club id → owner user id; club id → name.
  final Map<String, String> owners;
  final Map<String, String> clubNames;

  /// The server's "today" (Asia/Karachi).
  DateTime today;

  final calls = <TournamentCall>[];
  final failOn = <String, GatewayException>{};
  final tournaments = <String, FakeTournament>{};

  /// Entry rows (R shape) with their squad under `players`.
  final entries = <Map<String, dynamic>>[];
  final fixtureRows = <String, List<Map<String, dynamic>>>{};
  final awardRows = <String, List<Map<String, dynamic>>>{};
  var _seq = 0;
  var _clock = 0;

  String? get _me => auth.current?.id;
  bool _owns(String clubId) => owners[clubId] == _me;
  int count(String fn) => calls.where((c) => c.fn == fn).length;
  List<Map<String, Object?>> paramsOf(String fn) => [
    for (final c in calls)
      if (c.fn == fn) c.params,
  ];

  String _stamp() => DateTime.utc(
    2026,
    11,
    20,
    6,
  ).add(Duration(seconds: ++_clock)).toIso8601String();

  void _call(String fn, Map<String, Object?> params) {
    calls.add((fn: fn, params: params));
    if (failOn[fn] case final e?) throw e;
    if (_me == null) throw _err('42501', 'tournament: not authenticated');
  }

  FakeTournament _find(String id) =>
      tournaments[id] ?? (throw _err('P0002', 'tournament: not found'));

  Map<String, dynamic> _entry(String id) =>
      entries.where((e) => e['registration_id'] == id).firstOrNull ??
      (throw _err('P0002', 'tournament: registration not found'));

  Iterable<Map<String, dynamic>> _of(String tid, [String? status]) =>
      entries.where(
        (e) =>
            e['tournament_id'] == tid &&
            (status == null || e['status'] == status),
      );

  int _approved(String tid) => _of(tid, 'approved').length;

  String _effective(FakeTournament t) =>
      t.status == 'registration_open' && today.isAfter(t.deadline)
      ? 'registration_closed'
      : t.status;

  bool _accepts(FakeTournament t) =>
      _effective(t) == 'registration_open' &&
      _approved(t.id) < t.maxTeams &&
      t.fixturesAt == null;

  /// Adds a tournament directly (as another club would have published it).
  String addTournament(
    String clubId,
    String name, {
    String city = 'Lahore',
    String type = 'knockout',
    int maxTeams = 8,
    int startIn = 20,
    String status = 'registration_open',
  }) {
    final id = 'trn-${++_seq}';
    tournaments[id] = FakeTournament(
      id: id,
      organizerClubId: clubId,
      name: name,
      city: city,
      ground: 'Gaddafi Stadium',
      format: 't20',
      type: type,
      startDate: today.add(Duration(days: startIn)),
      endDate: today.add(Duration(days: startIn + 3)),
      deadline: today.add(Duration(days: startIn - 5)),
      maxTeams: maxTeams,
      entryFee: 5000,
      prize: 50000,
      description: 'Weekend cup',
      rules: const ['Standard T20 rules'],
      status: status,
      createdAt: DateTime.utc(2026, 11, 20).add(Duration(minutes: _seq)),
    );
    return id;
  }

  /// Adds an entry directly; returns its id.
  String addEntry(
    String tid,
    String clubId, {
    String status = 'pending',
    String? teamName,
  }) {
    final id = 'reg-${++_seq}';
    entries.add({
      'registration_id': id,
      'tournament_id': tid,
      'club_id': clubId,
      'club_name': clubNames[clubId],
      'club_short_name': null,
      'club_city': 'Lahore',
      'club_logo_path': null,
      'team_id': null,
      'team_name': teamName ?? '${clubNames[clubId]} XI',
      'status': status,
      'submitted_at': _stamp(),
      'decided_at': status == 'pending' ? null : _stamp(),
      'player_count': 15,
      'players': const <Map<String, dynamic>>[],
    });
    return id;
  }

  Map<String, dynamic> tRow(FakeTournament t) {
    final mine = _of(t.id)
        .where(
          (e) =>
              _owns(e['club_id'] as String) &&
              (e['status'] == 'pending' || e['status'] == 'approved'),
        )
        .firstOrNull;
    final approved = _approved(t.id);
    return {
      'tournament_id': t.id,
      'organizer_club_id': t.organizerClubId,
      'organizer_name': clubNames[t.organizerClubId],
      'organizer_short_name': null,
      'organizer_city': 'Lahore',
      'organizer_logo_path': null,
      'name': t.name,
      'city': t.city,
      'ground': t.ground,
      'format': t.format,
      'custom_overs': t.customOvers,
      'tournament_type': t.type,
      'start_date': _date(t.startDate),
      'end_date': _date(t.endDate),
      'registration_deadline': _date(t.deadline),
      'entry_fee': t.entryFee,
      'prize': t.prize,
      'max_teams': t.maxTeams,
      'description': t.description,
      'rules': t.rules,
      'status': _effective(t),
      'approved_count': approved,
      'pending_count': _owns(t.organizerClubId)
          ? _of(t.id, 'pending').length
          : null,
      'available_slots': (t.maxTeams - approved).clamp(0, t.maxTeams),
      'accepts_registrations': _accepts(t),
      'fixtures_generated': t.fixturesAt != null,
      'fixtures_generated_at': t.fixturesAt?.toIso8601String(),
      'winner_registration_id': t.winner,
      'winner_name': t.winner == null ? null : _entry(t.winner!)['club_name'],
      'is_organizer': _owns(t.organizerClubId),
      'my_registration_id': mine?['registration_id'],
      'my_registration_status': mine?['status'],
      'created_at': t.createdAt.toIso8601String(),
    };
  }

  Map<String, dynamic> _rRow(Map<String, dynamic> e) => {
    for (final MapEntry(:key, :value) in e.entries)
      if (key != 'players') key: value,
    'is_my_club': _owns(e['club_id'] as String),
  };

  @override
  Future<Map<String, dynamic>> createTournament(
    Map<String, Object?> params,
  ) async {
    _call('create_tournament', params);
    final clubId = params['p_club_id']! as String;
    if (!_owns(clubId)) throw _err('42501', 'tournament: not allowed');
    String clean(Object? v) =>
        ((v as String?) ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
    final name = clean(params['p_name']);
    if (name.isEmpty || name.length > 60) {
      throw _err('22023', 'tournament: invalid name');
    }
    final start = _parse(params['p_start_date']);
    if (start.isBefore(today)) {
      throw _err('22023', 'tournament: start date in the past');
    }
    final max = params['p_max_teams']! as int;
    if (max < 2 || max > 32) {
      throw _err('22023', 'tournament: invalid max teams');
    }
    final id = 'trn-${++_seq}';
    tournaments[id] = FakeTournament(
      id: id,
      organizerClubId: clubId,
      name: name,
      city: clean(params['p_city']),
      ground: clean(params['p_ground']),
      format: params['p_format']! as String,
      customOvers: params['p_format'] == 'custom'
          ? params['p_custom_overs'] as int?
          : null,
      type: params['p_tournament_type']! as String,
      startDate: start,
      endDate: _parse(params['p_end_date']),
      deadline: _parse(params['p_registration_deadline']),
      maxTeams: max,
      entryFee: params['p_entry_fee'] as int?,
      prize: params['p_prize'] as int?,
      description: params['p_description'] as String?,
      rules: (params['p_rules'] as List?)?.cast<String>(),
      createdAt: DateTime.utc(2026, 11, 20).add(Duration(minutes: _seq)),
    );
    return tRow(tournaments[id]!);
  }

  @override
  Future<List<Map<String, dynamic>>> myHostedTournaments(String clubId) async {
    _call('my_hosted_tournaments', {'p_club_id': clubId});
    if (!_owns(clubId)) throw _err('42501', 'tournament: not allowed');
    final mine =
        tournaments.values.where((t) => t.organizerClubId == clubId).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return [for (final t in mine) tRow(t)];
  }

  @override
  Future<List<Map<String, dynamic>>> browseTournaments({String? city}) async {
    _call('browse_tournaments', {'p_city': city});
    final c = city?.trim().toLowerCase();
    final list =
        tournaments.values
            .where(
              (t) =>
                  !_owns(t.organizerClubId) &&
                  (c == null || t.city.toLowerCase() == c),
            )
            .toList()
          ..sort((a, b) => a.startDate.compareTo(b.startDate));
    return [for (final t in list) tRow(t)];
  }

  @override
  Future<Map<String, dynamic>> tournamentDetail(String tournamentId) async {
    _call('tournament_detail', {'p_tournament_id': tournamentId});
    return tRow(_find(tournamentId));
  }

  @override
  Future<Map<String, dynamic>> tournamentHubStats(String clubId) async {
    _call('tournament_hub_stats', {'p_club_id': clubId});
    if (!_owns(clubId)) throw _err('42501', 'tournament: not allowed');
    final mine = entries.where((e) => e['club_id'] == clubId);
    return {
      'hosted': tournaments.values
          .where((t) => t.organizerClubId == clubId)
          .length,
      'open': tournaments.values
          .where((t) => !_owns(t.organizerClubId) && _accepts(t))
          .length,
      'registered': mine.length,
      'approved': mine.where((e) => e['status'] == 'approved').length,
      'pending': mine.where((e) => e['status'] == 'pending').length,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> tournamentTeams(
    String tournamentId,
  ) async {
    _call('tournament_teams', {'p_tournament_id': tournamentId});
    final t = _find(tournamentId);
    final organizer = _owns(t.organizerClubId);
    final visible = [
      for (final e in _of(tournamentId))
        if (e['status'] == 'approved' ||
            organizer ||
            _owns(e['club_id'] as String))
          e,
    ];
    int rank(Map<String, dynamic> e) => switch (e['status']) {
      'approved' => 0,
      'pending' => 1,
      _ => 2,
    };
    visible.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return switch (rank(a)) {
        0 => (a['decided_at'] as String).compareTo(b['decided_at'] as String),
        1 => (a['submitted_at'] as String).compareTo(
          b['submitted_at'] as String,
        ),
        _ => (b['decided_at'] as String).compareTo(a['decided_at'] as String),
      };
    });
    return [for (final e in visible) _rRow(e)];
  }

  @override
  Future<List<Map<String, dynamic>>> registrationSquad(
    String registrationId,
  ) async {
    _call('tournament_registration_squad', {
      'p_registration_id': registrationId,
    });
    final e = _entry(registrationId);
    final organizer = _owns(
      _find(e['tournament_id'] as String).organizerClubId,
    );
    if (!organizer && !_owns(e['club_id'] as String)) {
      throw _err('42501', 'tournament: not allowed');
    }
    return [...(e['players'] as List).cast<Map<String, dynamic>>()];
  }

  @override
  Future<Map<String, dynamic>> submitRegistration(
    Map<String, Object?> params,
  ) async {
    _call('submit_tournament_registration', params);
    final clubId = params['p_club_id']! as String;
    if (!_owns(clubId)) throw _err('42501', 'tournament: not allowed');
    final t = _find(params['p_tournament_id']! as String);
    if (params['p_agree_rules'] != true) {
      throw _err('22023', 'tournament: rules not agreed');
    }
    final players = (params['p_players']! as List).cast<Map<String, Object?>>();
    final playing = players.where((p) => p['selection'] == 'playing').length;
    if (playing != 11 || players.length - playing != 4) {
      throw _err('23514', 'tournament: squad must be 11 + 4');
    }
    if (t.organizerClubId == clubId) {
      throw _err('P0001', 'tournament: own tournament');
    }
    if (!_accepts(t)) {
      throw _err(
        'P0001',
        _approved(t.id) >= t.maxTeams
            ? 'tournament: registration full'
            : 'tournament: registration closed',
      );
    }
    if (_of(t.id).any(
      (e) =>
          e['club_id'] == clubId &&
          (e['status'] == 'pending' || e['status'] == 'approved'),
    )) {
      throw _err('P0001', 'tournament: already registered');
    }
    final id = addEntry(
      t.id,
      clubId,
      teamName: params['p_team_name'] as String?,
    );
    final e = _entry(id)
      ..['team_id'] = params['p_team_id']
      ..['players'] = [
        for (final (i, p) in players.indexed)
          {
            'registration_id': id,
            'position': i + 1,
            'member_id': p['member_id'],
            'user_id': 'u-${p['member_id']}',
            'full_name': 'Player ${p['member_id']}',
            'avatar_path': null,
            'member_role': 'player',
            'selection': p['selection'],
            'is_captain': p['member_id'] == params['p_captain_member_id'],
            'is_vice_captain': p['member_id'] == params['p_vice_member_id'],
            'is_wicket_keeper': p['member_id'] == params['p_keeper_member_id'],
            'member_active': true,
          },
      ];
    return _rRow(e);
  }

  @override
  Future<Map<String, dynamic>> decideRegistration(
    String registrationId, {
    required bool approve,
  }) async {
    _call('decide_tournament_registration', {
      'p_registration_id': registrationId,
      'p_approve': approve,
    });
    final e = _entry(registrationId);
    final t = _find(e['tournament_id'] as String);
    if (!_owns(t.organizerClubId)) {
      throw _err('42501', 'tournament: not allowed');
    }
    if (e['status'] != 'pending') {
      throw _err('P0001', 'tournament: not pending');
    }
    if (approve) {
      if (t.fixturesAt != null) {
        throw _err('P0001', 'tournament: fixtures generated');
      }
      if (_approved(t.id) >= t.maxTeams) {
        throw _err('P0001', 'tournament: registration full');
      }
    }
    e
      ..['status'] = approve ? 'approved' : 'rejected'
      ..['decided_at'] = _stamp();
    if (approve && _approved(t.id) >= t.maxTeams) {
      t.status = 'registration_full';
    }
    return _rRow(e);
  }

  @override
  Future<Map<String, dynamic>> removeTeam(String registrationId) async {
    _call('remove_tournament_team', {'p_registration_id': registrationId});
    final e = _entry(registrationId);
    final t = _find(e['tournament_id'] as String);
    if (!_owns(t.organizerClubId)) {
      throw _err('42501', 'tournament: not allowed');
    }
    if (e['status'] != 'approved') {
      throw _err('P0001', 'tournament: not approved');
    }
    if (t.fixturesAt != null) {
      throw _err('P0001', 'tournament: fixtures generated');
    }
    e
      ..['status'] = 'removed'
      ..['decided_at'] = _stamp();
    if (t.status == 'registration_full') t.status = 'registration_open';
    return _rRow(e);
  }

  @override
  Future<List<Map<String, dynamic>>> myRegistrations(
    String clubId, {
    String? status,
  }) async {
    _call('my_tournament_registrations', {
      'p_club_id': clubId,
      'p_status': status,
    });
    if (!_owns(clubId)) throw _err('42501', 'tournament: not allowed');
    final mine =
        entries
            .where(
              (e) =>
                  e['club_id'] == clubId &&
                  (status == null || e['status'] == status),
            )
            .toList()
          ..sort(
            (a, b) => (b['submitted_at'] as String).compareTo(
              a['submitted_at'] as String,
            ),
          );
    return [
      for (final e in mine)
        {
          'registration_id': e['registration_id'],
          'tournament_id': e['tournament_id'],
          'tournament_name': tournaments[e['tournament_id']]?.name,
          'organizer_club_id': tournaments[e['tournament_id']]?.organizerClubId,
          'organizer_name':
              clubNames[tournaments[e['tournament_id']]?.organizerClubId],
          'tournament_city': tournaments[e['tournament_id']]?.city,
          'ground': tournaments[e['tournament_id']]?.ground,
          'start_date': null,
          'end_date': null,
          'tournament_status': tournaments[e['tournament_id']]?.status,
          'team_id': e['team_id'],
          'team_name': e['team_name'],
          'status': e['status'],
          'submitted_at': e['submitted_at'],
          'decided_at': e['decided_at'],
          'player_count': e['player_count'],
        },
    ];
  }

  @override
  Future<Map<String, dynamic>> generateFixtures(String tournamentId) async {
    _call('generate_tournament_fixtures', {'p_tournament_id': tournamentId});
    final t = _find(tournamentId);
    if (!_owns(t.organizerClubId)) {
      throw _err('42501', 'tournament: not allowed');
    }
    if (t.fixturesAt != null) {
      return {
        'outcome': 'already_generated',
        'fixture_count': fixtureRows[t.id]?.length ?? 0,
      };
    }
    final seeds = _of(t.id, 'approved').toList()
      ..sort(
        (a, b) =>
            (a['decided_at'] as String).compareTo(b['decided_at'] as String),
      );
    if (seeds.length < 2) throw _err('P0001', 'tournament: not enough teams');
    for (final e in _of(t.id, 'pending').toList()) {
      e
        ..['status'] = 'rejected'
        ..['decided_at'] = _stamp();
    }
    t
      ..status = 'registration_closed'
      ..fixturesAt = DateTime.utc(2026, 11, 20, 7);
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic> row(
      int round,
      String name,
      int no,
      Map<String, dynamic>? home,
      Map<String, dynamic>? away,
    ) => {
      'fixture_id': 'fx-${++_seq}',
      'round_no': round,
      'round_name': name,
      'match_no': no,
      'home_registration_id': home?['registration_id'],
      'home_club_id': home?['club_id'],
      'home_name': home?['club_name'],
      'home_bye': false,
      'away_registration_id': away?['registration_id'],
      'away_club_id': away?['club_id'],
      'away_name': away?['club_name'],
      'away_bye': false,
      'winner_registration_id': null,
      'winner_bye': false,
      'state': home != null && away != null ? 'ready' : 'tbd',
      'next_fixture_id': null,
      'next_slot': null,
      'match_id': null,
      'decided_at': null,
    };
    if (t.type == 'league') {
      var no = 0;
      for (var i = 0; i < seeds.length; i++) {
        for (var j = i + 1; j < seeds.length; j++) {
          rows.add(row(1, 'League Stage', ++no, seeds[i], seeds[j]));
        }
      }
    } else {
      // Power-of-two sizes only (enough for these tests).
      const names = ['Final', 'Semifinal', 'Quarterfinal'];
      final size = seeds.length;
      var rounds = 0;
      while (1 << rounds < size) {
        rounds++;
      }
      for (var r = 1; r <= rounds; r++) {
        final matches = (1 << rounds) >> r;
        for (var m = 0; m < matches; m++) {
          rows.add(
            r == 1
                ? row(
                    r,
                    names[rounds - r],
                    m + 1,
                    seeds[2 * m],
                    seeds[2 * m + 1],
                  )
                : row(r, names[rounds - r], m + 1, null, null),
          );
        }
      }
    }
    fixtureRows[t.id] = rows;
    return {'outcome': 'generated', 'fixture_count': rows.length};
  }

  @override
  Future<List<Map<String, dynamic>>> tournamentFixtures(
    String tournamentId,
  ) async {
    _call('tournament_fixtures', {'p_tournament_id': tournamentId});
    _find(tournamentId);
    return [...?fixtureRows[tournamentId]];
  }

  @override
  Future<List<Map<String, dynamic>>> pointsTable(String tournamentId) async {
    _call('tournament_points_table', {'p_tournament_id': tournamentId});
    _find(tournamentId);
    final approved = _of(tournamentId, 'approved').toList();
    final decided = [
      for (final f
          in fixtureRows[tournamentId] ?? const <Map<String, dynamic>>[])
        if (f['winner_registration_id'] != null &&
            f['home_bye'] != true &&
            f['away_bye'] != true)
          f,
    ];
    final rows =
        [
          for (final e in approved)
            () {
              final id = e['registration_id'];
              final played = decided.where(
                (f) =>
                    f['home_registration_id'] == id ||
                    f['away_registration_id'] == id,
              );
              final won = played
                  .where((f) => f['winner_registration_id'] == id)
                  .length;
              return {
                'registration_id': id,
                'club_id': e['club_id'],
                'club_name': e['club_name'],
                'team_name': e['team_name'],
                'played': played.length,
                'won': won,
                'lost': played.length - won,
                'points': won * 2,
              };
            }(),
        ]..sort((a, b) {
          final p = (b['points']! as int).compareTo(a['points']! as int);
          return p != 0
              ? p
              : (a['club_name']! as String).compareTo(
                  b['club_name']! as String,
                );
        });
    return [
      for (final (i, r) in rows.indexed) {'position': i + 1, ...r},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> awards(String tournamentId) async {
    _call('tournament_awards', {'p_tournament_id': tournamentId});
    final t = _find(tournamentId);
    final participant =
        _owns(t.organizerClubId) ||
        _of(tournamentId, 'approved').any((e) => _owns(e['club_id'] as String));
    if (!participant) throw _err('42501', 'tournament: not allowed');
    return [...?awardRows[tournamentId]];
  }
}
