import '../enums/enums.dart';
import 'team.dart';

/// A tournament entry is either a club (seeded tournaments) or a registration
/// of one of the owner's teams. Stored as ids only — no name/abbr mixing.
class TournamentEntrant {
  const TournamentEntrant({required this.id, required this.displayName, this.clubId});
  final String id; // clubId or registrationId
  final String displayName;
  final String? clubId;

  @override
  bool operator ==(Object other) => other is TournamentEntrant && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class FixtureMatch {
  const FixtureMatch({required this.home, required this.away, this.winnerId});

  /// `null` = TBD (winner of a previous round), [bye] = no opponent.
  final String? home;
  final String? away;
  final String? winnerId;

  static const bye = '__BYE__';

  bool get completed => winnerId != null;
  bool get isBye => home == bye || away == bye;
  bool get ready => home != null && away != null && !isBye;

  FixtureMatch copyWith({String? home, String? away, String? winnerId}) => FixtureMatch(
        home: home ?? this.home,
        away: away ?? this.away,
        winnerId: winnerId ?? this.winnerId,
      );
}

class FixtureRound {
  const FixtureRound({required this.name, required this.matches});
  final String name; // Final / Semifinal / Quarterfinal / League Stage
  final List<FixtureMatch> matches;
}

class Standing {
  const Standing({this.played = 0, this.won = 0, this.lost = 0, this.points = 0});
  final int played;
  final int won;
  final int lost;
  final int points;

  static const pointsPerWin = 2;
}

/// Unified tournament model for hosted and browse tournaments.
class Tournament {
  const Tournament({
    required this.id,
    required this.name,
    required this.organizerClubId,
    required this.city,
    required this.ground,
    required this.format,
    required this.type,
    required this.startDate,
    required this.endDate,
    required this.registrationDeadline,
    required this.maxTeams,
    required this.status,
    this.customOvers,
    this.entryFee,
    this.prize,
    this.description = '',
    this.rules = const [],
    this.joined = const [],
    this.pending = const [],
    this.fixtures,
    this.standings = const {},
    this.winnerId,
  });

  static const minTeamsForFixtures = 2;

  final String id;
  final String name;
  final String organizerClubId;
  final String city;
  final String ground;
  final MatchFormat format;
  final int? customOvers;
  final TournamentType type;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime registrationDeadline;
  final int? entryFee;
  final int? prize;
  final int maxTeams;
  final String description;
  final List<String> rules;
  final TournamentStatus status;
  final List<TournamentEntrant> joined;
  final List<TournamentEntrant> pending;
  final List<FixtureRound>? fixtures;
  final Map<String, Standing> standings;
  final String? winnerId;

  int get availableSlots => (maxTeams - joined.length).clamp(0, maxTeams);
  bool get canGenerateFixtures => joined.length >= minTeamsForFixtures;
  bool get isFull => joined.length >= maxTeams;

  /// Status as of [now]: an open tournament whose registration deadline day
  /// has passed is closed (the stored status is not rewritten).
  TournamentStatus statusAt(DateTime now) {
    if (status != TournamentStatus.registrationOpen) return status;
    final today = DateTime(now.year, now.month, now.day);
    final deadline = DateTime(registrationDeadline.year, registrationDeadline.month, registrationDeadline.day);
    return today.isAfter(deadline) ? TournamentStatus.registrationClosed : status;
  }

  /// A club can still submit a registration.
  bool acceptsRegistrationsAt(DateTime now) =>
      statusAt(now) == TournamentStatus.registrationOpen && !isFull && fixtures == null;

  TournamentEntrant? entrant(String id) =>
      joined.where((e) => e.id == id).firstOrNull ?? pending.where((e) => e.id == id).firstOrNull;

  Tournament copyWith({
    TournamentStatus? status,
    List<TournamentEntrant>? joined,
    List<TournamentEntrant>? pending,
    List<FixtureRound>? fixtures,
    Map<String, Standing>? standings,
    String? winnerId,
  }) =>
      Tournament(
        id: id,
        name: name,
        organizerClubId: organizerClubId,
        city: city,
        ground: ground,
        format: format,
        customOvers: customOvers,
        type: type,
        startDate: startDate,
        endDate: endDate,
        registrationDeadline: registrationDeadline,
        entryFee: entryFee,
        prize: prize,
        maxTeams: maxTeams,
        description: description,
        rules: rules,
        status: status ?? this.status,
        joined: joined ?? this.joined,
        pending: pending ?? this.pending,
        fixtures: fixtures ?? this.fixtures,
        standings: standings ?? this.standings,
        winnerId: winnerId ?? this.winnerId,
      );
}

/// One club's entry request for a tournament, keyed by id. Its entrant id in
/// the tournament's pending / joined lists is this registration's [id].
class TournamentRegistration {
  const TournamentRegistration({
    required this.id,
    required this.tournamentId,
    required this.clubId,
    required this.teamName,
    required this.status,
    required this.submittedAt,
    this.teamId,
    this.lineup,
    this.decidedAt,
  });
  final String id;
  final String tournamentId;

  /// The registering club (the owner's own club for My Registrations).
  final String clubId;

  /// Club team the line-up was taken from (`null` for a new squad).
  final String? teamId;
  final String teamName;

  /// Snapshot of the registered squad (`null` for an incoming request whose
  /// squad this app doesn't hold).
  final Lineup? lineup;
  final RegistrationStatus status;
  final DateTime submittedAt;
  final DateTime? decidedAt;

  bool get isPending => status == RegistrationStatus.pending;

  TournamentRegistration copyWith({RegistrationStatus? status, DateTime? decidedAt}) => TournamentRegistration(
        id: id,
        tournamentId: tournamentId,
        clubId: clubId,
        teamId: teamId,
        teamName: teamName,
        lineup: lineup,
        status: status ?? this.status,
        submittedAt: submittedAt,
        decidedAt: decidedAt ?? this.decidedAt,
      );
}

/// One Tournament Dashboard award (prototype `tournamentAwardStats`).
class TournamentAward {
  const TournamentAward({required this.playerName, required this.entrantId, required this.value});
  final String playerName;
  final String entrantId;
  final int value; // runs / wickets / dismissals / catches
}

class TournamentAwards {
  const TournamentAwards({
    required this.topScorer,
    required this.topWicketTaker,
    required this.bestKeeper,
    required this.bestFielder,
  });
  final TournamentAward topScorer;
  final TournamentAward topWicketTaker;
  final TournamentAward bestKeeper;
  final TournamentAward bestFielder;
}

/// Destination of a notification row (a route location, resolved per role).
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.role,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.timeAgo,
    required this.tone,
    this.location,
  });
  final String id;
  final UserRole role;
  final String icon; // icon key, mapped by CeIcons
  final String title;
  final String subtitle;
  final String timeAgo;
  final NotificationTone tone;

  /// `null` = non-navigating (approved default P16).
  final String? location;
}
