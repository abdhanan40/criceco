import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/demo_mode.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../demo/demo_challenge_responder.dart';
import '../club/club_providers.dart';
import '../matches/club_matches_controller.dart';

/// Every city in the prototype's `pakistanCities` (Create Availability Slot).
const kPakistanCities = [
  'Karachi', 'Lahore', 'Islamabad', 'Rawalpindi', 'Faisalabad', 'Multan', 'Peshawar', 'Quetta', 'Sialkot',
  'Hyderabad', 'Gujranwala', 'Sargodha', 'Bahawalpur', 'Sukkur', 'Larkana', 'Abbottabad', 'Mardan', 'Sahiwal',
  'Gujrat', 'Rahim Yar Khan',
];

/// Challenges (sent and received), keyed by id. Status is fully modelled:
/// pending → accepted / declined / expired (revised architecture §11).
class ChallengesController extends AsyncNotifier<List<Challenge>> {
  @override
  Future<List<Challenge>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    final repo = ref.read(challengeRepositoryProvider);
    final now = ref.read(clockProvider).now();
    final list = await repo.challenges();
    // Persist expiry for pending challenges whose deadline has passed.
    return [
      for (final c in list)
        if (c.isPending && c.statusAt(now) == ChallengeStatus.expired)
          await repo.save(c.copyWith(status: ChallengeStatus.expired))
        else
          c,
    ];
  }

  DateTime get _now => ref.read(clockProvider).now();

  Challenge? byId(String id) => state.value?.where((c) => c.id == id).firstOrNull;

  void _put(Challenge c) {
    final list = [...?state.value];
    final i = list.indexWhere((x) => x.id == c.id);
    i == -1 ? list.add(c) : list[i] = c;
    state = AsyncData(list);
  }

  /// Send a challenge. It is always created PENDING; in Demo Mode the
  /// opponent then accepts instantly (the approved prototype flow).
  Future<Challenge> send(String opponentClubId, {MatchFormat? format}) async {
    final sent =
        await ref.read(challengeRepositoryProvider).send(opponentClubId: opponentClubId, format: format, at: _now);
    _put(sent);
    if (ref.read(demoModeProvider)) {
      return await const DemoChallengeResponder().respond(sent, accept) ?? sent;
    }
    return sent;
  }

  /// Accept (a received challenge, or the opponent's reply to a sent one).
  /// Creates exactly ONE pending club match — never a duplicate.
  Future<Challenge?> accept(String challengeId) async {
    final c = await _openOrExpired(challengeId);
    if (c == null || !c.isPending) return c;
    var matchId = c.matchId;
    if (matchId == null) {
      final club = (await ref.read(clubDirectoryProvider.future))[c.opponentClubId];
      final match = await ref.read(clubMatchesProvider.notifier).createPending(
            opponentClubId: c.opponentClubId,
            format: c.format ?? club?.preferredFormat,
            city: club?.city,
          );
      matchId = match.id;
    }
    final accepted = await ref
        .read(challengeRepositoryProvider)
        .save(c.copyWith(status: ChallengeStatus.accepted, matchId: matchId, isNew: false, respondedAt: _now));
    _put(accepted);
    return accepted;
  }

  Future<Challenge?> decline(String challengeId) async {
    final c = await _openOrExpired(challengeId);
    if (c == null || !c.isPending) return c;
    final declined = await ref
        .read(challengeRepositoryProvider)
        .save(c.copyWith(status: ChallengeStatus.declined, isNew: false, respondedAt: _now));
    _put(declined);
    return declined;
  }

  /// The challenge if it can still be answered; an overdue one is saved as
  /// expired and returned so the caller can say so.
  Future<Challenge?> _openOrExpired(String id) async {
    final c = byId(id);
    if (c == null || !c.isPending) return c;
    if (c.statusAt(_now) == ChallengeStatus.expired) {
      final expired = await ref.read(challengeRepositoryProvider).save(c.copyWith(status: ChallengeStatus.expired));
      _put(expired);
      return expired;
    }
    return c;
  }
}

final challengesProvider = AsyncNotifierProvider<ChallengesController, List<Challenge>>(ChallengesController.new);

/// Selected challenge — typed lookup by route id.
final challengeProvider = Provider.family<Challenge?, String>(
  (ref, id) => ref.watch(challengesProvider).value?.where((c) => c.id == id).firstOrNull,
);

/// My Challenges sections.
class MyChallengeSections {
  const MyChallengeSections({required this.awaitingDecision, required this.sent, required this.resolved});
  final List<Challenge> awaitingDecision; // received + pending
  final List<Challenge> sent; // sent + pending (Demo OFF, approved P9)
  final List<Challenge> resolved; // accepted / declined / expired, newest first
}

final myChallengeSectionsProvider = Provider<MyChallengeSections>((ref) {
  final now = ref.read(clockProvider).now();
  final all = ref.watch(challengesProvider).value ?? const <Challenge>[];
  bool open(Challenge c) => c.statusAt(now) == ChallengeStatus.pending;
  DateTime key(Challenge c) => c.respondedAt ?? c.proposedAt ?? c.createdAt;
  return MyChallengeSections(
    awaitingDecision: all.where((c) => c.direction == ChallengeDirection.received && open(c)).toList(),
    sent: all.where((c) => c.direction == ChallengeDirection.sent && open(c)).toList(),
    resolved: all.where((c) => !open(c)).toList()..sort((a, b) => key(b).compareTo(key(a))),
  );
});

/// Clubs with a sent challenge still awaiting a reply (their Challenge
/// buttons show "Challenge Sent" instead of sending a duplicate).
final pendingSentClubIdsProvider = Provider<Set<String>>((ref) {
  return {for (final c in ref.watch(myChallengeSectionsProvider).sent) c.opponentClubId};
});

/// Challenges hub list (prototype: KK, IU, RR, FW).
final challengeableClubsProvider = FutureProvider<List<ClubSummary>>((ref) async {
  final ids = await ref.read(challengeRepositoryProvider).challengeableClubIds();
  final dir = await ref.watch(clubDirectoryProvider.future);
  return [for (final id in ids) if (dir[id] != null) dir[id]!];
});

/// Find Match "Teams Looking for Opponents". The section count is derived
/// (fix: the prototype said "5 Teams" but listed 2).
final matchSeekersProvider = FutureProvider<List<MatchSeekerListing>>((ref) {
  return ref.read(challengeRepositoryProvider).matchSeekers();
});

// ---------------------------------------------------------------------------
// Availability slots (Create Availability Slot)
// ---------------------------------------------------------------------------

class AvailabilitySlotsController extends AsyncNotifier<List<AvailabilitySlot>> {
  @override
  Future<List<AvailabilitySlot>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return ref.read(challengeRepositoryProvider).availabilitySlots();
  }

  Future<AvailabilitySlot> post(AvailabilitySlot slot) async {
    final saved = await ref.read(challengeRepositoryProvider).postAvailabilitySlot(slot);
    state = AsyncData([...?state.value, saved]);
    return saved;
  }

  Future<void> remove(String slotId) async {
    await ref.read(challengeRepositoryProvider).removeAvailabilitySlot(slotId);
    state = AsyncData([for (final s in state.value ?? const <AvailabilitySlot>[]) if (s.id != slotId) s]);
  }
}

final availabilitySlotsProvider =
    AsyncNotifierProvider<AvailabilitySlotsController, List<AvailabilitySlot>>(AvailabilitySlotsController.new);
