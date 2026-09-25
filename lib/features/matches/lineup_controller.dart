import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../core/models/models.dart';
import '../club/teams/teams_controller.dart';
import 'club_matches_controller.dart';

/// Unsaved match-day line-up for one target (revised architecture §7:
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

  String get _matchId => (target as MatchLineupTarget).matchId;

  Lineup? get _saved => ref.read(clubMatchProvider(_matchId))?.lineup;

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
    await _save(Lineup(
      name: state.name ?? Lineup.newMatchDaySquadName,
      sourceTeamId: state.sourceTeamId,
      members: state.toMembers(),
    ));
    return null;
  }

  /// "Select Existing Team": the team's saved XI / subs become this match's
  /// line-up (a snapshot — later squad edits don't change a past line-up).
  /// Injured / unavailable members are left out. Returns how many were left out.
  Future<int> useTeam(Team team) async {
    final pool = await ref.read(clubPlayerPoolProvider.future);
    final byId = {for (final p in pool) p.id: p};
    final members = [for (final m in team.members) if (byId[m.playerId]?.locked == false) m];
    await _save(Lineup(name: team.name, sourceTeamId: team.id, members: members));
    return team.members.length - members.length;
  }

  Future<void> _save(Lineup lineup) async {
    final matches = ref.read(clubMatchesProvider.notifier);
    final m = matches.byId(_matchId);
    if (m == null) return;
    await matches.save(m.copyWith(lineup: lineup));
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
