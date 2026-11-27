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
    this.customOvers,
    this.message,
    this.opponentName,
    this.opponentShortName,
    this.opponentCity,
  });

  /// The opponent's public short name and city from the server (`null` in
  /// the demo, and on rows returned by send / respond).
  final String? opponentShortName;
  final String? opponentCity;

  /// Overs for a custom-format challenge (server challenges, migration 17).
  final int? customOvers;

  /// The sender's optional note (≤ 280 characters).
  final String? message;

  /// The opponent's public name from the server (the demo uses the club
  /// directory by [opponentClubId]).
  final String? opponentName;

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
        customOvers: customOvers,
        message: message,
        opponentName: opponentName,
        opponentShortName: opponentShortName,
        opponentCity: opponentCity,
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

/// "Teams Looking for Opponents" entry on Find Opponent.
class MatchSeekerListing {
  const MatchSeekerListing({
    required this.clubId,
    required this.rating,
    required this.format,
    required this.startsAt,
    required this.venue,
    this.slotId,
    this.customOvers,
    this.clubName,
    this.clubShortName,
    this.clubCity,
    this.clubWins = 0,
    this.clubLosses = 0,
    this.notes = '',
  });
  final String clubId;

  /// The demo's sample rating; "—" on the server (no rating is stored).
  final String rating;
  final MatchFormat format;
  final DateTime startsAt;
  final String venue;

  /// The server's open slot behind this listing (migration 32); `null` in
  /// the demo.
  final String? slotId;
  final int? customOvers;

  /// The posting club's public name, city and official record, as the
  /// server sends them with the slot (`null` / 0 in the demo, whose club
  /// profiles carry them).
  final String? clubName;
  final String? clubShortName;
  final String? clubCity;
  final int clubWins;
  final int clubLosses;
  final String notes;
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
    this.clubCity,
    this.isMyClub = false,
    this.interested = false,
    this.interestCount,
    this.isOpen = true,
  });

  static const minPlayers = 1;
  static const maxPlayers = 11;

  /// The posting club's city (server posts, migration 33).
  final String? clubCity;

  /// A post of the signed-in owner's own club.
  final bool isMyClub;

  /// The signed-in player expressed interest in it (server posts).
  final bool interested;

  /// Players interested so far — only on the owner's own club's posts.
  final int? interestCount;

  /// Open (not closed, not past its date).
  final bool isOpen;

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
    this.isMember = false,
    this.inviteStatus,
    this.figures,
    this.photoPath,
  });
  final String id;
  final String name;
  final HuntRole role;
  final String availabilityLabel; // "Available Now"
  final String city;
  final bool isMe;

  /// Already an active member of the owner's club (server, migration 33).
  final bool isMember;

  /// The owner's club's latest invite to this player; `null` = none.
  final HuntInviteStatus? inviteStatus;

  /// The player's official figures — only when they share their stats.
  final HuntPlayerFigures? figures;

  /// The player's stored profile picture (`avatars` object), if any.
  final String? photoPath;
}

/// Where a Player Hunt invite stands (migration 33). An invite waits 14 days.
enum HuntInviteStatus {
  pending('Invited'),
  accepted('Accepted'),
  declined('Declined'),
  expired('Expired');

  const HuntInviteStatus(this.label);
  final String label;
}

/// A player's official career figures as Player Hunt shows them (only when
/// the player shares their stats; migration 22's statistics).
class HuntPlayerFigures {
  const HuntPlayerFigures({
    required this.matches,
    required this.runs,
    required this.wickets,
    this.battingAverage,
    this.strikeRate,
    this.economy,
  });
  final int matches;
  final int runs;
  final int wickets;
  final double? battingAverage;
  final double? strikeRate;
  final double? economy;
}

/// The signed-in player's own listing for other clubs (migration 33).
class HuntListing {
  const HuntListing({required this.listed, required this.visible, this.role, this.city});
  final bool listed;

  /// Listed AND the profile is public: clubs can see the player now.
  final bool visible;
  final HuntRole? role;
  final String? city;
}

/// A player who tapped "I'm Interested" on one of the owner's posts.
class HuntInterest {
  const HuntInterest({
    required this.id,
    required this.postId,
    required this.playerId,
    required this.name,
    required this.createdAt,
    this.role,
    this.city,
    this.phone,
    this.figures,
    this.photoPath,
  });
  final String id;
  final String postId;
  final String playerId;
  final String name;
  final DateTime createdAt;
  final HuntRole? role;
  final String? city;

  /// Only when the player shares their phone with clubs.
  final String? phone;
  final HuntPlayerFigures? figures;
  final String? photoPath;
}

/// An invite the owner's club sent (Available Players).
class ClubHuntInvite {
  const ClubHuntInvite({
    required this.id,
    required this.playerId,
    required this.name,
    required this.status,
    required this.createdAt,
    this.role,
    this.city,
    this.postId,
    this.expiresAt,
    this.respondedAt,
    this.phone,
  });
  final String id;
  final String playerId;
  final String name;
  final HuntInviteStatus status;
  final DateTime createdAt;
  final HuntRole? role;
  final String? city;
  final String? postId;
  final DateTime? expiresAt;
  final DateTime? respondedAt;

  /// Only once accepted, and only when the player shares it with clubs.
  final String? phone;
}

/// An invite the signed-in player received (Playing Opportunities).
/// Accepting means "I'm interested — contact me": it never joins the club.
class PlayerHuntInvite {
  const PlayerHuntInvite({
    required this.id,
    required this.clubId,
    required this.clubName,
    required this.status,
    required this.createdAt,
    this.clubShortName,
    this.clubCity,
    this.postRole,
    this.postFormat,
    this.postDate,
    this.expiresAt,
    this.respondedAt,
  });
  final String id;
  final String clubId;
  final String clubName;
  final String? clubShortName;
  final String? clubCity;
  final HuntRole? postRole;
  final MatchFormat? postFormat;
  final DateTime? postDate;
  final HuntInviteStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? respondedAt;

  String get displayClubName => (clubShortName?.trim().isNotEmpty ?? false) ? clubShortName!.trim() : clubName;
}
