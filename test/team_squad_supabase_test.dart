// Teams and squads (migration 12) through SupabaseTeamRepository, on fakes
// that apply the database functions' rules: owner only, unique names among
// active teams, 11 + 4, active members of the same club only, captain /
// vice-captain in the squad and different, archive as delete, and a removed
// member leaving every team. No network, no database.
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_club_overlay.dart';
import 'package:criceco/data/supabase/membership_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_team_repository.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'membership_fakes.dart';
import 'supabase_fakes.dart';

void main() {
  late FakeDb db;
  late FakeAuth auth;
  late FakeClubDb clubs;
  late FakeMembershipDb memberships;
  late FakeTeamDb teamDb;
  late SupabaseClubRepository clubRepo;
  late SupabaseTeamRepository repo;
  late AuthUser owner;
  late Club club;

  AuthUser signIn(String email) {
    final u = auth.addUser(email, 'Cricket@123');
    auth.current = u;
    db.completeProfile(u.id);
    db.players[u.id] = {'user_id': u.id, 'player_role': 'all_rounder', 'batting_style': 'right_handed',
        'bowling_style': 'right_arm_fast', 'is_wicketkeeper': false};
    return u;
  }

  /// [n] approved members; returns their member ids (owner signed in after).
  Future<List<String>> addMembers(int n) async {
    for (var i = 0; i < n; i++) {
      final p = signIn('p$i-${memberships.members.length}@example.com');
      memberships.requestAs(p, club.code);
    }
    auth.current = owner;
    for (final r in await clubRepo.joinRequests(club.id)) {
      if (r.isPending) await clubRepo.decideJoinRequest(club.id, r.id, approve: true, at: DateTime(2026));
    }
    return [
      for (final m in await clubRepo.members(club.id))
        if (m.role != MemberRole.owner) m.id,
    ];
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    clubs = FakeClubDb(db);
    memberships = FakeMembershipDb(db, clubs);
    teamDb = FakeTeamDb(memberships);
    clubRepo = SupabaseClubRepository(
      auth: auth,
      db: clubs,
      overlay: LocalClubOverlay(prefs),
      local: InMemoryClubRepository(SeedData(DateTime(2026, 11, 16))),
      membership: memberships,
    );
    repo = SupabaseTeamRepository(db: teamDb);
    owner = signIn('owner@example.com');
    club = await clubRepo.createClub(accountId: owner.id, name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);
  });

  List<TeamMember> squadOf(List<String> ids, {int playing = 11}) => [
        for (var i = 0; i < ids.length; i++)
          TeamMember(playerId: ids[i], selection: i < playing ? SelectionRole.playing : SelectionRole.sub),
      ];

  test('create, list, and the format / overs are kept', () async {
    final t = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.custom, customOvers: 15);
    expect(t.format, MatchFormat.custom);
    expect(t.customOvers, 15);
    final list = await repo.teams(club.id);
    expect(list.single.name, 'First XI');
    expect(list.single.members, isEmpty);
    expect(teamDb.calls, containsAllInOrder(['createTeam', 'fetchTeams']));
  });

  test('a duplicate name (case and spaces ignored) is refused', () async {
    await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    await expectLater(
      repo.create(clubId: club.id, name: '  first   xi ', format: MatchFormat.odi),
      throwsA(isA<TeamRuleException>().having((e) => e.message, 'message', contains('already exists'))),
    );
  });

  test('the squad is saved in pick order; a player can\'t be listed twice', () async {
    final ids = await addMembers(3);
    final t = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    final saved = await repo.save(t.copyWith(members: squadOf(ids, playing: 2)));
    expect(saved.members.map((m) => m.playerId), ids);
    final read = (await repo.teams(club.id)).single;
    expect(read.members.map((m) => m.playerId), ids);
    expect(read.members.last.selection, SelectionRole.sub);
    await expectLater(
      repo.save(t.copyWith(members: squadOf([ids[0], ids[0]]))),
      throwsA(isA<TeamRuleException>()),
    );
  });

  test('more than 11 playing or 4 substitutes is refused', () async {
    final ids = await addMembers(12);
    final t = await repo.create(clubId: club.id, name: 'Big', format: MatchFormat.t20);
    await expectLater(
      repo.save(t.copyWith(members: squadOf(ids, playing: 12))),
      throwsA(isA<TeamRuleException>().having((e) => e.message, 'message', contains('11 players'))),
    );
    expect((await repo.teams(club.id)).single.members, isEmpty); // nothing half-saved
  });

  test('only active members of this club can be picked', () async {
    final ids = await addMembers(1);
    final t = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    await expectLater(
      repo.save(t.copyWith(members: squadOf(['someone-else']))),
      throwsA(isA<TeamRuleException>().having((e) => e.message, 'message', contains('active club members'))),
    );
    // Another club's member isn't allowed either.
    final other = signIn('other-owner@example.com');
    final otherClub = await clubRepo.createClub(accountId: other.id, name: 'Karachi Kings', city: 'Karachi', type: ClubType.professional);
    final p = signIn('other-player@example.com');
    memberships.requestAs(p, otherClub.code);
    auth.current = other;
    final r = (await clubRepo.joinRequests(otherClub.id)).single;
    await clubRepo.decideJoinRequest(otherClub.id, r.id, approve: true, at: DateTime(2026));
    final foreign = (await clubRepo.members(otherClub.id)).firstWhere((m) => m.role != MemberRole.owner).id;
    auth.current = owner;
    await expectLater(repo.save(t.copyWith(members: squadOf([ids.single, foreign]))), throwsA(isA<TeamRuleException>()));
  });

  test('captain and vice-captain: squad players, different people, optional', () async {
    final ids = await addMembers(3);
    final t = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    final withSquad = await repo.save(t.copyWith(members: squadOf(ids)));
    final led = await repo.save(withSquad.copyWith(captainId: ids[0], viceCaptainId: ids[1]));
    expect(led.captainId, ids[0]);
    expect(led.viceCaptainId, ids[1]);
    await expectLater(repo.save(withSquad.copyWith(captainId: ids[2], viceCaptainId: ids[2])), throwsA(isA<TeamRuleException>()));
    await expectLater(
      repo.save(withSquad.copyWith(members: squadOf([ids[1]]), captainId: ids[0], clearViceCaptain: true)),
      throwsA(isA<TeamRuleException>()),
    );
    final cleared = await repo.save(led.copyWith(clearCaptain: true, clearViceCaptain: true));
    expect(cleared.captainId, isNull);
    expect(cleared.viceCaptainId, isNull);
  });

  test('delete archives: gone from the list, name free again', () async {
    final t = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    await repo.archive(t.id);
    expect(await repo.teams(club.id), isEmpty);
    expect(teamDb.teams.single['status'], 'archived'); // the row is kept
    final again = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    expect(again.id, isNot(t.id));
    await expectLater(repo.save(t.copyWith(name: 'Renamed')), throwsA(isA<TeamRuleException>()));
  });

  test('removing a member takes them out of every team and clears captaincy', () async {
    final ids = await addMembers(2);
    final t = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    await repo.save(t.copyWith(members: squadOf(ids), captainId: ids[0]));
    await clubRepo.removeMember(club.id, ids[0]);
    final read = (await repo.teams(club.id)).single;
    expect(read.members.map((m) => m.playerId), [ids[1]]);
    expect(read.captainId, isNull);
  });

  test('someone else can\'t read or change the club\'s teams', () async {
    final t = await repo.create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    signIn('intruder@example.com');
    expect(await repo.teams(club.id), isEmpty); // RLS: no rows
    await expectLater(repo.create(clubId: club.id, name: 'Mine', format: MatchFormat.t20), throwsA(isA<PermissionDeniedException>()));
    await expectLater(repo.save(t), throwsA(isA<PermissionDeniedException>()));
    await expectLater(repo.archive(t.id), throwsA(isA<PermissionDeniedException>()));
  });

  test('save parameters carry the whole squad and leaders', () {
    final team = Team(
      id: 't1',
      clubId: 'c1',
      name: 'First XI',
      format: MatchFormat.odi,
      createdAt: DateTime(2026),
      captainId: 'm1',
      members: const [
        TeamMember(playerId: 'm1', selection: SelectionRole.playing),
        TeamMember(playerId: 'm2', selection: SelectionRole.sub),
      ],
    );
    final p = MembershipRowMapper.saveParams(team);
    expect(p['p_expected_version'], 1, reason: 'the copy it was made from (M4)');
    expect(p['p_format'], 'odi');
    expect(p['p_custom_overs'], isNull);
    expect(p['p_captain_member_id'], 'm1');
    expect(p['p_vice_member_id'], isNull);
    expect(p['p_players'], [
      {'member_id': 'm1', 'selection': 'playing'},
      {'member_id': 'm2', 'selection': 'sub'},
    ]);
  });

  test('offline → BackendUnavailableException', () async {
    final failing = SupabaseTeamRepository(db: _OfflineTeams());
    await expectLater(failing.teams('c1'), throwsA(isA<BackendUnavailableException>()));
  });

  test('without the switch: no teams, and creating says it isn\'t available', () async {
    const off = UnavailableTeamRepository();
    expect(await off.teams('c1'), isEmpty);
    await expectLater(off.create(clubId: 'c1', name: 'X', format: MatchFormat.t20), throwsA(isA<ModuleUnavailableException>()));
    await expectLater(off.archive('t1'), throwsA(isA<ModuleUnavailableException>()));
  });
}

class _OfflineTeams implements TeamGateway {
  @override
  Future<List<Map<String, dynamic>>> fetchTeams(String clubId) => throw const GatewayNetworkException();
  @override
  Future<Map<String, dynamic>> createTeam(Map<String, Object?> params) => throw const GatewayNetworkException();
  @override
  Future<Map<String, dynamic>> saveTeam(Map<String, Object?> params) => throw const GatewayNetworkException();
  @override
  Future<Map<String, dynamic>> archiveTeam(String teamId) => throw const GatewayNetworkException();
}
