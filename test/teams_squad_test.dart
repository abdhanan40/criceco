import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<ProviderContainer> _owner() async {
  final c = await makeContainer();
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  await c.read(teamsProvider.future);
  return c;
}

void main() {
  test('create team keeps format and custom overs; validates like the prototype', () async {
    final c = await _owner();
    final teams = c.read(teamsProvider.notifier);
    expect(await teams.create(name: ' ', format: MatchFormat.t20), CreateTeamError.nameRequired);
    expect(await teams.create(name: 'Team A'), CreateTeamError.formatRequired);
    expect(await teams.create(name: 'Team A', format: MatchFormat.custom), CreateTeamError.oversRequired);
    expect(await teams.create(name: 'bs cs xi', format: MatchFormat.odi), CreateTeamError.duplicateName);

    expect(await teams.create(name: 'Team A (First XI)', format: MatchFormat.custom, customOvers: 15), isNull);
    final created = c.read(teamsProvider).value!.last;
    expect(created.name, 'Team A (First XI)');
    expect(created.format, MatchFormat.custom);
    expect(created.customOvers, 15);
    expect(created.status, TeamStatus.active);
    expect(c.read(teamProvider(created.id))!.id, created.id);
  });

  test('squad draft survives leaving and returning; saved XI/Sub roles are never re-derived', () async {
    final c = await _owner();
    final pool = await c.read(clubPlayerPoolProvider.future);
    final available = pool.where((p) => !p.locked).toList();
    final editor = c.read(squadEditorProvider('team_cs').notifier);

    // Pick 11 playing, then 1 sub — then make an EARLY pool player the sub.
    for (final p in available.take(12)) {
      editor.cycle(p);
    }
    expect(c.read(squadEditorProvider('team_cs')).playing, 11);
    expect(c.read(squadEditorProvider('team_cs')).subs, 1);
    editor.cycle(available.first); // playing → sub
    expect(c.read(squadEditorProvider('team_cs')).picks[available.first.id], SelectionRole.sub);

    // "Navigate away": nothing reads the editor; the draft is still there.
    expect(c.read(squadEditorProvider('team_cs')).dirty, isTrue);
    expect(c.read(squadEditorProvider('team_cs')).picks[available.first.id], SelectionRole.sub);

    await editor.save();
    final team = c.read(teamProvider('team_cs'))!;
    expect(team.playingCount, 10);
    expect(team.subCount, 2);
    expect(team.members.firstWhere((m) => m.playerId == available.first.id).selection, SelectionRole.sub);

    // Reopen after the editor is disposed: roles come from the saved team.
    c.invalidate(squadEditorProvider('team_cs'));
    expect(c.read(squadEditorProvider('team_cs')).picks[available.first.id], SelectionRole.sub);
    expect(c.read(squadEditorProvider('team_cs')).dirty, isFalse);
  });

  test('locked (injured/unavailable) players cannot be picked; 11 + 4 cap', () async {
    final c = await _owner();
    final pool = await c.read(clubPlayerPoolProvider.future);
    final editor = c.read(squadEditorProvider('team_it').notifier);
    expect(editor.cycle(pool.firstWhere((p) => p.availability == PlayerAvailability.injured)), PickOutcome.locked);
    final available = pool.where((p) => !p.locked).toList();
    for (final p in available.take(15)) {
      expect(editor.cycle(p), PickOutcome.changed);
    }
    expect(c.read(squadEditorProvider('team_it')).playing, 11);
    expect(c.read(squadEditorProvider('team_it')).subs, 4);
  });
}
