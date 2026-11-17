import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config/backend_modules.dart';
import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/ranked_search.dart';
import '../../../core/utils/validators.dart';
import '../../../data/repositories/repositories.dart';
import '../club_providers.dart';

/// Validation failures for the inline Create Team form (prototype toasts).
enum CreateTeamError {
  nameRequired('Please enter a team name'),
  formatRequired('Please select a format'),
  oversRequired('Please enter the number of overs'),
  oversOutOfRange('Enter between 1 and ${CeValidators.maxCustomOvers} overs'),
  nameTooLong('Keep the team name to ${CeValidators.nameMaxLength} characters'),
  duplicateName('A team with this name already exists'); // approved default P23

  const CreateTeamError(this.message);
  final String message;
}

/// A team name as stored: trimmed, single spaces (the database does the same).
String normalizeTeamName(String name) => name.trim().replaceAll(RegExp(r'\s+'), ' ');

/// The checks Create Team and Edit Team share — [name] (already
/// [normalizeTeamName]d), format and Custom overs. Duplicate names are
/// checked separately, against the club's loaded teams.
CreateTeamError? validateTeamDetails({required String name, MatchFormat? format, int? customOvers}) {
  if (name.isEmpty) return CreateTeamError.nameRequired;
  if (name.length > CeValidators.nameMaxLength) return CreateTeamError.nameTooLong;
  if (format == null) return CreateTeamError.formatRequired;
  if (format == MatchFormat.custom) {
    if (customOvers == null) return CreateTeamError.oversRequired;
    if (CeValidators.customOvers(customOvers) != null) return CreateTeamError.oversOutOfRange;
  }
  return null;
}

/// Two team names clash when they match ignoring case and repeated spaces
/// (the database's `team_name_key`).
bool _sameTeamName(String a, String b) => normalizeQuery(a) == normalizeQuery(b);

/// The team was created but its suggested squad couldn't be saved ([reason]);
/// the team is listed, empty, so the owner can add players from Team Squad.
class TeamSquadNotSavedException implements Exception {
  const TeamSquadNotSavedException(this.reason);
  final String reason;
  String get message => 'The team was created, but its squad wasn’t saved: $reason';
  @override
  String toString() => message;
}

/// My Teams, keyed by id. Every value entered at creation is kept on the
/// [Team] (fix: format was discarded in the prototype).
class TeamsController extends AsyncNotifier<List<Team>> {
  @override
  Future<List<Team>> build() async {
    final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
    if (clubId == null) return const [];
    return ref.read(teamRepositoryProvider).teams(clubId);
  }

  Team? byId(String id) => state.value?.where((t) => t.id == id).firstOrNull;

  /// Returns an error to show, or `null` on success. [members] (Suggest
  /// Team, reviewed by the owner) become the new team's saved squad.
  Future<CreateTeamError?> create({
    required String name,
    MatchFormat? format,
    int? customOvers,
    List<TeamMember> members = const [],
  }) async {
    final trimmed = normalizeTeamName(name);
    final invalid = validateTeamDetails(name: trimmed, format: format, customOvers: customOvers);
    if (invalid != null) return invalid;
    // Duplicates are checked against the loaded teams (never an empty list
    // while they are still loading), ignoring case and repeated spaces.
    final existing = await future;
    if (existing.any((t) => _sameTeamName(t.name, trimmed))) return CreateTeamError.duplicateName;
    final clubId = ref.read(currentClubProvider)!.id;
    final repo = ref.read(teamRepositoryProvider);
    // format: non-null, checked by validateTeamDetails.
    final team = await repo.create(clubId: clubId, name: trimmed, format: format!, customOvers: customOvers);
    // The team exists from here on: list it now, so a failed squad save
    // below never leaves a stored team the app doesn't know (a retry would
    // then hit "name already exists").
    state = AsyncData([...existing, team]);
    if (members.isNotEmpty) {
      try {
        _replace(await repo.save(team.copyWith(members: members)));
      } on AccountException catch (e) {
        throw TeamSquadNotSavedException(e.message);
      }
    }
    return null;
  }

  /// Edit Team (Team Squad → pencil): the name, format and Custom overs.
  /// Returns an error to show, or `null` on success — also when nothing
  /// changed, and then nothing is saved. [format] defaults to the team's;
  /// [customOvers] to its current overs while the format stays Custom.
  ///
  /// `save_team` stores the whole team, squad included, so the club's teams
  /// are re-read first and the change is applied to the LATEST copy: a squad
  /// or captaincy changed elsewhere (another device) is kept, not overwritten.
  /// The squad, captain and vice-captain are never changed here. Refusals
  /// from the database (a name another device just took, not the owner, an
  /// archived team) are thrown as [AccountException]s.
  Future<CreateTeamError?> updateDetails(String teamId, String name, {MatchFormat? format, int? customOvers}) async {
    final current = byId(teamId) ?? (await future).where((t) => t.id == teamId).firstOrNull;
    if (current == null) throw const TeamRuleException('This team is no longer available');
    final trimmed = normalizeTeamName(name);
    final newFormat = format ?? current.format;
    final overs = newFormat != MatchFormat.custom
        ? null
        : customOvers ?? (current.format == MatchFormat.custom ? current.customOvers : null);
    final invalid = validateTeamDetails(name: trimmed, format: newFormat, customOvers: overs);
    if (invalid != null) return invalid;
    final currentOvers = current.format == MatchFormat.custom ? current.customOvers : null;
    if (trimmed == current.name && newFormat == current.format && overs == currentOvers) return null;

    // Re-read, then check the name against the latest teams (this one excluded).
    final clubId = ref.read(currentClubProvider)?.id ?? current.clubId;
    final repo = ref.read(teamRepositoryProvider);
    final fresh = await repo.teams(clubId);
    state = AsyncData(fresh);
    final latest = fresh.where((t) => t.id == teamId).firstOrNull;
    if (latest == null) throw const TeamRuleException('This team is no longer available');
    if (fresh.any((t) => t.id != teamId && _sameTeamName(t.name, trimmed))) return CreateTeamError.duplicateName;

    _replace(await repo.save(latest.copyWith(
      name: trimmed,
      format: newFormat,
      customOvers: overs,
      clearCustomOvers: overs == null,
    )));
    return null;
  }

  Future<void> saveMembers(String teamId, List<TeamMember> members) async {
    final team = byId(teamId);
    if (team == null) return;
    // A captain or vice-captain who left the squad loses that role (the
    // database requires both to be squad players).
    final ids = {for (final m in members) m.playerId};
    final saved = await ref.read(teamRepositoryProvider).save(team.copyWith(
          members: members,
          clearCaptain: team.captainId != null && !ids.contains(team.captainId),
          clearViceCaptain: team.viceCaptainId != null && !ids.contains(team.viceCaptainId),
        ));
    _replace(saved);
  }

  /// Captain / vice-captain (Team Squad). Both optional, both squad players,
  /// never the same person: making the vice-captain captain (or the other way
  /// round) moves them, leaving the other role empty. `null` clears the role.
  Future<void> setLeaders(String teamId, {required String? captainId, required String? viceCaptainId}) async {
    final team = byId(teamId);
    if (team == null) return;
    final ids = {for (final m in team.members) m.playerId};
    if ((captainId != null && !ids.contains(captainId)) || (viceCaptainId != null && !ids.contains(viceCaptainId))) {
      throw const TeamRuleException('Captain and vice-captain must be in this team’s squad');
    }
    if (captainId != null && captainId == viceCaptainId) {
      throw const TeamRuleException('The captain and vice-captain must be different players');
    }
    final saved = await ref.read(teamRepositoryProvider).save(team.copyWith(
          captainId: captainId,
          viceCaptainId: viceCaptainId,
          clearCaptain: captainId == null,
          clearViceCaptain: viceCaptainId == null,
        ));
    _replace(saved);
  }

  /// "Delete team": archived (its name is free again). Gone from My Teams.
  Future<void> archive(String teamId) async {
    await ref.read(teamRepositoryProvider).archive(teamId);
    state = AsyncData([for (final t in state.value ?? const <Team>[]) if (t.id != teamId) t]);
  }

  /// A player who left the club leaves every team too. Supabase: the database
  /// already did it (migration 12) — the teams are re-read. The demo removes
  /// them here, the same way.
  Future<void> dropPlayer(String playerId) async {
    if (!ref.read(backendModulesProvider).isDemo) {
      ref.invalidateSelf();
      return;
    }
    for (final team in [...?state.value]) {
      if (!team.members.any((m) => m.playerId == playerId)) continue;
      final saved = await ref.read(teamRepositoryProvider).save(team.copyWith(
            members: [for (final m in team.members) if (m.playerId != playerId) m],
            clearCaptain: team.captainId == playerId,
            clearViceCaptain: team.viceCaptainId == playerId,
          ));
      _replace(saved);
    }
  }

  void _replace(Team saved) =>
      state = AsyncData([for (final t in state.value ?? const <Team>[]) t.id == saved.id ? saved : t]);
}

/// Owner → Member Profile → Remove from Club. The member's team places go
/// with it; Members, the player pool and teams are re-read.
Future<void> removeClubMember(WidgetRef ref, ClubMember member) async {
  final club = ref.read(currentClubProvider);
  if (club == null) return;
  if (member.role == MemberRole.owner) throw const PermissionDeniedException();
  await ref.read(clubRepositoryProvider).removeMember(club.id, member.id);
  await ref.read(teamsProvider.notifier).dropPlayer(member.poolPlayerId ?? member.id);
  ref.invalidate(clubPlayerPoolProvider);
  ref.invalidate(clubMembersProvider);
}

final teamsProvider = AsyncNotifierProvider<TeamsController, List<Team>>(TeamsController.new);

/// selectedTeam — typed lookup by route id.
final teamProvider = Provider.family<Team?, String>(
  (ref, teamId) => ref.watch(teamsProvider).value?.where((t) => t.id == teamId).firstOrNull,
);

/// The club's player pool (Add Players / Team Builder source).
final clubPlayerPoolProvider = FutureProvider<List<SquadPlayer>>((ref) async {
  final clubId = ref.watch(currentClubProvider.select((c) => c?.id));
  if (clubId == null) return const [];
  return ref.read(clubRepositoryProvider).playerPool(clubId);
});

enum PickOutcome { changed, locked, full }

/// The one squad-pick rule, shared by Add Players (team squads) and the
/// match-day line-up (prototype `cycleAddPlayer` / `cycleSquadPick`):
/// Unselected → Playing XI (until 11) → Substitute (until 4) → Unselected.
/// Injured / unavailable players are locked. Returns the new picks (a copy,
/// insertion order kept) and what happened.
(Map<String, SelectionRole>, PickOutcome) cycleSquadPick(Map<String, SelectionRole> current, SquadPlayer player) {
  if (player.locked) return (current, PickOutcome.locked);
  final picks = Map.of(current);
  int count(SelectionRole r) => picks.values.where((x) => x == r).length;
  final role = picks[player.id];
  if (role == null) {
    if (count(SelectionRole.playing) < SquadRules.maxPlaying) {
      picks[player.id] = SelectionRole.playing;
    } else if (count(SelectionRole.sub) < SquadRules.maxSubs) {
      picks[player.id] = SelectionRole.sub;
    } else {
      return (current, PickOutcome.full);
    }
  } else if (role == SelectionRole.playing) {
    if (count(SelectionRole.sub) < SquadRules.maxSubs) {
      picks[player.id] = SelectionRole.sub;
    } else {
      picks.remove(player.id);
    }
  } else {
    picks.remove(player.id);
  }
  return (picks, PickOutcome.changed);
}

/// The same rule, choosing a role directly (Create Team sheet: XI / Sub /
/// Not selected): locked players can't be picked, and Playing XI and
/// substitutes stay within 11 + 4. `null` removes the player.
(Map<String, SelectionRole>, PickOutcome) setSquadPick(
  Map<String, SelectionRole> current,
  SquadPlayer player,
  SelectionRole? role,
) {
  if (current[player.id] == role) return (current, PickOutcome.changed);
  final picks = Map.of(current);
  if (role == null) {
    picks.remove(player.id);
    return (picks, PickOutcome.changed);
  }
  if (player.locked) return (current, PickOutcome.locked);
  final taken = picks.entries.where((e) => e.key != player.id && e.value == role).length;
  final cap = role == SelectionRole.playing ? SquadRules.maxPlaying : SquadRules.maxSubs;
  if (taken >= cap) return (current, PickOutcome.full);
  picks[player.id] = role;
  return (picks, PickOutcome.changed);
}

/// Unsaved Add Players selection for one team. Kept for the session, so
/// leaving and returning restores it (approved decision 5, default P5).
class SquadDraft {
  SquadDraft(Map<String, SelectionRole> picks, {this.dirty = false})
      : picks = UnmodifiableMapView(Map.of(picks));

  final Map<String, SelectionRole> picks; // insertion-ordered
  final bool dirty;

  int get playing => picks.values.where((r) => r == SelectionRole.playing).length;
  int get subs => picks.values.where((r) => r == SelectionRole.sub).length;

  List<TeamMember> toMembers() =>
      [for (final e in picks.entries) TeamMember(playerId: e.key, selection: e.value)];
}

class SquadEditor extends Notifier<SquadDraft> {
  SquadEditor(this.teamId);
  final String teamId;

  @override
  SquadDraft build() => _fromSaved();

  SquadDraft _fromSaved() {
    final team = ref.read(teamsProvider).value?.where((t) => t.id == teamId).firstOrNull;
    // Seeded from the SAVED selection roles — never re-derived by list index.
    return SquadDraft({for (final m in team?.members ?? const <TeamMember>[]) m.playerId: m.selection});
  }

  /// Prototype cycle: Unselected → Playing (until 11) → Sub (until 4) → Unselected.
  PickOutcome cycle(SquadPlayer player) {
    final (picks, outcome) = cycleSquadPick(state.picks, player);
    if (outcome == PickOutcome.changed) state = SquadDraft(picks, dirty: true);
    return outcome;
  }

  /// Explicit choice from the Add Player sheet: put [player] in the Playing
  /// XI or the Substitutes, or take them out (`null`). Same limits as [cycle].
  PickOutcome assign(SquadPlayer player, SelectionRole? role) {
    final picks = Map.of(state.picks);
    if (role == null) {
      // Removing is always allowed (e.g. a player injured since being picked).
      if (picks.remove(player.id) == null) return PickOutcome.changed;
    } else {
      if (player.locked) return PickOutcome.locked;
      if (picks[player.id] == role) return PickOutcome.changed;
      final taken = picks.values.where((r) => r == role).length;
      final max = role == SelectionRole.playing ? SquadRules.maxPlaying : SquadRules.maxSubs;
      if (taken >= max) return PickOutcome.full;
      picks[player.id] = role;
    }
    state = SquadDraft(picks, dirty: true);
    return PickOutcome.changed;
  }

  /// "Save Squad": commit to the team, then the draft equals the saved state.
  Future<void> save() async {
    await ref.read(teamsProvider.notifier).saveMembers(teamId, state.toMembers());
    state = SquadDraft(state.picks);
  }

  void discard() => state = _fromSaved();
}

final squadEditorProvider = NotifierProvider.family<SquadEditor, SquadDraft, String>(SquadEditor.new);
