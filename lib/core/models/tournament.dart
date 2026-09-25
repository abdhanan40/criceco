import '../enums/enums.dart';

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

class TournamentRegistration {
  const TournamentRegistration({
    required this.id,
    required this.tournamentId,
    required this.teamName,
    required this.status,
    required this.submittedAt,
    this.teamId,
  });
  final String id;
  final String tournamentId;
  final String? teamId;
  final String teamName;
  final RegistrationStatus status;
  final DateTime submittedAt;

  TournamentRegistration copyWith({RegistrationStatus? status}) => TournamentRegistration(
        id: id,
        tournamentId: tournamentId,
        teamId: teamId,
        teamName: teamName,
        status: status ?? this.status,
        submittedAt: submittedAt,
      );
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
