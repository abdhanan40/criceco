import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'match_row_mapper.dart';
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart';

/// [ChallengeRepository] on Supabase (migration 17, the matches switch).
///
/// - [send] → `send_challenge()`: the database checks the owner, the date
///   (from tomorrow, Asia/Karachi), venue, format, one open challenge per
///   pair of clubs and the 20-pending cap.
/// - [accept] / [decline] → `respond_to_challenge()`: only the receiving
///   club's owner; accepting creates the ONE pending match in the same
///   transaction and returns its id ([Challenge.matchId]). Nothing here
///   creates a match.
/// - Shared availability slots and match seekers (Find Opponent listings)
///   have no server side yet (decision 7): empty, never invented.
class SupabaseChallengeRepository implements ChallengeRepository {
  SupabaseChallengeRepository({required this.db, required this.ownClub});

  final MatchGateway db;
  final OwnClubLookup ownClub;

  @override
  Future<List<Challenge>> challenges() => guardMatchCall(() async {
    final clubId = await ownClub.clubId();
    if (clubId == null) return const <Challenge>[];
    return [
      for (final r in await db.clubChallenges(clubId))
        MatchRowMapper.challengeFromListRow(r),
    ];
  });

  /// The directory's clubs (other clubs, public fields only), for an owner.
  @override
  Future<List<String>> challengeableClubIds() => guardMatchCall(() async {
    if (await ownClub.clubId() == null) return const <String>[];
    return [
      for (final r in await db.clubDirectory())
        MatchRowMapper.directoryEntry(r).id,
    ];
  });

  @override
  Future<List<MatchSeekerListing>> matchSeekers() async => const [];

  @override
  Future<Challenge> send({
    required String opponentClubId,
    MatchFormat? format,
    String? groundName,
    DateTime? proposedAt,
    required DateTime at,
    int? customOvers,
    String? message,
  }) {
    final venue = groundName?.trim() ?? '';
    if (format == null) {
      return Future.error(const MatchRuleException('Choose a match format.'));
    }
    if (proposedAt == null) {
      return Future.error(const MatchRuleException('Choose a match date.'));
    }
    if (venue.isEmpty) {
      return Future.error(const MatchRuleException('Enter a venue.'));
    }
    final note = message?.trim();
    return guardMatchCall(() async {
      final clubId = await ownClub.requireClubId();
      final row = await db.sendChallenge(
        MatchRowMapper.sendParams(
          fromClubId: clubId,
          toClubId: opponentClubId,
          format: format,
          proposedAt: proposedAt,
          venueName: venue,
          customOvers: customOvers,
          message: note == null || note.isEmpty ? null : note,
        ),
      );
      return MatchRowMapper.challengeFromTableRow(row, ownClubId: clubId);
    });
  }

  /// The server records decisions only through [accept] / [decline].
  @override
  Future<Challenge> save(Challenge challenge) async =>
      throw const ModuleUnavailableException();

  @override
  Future<Challenge> accept(String challengeId, {required DateTime at}) =>
      _respond(challengeId, accept: true);

  @override
  Future<Challenge> decline(String challengeId, {required DateTime at}) =>
      _respond(challengeId, accept: false);

  Future<Challenge> _respond(String challengeId, {required bool accept}) =>
      guardMatchCall(() async {
        final clubId = await ownClub.requireClubId();
        final row = await db.respondToChallenge(challengeId, accept: accept);
        return MatchRowMapper.challengeFromTableRow(row, ownClubId: clubId);
      });

  @override
  Future<List<AvailabilitySlot>> availabilitySlots() async => const [];

  @override
  Future<AvailabilitySlot> postAvailabilitySlot(AvailabilitySlot slot) async =>
      throw const ModuleUnavailableException();

  @override
  Future<void> removeAvailabilitySlot(String slotId) async {}
}
