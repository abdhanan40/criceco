import 'club.dart';

/// Who a club announcement goes to.
enum AnnouncementAudience {
  all('All Club Members'),
  players('Players Only'),
  staff('Staff Only');

  const AnnouncementAudience(this.label);
  final String label;

  /// Players = members with a cricket profile; staff = the rest (coach,
  /// manager).
  bool includes(ClubMember m) => switch (this) {
        AnnouncementAudience.all => true,
        AnnouncementAudience.players => m.plays,
        AnnouncementAudience.staff => !m.plays,
      };
}

/// A short in-app club announcement (Club Owner → members). Lightweight on
/// purpose: create → publish → members are notified and can read it.
class ClubAnnouncement {
  const ClubAnnouncement({
    required this.id,
    required this.clubId,
    required this.clubName,
    required this.title,
    required this.message,
    required this.audience,
    required this.createdBy,
    required this.createdAt,
    required this.recipientMemberIds,
  });

  static const titleMaxLength = 60;
  static const messageMaxLength = 280;

  final String id;
  final String clubId;
  final String clubName;
  final String title;
  final String message;
  final AnnouncementAudience audience;

  /// Account id of the Club Owner who published it.
  final String createdBy;
  final DateTime createdAt;

  /// The club members it was delivered to.
  final List<String> recipientMemberIds;
}
