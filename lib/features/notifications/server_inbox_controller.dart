import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';

/// One role's server inbox as loaded so far (M3 P3): newest first, page by
/// page, with the server's unread count (which covers pages not loaded yet).
class ServerInbox {
  const ServerInbox({
    required this.items,
    required this.unread,
    this.next,
    this.loadingMore = false,
  });

  final List<ServerNotification> items;

  /// Unread in the whole inbox (the last 90 days), from the server.
  final int unread;

  /// Where the next (older) page starts; `null` = everything is loaded.
  final NotificationCursor? next;
  final bool loadingMore;

  bool get hasMore => next != null;

  ServerInbox copyWith({
    List<ServerNotification>? items,
    int? unread,
    NotificationCursor? next,
    bool clearNext = false,
    bool? loadingMore,
  }) => ServerInbox(
    items: items ?? this.items,
    unread: unread ?? this.unread,
    next: clearNext ? null : (next ?? this.next),
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// The server inbox of one role (migration 25; only with the notifications
/// switch — [notificationsBackendLiveProvider]). Read state lives on the
/// server (D6): marking read updates the list at once and then the server;
/// a mark the server refuses is undone. Refreshed when the inbox opens, when
/// the app resumes and on pull-down (D12).
class ServerInboxController extends AsyncNotifier<ServerInbox> {
  ServerInboxController(this.role);
  final UserRole role;

  static const pageSize = 30;

  NotificationInboxRepository get _repo =>
      ref.read(notificationInboxRepositoryProvider);

  @override
  Future<ServerInbox> build() {
    // A different account (or switch state) is a different inbox.
    ref.watch(currentAccountProvider.select((a) => a?.id));
    ref.watch(notificationInboxRepositoryProvider);
    return _load();
  }

  Future<ServerInbox> _load() async {
    final page = await _repo.page(role, limit: pageSize);
    final unread = await _repo.unreadCount(role);
    return ServerInbox(items: page.items, unread: unread, next: page.next);
  }

  /// Reloads the first page and the count. If it fails, the list shown stays
  /// as it was and the error is rethrown (the caller says so).
  Future<void> refresh() async {
    if (!state.hasValue) {
      if (state.isLoading) return; // the first load is still running
      ref.invalidateSelf(); // a failed first load: try again from scratch
      await future;
      return;
    }
    final fresh = await _load();
    state = AsyncData(fresh);
  }

  /// Appends the next (older) page; nothing when everything is loaded or a
  /// page is already on its way.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.next == null || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _repo.page(role, after: current.next, limit: pageSize);
      final latest = state.value ?? current;
      final known = {for (final n in latest.items) n.id};
      state = AsyncData(
        latest.copyWith(
          items: [
            ...latest.items,
            for (final n in page.items)
              if (!known.contains(n.id)) n,
          ],
          next: page.next,
          clearNext: page.next == null,
          loadingMore: false,
        ),
      );
    } catch (_) {
      state = AsyncData((state.value ?? current).copyWith(loadingMore: false));
      rethrow;
    }
  }

  /// Marks one notification read (opening it). Undone quietly if the server
  /// refuses — opening still works.
  Future<void> markRead(String id) async {
    final current = state.value;
    final at = current?.items.indexWhere((n) => n.id == id) ?? -1;
    if (current == null || at < 0 || current.items[at].isRead) return;
    final now = ref.read(clockProvider).now();
    state = AsyncData(
      current.copyWith(
        items: [
          for (final n in current.items) n.id == id ? n.withReadAt(now) : n,
        ],
        unread: math.max(0, current.unread - 1),
      ),
    );
    try {
      await _repo.markRead([id]);
    } catch (_) {
      final latest = state.value;
      if (latest == null) return;
      state = AsyncData(
        latest.copyWith(
          items: [
            for (final n in latest.items) n.id == id ? n.withReadAt(null) : n,
          ],
          unread: latest.unread + 1,
        ),
      );
    }
  }

  /// Marks the inbox read up to the newest notification shown, so one
  /// arriving meanwhile stays unread. On failure the list is restored and the
  /// error rethrown (the caller says so).
  Future<void> markAllRead() async {
    final current = state.value;
    if (current == null || current.items.isEmpty) return;
    final now = ref.read(clockProvider).now();
    state = AsyncData(
      current.copyWith(
        items: [
          for (final n in current.items) n.isRead ? n : n.withReadAt(now),
        ],
        unread: 0,
      ),
    );
    try {
      await _repo.markAllRead(role, upTo: current.items.first.cursor);
    } catch (_) {
      state = AsyncData(current);
      rethrow;
    }
    // Anything that arrived meanwhile is still unread on the server.
    try {
      final unread = await _repo.unreadCount(role);
      final latest = state.value;
      if (latest != null) state = AsyncData(latest.copyWith(unread: unread));
    } catch (_) {
      // The marks are saved; the count catches up on the next refresh.
    }
  }
}

final serverInboxProvider =
    AsyncNotifierProvider.family<ServerInboxController, ServerInbox, UserRole>(
      ServerInboxController.new,
    );
