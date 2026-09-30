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
/// the prototype hard-coded the owner as "ali"), with its Player profile when
/// the account has one (one account, both roles).
final clubMembersProvider = FutureProvider<List<ClubMember>>((ref) async {
  final club = ref.watch(currentClubProvider);
  final account = ref.watch(currentAccountProvider);
  if (club == null) return const [];
  final members = await ref.read(clubRepositoryProvider).members(club.id);
  final profile = account?.playerProfile;
  final plays = profile?.isComplete ?? false;
  return [
    for (final m in members)
      if (m.role == MemberRole.owner && account != null)
        ClubMember(
          id: m.id,
          name: account.fullName,
          phone: account.phone ?? m.phone,
          role: m.role,
          playingRole: plays ? profile!.role : null,
          isWicketkeeper: plays && profile!.isWicketkeeper,
          battingStyle: plays ? profile!.battingStyle : null,
          bowlingStyle: plays ? profile!.bowlingStyle : null,
        )
      else
        m,
  ];
});

/// One member by id (Member Profile).
final clubMemberProvider = Provider.family<ClubMember?, String>(
  (ref, id) => ref.watch(clubMembersProvider).value?.where((m) => m.id == id).firstOrNull,
);

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

/// Members role chips: playing roles (Wicket Keeper is its own option).
enum MemberRoleFilter {
  batsman('Batsman'),
  bowler('Bowler'),
  allRounder('All-Rounder'),
  wicketKeeper('Wicket Keeper');

  const MemberRoleFilter(this.label);
  final String label;

  bool matches(ClubMember m) => switch (this) {
        MemberRoleFilter.batsman => m.playingRole == PlayerRole.batsman,
        MemberRoleFilter.bowler => m.playingRole == PlayerRole.bowler,
        MemberRoleFilter.allRounder => m.playingRole == PlayerRole.allRounder,
        MemberRoleFilter.wicketKeeper => m.isWicketkeeper,
      };
}

enum MemberSort {
  name('Name'),
  fitnessHigh('Fitness: high to low'),
  fitnessLow('Fitness: low to high');

  const MemberSort(this.label);
  final String label;
}

/// Players filter (roles and fitness levels are OR within a group, AND
/// across groups). Staff are listed separately and hidden while filtering.
class MemberFilter {
  const MemberFilter({this.roles = const {}, this.levels = const {}, this.sort = MemberSort.name});
  final Set<MemberRoleFilter> roles;
  final Set<FitnessLevel> levels;
  final MemberSort sort;

  bool get narrows => roles.isNotEmpty || levels.isNotEmpty;

  /// Badge on the filter button: what the panel sets (the role is already
  /// visible in the chips at the top of the screen).
  int get activeCount => levels.length + (sort == MemberSort.name ? 0 : 1);

  bool accepts(ClubMember m, FitnessLevel? level) =>
      (roles.isEmpty || roles.any((r) => r.matches(m))) && (levels.isEmpty || (level != null && levels.contains(level)));

  MemberFilter copyWith({Set<MemberRoleFilter>? roles, Set<FitnessLevel>? levels, MemberSort? sort}) =>
      MemberFilter(roles: roles ?? this.roles, levels: levels ?? this.levels, sort: sort ?? this.sort);
}

final memberFilterProvider =
    NotifierProvider<SelectionController<MemberFilter>, MemberFilter>(() => SelectionController(const MemberFilter()));

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
