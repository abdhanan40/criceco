import '../../core/models/models.dart';

/// Repository contracts. Every method is async so an HTTP/Firebase backend can
/// replace the in-memory mocks without touching controllers or screens.

abstract interface class AccountRepository {
  Future<UserAccount?> signIn({required String identifier, required String password});
  Future<UserAccount> signUp({
    required String fullName,
    required ContactMethod method,
    required String identifier,
    required String password,
  });
  Future<UserAccount?> byId(String accountId);
  Future<UserAccount> update(UserAccount account);
}

abstract interface class ClubRepository {
  Future<Club?> ownClub(String accountId);
  Future<Club> createClub({
    required String accountId,
    required String name,
    required String city,
    required ClubType type,
    String? ownerName,
    String? address,
    String? email,
    String? homeGroundId,
    bool hasLogo = false,
  });
  Future<List<ClubSummary>> otherClubs();
  Future<ClubSummary?> clubSummary(String clubId);
  Future<List<ClubMember>> members(String clubId);
  Future<ClubMember> addMember(String clubId, {required String name, required String phone, required MemberRole role});
  Future<List<JoinRequest>> joinRequests(String clubId);
  /// Approve (with a club role) or decline a pending request. Approval adds
  /// a [ClubMember] with that role - a club membership only; it never grants
  /// the account-level Club Owner role. Deciding an already-decided request
  /// returns it unchanged (no duplicate member).
  Future<JoinRequest> decideJoinRequest(
    String clubId,
    String requestId, {
    required bool approve,
    MemberRole role = MemberRole.player,
    required DateTime at,
  });
  Future<List<SquadPlayer>> playerPool(String clubId);

  /// Outgoing join-by-code (membership onboarding).
  Future<ClubJoinRequest> requestToJoin(String code);
}

abstract interface class TeamRepository {
  Future<List<Team>> teams(String clubId);
  Future<Team> create({required String clubId, required String name, required MatchFormat format, int? customOvers});
  Future<Team> save(Team team);
}

abstract interface class MatchRepository {
  Future<List<ClubMatch>> clubMatches();
  Future<ClubMatch> saveClubMatch(ClubMatch match);
  Future<ClubMatch> createPendingMatch({required String opponentClubId, MatchFormat? format, String? city});
  Future<List<PlayerMatch>> playerMatches();
  Future<Scorecard?> scorecard(String scorecardId);
  Future<PerformanceSummary> performance();
}

abstract interface class GroundRepository {
  Future<List<Ground>> grounds();

  /// Mock availability calendar (prototype `dayStatusFor`), keyed by a real date.
  DayAvailability dayAvailability(String groundId, DateTime date);

  /// Slots permanently booked by the venue (prototype `taken: true`).
  bool slotBookedByVenue(String groundId, DateTime date, TimeSlot slot);
}

class SlotTakenException implements Exception {
  const SlotTakenException();
  @override
  String toString() => 'That slot was just taken by another club — pick another time';
}

abstract interface class ReservationRepository {
  List<ReservationHold> get holds;
  bool isSlotTaken({required String groundId, required DateTime slotStart, required DateTime now, String? exceptMatchId});

  /// Atomically checks and inserts (or replaces this match's own hold).
  /// Throws [SlotTakenException] on conflict.
  ReservationHold reserve({
    required String matchId,
    required String groundId,
    required DateTime slotStart,
    required DateTime slotEnd,
    required DateTime now,
  });
  ReservationHold update(ReservationHold hold);
}

abstract interface class WalletRepository {
  int get clubWalletBalance;
  void adjustClubWallet(int delta);
  int get escrowBalance;
  List<LedgerEntry> get ledger;
  void log(LedgerEntry entry, {required int escrowDelta});
}

abstract interface class ChallengeRepository {
  Future<List<Challenge>> challenges();
  Future<List<String>> challengeableClubIds();
  Future<List<MatchSeekerListing>> matchSeekers();
  /// Always creates a PENDING sent challenge (expires after
  /// [Challenge.responseWindow]). Demo Mode may then accept it instantly.
  Future<Challenge> send({required String opponentClubId, MatchFormat? format, required DateTime at});
  Future<Challenge> save(Challenge challenge);
  Future<List<AvailabilitySlot>> availabilitySlots();
  Future<AvailabilitySlot> postAvailabilitySlot(AvailabilitySlot slot);
  Future<void> removeAvailabilitySlot(String slotId);
}

abstract interface class HuntRepository {
  Future<List<PlayerHuntPost>> posts();
  Future<PlayerHuntPost> publish(PlayerHuntPost post);
  Future<void> remove(String postId);
  Future<List<OpenPlayer>> openPlayers();
  Future<void> setListed(OpenPlayer me, {required bool listed});
}

abstract interface class TournamentRepository {
  Future<List<Tournament>> tournaments();
  Future<Tournament> save(Tournament tournament);
  Future<Tournament> create(Tournament draft);
  Future<List<TournamentRegistration>> registrations();
  Future<TournamentRegistration> saveRegistration(TournamentRegistration registration);
}

abstract interface class NotificationRepository {
  Future<List<NotificationItem>> forRole(UserRole role);
}
