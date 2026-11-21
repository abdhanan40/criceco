import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'result_row_mapper.dart';
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart' show guardMatchCall;

/// [ResultsRepository] on Supabase (migrations 20–23, the results switch).
///
/// Every rule — who may submit, answer or read, and whether the scores and
/// cards add up — is checked by the database functions; this class maps
/// rows and errors only ([guardMatchCall]: refusals become
/// [MatchRuleException] / [PermissionDeniedException], an unreadable row a
/// generic error).
class SupabaseResultsRepository implements ResultsRepository {
  SupabaseResultsRepository({required this.db});

  final ResultsGateway db;

  @override
  Future<ResultReceipt> submit(ResultSubmission submission) => guardMatchCall(
    () async => ResultRowMapper.receipt(
      await db.submitResult(ResultRowMapper.submitParams(submission)),
    ),
  );

  @override
  Future<ResultReceipt> confirm(String matchId, int version) => guardMatchCall(
    () async =>
        ResultRowMapper.receipt(await db.confirmResult(matchId, version)),
  );

  @override
  Future<ResultReceipt> dispute(String matchId, int version, String reason) =>
      guardMatchCall(
        () async => ResultRowMapper.receipt(
          await db.disputeResult(
            matchId,
            version,
            reason.trim().replaceAll(RegExp(r'\s+'), ' '),
          ),
        ),
      );

  @override
  Future<List<ResultVersion>> matchResult(String matchId) => guardMatchCall(
    () async => [
      for (final r in await db.matchResult(matchId))
        ResultRowMapper.version(matchId, r),
    ],
  );

  @override
  Future<List<ClubResultRow>> clubResults(String clubId) => guardMatchCall(
    () async => [
      for (final r in await db.clubResults(clubId))
        ResultRowMapper.clubResult(r),
    ],
  );

  @override
  Future<ClubRecord> clubRecord(String clubId) => guardMatchCall(
    () async => ResultRowMapper.record(await db.clubRecord(clubId)),
  );

  @override
  Future<List<PoolPlayer>> playerPool(String matchId) => guardMatchCall(
    () async => [
      for (final r in await db.playerPool(matchId))
        ResultRowMapper.poolPlayer(r),
    ],
  );

  @override
  Future<List<InningsCard>> scorecard(String matchId, {int? version}) =>
      guardMatchCall(
        () async => [
          for (final r in await db.scorecard(matchId, version: version))
            ResultRowMapper.inningsCard(r),
        ]..sort((a, b) => a.inningsNo - b.inningsNo),
      );

  @override
  Future<CricketStats> playerStats({String? userId}) => guardMatchCall(
    () async => ResultRowMapper.stats(await db.playerStats(userId: userId)),
  );

  @override
  Future<List<ClubMemberStats>> clubMemberStats(String clubId) =>
      guardMatchCall(
        () async => [
          for (final r in await db.clubMemberStats(clubId))
            ResultRowMapper.memberStats(r),
        ],
      );

  @override
  Future<List<PlayerMatchLogRow>> matchLog({String? userId, int limit = 50}) =>
      guardMatchCall(
        () async => [
          for (final r in await db.playerMatchLog(
            userId: userId,
            limit: limit.clamp(1, 200),
          ))
            ResultRowMapper.logRow(r),
        ],
      );

  @override
  Future<List<MyMatch>> myMatches() => guardMatchCall(
    () async => [
      for (final r in await db.myMatches()) ResultRowMapper.myMatch(r),
    ],
  );
}
