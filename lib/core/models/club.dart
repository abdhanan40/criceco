import 'dart:ui' show Color;

import '../enums/enums.dart';

/// The account owner's own club.
class Club {
  const Club({
    required this.id,
    required this.name,
    required this.city,
    required this.type,
    required this.code,
    this.shortName,
    this.hasLogo = false,
    this.logoPath,
    this.ownerName,
    this.address,
    this.email,
    this.homeGroundId,
    this.establishedYear,
  });

  final String id;
  final String name;
  final String? shortName; // e.g. "Shalimar CC" on match cards
  final String city;
  final ClubType type;
  final String code;
  final bool hasLogo;

  /// Local path of the chosen club picture (device photo picker); `null` =
  /// the default club badge.
  final String? logoPath;
  final String? ownerName;
  final String? address;
  final String? email;
  final String? homeGroundId;
  final int? establishedYear;

  String get displayShortName => shortName ?? name;

  /// Club picture set / changed / removed (the rest stays as created).
  Club withLogo(String? path) => Club(
        id: id,
        name: name,
        city: city,
        type: type,
        code: code,
        shortName: shortName,
        hasLogo: path != null,
        logoPath: path,
        ownerName: ownerName,
        address: address,
        email: email,
        homeGroundId: homeGroundId,
        establishedYear: establishedYear,
      );
}

class ClubCaptain {
  const ClubCaptain({required this.name, required this.phone});
  final String name;
  final String phone;
}

class KeyPlayer {
  const KeyPlayer({required this.name, required this.position, this.isCaptain = false});
  final String name;
  final String position;
  final bool isCaptain;
}

/// Another club (opponent / organizer / applicant). Prototype `clubData`.
class ClubSummary {
  const ClubSummary({
    required this.id,
    required this.abbr,
    required this.name,
    required this.city,
    required this.level,
    required this.meta,
    required this.established,
    required this.squadSize,
    required this.formats,
    required this.homeGround,
    required this.captain,
    required this.keyPlayers,
    required this.recentForm,
    required this.winRate,
    required this.wins,
    required this.losses,
    required this.played,
    required this.about,
    required this.color,
    this.ownerName,
    this.coachName,
  });

  final String id;
  final String abbr;
  final String name;
  final String city;
  final String level;
  final String meta; // "Karachi · District"
  final int established;
  final int squadSize;
  final String formats; // "T20 / ODI"
  final String homeGround;
  final ClubCaptain captain;
  final List<KeyPlayer> keyPlayers;
  final List<MatchResult> recentForm; // last 5
  final int winRate;
  final int wins;
  final int losses;
  final int played;
  final String about;
  final Color color;

  /// Club Owner / Club Coach shown on the Club Profile (names only — no
  /// contact details). `null` when the club has not listed one.
  final String? ownerName;
  final String? coachName;

  MatchFormat? get preferredFormat {
    final first = formats.split(' / ').first.trim();
    for (final f in MatchFormat.values) {
      if (f.label == first) return f;
    }
    return null;
  }
}

class ClubMember {
  const ClubMember({
    required this.id,
    required this.name,
    required this.role,
    this.phone = '',
    this.playingRole,
    this.isWicketkeeper = false,
    this.battingStyle,
    this.bowlingStyle,
    this.poolPlayerId,
  });

  final String id;
  final String name;
  final String phone;

  /// Club role (Owner / Player / Coach / Manager).
  final MemberRole role;

  /// Cricket playing role — set for members who play (players, or an owner
  /// with a Player profile). `null` = non-playing staff.
  final PlayerRole? playingRole;
  final bool isWicketkeeper;
  final BattingStyle? battingStyle;
  final BowlingStyle? bowlingStyle;

  /// The same person in the club player pool (squads / Add Players), if any.
  final String? poolPlayerId;

  /// Has a cricket profile: fitness and player filters apply.
  bool get plays => playingRole != null;

  /// "Batsman · Wicket Keeper", or the club role for staff.
  String get roleLine => playingRole == null
      ? role.label
      : isWicketkeeper
          ? '${playingRole!.label} · Wicket Keeper'
          : playingRole!.label;
}

class JoinRequestPerformance {
  const JoinRequestPerformance({
    required this.matches,
    required this.runs,
    required this.average,
    required this.wickets,
  });
  final int matches;
  final int runs;
  final String average;
  final int wickets;
}

/// Incoming request from a player to join the owner's club.
class JoinRequest {
  const JoinRequest({
    required this.id,
    required this.name,
    required this.age,
    required this.city,
    required this.battingStyle,
    required this.bowlingStyle,
    required this.role,
    required this.phone,
    required this.appliedLabel,
    this.performance,
    this.review = JoinRequestReview.pending,
    this.assignedRole,
    this.decidedAt,
    this.declineReason,
  });

  final String id;
  final String name;
  final int age;
  final String city;
  final BattingStyle battingStyle;
  final BowlingStyle bowlingStyle;
  final PlayerRole role;
  final String phone;
  final String appliedLabel; // "Applied 2 days ago"
  final JoinRequestPerformance? performance;

  /// Kept after review (the prototype deleted decided requests) so the
  /// Approved / Declined tabs have history.
  final JoinRequestReview review;

  /// Club role given on approval (Player / Coach / Manager). A club
  /// membership only - never the account-level Club Owner role (fix C).
  final MemberRole? assignedRole;
  final DateTime? decidedAt;

  /// Short message given when the request was declined (optional).
  final String? declineReason;

  static const declineReasonMaxLength = 120;

  bool get isPending => review == JoinRequestReview.pending;

  JoinRequest decided(JoinRequestReview review, {MemberRole? role, required DateTime at, String? reason}) =>
      JoinRequest(
        id: id,
        name: name,
        age: age,
        city: city,
        battingStyle: battingStyle,
        bowlingStyle: bowlingStyle,
        role: this.role,
        phone: phone,
        appliedLabel: appliedLabel,
        performance: performance,
        review: review,
        assignedRole: role,
        decidedAt: at,
        declineReason: review == JoinRequestReview.declined && (reason ?? '').trim().isNotEmpty ? reason!.trim() : null,
      );
}
