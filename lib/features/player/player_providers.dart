import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../core/utils/ranked_search.dart';
import '../../demo/seed_data.dart';
import '../../shared/state/selection_controller.dart';

// ---------------------------------------------------------------------------
// Matches, scorecards, performance (read models)
// ---------------------------------------------------------------------------

/// All of the player's matches. Re-fetched when the signed-in account changes.
final playerMatchesProvider = FutureProvider<List<PlayerMatch>>((ref) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  final list = await ref.read(matchRepositoryProvider).playerMatches();
  return [...list]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
});

/// Selected match — typed lookup by route id.
final playerMatchProvider = Provider.family<PlayerMatch?, String>((ref, id) {
  return ref.watch(playerMatchesProvider).value?.where((m) => m.id == id).firstOrNull;
});

/// Matches for one tab (Upcoming / Past / Cancelled). Upcoming: soonest
/// first; Past and Cancelled: most recent first.
final playerMatchesByStatusProvider = Provider.family<List<PlayerMatch>, PlayerMatchStatus>((ref, status) {
  final all = ref.watch(playerMatchesProvider).value ?? const <PlayerMatch>[];
  final list = all.where((m) => m.status == status).toList();
  if (status != PlayerMatchStatus.upcoming) list.sort((a, b) => b.startsAt.compareTo(a.startsAt));
  return list;
});

/// The next upcoming match (dashboard "Next Match" and "View Match Details").
final nextPlayerMatchProvider = Provider<PlayerMatch?>((ref) {
  final upcoming = ref.watch(playerMatchesByStatusProvider(PlayerMatchStatus.upcoming));
  return upcoming.isEmpty ? null : upcoming.first;
});

final scorecardProvider = FutureProvider.family<Scorecard?, String>((ref, scorecardId) {
  return ref.read(matchRepositoryProvider).scorecard(scorecardId);
});

/// The signed-in player's own career / performance summary — the ONE source
/// for the Dashboard stats, My Performance and My Profile's Career cells, so
/// they can never disagree. Keyed by the account (never by the editable
/// name), so renaming yourself doesn't change your statistics.
final performanceProvider = FutureProvider<PerformanceSummary>((ref) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  return ref.read(matchRepositoryProvider).performance();
});

/// Rating wording for the dashboard stat card.
String ratingLabel(String rating) {
  final r = double.tryParse(rating) ?? 0;
  if (r >= 8) return 'Very Good';
  if (r >= 7) return 'Good';
  if (r >= 6) return 'Average';
  return 'Developing';
}

// ---------------------------------------------------------------------------
// Availability — single source of truth (dashboard pill + Availability screen)
// ---------------------------------------------------------------------------

class PlayerAvailabilityController extends Notifier<PlayerAvailabilityRecord> {
  @override
  PlayerAvailabilityRecord build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    // Prototype seed: Available since 12 Apr 2025.
    return PlayerAvailabilityRecord(status: PlayerAvailability.available, since: DateTime(2025, 4, 12));
  }

  DateTime get _now => ref.read(clockProvider).now();

  /// "Update Availability".
  void update({
    required PlayerAvailability status,
    AvailabilityReason? reason,
    AvailabilityUntil until = AvailabilityUntil.custom,
    DateTime? untilDate,
    String notes = '',
  }) {
    final available = status == PlayerAvailability.available;
    state = PlayerAvailabilityRecord(
      status: status,
      since: _now,
      reason: available ? null : reason,
      until: until,
      untilDate: available ? null : untilDate,
      notes: notes,
      openToOffers: state.openToOffers,
    );
  }

  /// Dashboard pill: Available ↔ Unavailable on the same record.
  void toggleQuick() => update(
        status: state.status == PlayerAvailability.available ? PlayerAvailability.unavailable : PlayerAvailability.available,
      );

  /// "List me as available to other clubs" (Open Matches + Availability).
  /// Lists the player in clubs' Available Players using the account city
  /// (fix: the prototype used an empty city, so the player never appeared).
  Future<void> setOpenToOffers(bool listed) async {
    final account = ref.read(currentAccountProvider);
    state = state.copyWith(openToOffers: listed);
    final role = switch (account?.playerProfile.role) {
      PlayerRole.bowler => HuntRole.bowler,
      PlayerRole.allRounder => HuntRole.allRounder,
      _ => HuntRole.batsman,
    };
    await ref.read(huntRepositoryProvider).setListed(
          OpenPlayer(
            id: 'op_me',
            name: account?.fullName ?? 'You',
            role: role,
            availabilityLabel: 'Available Now',
            city: account?.city ?? 'Islamabad',
            isMe: true,
          ),
          listed: listed,
        );
  }
}

final playerAvailabilityProvider =
    NotifierProvider<PlayerAvailabilityController, PlayerAvailabilityRecord>(PlayerAvailabilityController.new);

// ---------------------------------------------------------------------------
// Open Matches — club requirement posts + the player's interest
// ---------------------------------------------------------------------------

final huntPostsProvider = FutureProvider<List<PlayerHuntPost>>((ref) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  return ref.read(huntRepositoryProvider).posts();
});

/// Posts the player has tapped "I'm Interested" on (session feature state).
class HuntInterestController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return const {};
  }

  void express(String postId) => state = {...state, postId};
}

final huntInterestProvider = NotifierProvider<HuntInterestController, Set<String>>(HuntInterestController.new);

// ---------------------------------------------------------------------------
// Player's club (membership or the prototype's demo club)
// ---------------------------------------------------------------------------

class PlayerClubInfo {
  const PlayerClubInfo({required this.code, required this.city, required this.established, this.name});
  final String code;
  final String city;
  final int established;
  final String? name;
}

/// Prototype: "Club KRC001 • Islamabad", "EST. 2023" unless the player joined
/// a club, in which case the membership's code is shown.
final playerClubProvider = Provider<PlayerClubInfo>((ref) {
  final m = ref.watch(currentAccountProvider)?.memberships.firstOrNull;
  return PlayerClubInfo(
    code: m?.clubCode ?? SeedData.demoJoinCode,
    name: m?.clubName,
    city: 'Islamabad',
    established: 2023,
  );
});

// ---------------------------------------------------------------------------
// Performance screen selections (kept across tab switches, like the prototype)
// ---------------------------------------------------------------------------

enum PerformanceTab {
  batting('Batting', 'circle-dot'),
  bowling('Bowling', 'target'),
  fielding('Fielding', 'hand');

  const PerformanceTab(this.label, this.icon);
  final String label;
  final String icon;
}

enum HistoryFilter {
  all('All'),
  won('Won'),
  lost('Lost');

  const HistoryFilter(this.label);
  final String label;

  bool matches(MatchResult r) => switch (this) {
        HistoryFilter.all => true,
        HistoryFilter.won => r == MatchResult.won,
        HistoryFilter.lost => r == MatchResult.lost,
      };
}

/// What the History chart plots per match (both from the match log).
enum TrendMetric {
  runs('Runs'),
  wickets('Wickets');

  const TrendMetric(this.label);
  final String label;

  int of(MatchLogEntry m) => this == runs ? m.runs : m.wickets;
}

final performanceTabProvider =
    NotifierProvider<SelectionController<PerformanceTab>, PerformanceTab>(() => SelectionController(PerformanceTab.batting));
final historyFilterProvider =
    NotifierProvider<SelectionController<HistoryFilter>, HistoryFilter>(() => SelectionController(HistoryFilter.all));
final trendMetricProvider =
    NotifierProvider<SelectionController<TrendMetric>, TrendMetric>(() => SelectionController(TrendMetric.runs));

/// Open Matches role filter (`null` = "All": nothing listed until a role is
/// picked, as in the prototype) and search query.
final openMatchesRoleProvider =
    NotifierProvider<SelectionController<HuntRole?>, HuntRole?>(() => SelectionController<HuntRole?>(null));
final openMatchesQueryProvider = NotifierProvider<SelectionController<String>, String>(() => SelectionController(''));

/// Visible Open Matches posts: role filter, then ranked search over club
/// name (primary) and location (secondary).
final visibleHuntPostsProvider = Provider<List<PlayerHuntPost>>((ref) {
  final role = ref.watch(openMatchesRoleProvider);
  if (role == null) return const [];
  final posts = ref.watch(huntPostsProvider).value ?? const <PlayerHuntPost>[];
  return rankedSearch(
    posts.where((p) => p.role == role),
    ref.watch(openMatchesQueryProvider),
    fields: [SearchField((p) => p.clubName), SearchField((p) => p.location, weight: 1)],
  );
});
