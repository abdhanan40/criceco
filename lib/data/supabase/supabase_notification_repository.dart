import '../../core/models/models.dart';
import '../repositories/repositories.dart';
import 'notification_row_mapper.dart';
import 'supabase_gateways.dart';
import 'supabase_match_repository.dart' show guardMatchCall;

/// [NotificationInboxRepository] on Supabase (migration 25, the
/// notifications switch). Whose rows are read or marked is decided by the
/// database (`auth.uid()`); this class builds requests and maps rows and
/// errors only ([guardMatchCall]: a refusal becomes an [AccountException],
/// an unreadable row a generic error).
class SupabaseNotificationInboxRepository
    implements NotificationInboxRepository {
  SupabaseNotificationInboxRepository({required this.db});

  final NotificationsGateway db;

  /// The server's limit per `mark_notifications_read` call.
  static const markBatch = 200;

  @override
  Future<NotificationPage> page(
    UserRole role, {
    NotificationCursor? after,
    int limit = 30,
  }) => guardMatchCall(() async {
    final size = limit.clamp(1, 100);
    final rows = await db.myNotifications({
      'p_inbox': NotificationRowMapper.inboxCode(role),
      'p_before': after?.at,
      'p_before_id': after?.id,
      'p_limit': size,
    });
    return NotificationRowMapper.page(role, rows, size);
  });

  @override
  Future<int> unreadCount(UserRole role) => guardMatchCall(
    () => db.unreadCount(NotificationRowMapper.inboxCode(role)),
  );

  @override
  Future<int> markRead(Iterable<String> ids) => guardMatchCall(() async {
    final unique = {
      for (final id in ids)
        if (id.isNotEmpty) id,
    }.toList();
    var changed = 0;
    for (var i = 0; i < unique.length; i += markBatch) {
      changed += await db.markRead(
        unique.sublist(i, (i + markBatch).clamp(0, unique.length)),
      );
    }
    return changed;
  });

  @override
  Future<int> markAllRead(UserRole role, {NotificationCursor? upTo}) =>
      guardMatchCall(
        () => db.markAllRead(
          NotificationRowMapper.inboxCode(role),
          upTo: upTo?.at,
        ),
      );
}

/// [AnnouncementServerRepository] on Supabase (migration 25): the server
/// checks the owner, tidies and validates the text, picks the recipients and
/// enforces the daily limit.
class SupabaseAnnouncementServerRepository
    implements AnnouncementServerRepository {
  SupabaseAnnouncementServerRepository({required this.db});

  final NotificationsGateway db;

  @override
  Future<PublishedAnnouncement> publish({
    required String clubId,
    required String title,
    required String message,
    required AnnouncementAudience audience,
  }) => guardMatchCall(
    () async => NotificationRowMapper.published(
      await db.publishAnnouncement({
        'p_club_id': clubId,
        'p_title': title,
        'p_message': message,
        'p_audience': NotificationRowMapper.audienceCode(audience),
      }),
    ),
  );

  @override
  Future<AnnouncementRecord> announcement(String announcementId) =>
      guardMatchCall(() async {
        final rows = await db.announcement(announcementId);
        if (rows.isEmpty) {
          throw const NotificationRuleException(
            'This announcement is no longer available.',
          );
        }
        return NotificationRowMapper.announcement(rows.first);
      });

  @override
  Future<List<AnnouncementRecord>> clubAnnouncements(
    String clubId, {
    int limit = 50,
  }) => guardMatchCall(
    () async => [
      for (final r in await db.clubAnnouncements(
        clubId,
        limit: limit.clamp(1, 100),
      ))
        NotificationRowMapper.announcement(r),
    ],
  );
}
