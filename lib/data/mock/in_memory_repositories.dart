import 'dart:math';

import 'package:clock/clock.dart';

import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../../demo/seed_data.dart';
import '../repositories/repositories.dart';

int _seq = 0;
String _id(String prefix) => '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

class _PendingReset {
  _PendingReset({required this.accountId, required this.code, required this.expiresAt});
  final String accountId;
  final String code;
  final DateTime expiresAt;
  int attempts = 0;
}

/// An email sign-up waiting for its code (AUTH-02, [InMemoryAccountRepository.requireEmailCode]).
class _PendingSignUp {
  _PendingSignUp({required this.account, required this.password, required this.code, required this.sentAt});
  final UserAccount account;
  final String password;
  String code;
  DateTime sentAt;
  int attempts = 0;
}

/// Session-lifetime in-memory "backend" seeded from the prototype.
///
/// [requireEmailCode] (the email-codes switch, AUTH-02): an email sign-up
/// is only created once its 6-digit code is verified — shown on screen
/// ([EmailConfirmationRequiredException.demoCode]), nothing is sent. Phone
/// sign-ups are unchanged. [clock] dates the codes.
class InMemoryAccountRepository implements AccountRepository {
  InMemoryAccountRepository(SeedData seed, {this.requireEmailCode = false, this.clock = const Clock()})
      : _accounts = {seed.account.id: seed.account};
  final Map<String, UserAccount> _accounts;
  final bool requireEmailCode;
  final Clock clock;

  /// A sign-up code is valid for 15 minutes (the approved 900 s), can be
  /// tried [signUpCodeMaxAttempts] times, works once and is replaced by a
  /// resend — no sooner than [signUpCodeResendInterval] after the last one.
  static const signUpCodeLifetime = Duration(seconds: 900);
  static const signUpCodeMaxAttempts = 5;
  static const signUpCodeResendInterval = Duration(seconds: 60);

  /// Pending email sign-ups by lower-case email.
  final Map<String, _PendingSignUp> _pendingSignUps = {};

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

  /// The demo: the account is gone for this app run (sign-in then fails until
  /// the app restarts with its seed data). The password must be the one used
  /// to sign in, as on the server.
  @override
  Future<void> deleteAccount(String accountId, {required String password}) async {
    final account = _accounts[accountId];
    if (account == null) throw const NotSignedInException();
    // Approved policy: a club owner transfers the club first.
    if (account.hasClubOwnerProfile) throw const ClubOwnershipTransferRequiredException();
    final known = _passwords[accountId];
    if (password.isEmpty || (known != null && known != password)) throw const WrongPasswordException();
    _accounts.remove(accountId);
    _passwords.remove(accountId);
    _changed.remove(accountId);
  }

  // ---- Forgot password ----

  static const resetCodeLifetime = Duration(minutes: 10);
  static const resetMaxAttempts = 5;

  /// Pending resets by canonical identifier (03XXXXXXXXX / lower-case email).
  final Map<String, _PendingReset> _resets = {};
  final _random = Random.secure();

  static String? _canonical(String identifier) {
    final v = identifier.trim();
    if (v.contains('@')) return v.toLowerCase();
    return CeValidators.normalizePkPhone(v);
  }

  UserAccount? _accountFor(String key) => _accounts.values.where((a) {
        final phone = a.phone == null ? null : CeValidators.normalizePkPhone(a.phone!);
        return phone == key || a.email?.trim().toLowerCase() == key;
      }).firstOrNull;

  static String _mask(String key) => key.contains('@')
      ? '${key[0]}•••${key.substring(key.indexOf('@'))}'
      : '${key.substring(0, 4)} ••••• ${key.substring(key.length - 2)}';

  @override
  Future<PasswordResetTicket?> requestPasswordReset(String identifier, {required DateTime at}) async {
    final key = _canonical(identifier);
    final account = key == null ? null : _accountFor(key);
    if (account == null) return null;
    // A new request replaces the previous code (and its attempt count).
    final code = (100000 + _random.nextInt(900000)).toString();
    final expiresAt = at.add(resetCodeLifetime);
    _resets[key!] = _PendingReset(accountId: account.id, code: code, expiresAt: expiresAt);
    return PasswordResetTicket(destination: _mask(key), expiresAt: expiresAt, demoCode: code);
  }

  ResetCodeCheck _check(String identifier, String code, DateTime at) {
    final key = _canonical(identifier);
    final reset = key == null ? null : _resets[key];
    if (reset == null) return ResetCodeCheck.noRequest;
    if (!at.isBefore(reset.expiresAt)) return ResetCodeCheck.expired;
    if (reset.attempts >= resetMaxAttempts) return ResetCodeCheck.tooManyAttempts;
    if (code.trim() != reset.code) {
      reset.attempts++;
      return reset.attempts >= resetMaxAttempts ? ResetCodeCheck.tooManyAttempts : ResetCodeCheck.wrong;
    }
    return ResetCodeCheck.ok;
  }

  @override
  Future<ResetCodeCheck> verifyResetCode(String identifier, String code, {required DateTime at}) async =>
      _check(identifier, code, at);

  @override
  Future<ResetCodeCheck> resetPassword(String identifier, String code, String newPassword,
      {required DateTime at}) async {
    final check = _check(identifier, code, at);
    if (check != ResetCodeCheck.ok) return check;
    final reset = _resets.remove(_canonical(identifier))!;
    final id = reset.accountId;
    // From now on sign-in needs the new password (as after a Settings change).
    _passwords[id] = newPassword;
    _changed.add(id);
    final a = _accounts[id]!;
    _accounts[id] = a.copyWith(settings: a.settings.copyWith(passwordChangedAt: at));
    return ResetCodeCheck.ok;
  }

  @override
  Future<UserAccount> signUp({
    required String fullName,
    required ContactMethod method,
    required String identifier,
    required String password,
  }) async {
    final base = _accounts[SeedData.ownAccountId]!;
    // A brand-new account (the mock reuses the demo id so every screen has
    // data): no profile, no role set up yet — onboarding starts from scratch.
    final account = UserAccount(
      id: base.id,
      fullName: fullName.trim(),
      contactMethod: method,
      phone: method == ContactMethod.phone ? identifier : null,
      email: method == ContactMethod.email ? identifier : null,
      city: base.city,
    );
    if (requireEmailCode && method == ContactMethod.email) {
      final key = identifier.trim().toLowerCase();
      final pending = _pendingSignUps[key] =
          _PendingSignUp(account: account, password: password, code: _newCode(), sentAt: clock.now());
      throw EmailConfirmationRequiredException(demoCode: pending.code);
    }
    _passwords[account.id] = password;
    return _accounts[account.id] = account;
  }

  String _newCode() => (100000 + _random.nextInt(900000)).toString();

  @override
  Future<UserAccount> verifySignUpCode(String email, String code, {required DateTime at}) async {
    final key = email.trim().toLowerCase();
    final pending = _pendingSignUps[key];
    // No sign-up waiting (none, or already verified: a code works once),
    // expired, or used up by wrong attempts — one answer for all.
    if (pending == null ||
        !at.isBefore(pending.sentAt.add(signUpCodeLifetime)) ||
        pending.attempts >= signUpCodeMaxAttempts) {
      throw const InvalidVerificationCodeException();
    }
    if (code.trim() != pending.code) {
      pending.attempts++;
      throw const InvalidVerificationCodeException();
    }
    _pendingSignUps.remove(key);
    _passwords[pending.account.id] = pending.password;
    return _accounts[pending.account.id] = pending.account;
  }

  @override
  Future<SignUpCodeTicket> resendSignUpCode(String email, {required DateTime at}) async {
    final key = email.trim().toLowerCase();
    final pending = _pendingSignUps[key];
    final destination = SignUpCodeTicket.maskEmail(key);
    // No sign-up waiting: the same answer, and no code (nothing to verify).
    if (pending == null) return SignUpCodeTicket(destination: destination);
    if (at.isBefore(pending.sentAt.add(signUpCodeResendInterval))) throw const TooManyRequestsException();
    pending
      ..code = _newCode()
      ..sentAt = at
      ..attempts = 0;
    return SignUpCodeTicket(destination: destination, demoCode: pending.code);
  }

  @override
  Future<UserAccount?> byId(String accountId) async => _accounts[accountId];

  @override
  Future<UserAccount> update(UserAccount account) async => _accounts[account.id] = account;

  @override
  Future<UserAccount> saveProfileSetup(UserAccount account, {required DateTime at}) async {
    ProfileRules.checkProfileSetup(account, at);
    return _accounts[account.id] = account.copyWith(profileComplete: true);
  }

  @override
  Future<UserAccount> savePlayerProfile(String accountId, PlayerProfile profile) async {
    ProfileRules.checkPlayerProfile(profile);
    final account = _accounts[accountId];
    if (account == null) throw StateError('Account $accountId not found');
    return _accounts[accountId] = account.copyWith(playerProfile: profile);
  }

  /// No backend session in memory mode.
  @override
  Future<void> signOut() async {}

  // ---- AUTH-04 / AUTH-05: no backend sessions in the demo ----
  // The demo's reset stays in the Forgot Password sheet (code → new
  // password), and its Google sign-in signs in at once.

  @override
  bool get passwordRecoveryActive => false;

  @override
  Future<void> completePasswordRecovery(String newPassword, {required DateTime at}) async =>
      throw const RecoverySessionMissingException();

  @override
  Future<void> cancelPasswordRecovery() async {}

  @override
  Future<bool> startGoogleSignIn() async => false;

  @override
  Future<AccountAuthEvent?> sessionAtStart({required bool remembered}) async => null;

  @override
  Stream<AccountAuthEvent> get authEvents => const Stream.empty();
}

class InMemoryClubRepository implements ClubRepository {
  InMemoryClubRepository(SeedData seed)
      : _seedClub = seed.ownClub,
        _clubs = Map.of(seed.clubs),
        _members = {SeedData.ownClubId: [...seed.members]},
        _requests = {SeedData.ownClubId: [...seed.joinRequests]},
        _pool = {SeedData.ownClubId: [...seed.squad]},
        _activity = {SeedData.ownClubId: Map.of(seed.memberActivity)};

  final Club _seedClub;
  final Map<String, Club> _owned = {};
  final Map<String, ClubSummary> _clubs;
  final Map<String, List<ClubMember>> _members;
  final Map<String, List<JoinRequest>> _requests;
  final Map<String, List<SquadPlayer>> _pool;
  final Map<String, Map<String, List<MatchLogEntry>>> _activity;

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
  Future<Club> updateClub(String accountId, Club club) async => _owned[accountId] = club;

  @override
  Future<List<ClubSummary>> otherClubs() async => _clubs.values.toList();

  @override
  Future<ClubSummary?> clubSummary(String clubId) async => _clubs[clubId];

  @override
  Future<List<ClubMember>> members(String clubId) async => [...?_members[clubId]];

  @override
  Future<ClubMember> addMember(
    String clubId, {
    required String name,
    required String phone,
    required MemberRole role,
    PlayerRole? playingRole,
    BattingStyle? battingStyle,
    BowlingStyle? bowlingStyle,
    DateTime? joinedAt,
  }) async {
    final m = ClubMember(
      id: _id('mem'),
      name: name,
      phone: phone,
      role: role,
      playingRole: playingRole,
      battingStyle: battingStyle,
      bowlingStyle: bowlingStyle,
      joinedAt: joinedAt,
    );
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
    String? reason,
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
        : current.decided(JoinRequestReview.declined, at: at, reason: reason);
    list[i] = decided;
    if (approve) {
      // Approved as a Player: the applicant's cricket profile comes along.
      final player = role == MemberRole.player;
      await addMember(
        clubId,
        name: current.name,
        phone: current.phone,
        role: role,
        playingRole: player ? current.role : null,
        battingStyle: player ? current.battingStyle : null,
        bowlingStyle: player ? current.bowlingStyle : null,
        joinedAt: at, // approval date = join date (Member Growth)
      );
    }
    return decided;
  }

  @override
  Future<List<SquadPlayer>> playerPool(String clubId) async => [...?_pool[clubId]];

  @override
  Future<Map<String, List<MatchLogEntry>>> memberActivity(String clubId) async => {...?_activity[clubId]};

  @override
  Future<ClubCodePreview?> findClubByCode(String code) async {
    final upper = code.trim().toUpperCase();
    // The demo club players join (shown on the Player Dashboard as
    // "Club KRC001 • Islamabad"); its type and size aren't in the data.
    if (upper == SeedData.demoJoinCode) {
      return const ClubCodePreview(code: SeedData.demoJoinCode, name: SeedData.demoJoinClubName, city: 'Islamabad');
    }
    final owned = [_seedClub, ..._owned.values];
    final club = owned.where((c) => c.code.toUpperCase() == upper).firstOrNull;
    if (club == null) return null;
    return ClubCodePreview(
      code: club.code,
      name: club.name,
      city: club.city,
      type: club.type,
      memberCount: _members[club.id]?.length,
    );
  }

  @override
  Future<ClubJoinRequest> requestToJoin(String code) async {
    final upper = code.trim().toUpperCase();
    final name = upper == SeedData.demoJoinCode ? SeedData.demoJoinClubName : 'Club $upper';
    return _outgoing = ClubJoinRequest(clubCode: upper, clubName: name);
  }

  /// The demo's outgoing request (this run only; approval is simulated).
  ClubJoinRequest? _outgoing;

  @override
  Future<ClubJoinRequest?> myJoinRequest() async => _outgoing;

  @override
  Future<ClubJoinRequest> cancelJoinRequest(ClubJoinRequest request) async {
    _outgoing = null;
    return request.copyWith(status: JoinRequestStatus.cancelled);
  }

  /// Demo memberships live on the session's account (this run only).
  @override
  Future<List<ClubMembership>> myMemberships() async => const [];

  @override
  Future<void> removeMember(String clubId, String memberId) async {
    final list = _members[clubId];
    if (list == null) return;
    final i = list.indexWhere((m) => m.id == memberId);
    if (i == -1) return;
    if (list[i].role == MemberRole.owner) {
      throw ArgumentError.value(memberId, 'memberId', 'The club owner can’t be removed');
    }
    final removed = list.removeAt(i);
    if (removed.poolPlayerId case final poolId?) _pool[clubId]?.removeWhere((p) => p.id == poolId);
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

  @override
  Future<void> archive(String teamId) async => _teams.removeWhere((t) => t.id == teamId);
}

/// Supabase builds without the memberships switch: teams have no backend,
/// so nothing is listed and nothing can be created (no session-only teams
/// that would vanish on restart).
class UnavailableTeamRepository implements TeamRepository {
  const UnavailableTeamRepository();

  @override
  Future<List<Team>> teams(String clubId) async => const [];

  @override
  Future<Team> create({required String clubId, required String name, required MatchFormat format, int? customOvers}) async =>
      throw const ModuleUnavailableException();

  @override
  Future<Team> save(Team team) async => throw const ModuleUnavailableException();

  @override
  Future<void> archive(String teamId) async => throw const ModuleUnavailableException();
}

class InMemoryMatchRepository implements MatchRepository {
  InMemoryMatchRepository(SeedData seed)
      : _club = [...seed.clubMatches],
        _player = [...seed.playerMatches],
        _scorecards = seed.scorecards,
        _performance = seed.performance;

  /// Supabase builds: no backend for matches yet — nothing seeded, nothing
  /// invented (see docs/PRODUCTION_DEMO_MODE.md).
  InMemoryMatchRepository.empty()
      : _club = [],
        _player = [],
        _scorecards = const {},
        _performance = PerformanceSummary.empty;

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

  /// Supabase builds: no grounds backend yet — no grounds listed.
  InMemoryGroundRepository.empty() : _grounds = const [];
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

  /// Supabase builds: no reservations backend yet — no holds.
  InMemoryReservationRepository.empty() : _holds = [];
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
  /// Demo: the prototype's starting balance.
  InMemoryWalletRepository() : _club = SeedData.walletStartingBalance;

  /// Supabase builds: no payments backend yet — a zero balance, no ledger
  /// (never a made-up amount of money).
  InMemoryWalletRepository.empty() : _club = 0;

  int _club;
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

  /// Supabase builds: no challenges backend yet — nothing listed.
  InMemoryChallengeRepository.empty()
      : _challenges = [],
        _clubIds = const [],
        _seekers = const [];

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
  Future<Challenge> send({
    required String opponentClubId,
    MatchFormat? format,
    String? groundName,
    DateTime? proposedAt,
    required DateTime at,
  }) async {
    final c = Challenge(
      id: _id('ch'),
      opponentClubId: opponentClubId,
      direction: ChallengeDirection.sent,
      status: ChallengeStatus.pending,
      createdAt: at,
      format: format,
      groundName: groundName,
      proposedAt: proposedAt,
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

  /// Supabase builds: no player-hunt backend yet — nothing listed.
  InMemoryHuntRepository.empty()
      : _posts = [],
        _open = [];

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

  /// Supabase builds: no tournaments backend yet — nothing listed.
  InMemoryTournamentRepository.empty() : _tournaments = [];
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
  InMemoryNotificationRepository(SeedData seed) : _items = [...seed.notifications];

  /// Supabase builds: no notifications backend yet — none listed.
  InMemoryNotificationRepository.empty() : _items = [];
  final List<NotificationItem> _items;

  @override
  Future<List<NotificationItem>> forRole(UserRole role) async => _items.where((n) => n.role == role).toList();

  @override
  Future<void> deliver(List<NotificationItem> items) async => _items.addAll(items);
}

class InMemoryAnnouncementRepository implements AnnouncementRepository {
  final Map<String, ClubAnnouncement> _items = {};

  @override
  Future<ClubAnnouncement> publish(ClubAnnouncement announcement) async => _items[announcement.id] = announcement;

  @override
  Future<ClubAnnouncement?> byId(String id) async => _items[id];
}

/// Generates a unique id for new client-side entities.
String newEntityId(String prefix) => _id(prefix);
