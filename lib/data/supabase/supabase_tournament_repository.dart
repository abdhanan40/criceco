import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart' show OwnClubLookup, guardMatchCall;
import 'tournament_row_mapper.dart';

/// [TournamentRepository] and [TournamentBackend] on Supabase (migration 35,
/// the tournaments switch).
///
/// Every call is a database function that identifies the caller by
/// `auth.uid()`; ownership, the form rules, capacity, the squad rules
/// (exactly 11 + 4), availability and the limits are the server's. This
/// class maps rows and errors only (`tournament: …` refusals →
/// [TournamentRuleException]). It never records a result and takes no
/// payment (docs/M10_TOURNAMENTS.md).
class SupabaseTournamentRepository
    implements TournamentRepository, TournamentBackend {
  SupabaseTournamentRepository({required this.db, required this.ownClub});

  final TournamentGateway db;
  final OwnClubLookup ownClub;

  /// The own club's hosted tournaments (newest first), then every other
  /// club's (soonest first). A user without a club only browses.
  @override
  Future<List<Tournament>> tournaments() => guardMatchCall(() async {
    final clubId = await ownClub.clubId();
    final hosted = clubId == null
        ? const <Map<String, dynamic>>[]
        : await db.myHostedTournaments(clubId);
    final others = await db.browseTournaments();
    final seen = <String>{};
    return [
      for (final r in [...hosted, ...others])
        if (TournamentRowMapper.tournament(r) case final t when seen.add(t.id))
          t,
    ];
  });

  /// Publishes [draft] for its organizer club; the server's row (its id,
  /// trimmed fields, status) comes back.
  @override
  Future<Tournament> create(Tournament draft) => guardMatchCall(
    () async => TournamentRowMapper.tournament(
      await db.createTournament(TournamentRowMapper.createParams(draft)),
    ),
  );

  /// The server owns a tournament's state: it changes only through its
  /// functions.
  @override
  Future<Tournament> save(Tournament tournament) => throw UnsupportedError(
    'Server tournaments change only through their functions',
  );

  /// The own club's entries, newest first, every status.
  @override
  Future<List<TournamentRegistration>> registrations() =>
      guardMatchCall(() async {
        final clubId = await ownClub.clubId();
        if (clubId == null) return const <TournamentRegistration>[];
        return [
          for (final r in await db.myRegistrations(clubId))
            TournamentRowMapper.myRegistration(r, clubId),
        ];
      });

  @override
  Future<TournamentRegistration> saveRegistration(
    TournamentRegistration registration,
  ) => throw UnsupportedError(
    'Server entries change only through their functions',
  );

  @override
  Future<List<Tournament>> browse({String? city}) => guardMatchCall(() async {
    final c = city?.trim();
    return [
      for (final r in await db.browseTournaments(
        city: c == null || c.isEmpty ? null : c,
      ))
        TournamentRowMapper.tournament(r),
    ];
  });

  @override
  Future<Tournament> detail(String tournamentId) => guardMatchCall(
    () async =>
        TournamentRowMapper.tournament(await db.tournamentDetail(tournamentId)),
  );

  @override
  Future<TournamentServerStats> hubStats() => guardMatchCall(() async {
    final clubId = await ownClub.clubId();
    if (clubId == null) {
      return (hosted: 0, open: 0, registered: 0, approved: 0, pending: 0);
    }
    return TournamentRowMapper.hubStats(await db.tournamentHubStats(clubId));
  });

  @override
  Future<List<TournamentRegistration>> teams(String tournamentId) =>
      guardMatchCall(
        () async => [
          for (final r in await db.tournamentTeams(tournamentId))
            TournamentRowMapper.entry(r),
        ],
      );

  @override
  Future<Lineup> squad(String registrationId, {required String teamName}) =>
      guardMatchCall(
        () async => TournamentRowMapper.squad(
          await db.registrationSquad(registrationId),
          teamName: teamName,
        ),
      );

  @override
  Future<TournamentRegistration> submit({
    required String tournamentId,
    required String clubId,
    required Lineup lineup,
    required bool agreedToRules,
  }) => guardMatchCall(() async {
    final row = await db.submitRegistration(
      TournamentRowMapper.submitParams(
        tournamentId: tournamentId,
        clubId: clubId,
        lineup: lineup,
        agreedToRules: agreedToRules,
      ),
    );
    return TournamentRowMapper.entry(row).copyWith(lineup: lineup);
  });

  @override
  Future<TournamentRegistration> decide(
    String registrationId, {
    required bool approve,
  }) => guardMatchCall(
    () async => TournamentRowMapper.entry(
      await db.decideRegistration(registrationId, approve: approve),
    ),
  );

  @override
  Future<TournamentRegistration> remove(String registrationId) =>
      guardMatchCall(
        () async =>
            TournamentRowMapper.entry(await db.removeTeam(registrationId)),
      );

  @override
  Future<bool> generateFixtures(String tournamentId) =>
      guardMatchCall(() async {
        final row = await db.generateFixtures(tournamentId);
        return switch (row['outcome']) {
          'generated' => true,
          'already_generated' => false,
          _ => throw const BackendOperationException(),
        };
      });

  @override
  Future<List<FixtureRound>?> fixtures(String tournamentId) => guardMatchCall(
    () async =>
        TournamentRowMapper.fixtures(await db.tournamentFixtures(tournamentId)),
  );

  @override
  Future<Map<String, Standing>> pointsTable(String tournamentId) =>
      guardMatchCall(
        () async =>
            TournamentRowMapper.points(await db.pointsTable(tournamentId)),
      );

  @override
  Future<TournamentAwards?> awards(String tournamentId) => guardMatchCall(
    () async => TournamentRowMapper.awards(await db.awards(tournamentId)),
  );
}
