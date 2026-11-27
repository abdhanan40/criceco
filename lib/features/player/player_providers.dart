import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../core/utils/ranked_search.dart';
import '../../data/repositories/repositories.dart' show AccountException;
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
    // The demo's prototype seed (available since 12 Apr 2025). Elsewhere
    // nothing is stored yet, so no invented date: "since" is now.
    if (ref.read(backendModulesProvider).isDemo) {
      return PlayerAvailabilityRecord(status: PlayerAvailability.available, since: DateTime(2025, 4, 12));
    }
    // The server's record (migration 19), once read: nothing stored there
    // means available.
    if (_live) Future.microtask(_load);
    // The Player Hunt listing the server keeps (M8, migration 33).
    if (_huntLive) Future.microtask(_loadListing);
    return PlayerAvailabilityRecord(status: PlayerAvailability.available, since: ref.read(clockProvider).now());
  }

  DateTime get _now => ref.read(clockProvider).now();

  /// The server keeps this record (Supabase with the matches switch).
  bool get _live => ref.read(matchesBackendLiveProvider);

  bool _saving = false;

  /// The server keeps the Player Hunt listing (Supabase with the Player
  /// Hunt switch).
  bool get _huntLive => ref.read(huntBackendLiveProvider);

  Future<void> _loadListing() async {
    try {
      final listing = await ref.read(huntRepositoryProvider).myListing();
      if (listing != null && ref.mounted) state = state.copyWith(openToOffers: listing.listed);
    } on AccountException {
      // Not readable now (offline, no profile yet…): shown as not listed.
    }
  }

  Future<void> _load() async {
    try {
      final saved = await ref.read(playerAvailabilityRepositoryProvider).mine();
      if (saved != null && ref.mounted) state = saved.copyWith(openToOffers: state.openToOffers);
    } on AccountException {
      // Not readable now (offline…): shown as available until the next read.
    }
  }

  /// "Update Availability". The demo saves at once; on the server the new
  /// record is shown once stored. Returns `null` when saved, or why not
  /// (the record then stays as it was). A second save while one is on its
  /// way is ignored.
  Future<String?> update({
    required PlayerAvailability status,
    AvailabilityReason? reason,
    AvailabilityUntil until = AvailabilityUntil.custom,
    DateTime? untilDate,
    String notes = '',
  }) async {
    final available = status == PlayerAvailability.available;
    final record = PlayerAvailabilityRecord(
      status: status,
      since: _now,
      reason: available ? null : reason,
      until: until,
      untilDate: available ? null : untilDate,
      notes: notes,
      openToOffers: state.openToOffers,
    );
    if (!_live) {
      state = record;
      return null;
    }
    if (_saving) return null;
    _saving = true;
    try {
      final saved = await ref.read(playerAvailabilityRepositoryProvider).setMine(record);
      // The server doesn't keep the "until" shortcut or the Player Hunt flag.
      state = saved.copyWith(until: until, openToOffers: state.openToOffers);
      return null;
    } on AccountException catch (e) {
      return e.message;
    } finally {
      _saving = false;
    }
  }

  /// Dashboard pill: Available ↔ Unavailable on the same record.
  Future<String?> toggleQuick() => update(
        status: state.status == PlayerAvailability.available ? PlayerAvailability.unavailable : PlayerAvailability.available,
      );

  /// "List me as available to other clubs" (Open Matches + Availability).
  /// Lists the player in clubs' Available Players using the account city
  /// (fix: the prototype used an empty city, so the player never appeared).
  ///
  /// Returns `null` once saved, or why not (on the server: no cricket
  /// profile, no city…); the switch then goes back.
  Future<String?> setOpenToOffers(bool listed) async {
    final account = ref.read(currentAccountProvider);
    final before = state.openToOffers;
    state = state.copyWith(openToOffers: listed);
    final profile = account?.playerProfile;
    final role = switch (profile?.role) {
      PlayerRole.bowler => HuntRole.bowler,
      PlayerRole.allRounder => HuntRole.allRounder,
      // The server lists a batsman who keeps wicket as a Wicket-Keeper.
      PlayerRole.batsman when _huntLive && (profile?.isWicketkeeper ?? false) => HuntRole.wicketKeeper,
      _ => HuntRole.batsman,
    };
    final city = account?.city?.trim() ?? '';
    try {
      await ref.read(huntRepositoryProvider).setListed(
            OpenPlayer(
              id: 'op_me',
              name: account?.fullName ?? 'You',
              role: role,
              availabilityLabel: 'Available Now',
              // The server falls back to the saved listing / current address.
              city: _huntLive ? city : (account?.city ?? 'Islamabad'),
              isMe: true,
            ),
            listed: listed,
          );
      return null;
    } on AccountException catch (e) {
      if (ref.mounted) state = state.copyWith(openToOffers: before);
      return e.message;
    }
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

/// Posts the player has tapped "I'm Interested" on: the demo keeps them for
/// the session; the server (M8) remembers them (`interested` on each post)
/// and tells the club's owner once.
class HuntInterestController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    if (!_live) return const {};
    return {
      for (final p in ref.watch(huntPostsProvider).value ?? const <PlayerHuntPost>[])
        if (p.interested) p.id,
    };
  }

  bool get _live => ref.read(huntBackendLiveProvider);
  final _busy = <String>{};

  /// "I'm Interested": `null` once recorded, or why not (the post closed,
  /// your own club's, the daily limit…).
  Future<String?> express(String postId) async {
    if (!_live) {
      state = {...state, postId};
      return null;
    }
    if (!_busy.add(postId)) return null;
    try {
      await ref.read(huntRepositoryProvider).expressInterest(postId);
      if (ref.mounted) state = {...state, postId};
      return null;
    } on AccountException catch (e) {
      return e.message;
    } finally {
      _busy.remove(postId);
    }
  }

  /// Takes the interest back (the server only; the club is not told).
  Future<String?> withdraw(String postId) async {
    if (!_live) {
      state = {...state}..remove(postId);
      return null;
    }
    if (!_busy.add(postId)) return null;
    try {
      await ref.read(huntRepositoryProvider).withdrawInterest(postId);
      if (ref.mounted) state = {...state}..remove(postId);
      return null;
    } on AccountException catch (e) {
      return e.message;
    } finally {
      _busy.remove(postId);
    }
  }
}

/// The signed-in player's Player Hunt invites (M8, the server), newest
/// first; none in the demo.
final myHuntInvitesProvider = FutureProvider<List<PlayerHuntInvite>>((ref) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  if (!ref.watch(huntBackendLiveProvider)) return const [];
  return ref.read(huntRepositoryProvider).myInvites();
});

/// The player answers an invite: `null` once saved, or why not. Accepting
/// tells the club the player is interested — it never joins the club.
Future<String?> respondToHuntInvite(WidgetRef ref, String inviteId, {required bool accept}) async {
  try {
    await ref.read(huntRepositoryProvider).respondInvite(inviteId, accept: accept);
    return null;
  } on AccountException catch (e) {
    return e.message;
  } finally {
    ref.invalidate(myHuntInvitesProvider);
  }
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
  // Supabase builds: the player's real club, or none — never the demo club.
  if (!ref.watch(backendModulesProvider).isDemo) {
    return PlayerClubInfo(code: m?.clubCode ?? 'No club yet', name: m?.clubName, city: '', established: 0);
  }
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
