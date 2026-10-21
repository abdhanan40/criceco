import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/city_areas.dart';
import '../../core/models/models.dart';
import '../../data/mock/in_memory_repositories.dart';
import '../../data/repositories/repositories.dart';
import '../../demo/demo_stats.dart';
import '../../demo/seed_data.dart';

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
final accountRepositoryProvider =
    Provider<AccountRepository>((ref) => InMemoryAccountRepository(ref.watch(seedDataProvider)));
final clubRepositoryProvider = Provider<ClubRepository>((ref) => InMemoryClubRepository(ref.watch(seedDataProvider)));
final teamRepositoryProvider = Provider<TeamRepository>((ref) => InMemoryTeamRepository(ref.watch(seedDataProvider)));
final matchRepositoryProvider =
    Provider<MatchRepository>((ref) => InMemoryMatchRepository(ref.watch(seedDataProvider)));
final groundRepositoryProvider =
    Provider<GroundRepository>((ref) => InMemoryGroundRepository(ref.watch(seedDataProvider)));
final reservationRepositoryProvider =
    Provider<ReservationRepository>((ref) => InMemoryReservationRepository(ref.watch(seedDataProvider)));
final walletRepositoryProvider = Provider<WalletRepository>((ref) => InMemoryWalletRepository());
final challengeRepositoryProvider =
    Provider<ChallengeRepository>((ref) => InMemoryChallengeRepository(ref.watch(seedDataProvider)));
final huntRepositoryProvider = Provider<HuntRepository>((ref) => InMemoryHuntRepository(ref.watch(seedDataProvider)));
final tournamentRepositoryProvider =
    Provider<TournamentRepository>((ref) => InMemoryTournamentRepository(ref.watch(seedDataProvider)));
final notificationRepositoryProvider =
    Provider<NotificationRepository>((ref) => InMemoryNotificationRepository(ref.watch(seedDataProvider)));
final announcementRepositoryProvider =
    Provider<AnnouncementRepository>((ref) => InMemoryAnnouncementRepository());

/// Scouting stats per player name. Backed by the demo generator for now;
/// swap for a repository call when a backend exists (screens don't change).
final playerStatsProvider = Provider.family<PlayerStats, String>((ref, name) => DemoStats.forPlayer(name));
