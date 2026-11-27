import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config/backend_modules.dart';
import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../core/models/models.dart';
import '../../../data/repositories/repositories.dart' show AccountException;
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
    // The server (M8): the owner's own club's posts that are still open.
    if (ref.watch(huntBackendLiveProvider)) {
      final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
      if (clubId == null) return const [];
      return [for (final p in await ref.read(huntRepositoryProvider).clubPosts(clubId)) if (p.isOpen) p];
    }
    return ref.read(huntRepositoryProvider).posts();
  }

  /// "Post Player Requirement". Returns an error message, or `null` once
  /// posted (players see it in Open Matches straight away).
  Future<String?> publish(HuntDraft d) async {
    if (d.role == null) return 'Please select the role you need';
    final club = ref.read(currentClubProvider);
    if (club == null) return 'Only a club owner can post a requirement';
    final posts = await future;
    // The same open requirement twice is almost always a double post.
    final duplicate = posts.any((p) =>
        p.clubId == club.id &&
        p.role == d.role &&
        p.format == d.format &&
        p.playersNeeded == d.playersNeeded &&
        p.location == d.location &&
        p.date == d.date &&
        p.time == d.time &&
        p.budget == d.budget);
    if (duplicate) return 'You already have this requirement posted';
    final now = ref.read(clockProvider).now();
    final PlayerHuntPost post;
    try {
      post = await ref.read(huntRepositoryProvider).publish(PlayerHuntPost(
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
            isMyClub: true,
          ));
    } on AccountException catch (e) {
      // The server refused it (duplicate, the open / daily limits, a date…).
      return e.message;
    }
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

  /// Reloads the owner's posts (their interest counts).
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

/// Players interested in the owner's posts (M8, the server), newest first,
/// by post id. The demo has none (its interest stays on the player's device).
final huntInterestsProvider = FutureProvider<Map<String, List<HuntInterest>>>((ref) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null || !ref.watch(huntBackendLiveProvider)) return const {};
  final out = <String, List<HuntInterest>>{};
  for (final i in await ref.read(huntRepositoryProvider).clubInterests(clubId)) {
    (out[i.postId] ??= []).add(i);
  }
  return out;
});

/// The owner's club's invites that players accepted (M8): who to contact,
/// with the phone when they share it with clubs. None in the demo.
final acceptedHuntInvitesProvider = FutureProvider<List<ClubHuntInvite>>((ref) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null || !ref.watch(huntBackendLiveProvider)) return const [];
  final all = await ref.read(huntRepositoryProvider).clubInvites(clubId);
  return [for (final i in all) if (i.status == HuntInviteStatus.accepted) i];
});

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

/// Players the current club has invited ("Invite" → "Invited", never sent
/// twice). Stored through [HuntRepository] so the state belongs to the club
/// and survives rebuilds; delivery to the player is a backend concern — the
/// mock repository only records it (see [HuntRepository.invite]).
class InvitedPlayersController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
    return clubId == null ? const {} : ref.read(huntRepositoryProvider).invitedPlayerIds(clubId);
  }

  /// `false` when already invited (or there is no club to invite from).
  bool invite(String playerId) {
    final clubId = ref.read(currentClubProvider)?.id;
    if (clubId == null || state.contains(playerId)) return false;
    state = {...state, playerId};
    ref.read(huntRepositoryProvider).invite(clubId, playerId);
    return true;
  }

  final _sending = <String>{};

  /// "Invite": `null` once sent (the server tells the player), or why not —
  /// already invited, no longer available, the daily limit… The demo only
  /// records it ([invite]).
  Future<String?> send(String playerId) async {
    if (!ref.read(huntBackendLiveProvider)) {
      return invite(playerId) ? null : 'You already invited this player.';
    }
    final clubId = ref.read(currentClubProvider)?.id;
    if (clubId == null) return 'Only a club owner can invite players';
    if (state.contains(playerId)) return 'You already invited this player.';
    if (!_sending.add(playerId)) return null;
    try {
      await ref.read(huntRepositoryProvider).invite(clubId, playerId);
      if (ref.mounted) state = {...state, playerId};
      return null;
    } on AccountException catch (e) {
      return e.message;
    } finally {
      _sending.remove(playerId);
    }
  }
}

final invitedPlayersProvider = NotifierProvider<InvitedPlayersController, Set<String>>(InvitedPlayersController.new);
