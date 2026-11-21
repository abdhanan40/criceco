// Stand-in for the results gateway (migrations 20–23): canned responses
// per database function, every call recorded. Rows are shaped like the
// real functions' (see results_supabase_test.dart and the SQL local checks).
import 'package:criceco/data/supabase/supabase_gateways.dart';

/// Canned responses per function; every call recorded.
class FakeResultsDb implements ResultsGateway {
  final calls = <({String fn, Map<String, Object?> params})>[];
  final one = <String, Map<String, dynamic>>{};
  final many = <String, List<Map<String, dynamic>>>{};

  /// Per-match responses: function → match id → rows (checked before [many]).
  final byMatch = <String, Map<String, List<Map<String, dynamic>>>>{};

  /// Every call of a function fails with this while it's set.
  final failOn = <String, GatewayException>{};

  Future<Map<String, dynamic>> _one(String fn, Map<String, Object?> p) async {
    calls.add((fn: fn, params: p));
    if (failOn[fn] case final e?) throw e;
    return one[fn] ?? (throw GatewayUnexpectedException('$fn-no-row'));
  }

  Future<List<Map<String, dynamic>>> _many(
    String fn,
    Map<String, Object?> p,
  ) async {
    calls.add((fn: fn, params: p));
    if (failOn[fn] case final e?) throw e;
    if (p['p_match_id'] case final String id) {
      if (byMatch[fn]?[id] case final rows?) return rows;
    }
    return many[fn] ?? const [];
  }

  @override
  Future<Map<String, dynamic>> submitResult(Map<String, Object?> params) =>
      _one('submit_match_result_with_scorecard', params);
  @override
  Future<Map<String, dynamic>> confirmResult(String matchId, int version) =>
      _one('confirm_match_result', {
        'p_match_id': matchId,
        'p_version': version,
      });
  @override
  Future<Map<String, dynamic>> disputeResult(
    String matchId,
    int version,
    String reason,
  ) => _one('dispute_match_result', {
    'p_match_id': matchId,
    'p_version': version,
    'p_reason': reason,
  });
  @override
  Future<List<Map<String, dynamic>>> matchResult(String matchId) =>
      _many('match_result', {'p_match_id': matchId});
  @override
  Future<List<Map<String, dynamic>>> clubResults(String clubId) =>
      _many('club_results', {'p_club_id': clubId});
  @override
  Future<Map<String, dynamic>> clubRecord(String clubId) =>
      _one('club_record', {'p_club_id': clubId});
  @override
  Future<List<Map<String, dynamic>>> playerPool(String matchId) =>
      _many('match_player_pool', {'p_match_id': matchId});
  @override
  Future<List<Map<String, dynamic>>> scorecard(
    String matchId, {
    int? version,
  }) => _many('match_scorecard', {'p_match_id': matchId, 'p_version': version});
  @override
  Future<Map<String, dynamic>> playerStats({String? userId}) =>
      _one('player_stats', {'p_user_id': userId});
  @override
  Future<List<Map<String, dynamic>>> clubMemberStats(String clubId) =>
      _many('club_member_stats', {'p_club_id': clubId});
  @override
  Future<List<Map<String, dynamic>>> playerMatchLog({
    String? userId,
    int limit = 50,
  }) => _many('player_match_log', {'p_user_id': userId, 'p_limit': limit});
  @override
  Future<List<Map<String, dynamic>>> myMatches() =>
      _many('my_matches', const {});
}
