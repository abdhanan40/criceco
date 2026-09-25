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
  });

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

  Challenge copyWith({ChallengeStatus? status, String? matchId, bool? isNew}) => Challenge(
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
