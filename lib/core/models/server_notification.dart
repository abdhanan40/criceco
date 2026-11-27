import '../enums/enums.dart';
import 'announcement.dart';

/// What happened — one value per type of migration 25 (M3). The server
/// stores the type and its parameters; the app writes the wording
/// (decision D3).
enum ServerNotificationType {
  joinRequestReceived,
  joinRequestApproved,
  joinRequestDeclined,
  removedFromClub,
  ownershipOffered,
  ownershipAccepted,
  ownershipRejected,
  ownershipWithdrawn,
  challengeReceived,
  challengeAccepted,
  challengeDeclined,
  scheduleProposed,
  scheduleAccepted,
  scheduleDeclined,
  matchRescheduled,
  matchCancelled,
  lineupSelected,
  lineupChanged,
  lineupDropped,
  resultPublished,
  resultCorrected,
  playerOfMatch,
  announcement,

  // Reminders (migration 28, M3 P6).
  matchReminder,
  challengeExpiring,
  ownershipExpiring,

  // Player Hunt (migration 33, M8).
  huntInviteReceived,
  huntInterestReceived,
  huntInviteAccepted,

  // Tournaments (migration 35, M10): the club owner's inbox.
  tournamentRegistrationReceived,
  tournamentRegistrationApproved,
  tournamentRegistrationRejected,
  tournamentTeamRemoved,
  tournamentFixturesPublished,
}

/// One notification from the server inbox (migration 25): immutable except
/// for being read once.
class ServerNotification {
  const ServerNotification({
    required this.id,
    required this.role,
    required this.type,
    required this.params,
    required this.createdAt,
    required this.cursor,
    this.clubId,
    this.matchId,
    this.subjectId,
    this.readAt,
  });

  final String id;

  /// The inbox it is in (Player or Club Owner).
  final UserRole role;
  final ServerNotificationType type;

  /// Snapshots for the wording: club / opponent / person names, dates,
  /// selection, result. Absent keys are simply missing (the server strips
  /// nulls).
  final Map<String, Object?> params;

  /// The club / match it is about; `null` once deleted.
  final String? clubId;
  final String? matchId;

  /// The request, offer, challenge or announcement (no longer there = "not
  /// available" at the destination).
  final String? subjectId;
  final DateTime createdAt;
  final DateTime? readAt;

  /// Its exact place in the inbox: the next page starts after it, and
  /// "mark all read" up to it.
  final NotificationCursor cursor;

  bool get isRead => readAt != null;

  /// The same notification read at [at] (`null` = unread again: only to undo
  /// an optimistic mark that the server refused).
  ServerNotification withReadAt(DateTime? at) => ServerNotification(
    id: id,
    role: role,
    type: type,
    params: params,
    createdAt: createdAt,
    cursor: cursor,
    clubId: clubId,
    matchId: matchId,
    subjectId: subjectId,
    readAt: at,
  );

  /// A text parameter, or `null` when missing or not text.
  String? text(String key) => switch (params[key]) {
    final String s when s.trim().isNotEmpty => s.trim(),
    _ => null,
  };

  /// A boolean parameter (`false` when missing).
  bool flag(String key) => params[key] == true;

  /// An integer parameter, or `null`.
  int? integer(String key) => switch (params[key]) {
    final int i => i,
    final num n when n == n.roundToDouble() => n.toInt(),
    _ => null,
  };

  /// An instant parameter (ISO 8601) in local time, or `null`.
  DateTime? instant(String key) => switch (text(key)) {
    final String s => DateTime.tryParse(s)?.toLocal(),
    null => null,
  };

  /// A calendar-date parameter (`YYYY-MM-DD`), or `null`.
  DateTime? date(String key) {
    final s = text(key);
    if (s == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return null;
    return DateTime.tryParse(s);
  }

  /// The person named in it deleted their account (decision D11).
  bool get personDeleted => flag('person_deleted');
}

/// A place in an inbox (the next page starts after it). Opaque: it keeps the
/// server's exact timestamp text — a parsed [DateTime] can lose the
/// microseconds (on the web) and skip rows.
class NotificationCursor {
  const NotificationCursor(this.at, this.id);
  final String at;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is NotificationCursor && other.at == at && other.id == id;
  @override
  int get hashCode => Object.hash(at, id);
}

/// One page of an inbox, newest first.
class NotificationPage {
  const NotificationPage({required this.items, this.next});

  static const empty = NotificationPage(items: []);

  final List<ServerNotification> items;

  /// `null` when this was the last page.
  final NotificationCursor? next;
}

/// A club announcement as the server stores it (migration 25, decision D10).
class AnnouncementRecord {
  const AnnouncementRecord({
    required this.id,
    required this.clubId,
    required this.clubName,
    required this.title,
    required this.message,
    required this.audience,
    required this.createdAt,
    this.recipientCount,
  });

  final String id;
  final String clubId;
  final String clubName;
  final String title;
  final String message;
  final AnnouncementAudience audience;
  final DateTime createdAt;

  /// How many members were told — for the club's owner only (`null` for a
  /// recipient).
  final int? recipientCount;
}

/// What publishing an announcement returns.
class PublishedAnnouncement {
  const PublishedAnnouncement({required this.id, required this.recipientCount});
  final String id;
  final int recipientCount;
}

/// What a person can turn off (migration 26, M3 P4). Enforced on the server:
/// a category that is off is not created for them; what is already in the
/// inbox stays.
enum NotificationCategory {
  /// Join decisions, removal from a club, ownership offers: always on.
  membership(
    'Club membership and ownership',
    'Join decisions, removal from a club, ownership offers',
    icon: 'shield',
  ),
  joinRequests(
    'Join requests',
    'Someone asks to join your club',
    icon: 'user-plus',
    forOwners: true,
  ),
  challenges(
    'Challenges and scheduling',
    'Challenges, proposed times and their answers',
    icon: 'swords',
    forOwners: true,
  ),
  matches(
    'Line-ups and match changes',
    'Your selection, a rescheduled or cancelled match',
    icon: 'users',
  ),
  results(
    'Results and awards',
    'Official results, corrections, Player of the Match',
    icon: 'trophy',
  ),
  announcements(
    'Club announcements',
    'Messages from your club',
    icon: 'megaphone',
  );

  const NotificationCategory(
    this.label,
    this.description, {
    required this.icon,
    this.forOwners = false,
  });

  final String label;
  final String description;
  final String icon;

  /// Club Owner events (shown under "For club owners").
  final bool forOwners;

  /// Can't be turned off.
  bool get alwaysOn => this == NotificationCategory.membership;

  /// The category of [type] (as the server's `notification_category`).
  static NotificationCategory of(ServerNotificationType type) => switch (type) {
    ServerNotificationType.joinRequestReceived ||
    ServerNotificationType.huntInterestReceived ||
    ServerNotificationType.huntInviteAccepted ||
    ServerNotificationType.tournamentRegistrationReceived => joinRequests,
    ServerNotificationType.tournamentRegistrationApproved ||
    ServerNotificationType.tournamentRegistrationRejected ||
    ServerNotificationType.tournamentTeamRemoved => challenges,
    ServerNotificationType.tournamentFixturesPublished => matches,
    ServerNotificationType.challengeReceived ||
    ServerNotificationType.challengeAccepted ||
    ServerNotificationType.challengeDeclined ||
    ServerNotificationType.scheduleProposed ||
    ServerNotificationType.scheduleAccepted ||
    ServerNotificationType.scheduleDeclined => challenges,
    ServerNotificationType.lineupSelected ||
    ServerNotificationType.lineupChanged ||
    ServerNotificationType.lineupDropped ||
    ServerNotificationType.matchRescheduled ||
    ServerNotificationType.matchCancelled => matches,
    ServerNotificationType.resultPublished ||
    ServerNotificationType.resultCorrected ||
    ServerNotificationType.playerOfMatch => results,
    ServerNotificationType.announcement => announcements,
    ServerNotificationType.matchReminder => matches,
    ServerNotificationType.challengeExpiring => challenges,
    _ => membership,
  };
}

/// A person's notification preferences (migration 26). Everything on until
/// they change something.
class NotificationPreferences {
  const NotificationPreferences({
    this.joinRequests = true,
    this.challenges = true,
    this.matches = true,
    this.results = true,
    this.announcements = true,
    this.updatedAt,
  });

  static const allOn = NotificationPreferences();

  final bool joinRequests;
  final bool challenges;
  final bool matches;
  final bool results;
  final bool announcements;

  /// When they last changed it (`null` = never).
  final DateTime? updatedAt;

  bool isOn(NotificationCategory c) => switch (c) {
    NotificationCategory.membership => true,
    NotificationCategory.joinRequests => joinRequests,
    NotificationCategory.challenges => challenges,
    NotificationCategory.matches => matches,
    NotificationCategory.results => results,
    NotificationCategory.announcements => announcements,
  };

  /// The same, with [c] turned [on] (membership can't change).
  NotificationPreferences withCategory(
    NotificationCategory c,
    bool on,
  ) => NotificationPreferences(
    joinRequests: c == NotificationCategory.joinRequests ? on : joinRequests,
    challenges: c == NotificationCategory.challenges ? on : challenges,
    matches: c == NotificationCategory.matches ? on : matches,
    results: c == NotificationCategory.results ? on : results,
    announcements: c == NotificationCategory.announcements ? on : announcements,
    updatedAt: updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is NotificationPreferences &&
      other.joinRequests == joinRequests &&
      other.challenges == challenges &&
      other.matches == matches &&
      other.results == results &&
      other.announcements == announcements;

  @override
  int get hashCode =>
      Object.hash(joinRequests, challenges, matches, results, announcements);
}
