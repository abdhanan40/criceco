import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../core/utils/ranked_search.dart';
import '../../demo/demo_stats.dart';
import '../../shared/state/selection_controller.dart';
import '../matches/club_matches_controller.dart';

// ---------------------------------------------------------------------------
// Club Owner read models (dashboard, My Club, Members)
// ---------------------------------------------------------------------------

/// The owner's club members. The Owner row shows the signed-in account (fix:
/// the prototype hard-coded the owner as "ali").
final clubMembersProvider = FutureProvider<List<ClubMember>>((ref) async {
  final club = ref.watch(currentClubProvider);
  final account = ref.watch(currentAccountProvider);
  if (club == null) return const [];
  final members = await ref.read(clubRepositoryProvider).members(club.id);
  return [
    for (final m in members)
      if (m.role == MemberRole.owner && account != null)
        ClubMember(id: m.id, name: account.fullName, phone: account.phone ?? m.phone, role: m.role)
      else
        m,
  ];
});

/// Pending requests to join the club (dashboard count; the Requests screen
/// itself is migrated later).
final clubJoinRequestsProvider = FutureProvider<List<JoinRequest>>((ref) async {
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null) return const [];
  return ref.read(clubRepositoryProvider).joinRequests(clubId);
});

/// Other clubs by id (opponent names, badges).
final clubDirectoryProvider = FutureProvider<Map<String, ClubSummary>>((ref) async {
  final clubs = await ref.read(clubRepositoryProvider).otherClubs();
  return {for (final c in clubs) c.id: c};
});

/// Grounds by id (next-match ground row + Directions).
final groundDirectoryProvider = FutureProvider<Map<String, Ground>>((ref) async {
  final grounds = await ref.read(groundRepositoryProvider).grounds();
  return {for (final g in grounds) g.id: g};
});

/// Confirmed matches that have not started yet, soonest first.
final upcomingClubMatchesProvider = Provider<List<ClubMatch>>((ref) {
  final now = ref.read(clockProvider).now();
  final list = (ref.watch(clubMatchesProvider).value ?? const <ClubMatch>[])
      .where((m) => m.status == MatchStatus.confirmed && m.startsAt != null && m.startsAt!.isAfter(now))
      .toList()
    ..sort((a, b) => a.startsAt!.compareTo(b.startsAt!));
  return list;
});

/// Dashboard "Next Match": the soonest confirmed match.
final nextClubMatchProvider = Provider<ClubMatch?>((ref) => ref.watch(upcomingClubMatchesProvider).firstOrNull);

// ---------------------------------------------------------------------------
// Members search (the prototype's static box becomes a real input)
// ---------------------------------------------------------------------------

final membersQueryProvider = NotifierProvider<SelectionController<String>, String>(() => SelectionController(''));

/// Ranked search: name (primary), phone (secondary).
final visibleMembersProvider = Provider<List<ClubMember>>((ref) {
  final members = ref.watch(clubMembersProvider).value ?? const <ClubMember>[];
  return rankedSearch(
    members,
    ref.watch(membersQueryProvider),
    fields: [SearchField((m) => m.name), SearchField((m) => m.phone, weight: 1)],
  );
});

// ---------------------------------------------------------------------------
// Squad filters (per team) and scouting stats
// ---------------------------------------------------------------------------

/// Team Squad filter chip (`null` = All). Reset to All when a team is opened.
final teamSquadFilterProvider =
    NotifierProvider.family<SelectionController<SquadCategory?>, SquadCategory?, String>(
        (_) => SelectionController<SquadCategory?>(null));

/// Add Players filter chip (`null` = All). Reset to All when Add Players opens.
final addPlayersFilterProvider =
    NotifierProvider.family<SelectionController<SquadCategory?>, SquadCategory?, String>(
        (_) => SelectionController<SquadCategory?>(null));

/// Scouting stats for a pool player (Add Players rows + Stats sheet). Demo
/// generator for now; a repository call later without screen changes.
/// Keyed by a value record (name, position, availability) so lookups are
/// stable across pool reloads.
final squadPlayerStatsProvider = Provider.family<PlayerStats, (String, String, PlayerAvailability)>(
  (ref, key) => DemoStats.forPlayer(key.$1, position: key.$2, availability: key.$3),
);

PlayerStats readSquadPlayerStats(WidgetRef ref, SquadPlayer p) =>
    ref.watch(squadPlayerStatsProvider((p.name, p.position, p.availability)));
