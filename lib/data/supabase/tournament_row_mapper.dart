import 'dart:collection';

import '../../core/models/models.dart';
import '../repositories/repositories.dart' show TournamentServerStats;
import 'match_row_mapper.dart';

/// Rows of migration 35 (tournaments) ↔ the app's models
/// (docs/M10_TOURNAMENTS.md). A required field missing or of the wrong type,
/// or a code this version doesn't know, is a [MatchRowFormatException] —
/// never a guessed value. Dates are Pakistan calendar dates
/// ([MatchRowMapper.optDate] / [MatchRowMapper.dateCode]).
abstract final class TournamentRowMapper {
  static const _types = {
    'knockout': TournamentType.knockout,
    'league': TournamentType.league,
  };
  static const _statuses = {
    'registration_open': TournamentStatus.registrationOpen,
    'registration_full': TournamentStatus.registrationFull,
    'registration_closed': TournamentStatus.registrationClosed,
    'completed': TournamentStatus.completed,
  };

  static String typeCode(TournamentType t) =>
      _types.entries.firstWhere((e) => e.value == t).key;

  static TournamentType type(Object? code) =>
      _types[code] ?? (throw const MatchRowFormatException('tournament_type'));

  static TournamentStatus status(Object? code) =>
      _statuses[code] ?? (throw const MatchRowFormatException('status'));

  /// An entry's status: `removed` (the organizer removed a confirmed team)
  /// is listed as Rejected, flagged.
  static (RegistrationStatus, bool removed) registrationStatus(Object? code) =>
      switch (code) {
        'pending' => (RegistrationStatus.pending, false),
        'approved' => (RegistrationStatus.approved, false),
        'rejected' => (RegistrationStatus.rejected, false),
        'removed' => (RegistrationStatus.rejected, true),
        _ => throw const MatchRowFormatException('status'),
      };

  static DateTime _date(Map<String, dynamic> row, String key) =>
      MatchRowMapper.optDate(row, key) ?? (throw MatchRowFormatException(key));

  /// A tournament row (`create_tournament`, `my_hosted_tournaments`,
  /// `browse_tournaments`, `tournament_detail`). Its entries, draw and
  /// standings come from their own functions.
  static Tournament tournament(Map<String, dynamic> row) {
    final format = MatchRowMapper.format(row['format']);
    final rules = row['rules'];
    return Tournament(
      id: MatchRowMapper.text(row, 'tournament_id'),
      name: MatchRowMapper.text(row, 'name'),
      organizerClubId: MatchRowMapper.text(row, 'organizer_club_id'),
      organizerName: MatchRowMapper.optText(row, 'organizer_name'),
      city: MatchRowMapper.text(row, 'city'),
      ground: MatchRowMapper.text(row, 'ground'),
      format: format,
      customOvers: format == MatchFormat.custom
          ? MatchRowMapper.optInt(row, 'custom_overs')
          : null,
      type: type(row['tournament_type']),
      startDate: _date(row, 'start_date'),
      endDate: _date(row, 'end_date'),
      registrationDeadline: _date(row, 'registration_deadline'),
      entryFee: MatchRowMapper.optInt(row, 'entry_fee'),
      prize: MatchRowMapper.optInt(row, 'prize'),
      maxTeams: MatchRowMapper.integer(row, 'max_teams'),
      description: MatchRowMapper.optText(row, 'description') ?? '',
      rules: rules is List
          ? [
              for (final r in rules)
                if (r is String && r.trim().isNotEmpty) r,
            ]
          : const [],
      status: status(row['status']),
      approvedCount: MatchRowMapper.integer(row, 'approved_count'),
      pendingCount: MatchRowMapper.optInt(row, 'pending_count'),
      fixturesGenerated: MatchRowMapper.flag(row, 'fixtures_generated'),
      winnerId: MatchRowMapper.optText(row, 'winner_registration_id'),
      winnerName: MatchRowMapper.optText(row, 'winner_name'),
    );
  }

  /// An entry row (`tournament_teams`, `submit_tournament_registration`,
  /// `decide_tournament_registration`, `remove_tournament_team`).
  static TournamentRegistration entry(Map<String, dynamic> row) {
    final (status, removed) = registrationStatus(row['status']);
    return TournamentRegistration(
      id: MatchRowMapper.text(row, 'registration_id'),
      tournamentId: MatchRowMapper.text(row, 'tournament_id'),
      clubId: MatchRowMapper.text(row, 'club_id'),
      clubName: MatchRowMapper.optText(row, 'club_name'),
      clubCity: MatchRowMapper.optText(row, 'club_city'),
      teamId: MatchRowMapper.optText(row, 'team_id'),
      teamName: MatchRowMapper.text(row, 'team_name'),
      status: status,
      removed: removed,
      submittedAt: MatchRowMapper.time(row, 'submitted_at'),
      decidedAt: MatchRowMapper.optTime(row, 'decided_at'),
    );
  }

  /// An entry as a tournament entrant: its id is the registration id (the
  /// draw and the points table use it); its name is the club's.
  static TournamentEntrant entrant(TournamentRegistration r) =>
      TournamentEntrant(
        id: r.id,
        displayName: r.clubName ?? r.teamName,
        clubId: r.clubId,
        city: r.clubCity,
      );

  /// A `my_tournament_registrations` row of [clubId]'s.
  static TournamentRegistration myRegistration(
    Map<String, dynamic> row,
    String clubId,
  ) {
    final (status, removed) = registrationStatus(row['status']);
    return TournamentRegistration(
      id: MatchRowMapper.text(row, 'registration_id'),
      tournamentId: MatchRowMapper.text(row, 'tournament_id'),
      clubId: clubId,
      teamId: MatchRowMapper.optText(row, 'team_id'),
      teamName: MatchRowMapper.text(row, 'team_name'),
      status: status,
      removed: removed,
      submittedAt: MatchRowMapper.time(row, 'submitted_at'),
      decidedAt: MatchRowMapper.optTime(row, 'decided_at'),
    );
  }

  /// `tournament_registration_squad` rows (pick order) → the squad.
  static Lineup squad(
    List<Map<String, dynamic>> rows, {
    required String teamName,
  }) {
    String? flagged(String key) => rows
        .where((r) => r[key] == true)
        .map((r) => MatchRowMapper.text(r, 'member_id'))
        .firstOrNull;
    return Lineup(
      name: teamName,
      members: [
        for (final r in rows)
          TeamMember(
            playerId: MatchRowMapper.text(r, 'member_id'),
            selection: MatchRowMapper.selection(r['selection']),
          ),
      ],
      captainId: flagged('is_captain'),
      viceCaptainId: flagged('is_vice_captain'),
    );
  }

  /// `create_tournament`'s parameters for a validated [draft]: blank
  /// optional text is none; the custom overs only with the custom format.
  static Map<String, Object?> createParams(Tournament draft) {
    final description = draft.description.trim();
    final rules = [
      for (final r in draft.rules)
        if (r.trim().isNotEmpty) r.trim(),
    ];
    return {
      'p_club_id': draft.organizerClubId,
      'p_name': draft.name.trim(),
      'p_city': draft.city.trim(),
      'p_ground': draft.ground.trim(),
      'p_format': MatchRowMapper.formatCode(draft.format),
      'p_custom_overs': draft.format == MatchFormat.custom
          ? draft.customOvers
          : null,
      'p_tournament_type': typeCode(draft.type),
      'p_start_date': MatchRowMapper.dateCode(draft.startDate),
      'p_end_date': MatchRowMapper.dateCode(draft.endDate),
      'p_registration_deadline': MatchRowMapper.dateCode(
        draft.registrationDeadline,
      ),
      'p_max_teams': draft.maxTeams,
      'p_entry_fee': draft.entryFee,
      'p_prize': draft.prize,
      'p_description': description.isEmpty ? null : description,
      'p_rules': rules.isEmpty ? null : rules,
    };
  }

  /// `submit_tournament_registration`'s parameters: the Playing XI first
  /// (positions 1–11), then the substitutes (12–15), each in pick order;
  /// the team only when the squad came from one; no wicket-keeper flag
  /// (the app doesn't pick one).
  static Map<String, Object?> submitParams({
    required String tournamentId,
    required String clubId,
    required Lineup lineup,
    required bool agreedToRules,
  }) {
    final ordered = [
      for (final m in lineup.members)
        if (m.selection == SelectionRole.playing) m,
      for (final m in lineup.members)
        if (m.selection == SelectionRole.sub) m,
    ];
    return {
      'p_tournament_id': tournamentId,
      'p_club_id': clubId,
      'p_team_name': lineup.name.trim().isEmpty ? null : lineup.name.trim(),
      'p_team_id': lineup.sourceTeamId,
      'p_players': [
        for (final m in ordered)
          {
            'member_id': m.playerId,
            'selection': m.selection == SelectionRole.playing
                ? 'playing'
                : 'sub',
          },
      ],
      'p_captain_member_id': lineup.captainId,
      'p_vice_member_id': lineup.viceCaptainId,
      'p_keeper_member_id': null,
      'p_agree_rules': agreedToRules,
    };
  }

  /// `tournament_fixtures` rows → the draw by round; `null` when there is
  /// none yet. A BYE side is [FixtureMatch.bye]; a decided BYE fixture (a
  /// walkover) is a BYE match, which the screens don't list.
  static List<FixtureRound>? fixtures(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return null;
    final rounds = SplayTreeMap<int, (String, List<FixtureMatch>)>();
    String? side(Map<String, dynamic> r, String id, String bye) =>
        r[bye] == true ? FixtureMatch.bye : MatchRowMapper.optText(r, id);
    for (final r in rows) {
      final no = MatchRowMapper.integer(r, 'round_no');
      final round = rounds[no] ??= (
        MatchRowMapper.text(r, 'round_name'),
        <FixtureMatch>[],
      );
      round.$2.add(
        FixtureMatch(
          home: side(r, 'home_registration_id', 'home_bye'),
          away: side(r, 'away_registration_id', 'away_bye'),
          winnerId: side(r, 'winner_registration_id', 'winner_bye'),
        ),
      );
    }
    return [
      for (final (name, matches) in rounds.values)
        FixtureRound(name: name, matches: matches),
    ];
  }

  /// `tournament_points_table` rows → standings per entry, in table order.
  static Map<String, Standing> points(List<Map<String, dynamic>> rows) =>
      LinkedHashMap.fromEntries([
        for (final r in rows)
          MapEntry(
            MatchRowMapper.text(r, 'registration_id'),
            Standing(
              played: MatchRowMapper.integer(r, 'played'),
              won: MatchRowMapper.integer(r, 'won'),
              lost: MatchRowMapper.integer(r, 'lost'),
              points: MatchRowMapper.integer(r, 'points'),
            ),
          ),
      ]);

  /// `tournament_awards` rows → the awards; `null` when there are none (no
  /// official scorecard yet). An award this version doesn't know is left out.
  static TournamentAwards? awards(List<Map<String, dynamic>> rows) {
    final byAward = <String, TournamentAward>{
      for (final r in rows)
        if (r['award'] case final String code)
          code: TournamentAward(
            playerName: MatchRowMapper.text(r, 'player_name'),
            entrantId: MatchRowMapper.text(r, 'registration_id'),
            value: MatchRowMapper.integer(r, 'value'),
          ),
    };
    const known = [
      'top_run_scorer',
      'top_wicket_taker',
      'best_keeper',
      'best_fielder',
    ];
    if (!known.any(byAward.containsKey)) return null;
    return TournamentAwards(
      topScorer: byAward['top_run_scorer'],
      topWicketTaker: byAward['top_wicket_taker'],
      bestKeeper: byAward['best_keeper'],
      bestFielder: byAward['best_fielder'],
    );
  }

  /// `tournament_hub_stats`'s row.
  static TournamentServerStats hubStats(Map<String, dynamic> row) => (
    hosted: MatchRowMapper.integer(row, 'hosted'),
    open: MatchRowMapper.integer(row, 'open'),
    registered: MatchRowMapper.integer(row, 'registered'),
    approved: MatchRowMapper.integer(row, 'approved'),
    pending: MatchRowMapper.integer(row, 'pending'),
  );
}
