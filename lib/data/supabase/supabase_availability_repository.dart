import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'match_row_mapper.dart';
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart';

/// [PlayerAvailabilityRepository] on Supabase (migration 19, the matches
/// switch). The functions take the person from the session (`auth.uid()`):
/// no call here can name another user. Owners read their club's active
/// members only; the database refuses everyone else.
class SupabaseAvailabilityRepository implements PlayerAvailabilityRepository {
  SupabaseAvailabilityRepository({required this.db});

  final MatchGateway db;

  @override
  Future<PlayerAvailabilityRecord?> mine() => guardMatchCall(() async {
    final row = await db.myAvailability();
    return row == null ? null : MatchRowMapper.availabilityFromRow(row);
  });

  @override
  Future<PlayerAvailabilityRecord> setMine(PlayerAvailabilityRecord record) =>
      guardMatchCall(() async {
        final row = await db.setMyAvailability(
          MatchRowMapper.availabilityParams(record),
        );
        return MatchRowMapper.availabilityFromRow(row);
      });

  @override
  Future<List<ClubMemberAvailability>> clubAvailability(String clubId) =>
      guardMatchCall(
        () async => [
          for (final r in await db.clubAvailability(clubId))
            MatchRowMapper.memberAvailabilityFromRow(r),
        ],
      );
}
