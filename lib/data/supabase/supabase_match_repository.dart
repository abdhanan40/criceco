import 'package:clock/clock.dart';

import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'match_row_mapper.dart';
import 'result_display_adapter.dart';
import 'supabase_error_mapper.dart';
import 'supabase_gateways.dart';

/// Runs a matches-backend call: gateway failures become the app's errors
/// ([SupabaseErrorMapper]); a row the app can't read becomes a generic
/// "something went wrong" — never a guessed value.
Future<T> guardMatchCall<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on GatewayException catch (e) {
    throw SupabaseErrorMapper.map(e);
  } on MatchRowFormatException {
    throw const BackendOperationException();
  }
}

/// The signed-in owner's club id, read from `public.clubs` (RLS: own club
/// only) on every call — never cached, so an ownership transfer applies at
/// once. `null` when the user owns no club.
class OwnClubLookup {
  OwnClubLookup({required this.auth, required this.clubs});

  final AuthGateway auth;
  final ClubGateway clubs;

  Future<String?> clubId() async {
    final user = auth.currentUser;
    if (user == null) throw const NotSignedInException();
    final row = await clubs.fetchOwnClub(user.id);
    final id = row?['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// [clubId], or [PermissionDeniedException] for a user without a club.
  Future<String> requireClubId() async =>
      await clubId() ?? (throw const PermissionDeniedException());
}

/// [MatchRepository] on Supabase (migrations 17–18, the matches switch).
///
/// Every change is a database function that checks the caller and the
/// match's state; this class maps rows and errors only. Matches are
/// created by accepting a challenge ([SupabaseChallengeRepository.accept]) —
/// never here.
///
/// The player's matches, scorecards and statistics are the OFFICIAL results
/// (migrations 20–23), read through [results] when the results switch is on
/// — display only: this app never enters, edits, confirms or disputes a
/// result. Without it they are empty, never invented.
class SupabaseMatchRepository implements MatchRepository {
  SupabaseMatchRepository({
    required this.db,
    required this.ownClub,
    this.results,
    this.clock = const Clock(),
  });

  final MatchGateway db;
  final OwnClubLookup ownClub;

  /// Official results (read-only); `null` without the results switch.
  final ResultsRepository? results;
  final Clock clock;

  @override
  Future<List<ClubMatch>> clubMatches() => guardMatchCall(() async {
    final clubId = await ownClub.clubId();
    if (clubId == null) return const <ClubMatch>[];
    final matches = [
      for (final r in await db.clubMatches(clubId))
        MatchRowMapper.matchFromListRow(r),
    ];
    final official = results;
    if (official == null ||
        !matches.any((m) => m.status == MatchStatus.completed)) {
      return matches;
    }
    // Completed matches carry their official result, from the club's side.
    final byMatch = {
      for (final r in await official.clubResults(clubId)) r.matchId: r,
    };
    return [
      for (final m in matches)
        if (byMatch[m.id] case final r? when m.status == MatchStatus.completed)
          m.copyWith(resultText: ResultDisplayAdapter.sideText(r))
        else
          m,
    ];
  });

  /// The server changes a match only through its functions.
  @override
  Future<ClubMatch> saveClubMatch(ClubMatch match) async =>
      throw const ModuleUnavailableException();

  /// Accepting the challenge creates the match on the server: no second one.
  @override
  Future<ClubMatch> createPendingMatch({
    required String opponentClubId,
    MatchFormat? format,
    String? city,
  }) async => throw const ModuleUnavailableException();

  /// The signed-in player's scheduled matches across their clubs
  /// (`my_matches()`); empty without the results switch.
  @override
  Future<List<PlayerMatch>> playerMatches() async {
    final official = results;
    if (official == null) return const [];
    final now = clock.now();
    return [
      for (final m in await official.myMatches())
        ResultDisplayAdapter.playerMatch(m, now),
    ];
  }

  /// The official scorecard of match [scorecardId] (the scorecard id IS the
  /// match id): its confirmed result with the cards, or the innings totals
  /// alone when no card was published. `null` while no result is confirmed.
  @override
  Future<Scorecard?> scorecard(String scorecardId) async {
    final official = results;
    if (official == null) return null;
    final confirmed = (await official.matchResult(scorecardId))
        .where((v) => v.status == ResultStatus.confirmed)
        .firstOrNull;
    if (confirmed == null) return null;
    final cards = await official.scorecard(
      scorecardId,
      version: confirmed.version,
    );
    return ResultDisplayAdapter.scorecard(
      confirmed,
      cards,
      await _clubNames(scorecardId),
    );
  }

  /// The two clubs' names for a match the caller belongs to, from their own
  /// match list (an owner is an active member of their club too).
  Future<Map<String, String>> _clubNames(String matchId) async {
    final mine = (await results!.myMatches())
        .where((m) => m.matchId == matchId)
        .firstOrNull;
    if (mine != null) {
      return {
        mine.clubId: mine.clubName,
        mine.opponentClubId: mine.opponentName,
      };
    }
    return const {};
  }

  /// The signed-in player's official career figures and match log.
  @override
  Future<PerformanceSummary> performance() async {
    final official = results;
    if (official == null) return PerformanceSummary.empty;
    final stats = await official.playerStats();
    final log = await official.matchLog();
    return ResultDisplayAdapter.performance(stats, log);
  }

  @override
  Future<ClubMatch> proposeSchedule(
    String matchId, {
    required DateTime startsAt,
    required String venueName,
    String? city,
  }) => guardMatchCall(() async {
    final clubId = await ownClub.requireClubId();
    final row = await db.proposeSchedule(
      MatchRowMapper.proposeParams(matchId, startsAt, venueName, city),
    );
    return MatchRowMapper.matchFromTableRow(row, ownClubId: clubId);
  });

  @override
  Future<ClubMatch> respondToSchedule(
    String matchId, {
    required int proposalVersion,
    required bool accept,
  }) => guardMatchCall(() async {
    final clubId = await ownClub.requireClubId();
    final row = await db.respondToSchedule(
      matchId,
      proposalVersion: proposalVersion,
      accept: accept,
    );
    return MatchRowMapper.matchFromTableRow(row, ownClubId: clubId);
  });

  @override
  Future<ClubMatch> cancelMatch(String matchId, {required String reason}) =>
      guardMatchCall(() async {
        final clubId = await ownClub.requireClubId();
        return MatchRowMapper.matchFromTableRow(
          await db.cancelMatch(matchId, reason),
          ownClubId: clubId,
        );
      });

  @override
  Future<MatchLineup> saveLineup(
    String matchId,
    Lineup lineup, {
    String? captainMemberId,
    String? viceCaptainMemberId,
  }) => guardMatchCall(() async {
    final row = await db.saveLineup(
      MatchRowMapper.lineupParams(
        matchId,
        lineup,
        captainMemberId: captainMemberId,
        viceCaptainMemberId: viceCaptainMemberId,
      ),
    );
    return MatchRowMapper.lineupFromSaved(row, lineup);
  });

  /// The lineup of the caller's own club: the club they own, otherwise the
  /// one club they play for in this match. (Someone who is an active member
  /// of both clubs is shown the first, by club id.)
  @override
  Future<MatchLineup?> lineup(String matchId) => guardMatchCall(() async {
    final lineups = MatchRowMapper.lineupsFromRows(
      matchId,
      await db.matchLineup(matchId),
    );
    if (lineups.isEmpty) return null;
    final owned = await ownClub.clubId();
    return lineups.where((l) => l.clubId == owned).firstOrNull ?? lineups.first;
  });
}
