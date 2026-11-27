import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../club/club_providers.dart';
import '../tournaments/tournaments_controller.dart';
import 'server_inbox_controller.dart';
import 'server_notification_adapter.dart';

/// The route a notification opens — always inside the notification's own
/// role (Player targets are `/player/**`, Club Owner targets `/club/**`), so
/// opening one never changes the active role. `null` = non-navigating (P16).
String? notificationLocation(NotificationTarget? target) => switch (target) {
      null => null,
      PlayerMatchTarget(:final matchId) => Routes.playerMatchDetails(matchId),
      PlayerProfileTarget() => Routes.playerProfile,
      AvailabilityTarget() => Routes.availability,
      PlayingOpportunitiesTarget() => Routes.openMatches,
      PlayerHuntTarget(:final availablePlayers) => availablePlayers ? '${Routes.playerHunt}?tab=available' : Routes.playerHunt,
      OwnershipOffersTarget() => Routes.ownershipOffers,
      PlayerScorecardTarget(:final matchId) => Routes.matchScorecard(matchId),
      JoinRequestTarget(:final requestId) => Routes.joinRequestProfile(requestId),
      MyChallengesTarget() => Routes.myChallenges,
      ClubOwnershipTarget() => Routes.transferOwnership,
      ClubMatchResultTarget(:final matchId) => Routes.clubMatchResult(matchId),
      ClubMatchesTarget(:final tab) => Routes.matchManagement(tab),
      MyRegistrationsTarget(:final status) => Routes.myRegistrationsIn(status),
      RegistrationTarget(:final registrationId) => Routes.registrationDetails(registrationId),
      TournamentRequestTarget(:final tournamentId, :final registrationId) =>
        Routes.teamRequestDetail(tournamentId, registrationId),
      // Read in place (bottom sheet), not a route.
      AnnouncementTarget() => null,
    };

/// Club Owner notifications raised by tournament events: decisions on my
/// registrations, and requests to join tournaments I host. Derived from
/// state, so they always match what their destination shows.
final tournamentNotificationsProvider = Provider<List<NotificationItem>>((ref) {
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null) return const [];
  final regs = ref.watch(tournamentRegistrationsProvider).value ?? const <TournamentRegistration>[];
  final tournaments = {for (final t in ref.watch(tournamentsProvider).value ?? const <Tournament>[]) t.id: t};
  final clubs = ref.watch(clubDirectoryProvider).value ?? const <String, ClubSummary>{};
  return [
    for (final r in regs)
      if (tournaments[r.tournamentId] case final t?)
        if (r.clubId == clubId && r.decidedAt != null)
          r.status == RegistrationStatus.approved
              ? NotificationItem(
                  id: 'n_reg_${r.id}',
                  role: UserRole.clubOwner,
                  icon: 'trophy',
                  title: 'Tournament registration approved',
                  subtitle: '${t.name} · ${r.teamName}',
                  createdAt: r.decidedAt!,
                  tone: NotificationTone.blue,
                  target: RegistrationTarget(r.id),
                )
              : NotificationItem(
                  id: 'n_reg_${r.id}',
                  role: UserRole.clubOwner,
                  icon: 'x-circle',
                  title: 'Tournament registration not approved',
                  subtitle: '${t.name} · ${r.teamName}',
                  createdAt: r.decidedAt!,
                  tone: NotificationTone.amber,
                  target: RegistrationTarget(r.id),
                )
        else if (r.isPending && r.clubId != clubId && t.organizerClubId == clubId)
          NotificationItem(
            id: 'n_req_${r.id}',
            role: UserRole.clubOwner,
            icon: 'clipboard-list',
            title: 'Registration request from ${clubs[r.clubId]?.name ?? r.teamName}',
            subtitle: t.name,
            createdAt: r.submittedAt,
            tone: NotificationTone.amber,
            target: TournamentRequestTarget(t.id, r.id),
          ),
  ];
});

/// Club member records that are this account (its own member row in the club
/// it owns). Items delivered to a club member reach the account through these.
final ownMemberIdsProvider = FutureProvider<Set<String>>((ref) async {
  final members = await ref.watch(clubMembersProvider.future);
  return {for (final m in members) if (m.role == MemberRole.owner) m.id};
});

/// One role's inbox, newest first.
/// * With the notifications switch ([notificationsBackendLiveProvider]): the
///   server inbox as loaded so far ([serverInboxProvider]), in the app's
///   wording ([ServerNotificationAdapter]).
/// * Otherwise (the demo): the seeded items plus live event items. Items
///   addressed to a club member (announcements) show only to that member.
/// Player and Club Owner inboxes never mix.
final roleNotificationsProvider = FutureProvider.family<List<NotificationItem>, UserRole>((ref, role) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  if (ref.watch(notificationsBackendLiveProvider)) {
    final inbox = await ref.watch(serverInboxProvider(role).future);
    return [for (final n in inbox.items) ServerNotificationAdapter.item(n)];
  }
  final live = role == UserRole.clubOwner ? ref.watch(tournamentNotificationsProvider) : const <NotificationItem>[];
  final stored = await ref.read(notificationRepositoryProvider).forRole(role);
  final mine = stored.any((n) => n.recipientMemberId != null) ? await ref.watch(ownMemberIdsProvider.future) : const <String>{};
  return [
    for (final n in stored)
      if (n.recipientMemberId == null || mine.contains(n.recipientMemberId)) n,
    ...live,
  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
});

/// Read state of the demo inbox (this session only). Opening a row marks it
/// read; "Mark all as read". With the notifications switch read state is on
/// the server instead ([serverInboxProvider]).
class NotificationReadController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return const {};
  }

  void markRead(String id) {
    if (!state.contains(id)) state = {...state, id};
  }

  void markAllRead(Iterable<String> ids) => state = {...state, ...ids};
}

final notificationReadProvider =
    NotifierProvider<NotificationReadController, Set<String>>(NotificationReadController.new);

/// The unread rows among those loaded for [role]: the server's read state,
/// or the demo's session read state.
final unreadNotificationIdsProvider = Provider.family<Set<String>, UserRole>((ref, role) {
  if (ref.watch(notificationsBackendLiveProvider)) {
    final items = ref.watch(serverInboxProvider(role)).value?.items ?? const <ServerNotification>[];
    return {for (final n in items) if (!n.isRead) n.id};
  }
  final items = ref.watch(roleNotificationsProvider(role)).value ?? const <NotificationItem>[];
  final read = ref.watch(notificationReadProvider);
  return {for (final n in items) if (!read.contains(n.id)) n.id};
});

/// Unread count for a role (dashboard bell badge, "N new"). With the switch:
/// the server's count, which covers pages not loaded yet.
final unreadNotificationCountProvider = Provider.family<int, UserRole>((ref, role) {
  if (ref.watch(notificationsBackendLiveProvider)) {
    return ref.watch(serverInboxProvider(role)).value?.unread ?? 0;
  }
  return ref.watch(unreadNotificationIdsProvider(role)).length;
});

/// Whether older notifications can be loaded, and one page is on its way.
final notificationPagingProvider = Provider.family<({bool hasMore, bool loading}), UserRole>((ref, role) {
  if (!ref.watch(notificationsBackendLiveProvider)) return (hasMore: false, loading: false);
  final inbox = ref.watch(serverInboxProvider(role)).value;
  return (hasMore: inbox?.hasMore ?? false, loading: inbox?.loadingMore ?? false);
});

// ---- Actions shared by the panel, the screen and the app ----

/// Marks [n] read (opening it).
void markNotificationRead(WidgetRef ref, NotificationItem n) {
  if (ref.read(notificationsBackendLiveProvider)) {
    unawaited(ref.read(serverInboxProvider(n.role).notifier).markRead(n.id));
  } else {
    ref.read(notificationReadProvider.notifier).markRead(n.id);
  }
}

/// "Mark all read" for [role] ([ids]: the unread rows shown, demo only).
/// Throws if the server refuses (the list is restored).
Future<void> markAllNotificationsRead(WidgetRef ref, UserRole role, Iterable<String> ids) async {
  if (ref.read(notificationsBackendLiveProvider)) {
    await ref.read(serverInboxProvider(role).notifier).markAllRead();
  } else {
    ref.read(notificationReadProvider.notifier).markAllRead(ids);
  }
}

/// Reloads [role]'s inbox (opening it, pull-down, Retry). With the switch the
/// list shown stays if it fails, and the error is rethrown.
Future<void> refreshNotifications(WidgetRef ref, UserRole role) async {
  if (ref.read(notificationsBackendLiveProvider)) {
    await ref.read(serverInboxProvider(role).notifier).refresh();
  } else {
    ref.invalidate(roleNotificationsProvider(role));
  }
}

/// Loads the next (older) page of [role]'s inbox (server inbox only).
Future<void> loadMoreNotifications(WidgetRef ref, UserRole role) async {
  if (ref.read(notificationsBackendLiveProvider)) {
    await ref.read(serverInboxProvider(role).notifier).loadMore();
  }
}
