/// Typed enums for every state value found in the prototype (audit §21,
/// revised architecture §6, §7, §11). Each enum carries the exact UI label
/// used by the prototype so screens never hard-code strings.
library;

/// Account-level active context. A club *membership* role ([MemberRole]) is
/// never the same thing as the account-level [UserRole.clubOwner].
enum UserRole {
  player('Player'),
  clubOwner('Club Owner');

  const UserRole(this.label);
  final String label;
}

enum MemberRole {
  owner('Owner'),
  player('Player'),
  coach('Coach'),
  manager('Manager');

  const MemberRole(this.label);
  final String label;
}

enum ContactMethod { phone, email }

enum PlayerRole {
  batsman('Batsman'),
  bowler('Bowler'),
  allRounder('All-Rounder');

  const PlayerRole(this.label);
  final String label;
}

/// Roles used by Player Hunt / Open Matches / Available Players.
enum HuntRole {
  batsman('Batsman'),
  bowler('Bowler'),
  allRounder('All-Rounder'),
  wicketKeeper('Wicket-Keeper');

  const HuntRole(this.label);
  final String label;
}

/// Category derived from free-text squad positions (prototype `squadCategory`).
enum SquadCategory {
  batsman('Batsman'),
  bowler('Bowler'),
  allRounder('All-Rounder');

  const SquadCategory(this.label);
  final String label;

  static SquadCategory fromPosition(String position) {
    final p = position.toLowerCase();
    if (p.contains('all-rounder')) return SquadCategory.allRounder;
    if (p.contains('bowler') || p.contains('spinner')) {
      return SquadCategory.bowler;
    }
    return SquadCategory.batsman;
  }
}

enum BattingStyle {
  rightHanded('Right-handed'),
  leftHanded('Left-handed');

  const BattingStyle(this.label);
  final String label;
}

enum BowlingStyle {
  rightArmFast('Right-arm Fast'),
  rightArmMedium('Right-arm Medium'),
  rightArmOffSpin('Right-arm Off-spin'),
  rightArmLegSpin('Right-arm Leg-spin'),
  leftArmFast('Left-arm Fast'),
  leftArmMedium('Left-arm Medium'),
  leftArmOrthodox('Left-arm Orthodox'),
  leftArmChinaman('Left-arm Chinaman');

  const BowlingStyle(this.label);
  final String label;
}

enum PlayerAvailability {
  available('Available', 'You are available for selection.'),
  limited('Limited Availability', 'You have limited availability right now.'),
  unavailable('Unavailable', 'You are not available for selection.'),
  injured('Injured', 'You are marked as injured.'),
  other('Other', 'Your status is set to other.');

  const PlayerAvailability(this.label, this.description);
  final String label;
  final String description;

  /// Injured / unavailable players cannot be picked into a squad.
  bool get locksSelection =>
      this == PlayerAvailability.injured ||
      this == PlayerAvailability.unavailable;
}

enum AvailabilityUntil {
  today('Today'),
  tomorrow('Tomorrow'),
  weekend('This Weekend'),
  custom('Select Date');

  const AvailabilityUntil(this.label);
  final String label;
}

enum AvailabilityReason {
  injury('Injury'),
  personal('Personal Reasons'),
  work('Work Commitment'),
  travel('Travel'),
  familyEmergency('Family Emergency'),
  restDay('Rest Day'),
  other('Other');

  const AvailabilityReason(this.label);
  final String label;
}

enum SkillLevel {
  club('Club'),
  division('Division'),
  district('District'),
  premier('Premier');

  const SkillLevel(this.label);
  final String label;
}

enum ClubType {
  professional('Professional'),
  collegeUniversity('College/University'),
  corporate('Corporate Club');

  const ClubType(this.label);
  final String label;
}

/// T10 included (approved default P20).
enum MatchFormat {
  test('Test'),
  t20('T20'),
  odi('ODI'),
  t10('T10'),
  custom('Custom');

  const MatchFormat(this.label);
  final String label;

  /// Prototype `formatDisplay(f, overs)`.
  String display([int? customOvers]) {
    if (this != MatchFormat.custom) return label;
    return customOvers != null ? 'Custom · $customOvers overs' : 'Custom Overs';
  }

  /// Formats offered by Create Team / Match Setup / Create Tournament.
  static const standard = [
    MatchFormat.test,
    MatchFormat.t20,
    MatchFormat.odi,
    MatchFormat.custom
  ];

  /// Formats offered by Player Hunt.
  static const hunt = [
    MatchFormat.t20,
    MatchFormat.t10,
    MatchFormat.odi,
    MatchFormat.test,
    MatchFormat.custom
  ];
}

enum TournamentType {
  knockout('Knockout'),
  league('League');

  const TournamentType(this.label);
  final String label;
}

/// Club-side match lifecycle (Match Management).
enum MatchStatus { pending, reserved, confirmed, completed }

enum MatchTab {
  waiting('Waiting'),
  scheduled('Scheduled'),
  history('History');

  const MatchTab(this.label);
  final String label;

  bool includes(MatchStatus s) => switch (this) {
        MatchTab.waiting =>
          s == MatchStatus.pending || s == MatchStatus.reserved,
        MatchTab.scheduled => s == MatchStatus.confirmed,
        MatchTab.history => s == MatchStatus.completed,
      };
}

/// Player-side match tabs — approved terminology: Upcoming / Past / Cancelled.
enum PlayerMatchStatus {
  upcoming('Upcoming'),
  past('Past'),
  cancelled('Cancelled');

  const PlayerMatchStatus(this.label);
  final String label;
}

enum MatchResult { won, lost }

enum SelectionRole { playing, sub }

enum TeamCategory { firstXi, secondXi, youth, veterans, other }

enum TeamStatus { active, archived }

enum PaymentMethodType {
  wallet('CricEco Wallet', 'wallet'),
  easypaisa('EasyPaisa', 'Mobile account'),
  jazzcash('JazzCash', 'Mobile account'),
  card('Debit / Credit Card', 'Visa, Mastercard');

  const PaymentMethodType(this.label, this.subtitle);
  final String label;
  final String subtitle;
}

enum PaymentStatus { pending, processing, paid, failed, refunded, movedToWallet }

enum BookingStatus {
  draft,
  held,
  awaitingOpponent,
  confirmed,
  expired,
  resolved
}

enum HoldStatus { active, confirmed, expired, released }

enum DayAvailability { available, partial, full }

enum SlotState { open, booked, reserved, selected }

enum ReservationResolution { refund, wallet }

enum LedgerType { clubPayment, groundSettlement, refund }

enum TournamentStatus {
  registrationOpen('Registration Open'),
  registrationFull('Registration Full'),
  registrationClosed('Registration Closed'),
  completed('Completed');

  const TournamentStatus(this.label);
  final String label;
}

enum RegistrationStatus {
  pending('Pending'),
  approved('Approved'),
  rejected('Rejected');

  const RegistrationStatus(this.label);
  final String label;
}

enum JoinRequestStatus { pending, approved, cancelled }

/// Review state of an INCOMING request to join the owner's club (Requests tabs).
enum JoinRequestReview {
  pending('Pending'),
  approved('Approved'),
  declined('Declined');

  const JoinRequestReview(this.label);
  final String label;
}

enum ChallengeStatus { pending, accepted, declined, expired }

enum ChallengeDirection { sent, received }

enum NotificationTone { green, amber, blue }

enum HuntBudget {
  any('Any'),
  under2000('Under Rs 2,000'),
  from2000to5000('Rs 2,000 - 5,000'),
  over5000('Rs 5,000+');

  const HuntBudget(this.label);
  final String label;
}
