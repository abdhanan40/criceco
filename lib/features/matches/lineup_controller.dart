import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';
import '../club/teams/teams_controller.dart';
import '../tournaments/registration_draft.dart';
import 'club_matches_controller.dart';

/// Unsaved match-day / tournament line-up for one target (revised architecture §7:
/// `lineupDraftProvider(target)`). Same selection model as a team squad.
class LineupDraft {
  LineupDraft(Map<String, SelectionRole> picks, {this.name, this.sourceTeamId, this.dirty = false})
      : picks = UnmodifiableMapView(Map.of(picks));

  final Map<String, SelectionRole> picks; // insertion-ordered
  final String? name; // null → "New Match-Day Squad" on save
  final String? sourceTeamId;
  final bool dirty;

  int get playing => picks.values.where((r) => r == SelectionRole.playing).length;
  int get subs => picks.values.where((r) => r == SelectionRole.sub).length;
  bool get isComplete => playing == SquadRules.maxPlaying && subs == SquadRules.maxSubs;

  List<TeamMember> toMembers() =>
      [for (final e in picks.entries) TeamMember(playerId: e.key, selection: e.value)];
}

/// Why a built line-up can't be confirmed yet (prototype `confirmNewTeam`).
String? lineupIncompleteMessage(LineupDraft d) {
  final needXi = SquadRules.maxPlaying - d.playing;
  final needSubs = SquadRules.maxSubs - d.subs;
  if (needXi > 0) return 'Select $needXi more player${needXi == 1 ? '' : 's'} for Playing XI';
  if (needSubs > 0) return 'Select $needSubs more substitute${needSubs == 1 ? '' : 's'}';
  return null;
}

class LineupDraftController extends Notifier<LineupDraft> {
  LineupDraftController(this.target);
  final LineupTarget target;

  /// The confirmed line-up: on the match, or on the tournament registration
  /// draft (submitted with the registration).
  Lineup? get _saved => switch (target) {
        MatchLineupTarget(:final matchId) => ref.read(clubMatchProvider(matchId))?.lineup,
        TournamentEntryTarget(:final tournamentId) => ref.read(registrationDraftProvider(tournamentId)).lineup,
      };

  @override
  LineupDraft build() => _fromSaved();

  LineupDraft _fromSaved() {
    final l = _saved;
    return LineupDraft(
      {for (final m in l?.members ?? const <TeamMember>[]) m.playerId: m.selection},
      name: l?.name,
      sourceTeamId: l?.sourceTeamId,
    );
  }

  /// "Create New Team": a blank match-day squad — unless there are unsaved
  /// picks, which are kept (they persist when navigating away and back).
  void startNew() {
    if (state.dirty) return;
    state = LineupDraft(const {});
  }

  /// "Edit Playing XI": start from the saved line-up (or keep unsaved picks).
  void startEdit() {
    if (state.dirty) return;
    state = _fromSaved();
  }

  PickOutcome cycle(SquadPlayer player) {
    final (picks, outcome) = cycleSquadPick(state.picks, player);
    if (outcome == PickOutcome.changed) {
      state = LineupDraft(picks, name: state.name, sourceTeamId: state.sourceTeamId, dirty: true);
    }
    return outcome;
  }

  void discard() => state = _fromSaved();

  /// "Confirm Team" from the builder: exactly 11 + 4 (prototype rule). Returns
  /// an error message, or `null` once the match's line-up is saved.
  Future<String?> confirmBuilt() async {
    final error = lineupIncompleteMessage(state);
    if (error != null) return error;
    final pool = await ref.read(clubPlayerPoolProvider.future);
    final byId = {for (final p in pool) p.id: p};
    // Re-check availability at save time: a locked player never enters a line-up.
    if (state.picks.keys.any((id) => byId[id]?.locked ?? true)) {
      return 'Remove injured or unavailable players first';
    }
    try {
      await _save(Lineup(
        name: state.name ?? Lineup.newMatchDaySquadName,
        sourceTeamId: state.sourceTeamId,
        members: state.toMembers(),
      ));
    } on AccountException catch (e) {
      // The server refused it (a player left the club or is unavailable on
      // the match day, the match changed…): say why; the picks stay.
      return e.message;
    }
    return null;
  }

  /// "Select Existing Team": the team's saved XI / subs become this match's
  /// line-up (a snapshot — later squad edits don't change a past line-up).
  /// Injured / unavailable members are left out. Returns how many were left out.
  ///
  /// A server match (migration 18) takes only a complete line-up: exactly
  /// 11 + 4 after leaving those players out — otherwise a
  /// [MatchRuleException] says so and nothing is saved. Its captain and
  /// vice-captain come along when both are still in the Playing XI.
  Future<int> useTeam(Team team) async {
    final pool = await ref.read(clubPlayerPoolProvider.future);
    final byId = {for (final p in pool) p.id: p};
    final members = [for (final m in team.members) if (byId[m.playerId]?.locked == false) m];
    final leftOut = team.members.length - members.length;
    final lineup = Lineup(name: team.name, sourceTeamId: team.id, members: members);
    // A server tournament entry (migration 35) takes exactly 11 + 4 too;
    // the team's captain and vice-captain go with it when in the XI.
    if (_serverTournament) {
      final playing = members.where((m) => m.selection == SelectionRole.playing).toList();
      if (playing.length != SquadRules.maxPlaying || members.length - playing.length != SquadRules.maxSubs) {
        throw TournamentRuleException(
          '${team.name} has ${playing.length} + ${members.length - playing.length} available players'
          '${leftOut > 0 ? ' ($leftOut injured or unavailable left out)' : ''}. '
          'A tournament squad needs exactly ${SquadRules.maxPlaying} + ${SquadRules.maxSubs} — build one instead.',
        );
      }
      bool inXi(String? id) => id != null && playing.any((m) => m.playerId == id);
      final captain = inXi(team.captainId) ? team.captainId : null;
      final vice = inXi(team.viceCaptainId) && team.viceCaptainId != captain ? team.viceCaptainId : null;
      await _save(Lineup(
        name: team.name,
        sourceTeamId: team.id,
        members: members,
        captainId: captain,
        viceCaptainId: vice,
      ));
      return leftOut;
    }
    if (_serverMatch) {
      final playing = members.where((m) => m.selection == SelectionRole.playing).toList();
      if (playing.length != SquadRules.maxPlaying || members.length - playing.length != SquadRules.maxSubs) {
        throw MatchRuleException(
          '${team.name} has ${playing.length} + ${members.length - playing.length} available players'
          '${leftOut > 0 ? ' ($leftOut injured or unavailable left out)' : ''}. '
          'A match line-up needs exactly ${SquadRules.maxPlaying} + ${SquadRules.maxSubs} — build one instead.',
        );
      }
      bool inXi(String? id) => id != null && playing.any((m) => m.playerId == id);
      final captain = inXi(team.captainId) ? team.captainId : null;
      final vice = inXi(team.viceCaptainId) && team.viceCaptainId != captain ? team.viceCaptainId : null;
      await _save(lineup, captainMemberId: captain, viceCaptainMemberId: vice);
      return leftOut;
    }
    await _save(lineup);
    return leftOut;
  }

  /// A server match's line-up (migration 18) rather than the demo's.
  bool get _serverMatch => target is MatchLineupTarget && ref.read(matchesLiveProvider);

  /// A server tournament entry (the tournaments switch) rather than the demo's.
  bool get _serverTournament => target is TournamentEntryTarget && ref.read(tournamentBackendProvider) != null;

  Future<void> _save(Lineup lineup, {String? captainMemberId, String? viceCaptainMemberId}) async {
    switch (target) {
      case MatchLineupTarget(:final matchId) when _serverMatch:
        await ref.read(clubMatchesProvider.notifier).saveLineup(
              matchId,
              lineup,
              captainMemberId: captainMemberId,
              viceCaptainMemberId: viceCaptainMemberId,
            );
      case MatchLineupTarget(:final matchId):
        final matches = ref.read(clubMatchesProvider.notifier);
        final m = matches.byId(matchId);
        if (m == null) return;
        await matches.save(m.copyWith(lineup: lineup));
      case TournamentEntryTarget(:final tournamentId):
        ref.read(registrationDraftProvider(tournamentId).notifier).setLineup(lineup);
    }
    state = LineupDraft(
      {for (final x in lineup.members) x.playerId: x.selection},
      name: lineup.name,
      sourceTeamId: lineup.sourceTeamId,
    );
  }
}

/// Kept alive for the session: unsaved picks survive leaving and returning.
final lineupDraftProvider =
    NotifierProvider.family<LineupDraftController, LineupDraft, LineupTarget>(LineupDraftController.new);

/// A line-up can be set or changed only for a confirmed match that hasn't
/// started yet (edit "before match").
final lineupEditableProvider = Provider.family<bool, String>((ref, matchId) {
  final m = ref.watch(clubMatchProvider(matchId));
  if (m == null || m.status != MatchStatus.confirmed) return false;
  final start = m.startsAt;
  return start == null || start.isAfter(ref.read(clockProvider).now());
});
