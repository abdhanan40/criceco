import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/config/demo_mode.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../../data/supabase/match_row_mapper.dart';
import '../../demo/demo_challenge_responder.dart';
import '../club/club_providers.dart';
import '../matches/club_matches_controller.dart';

/// Challenges (sent and received), keyed by id. Status is fully modelled:
/// pending → accepted / declined / expired (revised architecture §11).
/// A challenge that can't be sent; [message] says why.
class ChallengeBlockedException implements Exception {
  const ChallengeBlockedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `true` when challenges are the server's (Supabase with the matches
/// switch: migration 17); `false` in the demo, which keeps its own flow.
final challengesLiveProvider = Provider<bool>((ref) => !ref.watch(backendModulesProvider).isDemo);

/// Server challenges: the proposed date is a calendar date in Pakistan,
/// from tomorrow up to a year ahead (migration 17's rule).
abstract final class ChallengeRules {
  static const messageMax = 280;
  static const venueMax = 100;
  static const dateMessage = 'Please select a match date from tomorrow (Pakistan time), up to a year ahead.';

  static DateTime firstDate(DateTime now) {
    final today = MatchRowMapper.karachiDate(now);
    return DateTime(today.year, today.month, today.day + 1);
  }

  static DateTime lastDate(DateTime now) {
    final today = MatchRowMapper.karachiDate(now);
    return DateTime(today.year, today.month, today.day + 365);
  }

  /// `null` when [date] may be proposed at [now].
  static String? date(DateTime? date, DateTime now) {
    if (date == null) return 'Please pick a date';
    final day = DateTime(date.year, date.month, date.day);
    return day.isBefore(firstDate(now)) || day.isAfter(lastDate(now)) ? dateMessage : null;
  }

  /// What's wrong with a server challenge's details, or `null`.
  static String? problem({
    required MatchFormat? format,
    required int? customOvers,
    required DateTime? proposedAt,
    required String? venueName,
    required String? message,
    required DateTime now,
  }) {
    if (format == null) return 'Choose a match format.';
    if (format == MatchFormat.custom && (customOvers == null || customOvers < 1 || customOvers > 50)) {
      return 'Enter between 1 and 50 overs for a custom match.';
    }
    if (date(proposedAt, now) case final m?) return m;
    final venue = venueName?.trim() ?? '';
    if (venue.isEmpty) return 'Enter a venue.';
    if (venue.length > venueMax) return 'Keep the venue to $venueMax characters.';
    if ((message?.trim().length ?? 0) > messageMax) return 'Keep the message to $messageMax characters.';
    return null;
  }
}

/// An opponent as the challenge screens show it: the demo's club profile
/// (with its sample record) when there is one, otherwise — on the server —
/// only the public fields (name, short name, city, type). Never invented
/// statistics.
class ChallengeOpponent {
  const ChallengeOpponent({
    required this.id,
    required this.name,
    this.shortName,
    this.city,
    this.type,
    this.summary,
  });

  factory ChallengeOpponent.fromSummary(ClubSummary s) =>
      ChallengeOpponent(id: s.id, name: s.name, shortName: s.abbr, city: s.city, summary: s);

  factory ChallengeOpponent.fromEntry(ClubDirectoryEntry e, {ClubSummary? summary}) => summary != null
      ? ChallengeOpponent.fromSummary(summary)
      : ChallengeOpponent(id: e.id, name: e.name, shortName: e.shortName, city: e.city, type: e.type);

  /// A challenge's opponent: the demo profile, or the names the server sent
  /// with the challenge; `null` when neither is known.
  static ChallengeOpponent? forChallenge(Challenge c, ClubSummary? summary) {
    if (summary != null) return ChallengeOpponent.fromSummary(summary);
    final name = c.opponentName;
    if (name == null) return null;
    return ChallengeOpponent(id: c.opponentClubId, name: name, shortName: c.opponentShortName, city: c.opponentCity);
  }

  /// The club behind an open slot (M7): its profile when known, else the
  /// public name and city the server sent with the slot.
  factory ChallengeOpponent.forSeeker(MatchSeekerListing s, ClubSummary? summary) => summary != null
      ? ChallengeOpponent.fromSummary(summary)
      : ChallengeOpponent(id: s.clubId, name: s.clubName ?? 'Club', shortName: s.clubShortName, city: s.clubCity);

  final String id;
  final String name;
  final String? shortName;
  final String? city;
  final ClubType? type;

  /// The demo's club profile (record, formats, home ground); `null` on the server.
  final ClubSummary? summary;

  /// Badge letters: the demo's abbreviation, the short name, or initials.
  String get abbr {
    if (summary != null) return summary!.abbr;
    final s = shortName?.trim() ?? '';
    if (s.isNotEmpty && s.length <= 4) return s.toUpperCase();
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    return words.take(2).map((w) => String.fromCharCode(w.runes.first).toUpperCase()).join();
  }

  /// The card's second line: the demo's city and record, or the public
  /// city and club type.
  String get meta => summary != null
      ? '${summary!.city} · W${summary!.wins}, L${summary!.losses}'
      : [?city, ?type?.label].join(' · ');
}

/// Opponent search (Find Opponent / Challenges tab): [search] in name or
/// short name, exact [city]; both trimmed, empty = no filter.
typedef OpponentQuery = ({String search, String city});

/// Other clubs from `ClubRepository.searchOpponents()` (the server's
/// directory, or the demo's clubs), never the user's own club. One request
/// per distinct query while it's shown (Riverpod caches it by value).
final opponentDirectoryProvider = FutureProvider.autoDispose.family<List<ChallengeOpponent>, OpponentQuery>((ref, q) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  final own = ref.watch(currentClubProvider.select((c) => c?.id));
  final entries = await ref.read(clubRepositoryProvider).searchOpponents(
        search: q.search.trim().isEmpty ? null : q.search.trim(),
        city: q.city.trim().isEmpty ? null : q.city.trim(),
      );
  final dir = await ref.watch(clubDirectoryProvider.future);
  return [
    for (final e in entries)
      if (e.id != own) ChallengeOpponent.fromEntry(e, summary: dir[e.id]),
  ];
});

/// Challenge ids with an accept / decline on its way (their buttons wait).
class RespondingChallenges extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool begin(String id) {
    if (state.contains(id)) return false;
    state = {...state, id};
    return true;
  }

  void end(String id) => state = {...state}..remove(id);
}

final respondingChallengesProvider = NotifierProvider<RespondingChallenges, Set<String>>(RespondingChallenges.new);

class ChallengesController extends AsyncNotifier<List<Challenge>> {
  @override
  Future<List<Challenge>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    final repo = ref.read(challengeRepositoryProvider);
    final list = await repo.challenges();
    // The server marks expiry itself (its rows carry the effective status).
    if (_live) return list;
    final now = ref.read(clockProvider).now();
    // Persist expiry for pending challenges whose deadline has passed.
    return [
      for (final c in list)
        if (c.isPending && c.statusAt(now) == ChallengeStatus.expired)
          await repo.save(c.copyWith(status: ChallengeStatus.expired))
        else
          c,
    ];
  }

  bool get _live => ref.read(challengesLiveProvider);
  DateTime get _now => ref.read(clockProvider).now();

  /// Clubs a challenge is being sent to right now (one request at a time).
  final _sending = <String>{};

  Challenge? byId(String id) => state.value?.where((c) => c.id == id).firstOrNull;

  void _put(Challenge c) {
    final list = [...?state.value];
    final i = list.indexWhere((x) => x.id == c.id);
    i == -1 ? list.add(c) : list[i] = c;
    state = AsyncData(list);
  }

  /// Reloads the list from the repository. [keepOnError]: a failed reload
  /// keeps the list shown (after a change that did succeed).
  Future<void> refresh({bool keepOnError = false}) async {
    try {
      state = AsyncData(await ref.read(challengeRepositoryProvider).challenges());
    } catch (e, st) {
      if (!keepOnError) state = AsyncError(e, st);
    }
  }

  /// Why a challenge to [opponentClubId] can't be sent, or `null`: your own
  /// club, one already awaiting their reply, or a date before tomorrow.
  String? blockReason(String opponentClubId, {DateTime? proposedAt}) {
    if (opponentClubId == ref.read(currentClubProvider)?.id) return "You can't challenge your own club";
    // Same rule as [pendingSentClubIdsProvider], from this controller's own
    // state (reading that provider here would be circular).
    final waiting = (state.value ?? const <Challenge>[]).any((c) =>
        c.direction == ChallengeDirection.sent &&
        c.opponentClubId == opponentClubId &&
        c.statusAt(_now) == ChallengeStatus.pending);
    if (waiting) {
      return 'A challenge to this club is already waiting for their reply';
    }
    if (proposedAt != null) {
      if (_live) {
        if (ChallengeRules.date(proposedAt, _now) case final m?) return m;
      } else if (CeValidators.matchDate(proposedAt, _now) != null) {
        return CeValidators.matchDateMessage;
      }
    }
    return null;
  }

  /// Send a challenge. It is always created PENDING; in Demo Mode the
  /// opponent then accepts instantly (the approved prototype flow). On the
  /// server it waits for the other club's owner — no match exists until
  /// they accept.
  /// Throws [ChallengeBlockedException] when it can't go; server refusals
  /// arrive as the repository's errors (e.g. `MatchRuleException`).
  Future<Challenge> send(
    String opponentClubId, {
    MatchFormat? format,
    String? groundName,
    DateTime? proposedAt,
    int? customOvers,
    String? message,
  }) async {
    final reason = blockReason(opponentClubId, proposedAt: proposedAt);
    if (reason != null) throw ChallengeBlockedException(reason);
    if (_live) {
      final problem = ChallengeRules.problem(
        format: format,
        customOvers: customOvers,
        proposedAt: proposedAt,
        venueName: groundName,
        message: message,
        now: _now,
      );
      if (problem != null) throw ChallengeBlockedException(problem);
    }
    if (!_sending.add(opponentClubId)) {
      throw const ChallengeBlockedException('This challenge is already being sent');
    }
    try {
      final sent = await ref.read(challengeRepositoryProvider).send(
            opponentClubId: opponentClubId,
            format: format,
            groundName: groundName,
            proposedAt: proposedAt,
            at: _now,
            customOvers: customOvers,
            message: message,
          );
      _put(sent);
      if (_live) {
        await refresh(keepOnError: true);
        return byId(sent.id) ?? sent;
      }
      if (ref.read(demoModeProvider)) {
        return await const DemoChallengeResponder().respond(sent, accept) ?? sent;
      }
      return sent;
    } finally {
      _sending.remove(opponentClubId);
    }
  }

  /// Accept (a received challenge, or the opponent's reply to a sent one).
  /// Exactly ONE pending club match comes of it — never a duplicate: on the
  /// server it is created in the same transaction and its id returned; the
  /// demo creates it here. A second tap while one is running does nothing.
  Future<Challenge?> accept(String challengeId) =>
      _live ? _respondLive(challengeId, accept: true) : _acceptDemo(challengeId);

  Future<Challenge?> decline(String challengeId) =>
      _live ? _respondLive(challengeId, accept: false) : _declineDemo(challengeId);

  /// Server accept / decline. An expired challenge comes back `expired`;
  /// one already answered is refused — the list is reloaded either way, so
  /// it shows the real status, and the refusal is passed on.
  Future<Challenge?> _respondLive(String challengeId, {required bool accept}) async {
    final responding = ref.read(respondingChallengesProvider.notifier);
    if (!responding.begin(challengeId)) return null;
    try {
      final repo = ref.read(challengeRepositoryProvider);
      final result = accept ? await repo.accept(challengeId, at: _now) : await repo.decline(challengeId, at: _now);
      _put(result);
      if (result.status == ChallengeStatus.accepted) ref.invalidate(clubMatchesProvider);
      await refresh(keepOnError: true);
      return byId(challengeId) ?? result;
    } catch (_) {
      await refresh(keepOnError: true);
      rethrow;
    } finally {
      responding.end(challengeId);
    }
  }

  Future<Challenge?> _acceptDemo(String challengeId) async {
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

  Future<Challenge?> _declineDemo(String challengeId) async {
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

/// Challenges hub list (prototype: KK, IU, RR, FW) — the demo's clubs.
final challengeableClubsProvider = FutureProvider<List<ClubSummary>>((ref) async {
  final ids = await ref.read(challengeRepositoryProvider).challengeableClubIds();
  final dir = await ref.watch(clubDirectoryProvider.future);
  return [for (final id in ids) if (dir[id] != null) dir[id]!];
});

/// Find Opponent "Teams Looking for Opponents". The section count is derived
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
