import '../enums/enums.dart';

/// The single CricEco account. Roles are profiles on this account.
class UserAccount {
  const UserAccount({
    required this.id,
    required this.fullName,
    required this.contactMethod,
    this.phone,
    this.email,
    this.city,
    this.dateOfBirth,
    this.playerProfile = const PlayerProfile(),
    this.hasClubOwnerProfile = false,
    this.ownedClubId,
    this.memberships = const [],
    this.onboardingComplete = false,
  });

  final String id;
  final String fullName;
  final ContactMethod contactMethod;
  final String? phone;
  final String? email;
  final String? city;
  final DateTime? dateOfBirth;
  final PlayerProfile playerProfile;

  /// Account-level Club Owner profile. Only set by creating a club — never by
  /// a club membership (approved fix C).
  final bool hasClubOwnerProfile;
  final String? ownedClubId;

  /// Membership of other clubs (Player / Coach / Manager).
  final List<ClubMembership> memberships;
  final bool onboardingComplete;

  String get initial => fullName.isEmpty ? 'A' : fullName[0].toUpperCase();

  UserAccount copyWith({
    String? fullName,
    ContactMethod? contactMethod,
    String? phone,
    String? email,
    String? city,
    DateTime? dateOfBirth,
    PlayerProfile? playerProfile,
    bool? hasClubOwnerProfile,
    String? ownedClubId,
    List<ClubMembership>? memberships,
    bool? onboardingComplete,
  }) =>
      UserAccount(
        id: id,
        fullName: fullName ?? this.fullName,
        contactMethod: contactMethod ?? this.contactMethod,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        city: city ?? this.city,
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        playerProfile: playerProfile ?? this.playerProfile,
        hasClubOwnerProfile: hasClubOwnerProfile ?? this.hasClubOwnerProfile,
        ownedClubId: ownedClubId ?? this.ownedClubId,
        memberships: memberships ?? this.memberships,
        onboardingComplete: onboardingComplete ?? this.onboardingComplete,
      );
}

class PlayerProfile {
  const PlayerProfile({
    this.role,
    this.battingStyle,
    this.bowlingStyle,
    this.isWicketkeeper = false,
    this.hasPhoto = false,
  });

  final PlayerRole? role;
  final BattingStyle? battingStyle;
  final BowlingStyle? bowlingStyle;
  final bool isWicketkeeper;
  final bool hasPhoto;

  PlayerProfile copyWith({
    PlayerRole? role,
    BattingStyle? battingStyle,
    BowlingStyle? bowlingStyle,
    bool? isWicketkeeper,
    bool? hasPhoto,
  }) =>
      PlayerProfile(
        role: role ?? this.role,
        battingStyle: battingStyle ?? this.battingStyle,
        bowlingStyle: bowlingStyle ?? this.bowlingStyle,
        isWicketkeeper: isWicketkeeper ?? this.isWicketkeeper,
        hasPhoto: hasPhoto ?? this.hasPhoto,
      );
}

/// Membership of a club. A Coach/Manager membership never grants the
/// account-level Club Owner role.
class ClubMembership {
  const ClubMembership({
    required this.clubId,
    required this.clubName,
    required this.clubCode,
    required this.role,
  });

  final String clubId;
  final String clubName;
  final String clubCode;
  final MemberRole role;
}

/// Outgoing request from this account to join a club by code.
class ClubJoinRequest {
  const ClubJoinRequest({
    required this.clubCode,
    required this.clubName,
    this.status = JoinRequestStatus.pending,
    this.approvedRole,
  });

  final String clubCode;
  final String clubName;
  final JoinRequestStatus status;
  final MemberRole? approvedRole;

  ClubJoinRequest copyWith({JoinRequestStatus? status, MemberRole? approvedRole}) =>
      ClubJoinRequest(
        clubCode: clubCode,
        clubName: clubName,
        status: status ?? this.status,
        approvedRole: approvedRole ?? this.approvedRole,
      );
}

/// The single source of truth for a player's availability (fixes the
/// prototype divergence between the dashboard pill and the status screen).
class PlayerAvailabilityRecord {
  const PlayerAvailabilityRecord({
    required this.status,
    required this.since,
    this.reason,
    this.until = AvailabilityUntil.custom,
    this.untilDate,
    this.notes = '',
    this.openToOffers = false,
  });

  final PlayerAvailability status;
  final DateTime since;
  final AvailabilityReason? reason;
  final AvailabilityUntil until;
  final DateTime? untilDate;
  final String notes; // max 200
  final bool openToOffers;

  static const notesMaxLength = 200;

  PlayerAvailabilityRecord copyWith({
    PlayerAvailability? status,
    DateTime? since,
    AvailabilityReason? reason,
    AvailabilityUntil? until,
    DateTime? untilDate,
    String? notes,
    bool? openToOffers,
  }) =>
      PlayerAvailabilityRecord(
        status: status ?? this.status,
        since: since ?? this.since,
        reason: reason ?? this.reason,
        until: until ?? this.until,
        untilDate: untilDate ?? this.untilDate,
        notes: notes ?? this.notes,
        openToOffers: openToOffers ?? this.openToOffers,
      );
}

class PrivacySecurityPrefs {
  const PrivacySecurityPrefs({
    this.publicProfile = true,
    this.showStats = true,
    this.showPhone = false,
    this.twoStep = false,
    this.loginAlerts = true,
  });

  final bool publicProfile;
  final bool showStats;
  final bool showPhone;
  final bool twoStep;
  final bool loginAlerts;

  PrivacySecurityPrefs copyWith({
    bool? publicProfile,
    bool? showStats,
    bool? showPhone,
    bool? twoStep,
    bool? loginAlerts,
  }) =>
      PrivacySecurityPrefs(
        publicProfile: publicProfile ?? this.publicProfile,
        showStats: showStats ?? this.showStats,
        showPhone: showPhone ?? this.showPhone,
        twoStep: twoStep ?? this.twoStep,
        loginAlerts: loginAlerts ?? this.loginAlerts,
      );
}
