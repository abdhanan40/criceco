import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'membership_row_mapper.dart';
import 'supabase_error_mapper.dart';
import 'supabase_gateways.dart';

/// [TeamRepository] on Supabase (migration 12, the memberships switch).
///
/// - Reads: the club owner's active teams with their squads (RLS: owner only).
/// - [create] → `create_team()`; [save] → `save_team()`: details, captain /
///   vice-captain and the whole squad in one transaction. The database checks
///   the owner, the squad limits (11 + 4), that every player is an active
///   member of the club, and that captain / vice-captain are two different
///   squad players — the app's own checks are a convenience, not the rule.
/// - [archive] → `archive_team()`: "Delete team" keeps the row (see
///   docs/TEAM_SQUAD_IMPLEMENTATION.md).
class SupabaseTeamRepository implements TeamRepository {
  SupabaseTeamRepository({required this.db});

  final TeamGateway db;

  @override
  Future<List<Team>> teams(String clubId) async {
    final rows = await _call(() => db.fetchTeams(clubId));
    return [for (final r in rows) MembershipRowMapper.teamFromRow(r)];
  }

  @override
  Future<Team> create({
    required String clubId,
    required String name,
    required MatchFormat format,
    int? customOvers,
  }) async {
    final row = await _call(() => db.createTeam({
          'p_club_id': clubId,
          'p_name': name,
          'p_format': MembershipRowMapper.formatCode(format),
          'p_custom_overs': format == MatchFormat.custom ? customOvers : null,
        }));
    return MembershipRowMapper.teamFromRow(row);
  }

  /// The saved team, its squad as sent (the function stores it in this order).
  @override
  Future<Team> save(Team team) async {
    final row = await _call(() => db.saveTeam(MembershipRowMapper.saveParams(team)));
    return MembershipRowMapper.teamFromRow(row).copyWith(members: team.members);
  }

  @override
  Future<void> archive(String teamId) => _call(() => db.archiveTeam(teamId));

  static Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on GatewayException catch (e) {
      throw SupabaseErrorMapper.map(e);
    }
  }
}
