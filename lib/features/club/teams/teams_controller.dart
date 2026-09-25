import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../core/models/models.dart';

/// Validation failures for the inline Create Team form (prototype toasts).
enum CreateTeamError {
  nameRequired('Please enter a team name'),
  formatRequired('Please select a format'),
  oversRequired('Please enter the number of overs'),
  duplicateName('A team with this name already exists'); // approved default P23

  const CreateTeamError(this.message);
  final String message;
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

  /// Returns an error to show, or `null` on success.
  Future<CreateTeamError?> create({required String name, MatchFormat? format, int? customOvers}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return CreateTeamError.nameRequired;
    if (format == null) return CreateTeamError.formatRequired;
    if (format == MatchFormat.custom && customOvers == null) return CreateTeamError.oversRequired;
    final existing = state.value ?? const [];
    if (existing.any((t) => t.name.toLowerCase() == trimmed.toLowerCase())) return CreateTeamError.duplicateName;
    final clubId = ref.read(currentClubProvider)!.id;
    final team = await ref
        .read(teamRepositoryProvider)
        .create(clubId: clubId, name: trimmed, format: format, customOvers: customOvers);
    state = AsyncData([...existing, team]);
    return null;
  }

  Future<void> saveMembers(String teamId, List<TeamMember> members) async {
    final team = byId(teamId);
    if (team == null) return;
    final saved = await ref.read(teamRepositoryProvider).save(team.copyWith(members: members));
    state = AsyncData([for (final t in state.value ?? const <Team>[]) t.id == saved.id ? saved : t]);
  }
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
    if (player.locked) return PickOutcome.locked;
    final picks = Map.of(state.picks);
    final current = picks[player.id];
    if (current == null) {
      if (state.playing < SquadRules.maxPlaying) {
        picks[player.id] = SelectionRole.playing;
      } else if (state.subs < SquadRules.maxSubs) {
        picks[player.id] = SelectionRole.sub;
      } else {
        return PickOutcome.full;
      }
    } else if (current == SelectionRole.playing) {
      if (state.subs < SquadRules.maxSubs) {
        picks[player.id] = SelectionRole.sub;
      } else {
        picks.remove(player.id);
      }
    } else {
      picks.remove(player.id);
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
