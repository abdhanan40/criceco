import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'hunt_row_mapper.dart';
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart' show OwnClubLookup, guardMatchCall;

/// [HuntRepository] on Supabase (migration 33, the Player Hunt switch).
///
/// Every call is a database function that identifies the caller by
/// `auth.uid()`; owner checks, consent (public profile, shared stats and
/// phone) and the daily limits are the server's. This class maps rows and
/// errors only (`hunt: …` refusals → [HuntRuleException]).
///
/// - [posts]: every club's open, unexpired posts (the owner's own included,
///   flagged), as Playing Opportunities lists them.
/// - [openPlayers]: Available Players — for club owners only; anyone else
///   gets none (no call refused for them).
/// - Accepting an invite never joins the club (docs/M8_PLAYER_HUNT.md).
class SupabaseHuntRepository implements HuntRepository {
  SupabaseHuntRepository({required this.db, required this.ownClub});

  final HuntGateway db;
  final OwnClubLookup ownClub;

  /// clubId → players with a standing invite (pending, accepted, or
  /// declined lately: the server refuses another), from the last
  /// [openPlayers] / [invite].
  final Map<String, Set<String>> _invited = {};

  @override
  Future<List<PlayerHuntPost>> posts() => guardMatchCall(
    () async => [for (final r in await db.openPosts()) HuntRowMapper.post(r)],
  );

  @override
  Future<List<PlayerHuntPost>> clubPosts(String clubId) => guardMatchCall(
    () async => [
      for (final r in await db.clubPosts(clubId)) HuntRowMapper.post(r),
    ],
  );

  @override
  Future<PlayerHuntPost> publish(PlayerHuntPost post) => guardMatchCall(
    () async => HuntRowMapper.post(
      await db.publishPost(HuntRowMapper.publishParams(post.clubId, post)),
    ),
  );

  @override
  Future<void> remove(String postId) =>
      guardMatchCall(() => db.closePost(postId));

  @override
  Future<List<OpenPlayer>> openPlayers() => guardMatchCall(() async {
    final clubId = await ownClub.clubId();
    if (clubId == null) return const <OpenPlayer>[];
    final players = [
      for (final r in await db.openPlayers()) HuntRowMapper.openPlayer(r),
    ];
    _invited[clubId] = {
      for (final p in players)
        if (p.inviteStatus != null &&
            p.inviteStatus != HuntInviteStatus.expired)
          p.id,
    };
    return players;
  });

  /// The signed-in player's own listing: [me]'s role and city are sent so a
  /// changed profile or city is what clubs see (the server derives them when
  /// none is known).
  @override
  Future<void> setListed(OpenPlayer me, {required bool listed}) =>
      guardMatchCall(() async {
        final city = me.city.trim();
        await db.setListing(
          listed: listed,
          role: listed ? HuntRowMapper.roleCode(me.role) : null,
          city: listed && city.isNotEmpty ? city : null,
        );
      });

  @override
  Future<HuntListing?> myListing() =>
      guardMatchCall(() async => HuntRowMapper.listing(await db.myListing()));

  @override
  Set<String> invitedPlayerIds(String clubId) => {...?_invited[clubId]};

  @override
  Future<void> invite(String clubId, String playerId) =>
      guardMatchCall(() async {
        await db.invitePlayer(clubId: clubId, userId: playerId);
        (_invited[clubId] ??= <String>{}).add(playerId);
      });

  @override
  Future<void> expressInterest(String postId) =>
      guardMatchCall(() => db.expressInterest(postId));

  @override
  Future<void> withdrawInterest(String postId) =>
      guardMatchCall(() => db.withdrawInterest(postId));

  @override
  Future<List<HuntInterest>> clubInterests(String clubId) => guardMatchCall(
    () async => [
      for (final r in await db.clubInterests(clubId)) HuntRowMapper.interest(r),
    ],
  );

  @override
  Future<List<ClubHuntInvite>> clubInvites(String clubId) => guardMatchCall(
    () async => [
      for (final r in await db.clubInvites(clubId)) HuntRowMapper.clubInvite(r),
    ],
  );

  @override
  Future<List<PlayerHuntInvite>> myInvites() => guardMatchCall(
    () async => [
      for (final r in await db.myInvites()) HuntRowMapper.playerInvite(r),
    ],
  );

  @override
  Future<HuntInviteStatus> respondInvite(
    String inviteId, {
    required bool accept,
  }) => guardMatchCall(
    () async => HuntRowMapper.invite(
      (await db.respondInvite(inviteId, accept: accept))['status'],
    ),
  );
}
