import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/city_areas.dart';
import '../../core/models/models.dart';
import '../../data/mock/in_memory_location_repository.dart';
import '../../data/mock/in_memory_repositories.dart';
import '../../data/repositories/repositories.dart';
import '../../data/supabase/local_account_overlay.dart';
import '../../data/supabase/local_club_overlay.dart';
import '../../data/supabase/supabase_account_repository.dart';
import '../../data/supabase/supabase_availability_repository.dart';
import '../../data/supabase/supabase_challenge_repository.dart';
import '../../data/supabase/supabase_club_repository.dart';
import '../../data/supabase/supabase_gateways.dart';
import '../../data/supabase/supabase_location_repository.dart';
import '../../data/supabase/supabase_match_repository.dart';
import '../../data/supabase/supabase_ownership_repository.dart';
import '../../data/supabase/supabase_results_repository.dart';
import '../../data/supabase/supabase_team_repository.dart';
import '../../demo/demo_stats.dart';
import '../../demo/seed_data.dart';
import '../config/account_privacy.dart';
import '../config/auth_features.dart';
import '../config/auth_redirects.dart';
import '../config/backend_config.dart';
import '../config/backend_modules.dart';

/// Injectable time source. Tests override with a fixed/fake [Clock].
final clockProvider = Provider<Clock>((ref) => const Clock());

/// Emits the current time every second. Reservation countdowns and the
/// expiry watcher derive everything from `expiresAt - now`.
final nowProvider = StreamProvider<DateTime>((ref) {
  final clock = ref.watch(clockProvider);
  return Stream<DateTime>.periodic(const Duration(seconds: 1), (_) => clock.now());
});

/// Must be overridden in `main()` / tests with an initialised instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider must be overridden'),
);

final seedDataProvider = Provider<SeedData>((ref) => SeedData(ref.watch(clockProvider).now()));

/// City → areas for the Profile Setup Area picker (`assets/data/city_areas.json`).
/// A missing or unreadable file means no listed areas (typed Area field).
/// The file currently holds TEMPORARY DEMO areas (see [CityAreas]) — replace
/// with verified / backend data later; this provider is the one place to swap.
final cityAreasProvider = FutureProvider<CityAreas>((ref) async {
  try {
    return CityAreas.parse(await rootBundle.loadString('assets/data/city_areas.json'));
  } catch (_) {
    return CityAreas.empty;
  }
});

// ---- Repositories (in-memory mocks; replace with real implementations later) ----
/// The account and club repositories switch with the backend
/// (`CRICECO_BACKEND`); every other repository stays in-memory.
final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  final config = ref.watch(backendConfigProvider);
  return switch (config.mode) {
    // The email-codes switch (AUTH-02, OFF by default): demo email sign-ups
    // then wait for their 6-digit code.
    BackendMode.memory => InMemoryAccountRepository(
        ref.watch(seedDataProvider),
        requireEmailCode: ref.watch(emailCodesEnabledProvider),
        clock: ref.watch(clockProvider),
      ),
    // The gateway providers throw "not available yet" until Step 4 adds
    // supabase_flutter; tests override them with fakes.
    BackendMode.supabase => SupabaseAccountRepository(
        auth: ref.watch(authGatewayProvider),
        db: ref.watch(profileGatewayProvider),
        overlay: LocalAccountOverlay(ref.watch(sharedPreferencesProvider)),
        clock: ref.watch(clockProvider),
        authCallbackUrl: ref.watch(authCallbackUrlProvider),
        // Phone consent and account deletion on the server: only with the
        // account-privacy switch (migrations 13–14 and the Edge Function live).
        privacy: ref.watch(accountPrivacyEnabledProvider) ? ref.watch(accountPrivacyGatewayProvider) : null,
      ),
  };
});
/// Supabase mode: the owner's club is in `public.clubs`; members, join
/// requests and the squad pool come from a dedicated in-memory repository of
/// its own (keyed by the real club id), never the memory-mode instance.
final clubRepositoryProvider = Provider<ClubRepository>((ref) {
  final config = ref.watch(backendConfigProvider);
  return switch (config.mode) {
    BackendMode.memory => InMemoryClubRepository(ref.watch(seedDataProvider)),
    BackendMode.supabase => SupabaseClubRepository(
        auth: ref.watch(authGatewayProvider),
        db: ref.watch(clubGatewayProvider),
        overlay: LocalClubOverlay(ref.watch(sharedPreferencesProvider)),
        local: InMemoryClubRepository(ref.watch(seedDataProvider)),
        // Migration 11's functions, only with the memberships switch.
        membership: ref.watch(membershipsEnabledProvider) ? ref.watch(membershipGatewayProvider) : null,
        // Migration 17's opponent directory, only with the matches switch.
        matches: ref.watch(matchesBackendLiveProvider) ? ref.watch(matchGatewayProvider) : null,
        clock: ref.watch(clockProvider),
      ),
  };
});

// ---- Modules without a backend yet ----
// Memory mode: the demo's seeded data. Supabase mode: the same in-memory
// repositories but EMPTY — never seeded, never invented — and their screens
// say the module isn't available yet ([backendModulesProvider],
// docs/PRODUCTION_DEMO_MODE.md).
bool _demo(Ref ref) => !ref.watch(backendConfigProvider).isSupabase;

/// Supabase mode: migration 12 with the memberships switch; without it,
/// no teams at all (nothing session-only that would vanish on restart).
final teamRepositoryProvider = Provider<TeamRepository>((ref) {
  if (_demo(ref)) return InMemoryTeamRepository(ref.watch(seedDataProvider));
  return ref.watch(membershipsEnabledProvider)
      ? SupabaseTeamRepository(db: ref.watch(teamGatewayProvider))
      : const UnavailableTeamRepository();
});
/// Club ownership transfer: Supabase with migration 16 (the account-privacy
/// switch and memberships); elsewhere nothing is listed or changed.
final ownershipTransferRepositoryProvider = Provider<OwnershipTransferRepository>((ref) =>
    ref.watch(ownershipTransferAvailableProvider)
        ? SupabaseOwnershipTransferRepository(db: ref.watch(ownershipGatewayProvider))
        : const UnavailableOwnershipTransferRepository());
/// The signed-in owner's club id for the match functions (Supabase only).
final ownClubLookupProvider = Provider<OwnClubLookup>(
  (ref) => OwnClubLookup(auth: ref.watch(authGatewayProvider), clubs: ref.watch(clubGatewayProvider)),
);

/// Matches, challenges and player availability: the demo's seeded data in
/// memory mode; migrations 17–19 in Supabase mode with the memberships AND
/// matches switches ([matchesBackendLiveProvider]); otherwise empty / "not
/// available yet" — no network call is made for them then.
final matchRepositoryProvider = Provider<MatchRepository>((ref) {
  if (_demo(ref)) return InMemoryMatchRepository(ref.watch(seedDataProvider));
  return ref.watch(matchesBackendLiveProvider)
      ? SupabaseMatchRepository(
          db: ref.watch(matchGatewayProvider),
          ownClub: ref.watch(ownClubLookupProvider),
          // Official results (read-only), only with the results switch.
          results: ref.watch(resultsBackendLiveProvider) ? ref.watch(resultsRepositoryProvider) : null,
          clock: ref.watch(clockProvider),
        )
      : InMemoryMatchRepository.empty();
});
final groundRepositoryProvider = Provider<GroundRepository>(
    (ref) => _demo(ref) ? InMemoryGroundRepository(ref.watch(seedDataProvider)) : InMemoryGroundRepository.empty());
final reservationRepositoryProvider = Provider<ReservationRepository>((ref) =>
    _demo(ref) ? InMemoryReservationRepository(ref.watch(seedDataProvider)) : InMemoryReservationRepository.empty());
final walletRepositoryProvider =
    Provider<WalletRepository>((ref) => _demo(ref) ? InMemoryWalletRepository() : InMemoryWalletRepository.empty());
final challengeRepositoryProvider = Provider<ChallengeRepository>((ref) {
  if (_demo(ref)) {
    return InMemoryChallengeRepository(
      ref.watch(seedDataProvider),
      // accept() creates the match the way the server does (one per challenge).
      createMatch: (c) => ref.read(matchRepositoryProvider).createPendingMatch(opponentClubId: c.opponentClubId, format: c.format),
    );
  }
  return ref.watch(matchesBackendLiveProvider)
      ? SupabaseChallengeRepository(db: ref.watch(matchGatewayProvider), ownClub: ref.watch(ownClubLookupProvider))
      : InMemoryChallengeRepository.empty();
});

/// Match results, scorecards, statistics and the player's match list:
/// migrations 20–23 in Supabase mode with the memberships, matches AND
/// results switches ([resultsBackendLiveProvider]). Everywhere else — the
/// demo included, whose screens keep their own sample data — nothing is
/// listed and no network call is made for them.
final resultsRepositoryProvider = Provider<ResultsRepository>((ref) => ref.watch(resultsBackendLiveProvider)
    ? SupabaseResultsRepository(db: ref.watch(resultsGatewayProvider))
    : const UnavailableResultsRepository());

/// The signed-in person's availability and the owner's view of the club's.
final playerAvailabilityRepositoryProvider = Provider<PlayerAvailabilityRepository>((ref) {
  if (_demo(ref)) return InMemoryPlayerAvailabilityRepository();
  return ref.watch(matchesBackendLiveProvider)
      ? SupabaseAvailabilityRepository(db: ref.watch(matchGatewayProvider))
      : const UnavailablePlayerAvailabilityRepository();
});
final huntRepositoryProvider = Provider<HuntRepository>(
    (ref) => _demo(ref) ? InMemoryHuntRepository(ref.watch(seedDataProvider)) : InMemoryHuntRepository.empty());
final tournamentRepositoryProvider = Provider<TournamentRepository>((ref) =>
    _demo(ref) ? InMemoryTournamentRepository(ref.watch(seedDataProvider)) : InMemoryTournamentRepository.empty());
final notificationRepositoryProvider = Provider<NotificationRepository>((ref) =>
    _demo(ref) ? InMemoryNotificationRepository(ref.watch(seedDataProvider)) : InMemoryNotificationRepository.empty());
final announcementRepositoryProvider =
    Provider<AnnouncementRepository>((ref) => InMemoryAnnouncementRepository());

/// Location lookup (Stage 4.2). Supabase mode: the location tables of
/// migration 6 (read-only); memory mode: the 20 featured cities only. Not yet
/// used by any screen — the city pickers switch in Stage 4.3.
final locationRepositoryProvider = Provider<LocationRepository>((ref) {
  final config = ref.watch(backendConfigProvider);
  return switch (config.mode) {
    BackendMode.memory => InMemoryLocationRepository(),
    BackendMode.supabase => SupabaseLocationRepository(db: ref.watch(locationGatewayProvider)),
  };
});

/// Scouting stats per player name. Memory mode: the demo generator.
/// Supabase mode: no match statistics are stored yet, so nothing recorded
/// ([PlayerStats.unrecorded]) — never generated numbers.
final playerStatsProvider = Provider.family<PlayerStats, String>((ref, name) {
  if (_demo(ref)) return DemoStats.forPlayer(name);
  return PlayerStats.unrecorded(position: '—', category: SquadCategory.batsman);
});
