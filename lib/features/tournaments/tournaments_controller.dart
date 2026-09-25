import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/demo_mode.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/domain/fixture_engine.dart';
import '../../core/models/models.dart';
import '../../demo/demo_tournament_tools.dart';
import '../../shared/state/selection_controller.dart';
import '../club/club_providers.dart';
import '../club/teams/teams_controller.dart';
import '../matches/lineup_controller.dart';
import 'registration_draft.dart';

// ---------------------------------------------------------------------------
// Create Tournament input + validation (prototype `submitTournament`)
// ---------------------------------------------------------------------------

abstract final class TournamentLimits {
  static const maxOvers = 50;
  static const minTeams = Tournament.minTeamsForFixtures;
  static const maxTeams = 32;
}

class TournamentInput {
  const TournamentInput({
    this.name = '',
    this.city,
    this.ground = '',
    this.format,
    this.customOvers,
    this.type,
    this.startDate,
    this.endDate,
    this.registrationDeadline,
    this.entryFee,
    this.prize,
    this.maxTeams,
    this.description = '',
  });

  final String name;
  final String? city;
  final String ground;
  final MatchFormat? format;
  final int? customOvers;
  final TournamentType? type;
  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime? registrationDeadline;
  final int? entryFee;
  final int? prize;
  final int? maxTeams;
  final String description;
}

/// Field key → message, in the prototype's order, plus the approved date
/// checks (end ≥ start, deadline ≤ start; §9) and no past dates.
Map<String, String> validateTournamentInput(TournamentInput i, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final e = <String, String>{};
  if (i.name.trim().isEmpty) e['name'] = 'Please enter a tournament name';
  if (i.city == null) e['city'] = 'Please select a city';
  if (i.ground.trim().isEmpty) e['ground'] = 'Please enter a ground';
  if (i.format == null) e['format'] = 'Please select a tournament format';
  if (i.format == MatchFormat.custom) {
    final o = i.customOvers;
    if (o == null) {
      e['overs'] = 'Please enter the number of overs';
    } else if (o < 1 || o > TournamentLimits.maxOvers) {
      e['overs'] = 'Enter between 1 and ${TournamentLimits.maxOvers} overs';
    }
  }
  if (i.type == null) e['type'] = 'Please select a tournament type';
  final start = i.startDate;
  final end = i.endDate;
  final deadline = i.registrationDeadline;
  if (start == null) {
    e['start'] = 'Please select a start date';
  } else if (start.isBefore(today)) {
    e['start'] = 'Start date cannot be in the past';
  }
  if (end == null) {
    e['end'] = 'Please select an end date';
  } else if (start != null && end.isBefore(start)) {
    e['end'] = 'End date must be on or after the start date';
  }
  if (deadline == null) {
    e['deadline'] = 'Please select a registration deadline';
  } else if (deadline.isBefore(today)) {
    e['deadline'] = 'Registration deadline cannot be in the past';
  } else if (start != null && deadline.isAfter(start)) {
    e['deadline'] = 'Registration must close on or before the start date';
  }
  final max = i.maxTeams;
  if (max == null) {
    e['maxTeams'] = 'Please enter maximum teams';
  } else if (max < TournamentLimits.minTeams || max > TournamentLimits.maxTeams) {
    e['maxTeams'] = 'Enter between ${TournamentLimits.minTeams} and ${TournamentLimits.maxTeams} teams';
  }
  return e;
}

// ---------------------------------------------------------------------------
// Tournaments (hosted + browse, one id space)
// ---------------------------------------------------------------------------

enum FixturesOutcome { generated, alreadyGenerated, notEnoughTeams, notFound }

class TournamentsController extends AsyncNotifier<List<Tournament>> {
  @override
  Future<List<Tournament>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return ref.read(tournamentRepositoryProvider).tournaments();
  }

  DateTime get _now => ref.read(clockProvider).now();

  Tournament? byId(String id) => state.value?.where((t) => t.id == id).firstOrNull;

  void _put(Tournament t) {
    final list = [...?state.value];
    final i = list.indexWhere((x) => x.id == t.id);
    i == -1 ? list.add(t) : list[i] = t;
    state = AsyncData(list);
  }

  Future<Tournament> save(Tournament t) async {
    final saved = await ref.read(tournamentRepositoryProvider).save(t);
    _put(saved);
    return saved;
  }

  /// Publish a tournament. The organizer is always the owner's own club
  /// (fix: the prototype used the last-viewed club).
  Future<Tournament> create(TournamentInput input) async {
    final club = ref.read(currentClubProvider);
    if (club == null) throw StateError('Only a club owner can host a tournament');
    final now = _now;
    final errors = validateTournamentInput(input, now);
    if (errors.isNotEmpty) throw ArgumentError(errors.values.first);
    await future;
    final created = await ref.read(tournamentRepositoryProvider).create(Tournament(
          id: 't_${now.microsecondsSinceEpoch}_${state.value?.length ?? 0}',
          name: input.name.trim(),
          organizerClubId: club.id,
          city: input.city!,
          ground: input.ground.trim(),
          format: input.format!,
          customOvers: input.format == MatchFormat.custom ? input.customOvers : null,
          type: input.type!,
          startDate: input.startDate!,
          endDate: input.endDate!,
          registrationDeadline: input.registrationDeadline!,
          entryFee: input.entryFee,
          prize: input.prize,
          maxTeams: input.maxTeams!,
          description: input.description.trim(),
          status: TournamentStatus.registrationOpen,
        ));
    _put(created);
    if (ref.read(demoModeProvider)) {
      final clubs = (await ref.read(clubDirectoryProvider.future)).values.toList();
      await const DemoTournamentEntries().seedRequests(
        created,
        clubs,
        (tid, clubId, teamName) =>
            ref.read(tournamentRegistrationsProvider.notifier).receive(tid, clubId: clubId, teamName: teamName),
      );
    }
    return byId(created.id) ?? created;
  }

  /// Organizer: build the bracket / league from the confirmed teams.
  /// Registration closes once fixtures exist (the draw is fixed).
  Future<FixturesOutcome> generateFixtures(String id) async {
    await future;
    final t = byId(id);
    if (t == null) return FixturesOutcome.notFound;
    if (t.fixtures != null) return FixturesOutcome.alreadyGenerated;
    if (!t.canGenerateFixtures) return FixturesOutcome.notEnoughTeams;
    final ids = [for (final e in t.joined) e.id];
    await save(t.copyWith(
      fixtures: FixtureEngine.generate(t.type, ids),
      standings: FixtureEngine.emptyStandings(ids),
      status: t.status == TournamentStatus.registrationOpen ? TournamentStatus.registrationClosed : t.status,
    ));
    return FixturesOutcome.generated;
  }

  /// Records a fixture result (standings, next knockout round, champion).
  Future<Tournament?> recordResult(String id, int roundIdx, int matchIdx, String winnerId) async {
    final t = byId(id);
    final fixtures = t?.fixtures;
    if (t == null || fixtures == null) return null;
    if (roundIdx >= fixtures.length || matchIdx >= fixtures[roundIdx].matches.length) return null;
    final updated = FixtureEngine.recordResult(t, roundIdx, matchIdx, winnerId);
    if (identical(updated, t)) return null;
    return save(updated);
  }

  /// Organizer: remove a confirmed team. Only before fixtures exist — the
  /// draw would otherwise break.
  Future<bool> removeTeam(String id, String entrantId) async {
    final t = byId(id);
    if (t == null || t.fixtures != null || !t.joined.any((e) => e.id == entrantId)) return false;
    await save(t.copyWith(
      joined: [for (final e in t.joined) if (e.id != entrantId) e],
      status: t.status == TournamentStatus.registrationFull ? TournamentStatus.registrationOpen : t.status,
    ));
    await ref.read(tournamentRegistrationsProvider.notifier)._markRemoved(entrantId);
    return true;
  }
}

final tournamentsProvider = AsyncNotifierProvider<TournamentsController, List<Tournament>>(TournamentsController.new);

/// Selected tournament — typed lookup by route id.
final tournamentProvider = Provider.family<Tournament?, String>(
  (ref, id) => ref.watch(tournamentsProvider).value?.where((t) => t.id == id).firstOrNull,
);

// ---------------------------------------------------------------------------
// Registrations (mine and incoming), keyed by id
// ---------------------------------------------------------------------------

enum RegistrationDecision { approved, rejected, full, closed, notPending, notFound }

typedef RegistrationSubmitResult = ({TournamentRegistration? registration, String? error});

class TournamentRegistrationsController extends AsyncNotifier<List<TournamentRegistration>> {
  @override
  Future<List<TournamentRegistration>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return ref.read(tournamentRepositoryProvider).registrations();
  }

  DateTime get _now => ref.read(clockProvider).now();

  TournamentRegistration? byId(String id) => state.value?.where((r) => r.id == id).firstOrNull;

  Future<TournamentRegistration> _store(TournamentRegistration r) async {
    final saved = await ref.read(tournamentRepositoryProvider).saveRegistration(r);
    final list = [...?state.value];
    final i = list.indexWhere((x) => x.id == saved.id);
    i == -1 ? list.add(saved) : list[i] = saved;
    state = AsyncData(list);
    return saved;
  }

  bool _hasActive(String tournamentId, String clubId) => (state.value ?? const []).any(
      (r) => r.tournamentId == tournamentId && r.clubId == clubId && r.status != RegistrationStatus.rejected);

  String? _closedReason(Tournament t) {
    if (t.acceptsRegistrationsAt(_now)) return null;
    if (t.isFull || t.statusAt(_now) == TournamentStatus.registrationFull) return 'Registration is full';
    return 'Registration for this tournament has closed';
  }

  /// "Submit Registration": my club enters the squad confirmed in the
  /// registration draft. Pending until the organizer decides.
  Future<RegistrationSubmitResult> submit(String tournamentId) async {
    await future;
    final club = ref.read(currentClubProvider);
    final t = (await ref.read(tournamentsProvider.future)).where((x) => x.id == tournamentId).firstOrNull;
    if (club == null || t == null) return (registration: null, error: 'This tournament is no longer available');
    if (t.organizerClubId == club.id) return (registration: null, error: 'Your club is hosting this tournament');
    if (_hasActive(t.id, club.id)) {
      return (registration: null, error: 'Your club has already registered for this tournament');
    }
    final closed = _closedReason(t);
    if (closed != null) return (registration: null, error: closed);
    final draft = ref.read(registrationDraftProvider(tournamentId));
    final lineup = draft.lineup;
    if (lineup == null) return (registration: null, error: 'Please pick your team first');
    if (!draft.agreed) return (registration: null, error: 'Please agree to the tournament rules');

    final now = _now;
    final reg = await _store(TournamentRegistration(
      id: 'reg_${now.microsecondsSinceEpoch}_${state.value?.length ?? 0}',
      tournamentId: t.id,
      clubId: club.id,
      teamId: lineup.sourceTeamId,
      teamName: lineup.name,
      lineup: lineup,
      status: RegistrationStatus.pending,
      submittedAt: now,
    ));
    await ref.read(tournamentsProvider.notifier).save(t.copyWith(pending: [
      ...t.pending,
      TournamentEntrant(id: reg.id, displayName: club.name, clubId: club.id),
    ]));
    ref.read(registrationDraftProvider(tournamentId).notifier).clear();
    ref.invalidate(lineupDraftProvider(TournamentEntryTarget(tournamentId)));
    return (registration: reg, error: null);
  }

  /// Another club applies to one of my tournaments (backend event; seeded by
  /// Demo Mode on publish).
  Future<TournamentRegistration?> receive(String tournamentId, {required String clubId, required String teamName}) async {
    await future;
    final t = (await ref.read(tournamentsProvider.future)).where((x) => x.id == tournamentId).firstOrNull;
    if (t == null || t.organizerClubId == clubId || _hasActive(tournamentId, clubId)) return null;
    if (_closedReason(t) != null) return null;
    final club = (await ref.read(clubDirectoryProvider.future))[clubId];
    final now = _now;
    final reg = await _store(TournamentRegistration(
      id: 'reg_${now.microsecondsSinceEpoch}_${state.value?.length ?? 0}',
      tournamentId: tournamentId,
      clubId: clubId,
      teamName: teamName,
      status: RegistrationStatus.pending,
      submittedAt: now,
    ));
    final latest = ref.read(tournamentsProvider.notifier).byId(tournamentId) ?? t;
    await ref.read(tournamentsProvider.notifier).save(latest.copyWith(pending: [
      ...latest.pending,
      TournamentEntrant(id: reg.id, displayName: club?.name ?? teamName, clubId: clubId),
    ]));
    return reg;
  }

  /// Organizer decision on a pending registration: approval moves the entry
  /// from pending to joined (§9); rejection drops it from pending.
  Future<RegistrationDecision> decide(String registrationId, {required bool approve}) async {
    await future;
    final r = byId(registrationId);
    if (r == null) return RegistrationDecision.notFound;
    if (!r.isPending) return RegistrationDecision.notPending;
    final tournaments = ref.read(tournamentsProvider.notifier);
    await ref.read(tournamentsProvider.future);
    final t = tournaments.byId(r.tournamentId);
    if (t == null) return RegistrationDecision.notFound;
    final entrant = t.pending.where((e) => e.id == r.id).firstOrNull ??
        TournamentEntrant(id: r.id, displayName: r.teamName, clubId: r.clubId);
    final pending = [for (final e in t.pending) if (e.id != r.id) e];
    if (approve) {
      if (t.fixtures != null) return RegistrationDecision.closed;
      if (t.isFull) return RegistrationDecision.full;
      final joined = [...t.joined, entrant];
      await tournaments.save(t.copyWith(
        joined: joined,
        pending: pending,
        status: joined.length >= t.maxTeams ? TournamentStatus.registrationFull : t.status,
      ));
    } else {
      await tournaments.save(t.copyWith(pending: pending));
    }
    await _store(r.copyWith(
      status: approve ? RegistrationStatus.approved : RegistrationStatus.rejected,
      decidedAt: _now,
    ));
    return approve ? RegistrationDecision.approved : RegistrationDecision.rejected;
  }

  Future<void> _markRemoved(String registrationId) async {
    final r = byId(registrationId);
    if (r == null || r.status == RegistrationStatus.rejected) return;
    await _store(r.copyWith(status: RegistrationStatus.rejected, decidedAt: _now));
  }
}

final tournamentRegistrationsProvider =
    AsyncNotifierProvider<TournamentRegistrationsController, List<TournamentRegistration>>(
        TournamentRegistrationsController.new);

/// Selected registration — typed lookup by route id.
final registrationProvider = Provider.family<TournamentRegistration?, String>(
  (ref, id) => ref.watch(tournamentRegistrationsProvider).value?.where((r) => r.id == id).firstOrNull,
);

// ---------------------------------------------------------------------------
// Read models
// ---------------------------------------------------------------------------

String? _ownClubId(Ref ref) => ref.watch(currentClubProvider.select((c) => c?.id));

/// My Tournaments: tournaments hosted by the owner's own club.
final hostedTournamentsProvider = Provider<List<Tournament>>((ref) {
  final clubId = _ownClubId(ref);
  final all = ref.watch(tournamentsProvider).value ?? const <Tournament>[];
  return [for (final t in all) if (clubId != null && t.organizerClubId == clubId) t];
});

/// Browse: other clubs' tournaments (my own hosted ones are never listed).
final browseTournamentsProvider = Provider<List<Tournament>>((ref) {
  final clubId = _ownClubId(ref);
  final all = ref.watch(tournamentsProvider).value ?? const <Tournament>[];
  return [for (final t in all) if (t.organizerClubId != clubId) t];
});

/// Browse city options, in listing order.
final browseCitiesProvider = Provider<List<String>>((ref) {
  return {for (final t in ref.watch(browseTournamentsProvider)) t.city}.toList();
});

/// My Registrations: my club's registrations, newest first.
final myRegistrationsProvider = Provider<List<TournamentRegistration>>((ref) {
  final clubId = _ownClubId(ref);
  final all = ref.watch(tournamentRegistrationsProvider).value ?? const <TournamentRegistration>[];
  return [for (final r in all) if (r.clubId == clubId) r]..sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
});

final myRegistrationsByStatusProvider = Provider.family<List<TournamentRegistration>, RegistrationStatus>(
  (ref, status) => [for (final r in ref.watch(myRegistrationsProvider)) if (r.status == status) r],
);

/// My club's live (pending / approved) registration for a tournament — the
/// Browse card and Tournament Details show "View Registration" instead of
/// registering twice.
final activeRegistrationProvider = Provider.family<TournamentRegistration?, String>((ref, tournamentId) {
  return ref
      .watch(myRegistrationsProvider)
      .where((r) => r.tournamentId == tournamentId && r.status != RegistrationStatus.rejected)
      .firstOrNull;
});

/// Organizer: pending requests for one of my tournaments, oldest first.
final pendingRequestsProvider = Provider.family<List<TournamentRegistration>, String>((ref, tournamentId) {
  final all = ref.watch(tournamentRegistrationsProvider).value ?? const <TournamentRegistration>[];
  return [for (final r in all) if (r.tournamentId == tournamentId && r.isPending) r]
    ..sort((a, b) => a.submittedAt.compareTo(b.submittedAt));
});

class TournamentHubStats {
  const TournamentHubStats({
    required this.hosted,
    required this.open,
    required this.registered,
    required this.approved,
    required this.pendingRegistrations,
  });
  final int hosted;
  final int open;
  final int registered;
  final int approved;
  final int pendingRegistrations;
}

/// Tournament Center stats and hub badges (all derived).
final tournamentHubStatsProvider = Provider<TournamentHubStats>((ref) {
  final now = ref.read(clockProvider).now();
  final mine = ref.watch(myRegistrationsProvider);
  return TournamentHubStats(
    hosted: ref.watch(hostedTournamentsProvider).length,
    open: ref.watch(browseTournamentsProvider).where((t) => t.acceptsRegistrationsAt(now)).length,
    registered: mine.length,
    approved: mine.where((r) => r.status == RegistrationStatus.approved).length,
    pendingRegistrations: mine.where((r) => r.isPending).length,
  );
});

/// A club taking part in a tournament (organizer, entrant, applicant):
/// another club from the directory, or the owner's own club.
class TournamentClub {
  const TournamentClub({required this.id, required this.name, required this.city, this.summary, this.color});
  final String id;
  final String name;
  final String city;
  final ClubSummary? summary;
  final Color? color;
  String? get abbr => summary?.abbr;
}

final tournamentClubsProvider = Provider<Map<String, TournamentClub>>((ref) {
  final dir = ref.watch(clubDirectoryProvider).value ?? const <String, ClubSummary>{};
  final own = ref.watch(currentClubProvider);
  return {
    for (final c in dir.values) c.id: TournamentClub(id: c.id, name: c.name, city: c.city, summary: c, color: c.color),
    if (own != null) own.id: TournamentClub(id: own.id, name: own.name, city: own.city),
  };
});

/// One fixture with its position in the draw.
class FixtureRef {
  const FixtureRef({required this.roundIdx, required this.matchIdx, required this.roundName, required this.match});
  final int roundIdx;
  final int matchIdx;
  final String roundName;
  final FixtureMatch match;
}

/// Every fixture in draw order (prototype `flattenFixtureMatches`). BYE
/// walkovers are not listed as matches.
List<FixtureRef> flattenFixtures(Tournament t) => [
      for (final (ri, round) in (t.fixtures ?? const <FixtureRound>[]).indexed)
        for (final (mi, m) in round.matches.indexed)
          if (!m.isBye) FixtureRef(roundIdx: ri, matchIdx: mi, roundName: round.name, match: m),
    ];

/// Points-table rows: points, then name (prototype `tournamentPointsTab`).
List<(TournamentEntrant, Standing)> standingsTable(Tournament t) {
  final rows = [for (final e in t.joined) (e, t.standings[e.id] ?? const Standing())];
  rows.sort((a, b) {
    final byPts = b.$2.points.compareTo(a.$2.points);
    return byPts != 0 ? byPts : a.$1.displayName.compareTo(b.$1.displayName);
  });
  return rows;
}

/// Display name for an entrant id in a fixture ("TBD" for an undecided slot).
String entrantLabel(Tournament t, String? id) {
  if (id == null) return 'TBD';
  if (id == FixtureMatch.bye) return 'BYE';
  return t.entrant(id)?.displayName ?? 'TBD';
}

/// Tournament Dashboard awards, ranked over the confirmed teams' players:
/// my registered squad, or another club's key players.
final tournamentAwardsProvider = Provider.family<TournamentAwards?, String>((ref, id) {
  final t = ref.watch(tournamentProvider(id));
  if (t == null || t.joined.isEmpty) return null;
  final pool = {for (final p in ref.watch(clubPlayerPoolProvider).value ?? const <SquadPlayer>[]) p.id: p};
  final regs = {for (final r in ref.watch(tournamentRegistrationsProvider).value ?? const <TournamentRegistration>[]) r.id: r};
  final clubs = ref.watch(tournamentClubsProvider);
  final players = <(String, String, String)>[];
  for (final e in t.joined) {
    final lineup = regs[e.id]?.lineup;
    if (lineup != null) {
      for (final m in lineup.members) {
        final p = pool[m.playerId];
        if (p != null) players.add((p.name, p.position, e.id));
      }
    } else {
      for (final k in clubs[e.clubId]?.summary?.keyPlayers ?? const <KeyPlayer>[]) {
        players.add((k.name, k.position, e.id));
      }
    }
  }
  return DemoTournamentAwards.compute(t.id, players);
});

// ---------------------------------------------------------------------------
// Remembered selections (prototype globals `browseTournamentsCityFilter`,
// `myRegTab`): Back from a tournament / registration returns to the same
// city / tab. The route query still wins when present (deep links).
// ---------------------------------------------------------------------------

final browseCityProvider = NotifierProvider<SelectionController<String?>, String?>(() => SelectionController(null));

final myRegistrationsTabProvider = NotifierProvider<SelectionController<RegistrationStatus>, RegistrationStatus>(
    () => SelectionController(RegistrationStatus.pending));
