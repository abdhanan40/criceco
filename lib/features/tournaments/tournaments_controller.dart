import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_config.dart';
import '../../app/config/demo_mode.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/domain/fixture_engine.dart';
import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../../data/repositories/repositories.dart';
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
  static const maxOvers = CeValidators.maxCustomOvers;
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

/// A server provider that fails stays failed (its screen shows what it has):
/// no automatic retry.
Duration? _noRetry(int count, Object error) => null;

/// `true` when the tournament screens use the server (migration 35, the
/// tournaments switch): its functions decide, the in-app rules are only the
/// form's first check.
final tournamentsLiveProvider = Provider<bool>((ref) => ref.watch(tournamentBackendProvider) != null);

class TournamentsController extends AsyncNotifier<List<Tournament>> {
  @override
  Future<List<Tournament>> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    return ref.read(tournamentRepositoryProvider).tournaments();
  }

  DateTime get _now => ref.read(clockProvider).now();

  /// The server's functions; `null` in the demo and without the switch.
  TournamentBackend? get _server => ref.read(tournamentBackendProvider);

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

  /// Server: the list again (hosted + browse), keeping the entries, draw and
  /// standings already loaded for a tournament until its detail is read
  /// again. A failure keeps what is shown.
  Future<void> reload() async {
    if (_server == null) return;
    try {
      final fresh = await ref.read(tournamentRepositoryProvider).tournaments();
      final old = {for (final t in state.value ?? const <Tournament>[]) t.id: t};
      final ids = {for (final t in fresh) t.id};
      state = AsyncData([
        for (final t in fresh)
          if (old[t.id] case final o?)
            t.copyWith(joined: o.joined, pending: o.pending, fixtures: o.fixtures, standings: o.standings)
          else
            t,
        for (final o in old.values)
          if (!ids.contains(o.id)) o,
      ]);
    } on AccountException {
      // Keep the list shown.
    }
  }

  /// Server: one tournament with its entries (confirmed in approval order,
  /// requests oldest first), its draw and its standings; the entries also
  /// go to [tournamentRegistrationsProvider]. A tournament the server no
  /// longer has is dropped.
  Future<Tournament?> refreshDetail(String id) async {
    final server = _server;
    if (server == null) return byId(id);
    final Tournament row;
    final List<TournamentRegistration> regs;
    final List<FixtureRound>? fixtures;
    final Map<String, Standing> standings;
    try {
      final parts = await Future.wait<Object?>([
        server.detail(id),
        server.teams(id),
        server.fixtures(id),
        server.pointsTable(id),
      ]);
      row = parts[0]! as Tournament;
      regs = parts[1]! as List<TournamentRegistration>;
      fixtures = parts[2] as List<FixtureRound>?;
      standings = parts[3]! as Map<String, Standing>;
    } on TournamentRuleException catch (e) {
      if (e.reason != 'not found') rethrow;
      state = AsyncData([for (final t in state.value ?? const <Tournament>[]) if (t.id != id) t]);
      return null;
    }
    TournamentEntrant entrant(TournamentRegistration r) =>
        TournamentEntrant(id: r.id, displayName: r.clubName ?? r.teamName, clubId: r.clubId, city: r.clubCity);
    final full = row.copyWith(
      joined: [for (final r in regs) if (r.status == RegistrationStatus.approved) entrant(r)],
      pending: [for (final r in regs) if (r.isPending) entrant(r)],
      fixtures: fixtures,
      standings: standings,
    );
    _put(full);
    await ref.read(tournamentRegistrationsProvider.notifier)._merge(regs);
    ref.invalidate(tournamentServerAwardsProvider(id));
    return full;
  }

  /// [refreshDetail] after a change the server accepted: a failed reload
  /// doesn't make the change look failed.
  Future<void> _refreshQuietly(String id) async {
    try {
      await refreshDetail(id);
    } on AccountException {
      // The change is made; the screen catches up on its next load.
    }
    ref.invalidate(tournamentServerStatsProvider);
  }

  /// Publish a tournament. The organizer is always the owner's own club
  /// (fix: the prototype used the last-viewed club). On the server the
  /// form's checks are repeated there; its row (and id) is what is listed.
  Future<Tournament> create(TournamentInput input) async {
    final club = ref.read(currentClubProvider);
    if (club == null) throw StateError('Only a club owner can host a tournament');
    final now = _now;
    final errors = validateTournamentInput(input, now);
    if (errors.isNotEmpty) throw ArgumentError(errors.values.first);
    await future;
    final server = _server;
    final created = await ref.read(tournamentRepositoryProvider).create(Tournament(
          id: server != null ? '' : 't_${now.microsecondsSinceEpoch}_${state.value?.length ?? 0}',
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
    if (server != null) {
      ref.invalidate(tournamentServerStatsProvider);
      return created;
    }
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
  /// Registration closes once fixtures exist (the draw is fixed). On the
  /// server the draw is made there (`generate_tournament_fixtures`, seeded in
  /// approval order; requests still waiting are rejected) and read back.
  Future<FixturesOutcome> generateFixtures(String id) async {
    await future;
    final t = byId(id);
    if (t == null) return FixturesOutcome.notFound;
    if (t.hasFixtures) return FixturesOutcome.alreadyGenerated;
    if (!t.canGenerateFixtures) return FixturesOutcome.notEnoughTeams;
    final server = _server;
    if (server != null) {
      final bool made;
      try {
        made = await server.generateFixtures(id);
      } on TournamentRuleException catch (e) {
        if (e.reason != 'not enough teams') rethrow;
        await _refreshQuietly(id);
        return FixturesOutcome.notEnoughTeams;
      }
      await _refreshQuietly(id);
      return made ? FixturesOutcome.generated : FixturesOutcome.alreadyGenerated;
    }
    final ids = [for (final e in t.joined) e.id];
    await save(t.copyWith(
      fixtures: FixtureEngine.generate(t.type, ids),
      standings: FixtureEngine.emptyStandings(ids),
      status: t.status == TournamentStatus.registrationOpen ? TournamentStatus.registrationClosed : t.status,
    ));
    return FixturesOutcome.generated;
  }

  /// Records a fixture result (standings, next knockout round, champion).
  /// Demo only: on the server results are read-only (a fixture's winner
  /// comes from the trusted scorer), so nothing is recorded there.
  Future<Tournament?> recordResult(String id, int roundIdx, int matchIdx, String winnerId) async {
    if (_server != null) return null;
    final t = byId(id);
    final fixtures = t?.fixtures;
    if (t == null || fixtures == null) return null;
    if (roundIdx >= fixtures.length || matchIdx >= fixtures[roundIdx].matches.length) return null;
    final updated = FixtureEngine.recordResult(t, roundIdx, matchIdx, winnerId);
    if (identical(updated, t)) return null;
    return save(updated);
  }

  /// Organizer: remove a confirmed team. Only before fixtures exist — the
  /// draw would otherwise break. On the server (`remove_tournament_team`)
  /// the entry becomes "removed", listed as Rejected.
  Future<bool> removeTeam(String id, String entrantId) async {
    final t = byId(id);
    if (t == null || t.hasFixtures || !t.joined.any((e) => e.id == entrantId)) return false;
    final server = _server;
    if (server != null) {
      try {
        await ref.read(tournamentRegistrationsProvider.notifier)._upsert(await server.remove(entrantId));
      } on TournamentRuleException catch (e) {
        if (e.reason != 'fixtures generated' && e.reason != 'not approved') rethrow;
        await _refreshQuietly(id);
        return false;
      }
      await _refreshQuietly(id);
      return true;
    }
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

  TournamentBackend? get _server => ref.read(tournamentBackendProvider);

  /// Server: the own club's entries again. A failure keeps what is shown;
  /// squads already known stay.
  Future<void> reload() async {
    if (_server == null) return;
    try {
      final fresh = await ref.read(tournamentRepositoryProvider).registrations();
      final mine = {for (final r in fresh) r.id};
      final kept = [for (final r in state.value ?? const <TournamentRegistration>[]) if (!mine.contains(r.id)) r];
      state = AsyncData(kept);
      await _merge(fresh);
    } on AccountException {
      // Keep the list shown.
    }
  }

  /// A server entry row: replaces the one with its id (keeping a squad
  /// already known, and the club's name / city when the row has none).
  Future<void> _upsert(TournamentRegistration r) => _merge([r]);

  Future<void> _merge(List<TournamentRegistration> rows) async {
    if (rows.isEmpty) return;
    await future;
    final list = [...?state.value];
    for (final r in rows) {
      final i = list.indexWhere((x) => x.id == r.id);
      if (i == -1) {
        list.add(r);
        continue;
      }
      final old = list[i];
      list[i] = TournamentRegistration(
        id: r.id,
        tournamentId: r.tournamentId,
        clubId: r.clubId,
        teamId: r.teamId,
        teamName: r.teamName,
        lineup: r.lineup ?? old.lineup,
        status: r.status,
        submittedAt: r.submittedAt,
        decidedAt: r.decidedAt,
        clubName: r.clubName ?? old.clubName,
        clubCity: r.clubCity ?? old.clubCity,
        removed: r.removed,
      );
    }
    state = AsyncData(list);
  }

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

    // The server checks it all again (11 + 4, availability on the start
    // date, capacity, one entry per club and per player) and says why not.
    final server = _server;
    if (server != null) {
      final TournamentRegistration reg;
      try {
        reg = await server.submit(tournamentId: t.id, clubId: club.id, lineup: lineup, agreedToRules: draft.agreed);
      } on AccountException catch (e) {
        return (registration: null, error: e.message);
      }
      await _upsert(reg);
      ref.read(registrationDraftProvider(tournamentId).notifier).clear();
      ref.invalidate(lineupDraftProvider(TournamentEntryTarget(tournamentId)));
      await ref.read(tournamentsProvider.notifier)._refreshQuietly(t.id);
      return (registration: byId(reg.id) ?? reg, error: null);
    }

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
    if (_server != null) return null; // Real clubs apply on the server.
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
  ///
  /// On the server (`decide_tournament_registration`, organizer only) its
  /// refusals map to the same outcomes; any other is thrown
  /// ([AccountException]).
  Future<RegistrationDecision> decide(String registrationId, {required bool approve}) async {
    await future;
    final r = byId(registrationId);
    if (r == null) return RegistrationDecision.notFound;
    if (!r.isPending) return RegistrationDecision.notPending;
    final server = _server;
    if (server != null) {
      final tournaments = ref.read(tournamentsProvider.notifier);
      try {
        await _upsert(await server.decide(registrationId, approve: approve));
      } on TournamentRuleException catch (e) {
        final outcome = switch (e.reason) {
          'not pending' => RegistrationDecision.notPending,
          'registration full' => RegistrationDecision.full,
          'fixtures generated' => RegistrationDecision.closed,
          'registration not found' => RegistrationDecision.notFound,
          _ => null,
        };
        if (outcome == null) rethrow;
        await tournaments._refreshQuietly(r.tournamentId);
        return outcome;
      }
      await tournaments._refreshQuietly(r.tournamentId);
      return approve ? RegistrationDecision.approved : RegistrationDecision.rejected;
    }
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
    if (_server != null) return; // The server's row says "removed".
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

/// The server's Tournament Center counts (`tournament_hub_stats`); `null`
/// in the demo, without the switch, and while loading or failed. Read again
/// after every change made here and on every list sync.
final tournamentServerStatsProvider = FutureProvider<TournamentServerStats?>(retry: _noRetry, (ref) async {
  ref.watch(currentAccountProvider.select((a) => a?.id));
  final server = ref.watch(tournamentBackendProvider);
  if (server == null) return null;
  return server.hubStats();
});

/// Tournament Center stats and hub badges: the server's counts when the
/// tournaments switch is on (derived from what is loaded until they
/// arrive), else derived.
final tournamentHubStatsProvider = Provider<TournamentHubStats>((ref) {
  if (ref.watch(tournamentsLiveProvider)) {
    if (ref.watch(tournamentServerStatsProvider).value case final s?) {
      return TournamentHubStats(
        hosted: s.hosted,
        open: s.open,
        registered: s.registered,
        approved: s.approved,
        pendingRegistrations: s.pending,
      );
    }
  }
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
  return t.entrant(id)?.displayName ?? (id == t.winnerId ? t.winnerName : null) ?? 'TBD';
}

/// The server's awards (`tournament_awards`): only from the official
/// scorecards of fixtures linked to a match; `null` while there is none, in
/// the demo, without the switch, and for a club that may not read them.
/// Read again with the tournament's detail.
final tournamentServerAwardsProvider =
    FutureProvider.family<TournamentAwards?, String>(retry: _noRetry, (ref, id) async {
  final server = ref.watch(tournamentBackendProvider);
  if (server == null) return null;
  try {
    return await server.awards(id);
  } on AccountException {
    return null;
  }
});

/// Tournament Dashboard awards.
/// * Server (the tournaments switch): [tournamentServerAwardsProvider] —
///   official results only, `null` (the empty state) until there are some.
/// * Any other Supabase build: none — never invented.
/// * The demo: ranked over the confirmed teams' players (my registered
///   squad, or another club's key players) by `DemoTournamentAwards`.
final tournamentAwardsProvider = Provider.family<TournamentAwards?, String>((ref, id) {
  if (ref.watch(tournamentsLiveProvider)) return ref.watch(tournamentServerAwardsProvider(id)).value;
  if (ref.watch(backendConfigProvider).isSupabase) return null;
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

/// Server: reads one tournament's detail (entries, draw, standings) when a
/// screen keyed by it opens. Nothing to do in the demo.
final tournamentDetailProvider =
    FutureProvider.autoDispose.family<void, String>(retry: _noRetry, (ref, id) async {
  if (ref.watch(tournamentBackendProvider) == null) return;
  await ref.read(tournamentsProvider.future);
  await ref.read(tournamentRegistrationsProvider.future);
  await ref.read(tournamentsProvider.notifier).refreshDetail(id);
});

/// Server: reads the tournament list, the own club's entries and the hub
/// counts again when a list screen ([screen]) opens — unless they are
/// loading for the first time right now. Nothing to do in the demo.
final tournamentsSyncProvider =
    FutureProvider.autoDispose.family<void, String>(retry: _noRetry, (ref, screen) async {
  if (ref.watch(tournamentBackendProvider) == null) return;
  final listLoaded = ref.read(tournamentsProvider).hasValue;
  final regsLoaded = ref.read(tournamentRegistrationsProvider).hasValue;
  await Future.wait([
    if (listLoaded) ref.read(tournamentsProvider.notifier).reload() else ref.read(tournamentsProvider.future),
    if (regsLoaded)
      ref.read(tournamentRegistrationsProvider.notifier).reload()
    else
      ref.read(tournamentRegistrationsProvider.future),
  ]);
  if (listLoaded || regsLoaded) ref.invalidate(tournamentServerStatsProvider);
});

/// Server: an entry's squad (`tournament_registration_squad`, the entering
/// club's and the organizer's owners only); `null` in the demo (its
/// registrations keep their squad), and when it can't be read.
final registrationSquadProvider =
    FutureProvider.autoDispose.family<Lineup?, String>(retry: _noRetry, (ref, registrationId) async {
  final server = ref.watch(tournamentBackendProvider);
  if (server == null) return null;
  final r = ref.read(tournamentRegistrationsProvider.notifier).byId(registrationId);
  try {
    return await server.squad(registrationId, teamName: r?.teamName ?? '');
  } on AccountException {
    return null;
  }
});

// ---------------------------------------------------------------------------
// Remembered selections (prototype globals `browseTournamentsCityFilter`,
// `myRegTab`): Back from a tournament / registration returns to the same
// city / tab. The route query still wins when present (deep links).
// ---------------------------------------------------------------------------

final browseCityProvider = NotifierProvider<SelectionController<String?>, String?>(() => SelectionController(null));

final myRegistrationsTabProvider = NotifierProvider<SelectionController<RegistrationStatus>, RegistrationStatus>(
    () => SelectionController(RegistrationStatus.pending));
