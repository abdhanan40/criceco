import '../../core/domain/player_ranking.dart';
import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'discovery_row_mapper.dart';
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart' show guardMatchCall;

/// [DiscoveryRepository] on Supabase (migration 32, the discovery switch):
/// the shared player leaderboard (`player_rankings`; who is listed and the
/// consent rules are the server's, the ranking math the app's) and a
/// pending applicant's statistics (`club_applicant_stats`, owner only).
class SupabaseDiscoveryRepository implements DiscoveryRepository {
  SupabaseDiscoveryRepository({required this.db});

  final DiscoveryGateway db;

  @override
  Future<List<RankingInput>> playerRankings({int limit = 200}) =>
      guardMatchCall(
        () async => [
          for (final r in await db.playerRankings({
            'p_role': null,
            'p_club_id': null,
            'p_search': null,
            'p_limit': limit,
          }))
            DiscoveryRowMapper.rankingInput(r),
        ],
      );

  @override
  Future<JoinRequestPerformance?> applicantPerformance(String requestId) =>
      guardMatchCall(
        () async => DiscoveryRowMapper.applicantPerformance(
          await db.clubApplicantStats(requestId),
        ),
      );
}
