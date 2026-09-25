import '../../core/models/models.dart';
import '../../demo/seed_data.dart';
import '../repositories/repositories.dart';

int _seq = 0;
String _id(String prefix) => '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

/// Session-lifetime in-memory "backend" seeded from the prototype.
class InMemoryAccountRepository implements AccountRepository {
  InMemoryAccountRepository(SeedData seed) : _accounts = {seed.account.id: seed.account};
  final Map<String, UserAccount> _accounts;

  /// Last password used or set per account (mock credential store).
  final Map<String, String> _passwords = {};

  /// Accounts whose password was changed in Settings: from then on sign-in
  /// requires that password.
  final Set<String> _changed = {};

  @override
  Future<UserAccount?> signIn({required String identifier, required String password}) async {
    // Prototype parity: any credentials sign in to the demo account — until
    // its password has been changed in Password & security.
    const id = SeedData.ownAccountId;
    if (_changed.contains(id)) return _passwords[id] == password ? _accounts[id] : null;
    if (password.isNotEmpty) _passwords[id] = password;
    return _accounts[id];
  }

  @override
  Future<bool> changePassword(String accountId, {required String current, required String next}) async {
    final known = _passwords[accountId];
    if (known != null && known != current) return false;
    _passwords[accountId] = next;
    _changed.add(accountId);
    return true;
  }

  @override
  Future<UserAccount> signUp({
    required String fullName,
    required ContactMethod method,
    required String identifier,
    required String password,
  }) async {
    final base = _accounts[SeedData.ownAccountId]!;
    final account = base.copyWith(
      fullName: fullName.trim().isEmpty ? base.fullName : fullName.trim(),
      contactMethod: method,
      phone: method == ContactMethod.phone ? identifier : base.phone,
      email: method == ContactMethod.email ? identifier : null,
      onboardingComplete: false,
    );
    _passwords[account.id] = password;
    return _accounts[account.id] = account;
  }

  @override
  Future<UserAccount?> byId(String accountId) async => _accounts[accountId];

  @override
  Future<UserAccount> update(UserAccount account) async => _accounts[account.id] = account;
}

class InMemoryClubRepository implements ClubRepository {
  InMemoryClubRepository(SeedData seed)
      : _seedClub = seed.ownClub,
        _clubs = Map.of(seed.clubs),
        _members = {SeedData.ownClubId: [...seed.members]},
        _requests = {SeedData.ownClubId: [...seed.joinRequests]},
        _pool = {SeedData.ownClubId: [...seed.squad]};

  final Club _seedClub;
  final Map<String, Club> _owned = {};
  final Map<String, ClubSummary> _clubs;
  final Map<String, List<ClubMember>> _members;
  final Map<String, List<JoinRequest>> _requests;
  final Map<String, List<SquadPlayer>> _pool;

  @override
  Future<Club?> ownClub(String accountId) async => _owned[accountId];

  /// Creating a club returns the demo club (seeded members, teams, pool) with
  /// the details the owner entered, so every club-owner screen has data.
  @override
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
  }) async {
    final club = Club(
      id: _seedClub.id,
      name: name,
      city: city,
      type: type,
      code: _seedClub.code,
      shortName: name,
      ownerName: ownerName,
      address: address,
      email: email,
      homeGroundId: homeGroundId,
      hasLogo: hasLogo,
      establishedYear: DateTime.now().year,
    );
    return _owned[accountId] = club;
  }

  @override
  Future<List<ClubSummary>> otherClubs() async => _clubs.values.toList();

  @override
  Future<ClubSummary?> clubSummary(String clubId) async => _clubs[clubId];

  @override
  Future<List<ClubMember>> members(String clubId) async => [...?_members[clubId]];

  @override
  Future<ClubMember> addMember(String clubId, {required String name, required String phone, required MemberRole role}) async {
    final m = ClubMember(id: _id('mem'), name: name, phone: phone, role: role);
    (_members[clubId] ??= []).add(m);
    return m;
  }

  @override
  Future<List<JoinRequest>> joinRequests(String clubId) async => [...?_requests[clubId]];

  @override
  Future<JoinRequest> decideJoinRequest(
    String clubId,
    String requestId, {
    required bool approve,
    MemberRole role = MemberRole.player,
    required DateTime at,
  }) async {
    final list = _requests[clubId] ?? const <JoinRequest>[];
    final i = list.indexWhere((r) => r.id == requestId);
    if (i == -1) throw StateError('Join request $requestId not found');
    final current = list[i];
    if (!current.isPending) return current;
    if (approve && role == MemberRole.owner) {
      throw ArgumentError.value(role, 'role', 'A join request can never grant club ownership');
    }
    final decided = approve
        ? current.decided(JoinRequestReview.approved, role: role, at: at)
        : current.decided(JoinRequestReview.declined, at: at);
    list[i] = decided;
    if (approve) await addMember(clubId, name: current.name, phone: current.phone, role: role);
    return decided;
  }

  @override
  Future<List<SquadPlayer>> playerPool(String clubId) async => [...?_pool[clubId]];

  @override
  Future<ClubJoinRequest> requestToJoin(String code) async {
    final upper = code.trim().toUpperCase();
    final name = upper == SeedData.demoJoinCode ? SeedData.demoJoinClubName : 'Club $upper';
    return ClubJoinRequest(clubCode: upper, clubName: name);
  }
}

class InMemoryTeamRepository implements TeamRepository {
  InMemoryTeamRepository(SeedData seed) : _teams = [...seed.teams];
  final List<Team> _teams;

  @override
  Future<List<Team>> teams(String clubId) async => _teams.where((t) => t.clubId == clubId).toList();

  @override
  Future<Team> create({required String clubId, required String name, required MatchFormat format, int? customOvers}) async {
    final team = Team(
      id: _id('team'),
      clubId: clubId,
      name: name.trim(),
      format: format,
      customOvers: customOvers,
      createdAt: DateTime.now(),
    );
    _teams.add(team);
    return team;
  }

  @override
  Future<Team> save(Team team) async {
    final i = _teams.indexWhere((t) => t.id == team.id);
    if (i == -1) {
      _teams.add(team);
    } else {
      _teams[i] = team;
    }
    return team;
  }
}

class InMemoryMatchRepository implements MatchRepository {
  InMemoryMatchRepository(SeedData seed)
      : _club = [...seed.clubMatches],
        _player = [...seed.playerMatches],
        _scorecards = seed.scorecards,
        _performance = seed.performance;

  final List<ClubMatch> _club;
  final List<PlayerMatch> _player;
  final Map<String, Scorecard> _scorecards;
  final PerformanceSummary _performance;

  @override
  Future<List<ClubMatch>> clubMatches() async => [..._club];

  @override
  Future<ClubMatch> saveClubMatch(ClubMatch match) async {
    final i = _club.indexWhere((m) => m.id == match.id);
    if (i == -1) {
      _club.add(match);
    } else {
      _club[i] = match;
    }
    return match;
  }

  @override
  Future<ClubMatch> createPendingMatch({required String opponentClubId, MatchFormat? format, String? city}) async {
    final m = ClubMatch(id: _id('m'), opponentClubId: opponentClubId, status: MatchStatus.pending, format: format, city: city);
    _club.add(m);
    return m;
  }

  @override
  Future<List<PlayerMatch>> playerMatches() async => [..._player];

  @override
  Future<Scorecard?> scorecard(String scorecardId) async => _scorecards[scorecardId];

  @override
  Future<PerformanceSummary> performance() async => _performance;
}

class InMemoryGroundRepository implements GroundRepository {
  InMemoryGroundRepository(SeedData seed) : _grounds = seed.grounds;
  final List<Ground> _grounds;

  @override
  Future<List<Ground>> grounds() async => _grounds;

  @override
  DayAvailability dayAvailability(String groundId, DateTime date) => switch (date.day % 5) {
        0 => DayAvailability.full,
        1 => DayAvailability.partial,
        _ => DayAvailability.available,
      };

  @override
  bool slotBookedByVenue(String groundId, DateTime date, TimeSlot slot) =>
      slot.startHour == 6 || slot.startHour == 16; // prototype: 6am & 4pm taken
}

class InMemoryReservationRepository implements ReservationRepository {
  InMemoryReservationRepository(SeedData seed) : _holds = [...seed.holds];
  final List<ReservationHold> _holds;

  @override
  List<ReservationHold> get holds => List.unmodifiable(_holds);

  @override
  bool isSlotTaken({required String groundId, required DateTime slotStart, required DateTime now, String? exceptMatchId}) =>
      _holds.any((h) =>
          h.groundId == groundId && h.slotStart == slotStart && h.matchId != exceptMatchId && h.blocksSlot(now));

  @override
  ReservationHold reserve({
    required String matchId,
    required String groundId,
    required DateTime slotStart,
    required DateTime slotEnd,
    required DateTime now,
  }) {
    if (isSlotTaken(groundId: groundId, slotStart: slotStart, now: now, exceptMatchId: matchId)) {
      throw const SlotTakenException();
    }
    // Idempotent per match: release this match's previous active hold.
    for (var i = 0; i < _holds.length; i++) {
      final h = _holds[i];
      if (h.matchId == matchId && h.status == HoldStatus.active) {
        _holds[i] = h.copyWith(status: HoldStatus.released);
      }
    }
    final hold = ReservationHold(
      id: _id('hold'),
      matchId: matchId,
      groundId: groundId,
      slotStart: slotStart,
      slotEnd: slotEnd,
      reservedAt: now,
      expiresAt: now.add(ReservationHold.holdDuration),
    );
    _holds.add(hold);
    return hold;
  }

  @override
  ReservationHold update(ReservationHold hold) {
    final i = _holds.indexWhere((h) => h.id == hold.id);
    if (i != -1) _holds[i] = hold;
    return hold;
  }
}

class InMemoryWalletRepository implements WalletRepository {
  int _club = SeedData.walletStartingBalance;
  int _escrow = 0;
  final List<LedgerEntry> _ledger = [];

  @override
  int get clubWalletBalance => _club;
  @override
  void adjustClubWallet(int delta) => _club += delta;
  @override
  int get escrowBalance => _escrow;
  @override
  List<LedgerEntry> get ledger => List.unmodifiable(_ledger);
  @override
  void log(LedgerEntry entry, {required int escrowDelta}) {
    _ledger.add(entry);
    _escrow += escrowDelta;
  }
}

class InMemoryChallengeRepository implements ChallengeRepository {
  InMemoryChallengeRepository(SeedData seed)
      : _challenges = [...seed.challenges],
        _clubIds = seed.challengeableClubIds,
        _seekers = seed.matchSeekers;

  final List<Challenge> _challenges;
  final List<String> _clubIds;
  final List<MatchSeekerListing> _seekers;
  final List<AvailabilitySlot> _slots = [];

  @override
  Future<List<Challenge>> challenges() async => [..._challenges];
  @override
  Future<List<String>> challengeableClubIds() async => _clubIds;
  @override
  Future<List<MatchSeekerListing>> matchSeekers() async => _seekers;

  @override
  Future<Challenge> send({required String opponentClubId, MatchFormat? format, required DateTime at}) async {
    final c = Challenge(
      id: _id('ch'),
      opponentClubId: opponentClubId,
      direction: ChallengeDirection.sent,
      status: ChallengeStatus.pending,
      createdAt: at,
      format: format,
      expiresAt: at.add(Challenge.responseWindow),
    );
    _challenges.add(c);
    return c;
  }

  @override
  Future<Challenge> save(Challenge challenge) async {
    final i = _challenges.indexWhere((c) => c.id == challenge.id);
    if (i == -1) {
      _challenges.add(challenge);
    } else {
      _challenges[i] = challenge;
    }
    return challenge;
  }

  @override
  Future<List<AvailabilitySlot>> availabilitySlots() async => [..._slots];

  @override
  Future<AvailabilitySlot> postAvailabilitySlot(AvailabilitySlot slot) async {
    _slots.add(slot);
    return slot;
  }

  @override
  Future<void> removeAvailabilitySlot(String slotId) async => _slots.removeWhere((s) => s.id == slotId);
}

class InMemoryHuntRepository implements HuntRepository {
  InMemoryHuntRepository(SeedData seed)
      : _posts = [...seed.huntPosts],
        _open = [...seed.openPlayers];

  final List<PlayerHuntPost> _posts;
  final List<OpenPlayer> _open;

  @override
  Future<List<PlayerHuntPost>> posts() async => [..._posts];

  @override
  Future<PlayerHuntPost> publish(PlayerHuntPost post) async {
    _posts.insert(0, post);
    return post;
  }

  @override
  Future<void> remove(String postId) async => _posts.removeWhere((p) => p.id == postId);

  @override
  Future<List<OpenPlayer>> openPlayers() async => [..._open];

  @override
  Future<void> setListed(OpenPlayer me, {required bool listed}) async {
    _open.removeWhere((p) => p.isMe);
    if (listed) _open.insert(0, me);
  }

  /// clubId → invited player ids (session memory only; nothing is sent).
  final Map<String, Set<String>> _invites = {};

  @override
  Set<String> invitedPlayerIds(String clubId) => {...?_invites[clubId]};

  @override
  Future<void> invite(String clubId, String playerId) async =>
      (_invites[clubId] ??= <String>{}).add(playerId);
}

class InMemoryTournamentRepository implements TournamentRepository {
  InMemoryTournamentRepository(SeedData seed) : _tournaments = [...seed.tournaments];
  final List<Tournament> _tournaments;
  final List<TournamentRegistration> _registrations = [];

  @override
  Future<List<Tournament>> tournaments() async => [..._tournaments];

  @override
  Future<Tournament> save(Tournament tournament) async {
    final i = _tournaments.indexWhere((t) => t.id == tournament.id);
    if (i == -1) {
      _tournaments.add(tournament);
    } else {
      _tournaments[i] = tournament;
    }
    return tournament;
  }

  @override
  Future<Tournament> create(Tournament draft) async {
    _tournaments.add(draft);
    return draft;
  }

  @override
  Future<List<TournamentRegistration>> registrations() async => [..._registrations];

  @override
  Future<TournamentRegistration> saveRegistration(TournamentRegistration registration) async {
    final i = _registrations.indexWhere((r) => r.id == registration.id);
    if (i == -1) {
      _registrations.add(registration);
    } else {
      _registrations[i] = registration;
    }
    return registration;
  }
}

class InMemoryNotificationRepository implements NotificationRepository {
  InMemoryNotificationRepository(SeedData seed) : _items = seed.notifications;
  final List<NotificationItem> _items;

  @override
  Future<List<NotificationItem>> forRole(UserRole role) async => _items.where((n) => n.role == role).toList();
}

/// Generates a unique id for new client-side entities.
String newEntityId(String prefix) => _id(prefix);
