import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../club/club_providers.dart';
import '../tournaments/tournaments_controller.dart';

/// The route a notification opens — always inside the notification's own
/// role (Player targets are `/player/**`, Club Owner targets `/club/**`), so
/// opening one never changes the active role. `null` = non-navigating (P16).
String? notificationLocation(NotificationTarget? target) => switch (target) {
      null => null,
      PlayerMatchTarget(:final matchId) => Routes.playerMatchDetails(matchId),
      PlayerProfileTarget() => Routes.playerProfile,
      AvailabilityTarget() => Routes.availability,
      JoinRequestTarget(:final requestId) => Routes.joinRequestProfile(requestId),
      MyChallengesTarget() => Routes.myChallenges,
      ClubMatchesTarget(:final tab) => Routes.matchManagement(tab),
      MyRegistrationsTarget(:final status) => Routes.myRegistrationsIn(status),
      RegistrationTarget(:final registrationId) => Routes.registrationDetails(registrationId),
      TournamentRequestTarget(:final tournamentId, :final registrationId) =>
        Routes.teamRequestDetail(tournamentId, registrationId),
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

/// One role's inbox, newest first: the seeded items plus live event items.
/// Player and Club Owner inboxes never mix.
final roleNotificationsProvider = FutureProvider.family<List<NotificationItem>, UserRole>((ref, role) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  final live = role == UserRole.clubOwner ? ref.watch(tournamentNotificationsProvider) : const <NotificationItem>[];
  final seeded = await ref.read(notificationRepositoryProvider).forRole(role);
  return [...seeded, ...live]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
});

/// Read state (session). Opening a row marks it read; "Mark all as read".
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

/// Unread count for a role (dashboard bell badge).
final unreadNotificationCountProvider = Provider.family<int, UserRole>((ref, role) {
  final items = ref.watch(roleNotificationsProvider(role)).value ?? const <NotificationItem>[];
  final read = ref.watch(notificationReadProvider);
  return items.where((n) => !read.contains(n.id)).length;
});
