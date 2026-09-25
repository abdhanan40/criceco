import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../core/models/models.dart';
import '../../../shared/state/selection_controller.dart';
import '../../player/player_providers.dart';

// ---------------------------------------------------------------------------
// Find Players: the requirement being written (prototype `newHunt`) — kept
// for the session, so switching tabs doesn't lose it.
// ---------------------------------------------------------------------------

class HuntDraft {
  const HuntDraft({
    this.role,
    this.format = MatchFormat.t20,
    this.playersNeeded = PlayerHuntPost.minPlayers,
    this.location,
    this.date,
    this.time,
    this.budget = HuntBudget.any,
  });
  final HuntRole? role;
  final MatchFormat format;
  final int playersNeeded;
  final String? location; // null = All
  final DateTime? date; // null = Flexible
  final String? time; // "14:00"; null = Anytime
  final HuntBudget budget;

  HuntDraft copyWith({
    HuntRole? role,
    MatchFormat? format,
    int? playersNeeded,
    String? Function()? location,
    DateTime? Function()? date,
    String? Function()? time,
    HuntBudget? budget,
  }) =>
      HuntDraft(
        role: role ?? this.role,
        format: format ?? this.format,
        playersNeeded: playersNeeded ?? this.playersNeeded,
        location: location == null ? this.location : location(),
        date: date == null ? this.date : date(),
        time: time == null ? this.time : time(),
        budget: budget ?? this.budget,
      );
}

class HuntDraftController extends Notifier<HuntDraft> {
  @override
  HuntDraft build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return const HuntDraft();
  }

  void set(HuntDraft d) => state = d;

  /// Players Needed stepper, clamped to 1–11 (prototype `huntPlayersStep`).
  void step(int delta) => state = state.copyWith(
      playersNeeded: (state.playersNeeded + delta).clamp(PlayerHuntPost.minPlayers, PlayerHuntPost.maxPlayers));

  void reset() => state = const HuntDraft();
}

final huntDraftProvider = NotifierProvider<HuntDraftController, HuntDraft>(HuntDraftController.new);

// ---------------------------------------------------------------------------
// Published requirements (shared with the Player's Open Matches)
// ---------------------------------------------------------------------------

String _initials(String name) =>
    name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase()).take(2).join();

class PlayerHuntController extends AsyncNotifier<List<PlayerHuntPost>> {
  @override
  Future<List<PlayerHuntPost>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return ref.read(huntRepositoryProvider).posts();
  }

  /// "Post Player Requirement". Returns an error message, or `null` once
  /// posted (players see it in Open Matches straight away).
  Future<String?> publish(HuntDraft d) async {
    if (d.role == null) return 'Please select the role you need';
    final club = ref.read(currentClubProvider);
    if (club == null) return 'Only a club owner can post a requirement';
    await future;
    final now = ref.read(clockProvider).now();
    final post = await ref.read(huntRepositoryProvider).publish(PlayerHuntPost(
          id: 'hunt_${now.microsecondsSinceEpoch}_${state.value?.length ?? 0}',
          clubId: club.id,
          clubName: club.displayShortName,
          clubAbbr: _initials(club.displayShortName),
          role: d.role!,
          format: d.format,
          playersNeeded: d.playersNeeded,
          location: d.location,
          date: d.date,
          time: d.time,
          budget: d.budget,
        ));
    state = AsyncData([post, ...?state.value]);
    ref.invalidate(huntPostsProvider);
    return null;
  }

  /// "Remove Slot" — only the owner's own posts.
  Future<void> remove(String postId) async {
    final clubId = ref.read(currentClubProvider)?.id;
    final post = state.value?.where((p) => p.id == postId).firstOrNull;
    if (post == null || post.clubId != clubId) return;
    await ref.read(huntRepositoryProvider).remove(postId);
    state = AsyncData([for (final p in state.value ?? const <PlayerHuntPost>[]) if (p.id != postId) p]);
    ref.invalidate(huntPostsProvider);
  }
}

final playerHuntProvider = AsyncNotifierProvider<PlayerHuntController, List<PlayerHuntPost>>(PlayerHuntController.new);

/// "Your Published Slots": the owner's own club posts, newest first.
final myHuntPostsProvider = Provider<List<PlayerHuntPost>>((ref) {
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  return [for (final p in ref.watch(playerHuntProvider).value ?? const <PlayerHuntPost>[]) if (p.clubId == clubId) p];
});

// ---------------------------------------------------------------------------
// Available Players
// ---------------------------------------------------------------------------

/// Players listed as available. The signed-in player appears only while
/// listed ("open to offers") AND their Privacy → Public profile is on.
final openPlayersProvider = FutureProvider<List<OpenPlayer>>((ref) async {
  ref.watch(playerAvailabilityProvider.select((a) => a.openToOffers));
  final public = ref.watch(currentAccountProvider.select((a) => a?.settings.publicProfile ?? true));
  final all = await ref.read(huntRepositoryProvider).openPlayers();
  return [for (final p in all) if (!p.isMe || public) p];
});

/// City options, in listing order (prototype `openPlayersCities`).
final openPlayerCitiesProvider = Provider<List<String>>((ref) {
  return {for (final p in ref.watch(openPlayersProvider).value ?? const <OpenPlayer>[]) p.city}.toList();
});

/// Filters are remembered like the prototype's globals.
final openPlayersCityProvider = NotifierProvider<SelectionController<String?>, String?>(() => SelectionController(null));
final openPlayersRoleProvider =
    NotifierProvider<SelectionController<HuntRole?>, HuntRole?>(() => SelectionController(null));

/// Players invited this session ("Invite" → "Invited", never sent twice).
class InvitedPlayersController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return const {};
  }

  /// `false` when already invited.
  bool invite(String playerId) {
    if (state.contains(playerId)) return false;
    state = {...state, playerId};
    return true;
  }
}

final invitedPlayersProvider = NotifierProvider<InvitedPlayersController, Set<String>>(InvitedPlayersController.new);
