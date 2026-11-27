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

/// Playing Opportunities: clubs' requirements and my Player Hunt invites
/// (M8: `hunt_invite_received`).
class PlayingOpportunitiesTarget extends NotificationTarget {
  const PlayingOpportunitiesTarget();
}

/// The club ownership offers made to me (M3: `ownership_offered`).
class OwnershipOffersTarget extends NotificationTarget {
  const OwnershipOffersTarget();
}

/// A match's official scorecard, from the player's side (M3: results).
class PlayerScorecardTarget extends NotificationTarget {
  const PlayerScorecardTarget(this.matchId);
  final String matchId;
}

// ---- Club Owner ----
class JoinRequestTarget extends NotificationTarget {
  const JoinRequestTarget(this.requestId);
  final String requestId;
}

/// Find Player (M8): my posts and the interested players, or Available
/// Players with the accepted invites ([availablePlayers]).
class PlayerHuntTarget extends NotificationTarget {
  const PlayerHuntTarget({this.availablePlayers = false});
  final bool availablePlayers;
}

class MyChallengesTarget extends NotificationTarget {
  const MyChallengesTarget();
}

/// My club's ownership transfer screen (M3: an offer was declined).
class ClubOwnershipTarget extends NotificationTarget {
  const ClubOwnershipTarget();
}

/// A match's official result, from the owner's side (M3: results).
class ClubMatchResultTarget extends NotificationTarget {
  const ClubMatchResultTarget(this.matchId);
  final String matchId;
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

// ---- Club members (Player inbox) ----
/// A club announcement: opens its full text in place (no route).
class AnnouncementTarget extends NotificationTarget {
  const AnnouncementTarget(this.announcementId);
  final String announcementId;
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
    this.recipientMemberId,
  });
  final String id;
  final UserRole role;
  final String icon; // icon key, mapped by CeIcons
  final String title;
  final String subtitle;
  final DateTime createdAt;
  final NotificationTone tone;
  final NotificationTarget? target;

  /// Delivered to one club member (e.g. an announcement); `null` = the
  /// account's own inbox item.
  final String? recipientMemberId;
}
