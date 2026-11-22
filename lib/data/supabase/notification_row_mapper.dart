import '../../core/models/models.dart';
import 'match_row_mapper.dart';

/// Rows of migration 25 ↔ the app's models. A required field missing or of
/// the wrong type is a [MatchRowFormatException] — never a guessed value.
/// One exception, for forward compatibility: a notification TYPE this
/// version doesn't know (a newer server) is skipped, not an error, so the
/// rest of the inbox still shows.
abstract final class NotificationRowMapper {
  static const _types = {
    'join_request_received': ServerNotificationType.joinRequestReceived,
    'join_request_approved': ServerNotificationType.joinRequestApproved,
    'join_request_declined': ServerNotificationType.joinRequestDeclined,
    'removed_from_club': ServerNotificationType.removedFromClub,
    'ownership_offered': ServerNotificationType.ownershipOffered,
    'ownership_accepted': ServerNotificationType.ownershipAccepted,
    'ownership_rejected': ServerNotificationType.ownershipRejected,
    'ownership_withdrawn': ServerNotificationType.ownershipWithdrawn,
    'challenge_received': ServerNotificationType.challengeReceived,
    'challenge_accepted': ServerNotificationType.challengeAccepted,
    'challenge_declined': ServerNotificationType.challengeDeclined,
    'schedule_proposed': ServerNotificationType.scheduleProposed,
    'schedule_accepted': ServerNotificationType.scheduleAccepted,
    'schedule_declined': ServerNotificationType.scheduleDeclined,
    'match_rescheduled': ServerNotificationType.matchRescheduled,
    'match_cancelled': ServerNotificationType.matchCancelled,
    'lineup_selected': ServerNotificationType.lineupSelected,
    'lineup_changed': ServerNotificationType.lineupChanged,
    'lineup_dropped': ServerNotificationType.lineupDropped,
    'result_published': ServerNotificationType.resultPublished,
    'result_corrected': ServerNotificationType.resultCorrected,
    'player_of_match': ServerNotificationType.playerOfMatch,
    'announcement': ServerNotificationType.announcement,
  };

  /// The database code of [type].
  static String typeCode(ServerNotificationType type) =>
      _types.entries.firstWhere((e) => e.value == type).key;

  /// `p_inbox` for [role].
  static String inboxCode(UserRole role) => switch (role) {
    UserRole.player => 'player',
    UserRole.clubOwner => 'club_owner',
  };

  static const _audiences = {
    'all': AnnouncementAudience.all,
    'players': AnnouncementAudience.players,
    'staff': AnnouncementAudience.staff,
  };

  static String audienceCode(AnnouncementAudience a) => switch (a) {
    AnnouncementAudience.all => 'all',
    AnnouncementAudience.players => 'players',
    AnnouncementAudience.staff => 'staff',
  };

  /// A `my_notifications` row of [role]'s inbox; `null` for an unknown type.
  static ServerNotification? notification(
    UserRole role,
    Map<String, dynamic> row,
  ) {
    final code = row['type'];
    if (code is! String || code.isEmpty) {
      throw const MatchRowFormatException('type');
    }
    final type = _types[code];
    if (type == null) return null;
    final params = switch (row['params']) {
      null => const <String, Object?>{},
      final Map<dynamic, dynamic> m => {
        for (final e in m.entries) '${e.key}': e.value as Object?,
      },
      _ => throw const MatchRowFormatException('params'),
    };
    final id = MatchRowMapper.text(row, 'notification_id');
    return ServerNotification(
      id: id,
      role: role,
      type: type,
      params: params,
      clubId: MatchRowMapper.optText(row, 'club_id'),
      matchId: MatchRowMapper.optText(row, 'match_id'),
      subjectId: MatchRowMapper.optText(row, 'subject_id'),
      createdAt: MatchRowMapper.time(row, 'created_at'),
      readAt: MatchRowMapper.optTime(row, 'read_at'),
      cursor: NotificationCursor(MatchRowMapper.text(row, 'created_at'), id),
    );
  }

  /// One page from [rows] (asked with [limit]). A full page may have more
  /// after it: the next one starts after its LAST row — skipped unknown
  /// types included, so nothing is fetched twice or missed.
  static NotificationPage page(
    UserRole role,
    List<Map<String, dynamic>> rows,
    int limit,
  ) {
    final items = [for (final r in rows) ?notification(role, r)];
    if (rows.length < limit) return NotificationPage(items: items);
    final last = rows.last;
    return NotificationPage(
      items: items,
      next: NotificationCursor(
        MatchRowMapper.text(last, 'created_at'),
        MatchRowMapper.text(last, 'notification_id'),
      ),
    );
  }

  static AnnouncementRecord announcement(Map<String, dynamic> row) =>
      AnnouncementRecord(
        id: MatchRowMapper.text(row, 'announcement_id'),
        clubId: MatchRowMapper.text(row, 'club_id'),
        clubName: MatchRowMapper.text(row, 'club_name'),
        title: MatchRowMapper.text(row, 'title'),
        message: MatchRowMapper.text(row, 'message'),
        audience:
            _audiences[row['audience']] ??
            (throw const MatchRowFormatException('audience')),
        createdAt: MatchRowMapper.time(row, 'created_at'),
        recipientCount: MatchRowMapper.optInt(row, 'recipient_count'),
      );

  static PublishedAnnouncement published(Map<String, dynamic> row) =>
      PublishedAnnouncement(
        id: MatchRowMapper.text(row, 'announcement_id'),
        recipientCount: MatchRowMapper.integer(row, 'recipient_count'),
      );
}
