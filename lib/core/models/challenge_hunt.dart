import '../enums/enums.dart';
import 'match_booking.dart';

/// A challenge between the owner's club and another club. Fully modelled so a
/// backend can drive pending → accepted / declined / expired. In Demo Mode a
/// sent challenge is accepted instantly (approved flow).
class Challenge {
  const Challenge({
    required this.id,
    required this.opponentClubId,
    required this.direction,
    required this.status,
    required this.createdAt,
    this.format,
    this.proposedAt,
    this.groundName,
    this.isNew = false,
    this.matchId,
    this.expiresAt,
    this.respondedAt,
  });

  /// How long a sent challenge waits for a reply before it expires (no
  /// response window exists in the prototype; 7 days is the default here).
  static const responseWindow = Duration(days: 7);

  final String id;
  final String opponentClubId;
  final ChallengeDirection direction;
  final ChallengeStatus status;
  final DateTime createdAt;
  final MatchFormat? format;
  final DateTime? proposedAt;
  final String? groundName;
  final bool isNew;

  /// Pending club match created on acceptance (at most one — no duplicates).
  final String? matchId;

  /// A pending challenge becomes expired after this instant (sent: response
  /// window) or once the proposed match time has passed (received).
  final DateTime? expiresAt;
  final DateTime? respondedAt;

  bool get isPending => status == ChallengeStatus.pending;

  /// The status as of [now]: a pending challenge past its deadline is expired.
  ChallengeStatus statusAt(DateTime now) {
    if (status != ChallengeStatus.pending) return status;
    final deadline = expiresAt ?? proposedAt;
    return deadline != null && !now.isBefore(deadline) ? ChallengeStatus.expired : status;
  }

  Challenge copyWith({ChallengeStatus? status, String? matchId, bool? isNew, DateTime? respondedAt}) => Challenge(
        id: id,
        opponentClubId: opponentClubId,
        direction: direction,
        status: status ?? this.status,
        createdAt: createdAt,
        format: format,
        proposedAt: proposedAt,
        groundName: groundName,
        isNew: isNew ?? this.isNew,
        matchId: matchId ?? this.matchId,
        expiresAt: expiresAt,
        respondedAt: respondedAt ?? this.respondedAt,
      );
}

/// A club's posted open date (Create Availability Slot).
class AvailabilitySlot {
  const AvailabilitySlot({
    required this.id,
    required this.format,
    required this.city,
    required this.date,
    required this.slot,
    this.customOvers,
    this.groundId,
    this.notes = '',
  });
  final String id;
  final MatchFormat format;
  final int? customOvers;
  final String city;
  final String? groundId;
  final DateTime date;
  final TimeSlot slot;
  final String notes;
}

/// "Teams Looking for Opponents" entry on Find Match.
class MatchSeekerListing {
  const MatchSeekerListing({
    required this.clubId,
    required this.rating,
    required this.format,
    required this.startsAt,
    required this.venue,
  });
  final String clubId;
  final String rating;
  final MatchFormat format;
  final DateTime startsAt;
  final String venue;
}

/// A club's player requirement (Player Hunt → Find Players; Player → Open Matches).
class PlayerHuntPost {
  const PlayerHuntPost({
    required this.id,
    required this.clubId,
    required this.clubName,
    required this.clubAbbr,
    required this.role,
    required this.format,
    required this.playersNeeded,
    this.location,
    this.date,
    this.time,
    this.budget = HuntBudget.any,
    this.notes = '',
  });

  static const minPlayers = 1;
  static const maxPlayers = 11;

  final String id;
  final String clubId;
  final String clubName;
  final String clubAbbr;
  final HuntRole role;
  final MatchFormat format;
  final int playersNeeded;
  final String? location;
  final DateTime? date;
  final String? time; // "14:00"
  final HuntBudget budget;
  final String notes;
}

/// A free-agent player listed as available (Player Hunt → Available Players).
class OpenPlayer {
  const OpenPlayer({
    required this.id,
    required this.name,
    required this.role,
    required this.availabilityLabel,
    required this.city,
    this.isMe = false,
  });
  final String id;
  final String name;
  final HuntRole role;
  final String availabilityLabel; // "Available Now"
  final String city;
  final bool isMe;
}
