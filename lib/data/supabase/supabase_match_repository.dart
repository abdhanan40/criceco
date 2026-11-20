import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'match_row_mapper.dart';
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
/// never here. Player match history, scorecards and statistics have no
/// server side yet (M2): empty, never invented.
class SupabaseMatchRepository implements MatchRepository {
  SupabaseMatchRepository({required this.db, required this.ownClub});

  final MatchGateway db;
  final OwnClubLookup ownClub;

  @override
  Future<List<ClubMatch>> clubMatches() => guardMatchCall(() async {
    final clubId = await ownClub.clubId();
    if (clubId == null) return const <ClubMatch>[];
    return [
      for (final r in await db.clubMatches(clubId))
        MatchRowMapper.matchFromListRow(r),
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

  @override
  Future<List<PlayerMatch>> playerMatches() async => const [];

  @override
  Future<Scorecard?> scorecard(String scorecardId) async => null;

  @override
  Future<PerformanceSummary> performance() async => PerformanceSummary.empty;

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
