// Stand-in for the notifications gateway (migration 25): canned responses per
// database function, every call recorded. Rows are shaped like the real
// functions' (see notifications_supabase_test.dart and the SQL local check 20).
import 'package:criceco/data/supabase/supabase_gateways.dart';

class FakeNotificationsDb implements NotificationsGateway {
  final calls = <({String fn, Map<String, Object?> params})>[];

  /// `my_notifications` pages, returned in order (then empty).
  final pages = <List<Map<String, dynamic>>>[];
  int unread = 0;

  /// What each `mark_notifications_read` call returns: its ids' count.
  int Function(List<String> ids) markReadResult = (ids) => ids.length;
  int markAllResult = 0;
  Map<String, dynamic> published = {
    'announcement_id': 'ann-1',
    'recipient_count': 3,
  };
  List<Map<String, dynamic>> announcementRows = [];
  List<Map<String, dynamic>> listRows = [];

  /// Every call of a function fails with this while it's set.
  final failOn = <String, GatewayException>{};

  void _record(String fn, Map<String, Object?> p) {
    calls.add((fn: fn, params: p));
    if (failOn[fn] case final e?) throw e;
  }

  @override
  Future<List<Map<String, dynamic>>> myNotifications(
    Map<String, Object?> params,
  ) async {
    _record('my_notifications', params);
    return pages.isEmpty ? const [] : pages.removeAt(0);
  }

  @override
  Future<int> unreadCount(String inbox) async {
    _record('notification_unread_count', {'p_inbox': inbox});
    return unread;
  }

  @override
  Future<int> markRead(List<String> ids) async {
    _record('mark_notifications_read', {'p_ids': ids});
    return markReadResult(ids);
  }

  @override
  Future<int> markAllRead(String inbox, {String? upTo}) async {
    _record('mark_all_notifications_read', {'p_inbox': inbox, 'p_up_to': upTo});
    return markAllResult;
  }

  @override
  Future<Map<String, dynamic>> publishAnnouncement(
    Map<String, Object?> params,
  ) async {
    _record('publish_club_announcement', params);
    return published;
  }

  @override
  Future<List<Map<String, dynamic>>> announcement(String announcementId) async {
    _record('club_announcement', {'p_announcement_id': announcementId});
    return announcementRows;
  }

  @override
  Future<List<Map<String, dynamic>>> clubAnnouncements(
    String clubId, {
    int limit = 50,
  }) async {
    _record('club_announcement_list', {'p_club_id': clubId, 'p_limit': limit});
    return listRows;
  }
}
