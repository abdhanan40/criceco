import '../enums/enums.dart';

class TeamMember {
  const TeamMember({required this.playerId, required this.selection});
  final String playerId;
  final SelectionRole selection;
}

/// A club team (My Teams). Everything entered at creation is stored
/// (fix: the prototype discarded `format`). Category / captain / vice-captain
/// / status are modelled only — no UI yet (approved P4).
class Team {
  const Team({
    required this.id,
    required this.clubId,
    required this.name,
    required this.format,
    required this.createdAt,
    this.customOvers,
    this.category,
    this.captainId,
    this.viceCaptainId,
    this.status = TeamStatus.active,
    this.members = const [],
  });

  final String id;
  final String clubId;
  final String name;
  final MatchFormat format;
  final int? customOvers;
  final TeamCategory? category;
  final String? captainId;
  final String? viceCaptainId;
  final TeamStatus status;
  final List<TeamMember> members;
  final DateTime createdAt;

  int get playerCount => members.length;
  int get playingCount =>
      members.where((m) => m.selection == SelectionRole.playing).length;
  int get subCount =>
      members.where((m) => m.selection == SelectionRole.sub).length;

  Team copyWith({
    String? name,
    MatchFormat? format,
    int? customOvers,
    TeamCategory? category,
    String? captainId,
    String? viceCaptainId,
    TeamStatus? status,
    List<TeamMember>? members,
  }) =>
      Team(
        id: id,
        clubId: clubId,
        name: name ?? this.name,
        format: format ?? this.format,
        customOvers: customOvers ?? this.customOvers,
        category: category ?? this.category,
        captainId: captainId ?? this.captainId,
        viceCaptainId: viceCaptainId ?? this.viceCaptainId,
        status: status ?? this.status,
        members: members ?? this.members,
        createdAt: createdAt,
      );
}

/// Squad limits shared by Add Players and the Team Builder.
abstract final class SquadRules {
  static const maxPlaying = 11;
  static const maxSubs = 4;
}

/// Where a match-day / tournament line-up is going.
sealed class LineupTarget {
  const LineupTarget();
}

class MatchLineupTarget extends LineupTarget {
  const MatchLineupTarget(this.matchId);
  final String matchId;

  @override
  bool operator ==(Object other) =>
      other is MatchLineupTarget && other.matchId == matchId;
  @override
  int get hashCode => Object.hash('match', matchId);
}

class TournamentEntryTarget extends LineupTarget {
  const TournamentEntryTarget(this.tournamentId);
  final String tournamentId;

  @override
  bool operator ==(Object other) =>
      other is TournamentEntryTarget && other.tournamentId == tournamentId;
  @override
  int get hashCode => Object.hash('tournament', tournamentId);
}

/// A confirmed match-day or tournament line-up. "Create New Team" in the Team
/// Builder does not add to My Teams (prototype parity).
class Lineup {
  const Lineup({
    required this.name,
    required this.members,
    this.sourceTeamId,
  });

  static const newMatchDaySquadName = 'New Match-Day Squad';

  final String name;
  final String? sourceTeamId;
  final List<TeamMember> members;
}
