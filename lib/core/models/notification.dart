import '../enums/enums.dart';

/// Where a notification leads — a typed entity reference, never a raw
/// location string. The notifications feature maps it to a route inside the
/// notification's own role (a Player item never opens a Club Owner screen).
sealed class NotificationTarget {
  const NotificationTarget();
}

// ---- Player ----
class PlayerMatchTarget extends NotificationTarget {
  const PlayerMatchTarget(this.matchId);
  final String matchId;
}

class PlayerProfileTarget extends NotificationTarget {
  const PlayerProfileTarget();
}

class AvailabilityTarget extends NotificationTarget {
  const AvailabilityTarget();
}

// ---- Club Owner ----
class JoinRequestTarget extends NotificationTarget {
  const JoinRequestTarget(this.requestId);
  final String requestId;
}

class MyChallengesTarget extends NotificationTarget {
  const MyChallengesTarget();
}

class ClubMatchesTarget extends NotificationTarget {
  const ClubMatchesTarget(this.tab);
  final MatchTab tab;
}

class MyRegistrationsTarget extends NotificationTarget {
  const MyRegistrationsTarget(this.status);
  final RegistrationStatus status;
}

class RegistrationTarget extends NotificationTarget {
  const RegistrationTarget(this.registrationId);
  final String registrationId;
}

class TournamentRequestTarget extends NotificationTarget {
  const TournamentRequestTarget(this.tournamentId, this.registrationId);
  final String tournamentId;
  final String registrationId;
}

/// One inbox row. [target] `null` = non-navigating (approved default P16).
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.role,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.createdAt,
    required this.tone,
    this.target,
  });
  final String id;
  final UserRole role;
  final String icon; // icon key, mapped by CeIcons
  final String title;
  final String subtitle;
  final DateTime createdAt;
  final NotificationTone tone;
  final NotificationTarget? target;
}
