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
  final String? ownerName;
  final String? address;
  final String? email;
  final String? homeGroundId;
  final int? establishedYear;

  String get displayShortName => shortName ?? name;
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
  });

  final String id;
  final String name;
  final String phone;
  final MemberRole role;
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
}
