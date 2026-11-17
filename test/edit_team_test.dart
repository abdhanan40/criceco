// Edit Team (docs/TEAM_SQUAD_IMPLEMENTATION.md): TeamsController.updateDetails
// on the Supabase repositories over fakes that apply the database functions'
// rules (owner only, unique active names, save_team storing the whole team).
// Name / format / Custom overs change; the squad, captain and vice-captain are
// kept — also when they were changed elsewhere since the app loaded them.
// No network, no database.
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// A team named like the one being saved appears on "another device" just
/// before save_team runs — after the controller re-read the teams.
class _RacingTeams implements TeamGateway {
  _RacingTeams(this.inner);
  final FakeTeamDb inner;
  bool armed = false; // set by the test, after its setup saves
  bool raced = false;

  @override
  Future<List<Map<String, dynamic>>> fetchTeams(String clubId) => inner.fetchTeams(clubId);
  @override
  Future<Map<String, dynamic>> createTeam(Map<String, Object?> params) => inner.createTeam(params);
  @override
  Future<Map<String, dynamic>> archiveTeam(String teamId) => inner.archiveTeam(teamId);
  @override
  Future<Map<String, dynamic>> saveTeam(Map<String, Object?> params) async {
    if (armed && !raced) {
      raced = true;
      final team = inner.teams.firstWhere((t) => t['id'] == params['p_team_id']);
      await inner.createTeam({'p_club_id': team['club_id'], 'p_name': params['p_name'], 'p_format': 't20'});
    }
    return inner.saveTeam(params);
  }
}

void main() {
  late FakeDb db;
  late FakeAuth auth;
  late FakeMembershipDb memberships;
  late FakeTeamDb teamDb;
  _RacingTeams? racing;
  late ProviderContainer c;
  late AuthUser owner;
  late Club club;

  AuthUser signIn(String email) {
    final u = auth.addUser(email, 'Cricket@123');
    auth.current = u;
    db.completeProfile(u.id);
    db.players[u.id] = {
      'user_id': u.id,
      'player_role': 'all_rounder',
      'batting_style': 'right_handed',
      'bowling_style': 'right_arm_fast',
      'is_wicketkeeper': false,
    };
    return u;
  }

  /// The club owner signed in, with the switch on; [race] wraps save_team.
  Future<void> setUpOwner({bool race = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    final clubs = FakeClubDb(db);
    memberships = FakeMembershipDb(db, clubs);
    teamDb = FakeTeamDb(memberships);
    owner = signIn('owner@example.com');
    Club? created;
    c = ProviderContainer(
      overrides: [
        currentClubProvider.overrideWith((ref) => created),
        sharedPreferencesProvider.overrideWithValue(prefs),
        backendConfigProvider.overrideWithValue(_supabase),
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(clubs),
        membershipGatewayProvider.overrideWithValue(memberships),
        teamGatewayProvider.overrideWithValue(race ? racing = _RacingTeams(teamDb) : teamDb),
        membershipsEnabledProvider.overrideWithValue(true),
      ],
    );
    addTearDown(c.dispose);
    created = await c
        .read(clubRepositoryProvider)
        .createClub(accountId: owner.id, name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);
    club = created;
    await c.read(teamsProvider.future);
  }

  /// [n] approved members of the club; their member ids. The owner is signed in after.
  Future<List<String>> addMembers(int n) async {
    final repo = c.read(clubRepositoryProvider);
    for (var i = 0; i < n; i++) {
      memberships.requestAs(signIn('p$i-${memberships.members.length}@example.com'), club.code);
    }
    auth.current = owner;
    for (final r in await repo.joinRequests(club.id)) {
      if (r.isPending) await repo.decideJoinRequest(club.id, r.id, approve: true, at: DateTime(2026));
    }
    return [
      for (final m in await repo.members(club.id))
        if (m.role != MemberRole.owner) m.id,
    ];
  }

  TeamsController ctrl() => c.read(teamsProvider.notifier);

  /// A new team (via the controller) with [ids] as its squad, the first two
  /// as captain and vice-captain, saved straight to the database.
  Future<Team> teamWithSquad(String name, List<String> ids, {MatchFormat format = MatchFormat.t20, int? overs}) async {
    expect(await ctrl().create(name: name, format: format, customOvers: overs), isNull);
    final team = c.read(teamsProvider).value!.firstWhere((t) => t.name == name);
    await c
        .read(teamRepositoryProvider)
        .save(
          team.copyWith(
            members: [
              for (final (i, id) in ids.indexed)
                TeamMember(playerId: id, selection: i < 2 ? SelectionRole.playing : SelectionRole.sub),
            ],
            captainId: ids.isEmpty ? null : ids[0],
            viceCaptainId: ids.length < 2 ? null : ids[1],
          ),
        );
    c.invalidate(teamsProvider);
    await c.read(teamsProvider.future);
    return ctrl().byId(team.id)!;
  }

  Map<String, dynamic> row(String teamId) => teamDb.teams.firstWhere((t) => t['id'] == teamId);
  List<String> stored(String teamId) => [
    for (final p
        in teamDb.players.where((p) => p['team_id'] == teamId).toList()
          ..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int)))
      p['member_id'] as String,
  ];
  int saves() => teamDb.calls.where((x) => x == 'saveTeam').length;

  group('updateDetails (Supabase, switch on)', () {
    setUp(setUpOwner);

    test('renames; the squad, captain and vice-captain are kept', () async {
      final ids = await addMembers(3);
      final team = await teamWithSquad('First XI', ids);
      expect(await ctrl().updateDetails(team.id, '  Punjab   Lions  '), isNull);
      final after = ctrl().byId(team.id)!;
      expect(after.name, 'Punjab Lions');
      expect(after.format, MatchFormat.t20);
      expect(after.members.map((m) => m.playerId), ids);
      expect(after.members.map((m) => m.selection), [SelectionRole.playing, SelectionRole.playing, SelectionRole.sub]);
      expect(after.captainId, ids[0]);
      expect(after.viceCaptainId, ids[1]);
      // Stored the same way.
      expect(row(team.id)['name'], 'Punjab Lions');
      expect(row(team.id)['captain_member_id'], ids[0]);
      expect(row(team.id)['vice_captain_member_id'], ids[1]);
      expect(stored(team.id), ids);
      // Re-read first, then one save.
      expect(teamDb.calls.sublist(teamDb.calls.length - 2), ['fetchTeams', 'saveTeam']);
    });

    test('format and Custom overs: set, kept while Custom, cleared for another format', () async {
      final team = await teamWithSquad('First XI', const []);
      expect(await ctrl().updateDetails(team.id, 'First XI', format: MatchFormat.custom, customOvers: 15), isNull);
      expect(ctrl().byId(team.id)!.format, MatchFormat.custom);
      expect(ctrl().byId(team.id)!.customOvers, 15);
      expect(row(team.id)['custom_overs'], 15);

      expect(await ctrl().updateDetails(team.id, 'First XI', format: MatchFormat.custom, customOvers: 20), isNull);
      expect(ctrl().byId(team.id)!.customOvers, 20);
      // Renaming without a format keeps Custom and its overs.
      expect(await ctrl().updateDetails(team.id, 'First XI Custom'), isNull);
      expect(ctrl().byId(team.id)!.customOvers, 20);

      expect(await ctrl().updateDetails(team.id, 'First XI Custom', format: MatchFormat.odi), isNull);
      expect(ctrl().byId(team.id)!.format, MatchFormat.odi);
      expect(ctrl().byId(team.id)!.customOvers, isNull);
      expect(row(team.id)['format'], 'odi');
      expect(row(team.id)['custom_overs'], isNull);
    });

    test('empty, too long, and Custom without valid overs are refused; nothing is saved', () async {
      final team = await teamWithSquad('First XI', const []);
      final before = saves();
      expect(await ctrl().updateDetails(team.id, '   '), CreateTeamError.nameRequired);
      expect(await ctrl().updateDetails(team.id, 'x' * 41), CreateTeamError.nameTooLong);
      expect(await ctrl().updateDetails(team.id, 'x' * 40), isNull, reason: '40 is the limit');
      expect(
        await ctrl().updateDetails(team.id, 'First XI', format: MatchFormat.custom),
        CreateTeamError.oversRequired,
      );
      expect(
        await ctrl().updateDetails(team.id, 'First XI', format: MatchFormat.custom, customOvers: 51),
        CreateTeamError.oversOutOfRange,
      );
      expect(saves(), before + 1, reason: 'only the valid 40-character name');
      expect(row(team.id)['name'], 'x' * 40);
    });

    test('unchanged values (spaces aside) save nothing and read nothing', () async {
      final team = await teamWithSquad('First XI', const [], format: MatchFormat.custom, overs: 12);
      final calls = teamDb.calls.length;
      expect(await ctrl().updateDetails(team.id, 'First XI'), isNull);
      expect(await ctrl().updateDetails(team.id, '  First   XI ', format: MatchFormat.custom, customOvers: 12), isNull);
      expect(await ctrl().updateDetails(team.id, 'First XI', format: MatchFormat.custom), isNull, reason: 'overs kept');
      expect(teamDb.calls.length, calls);
    });

    test('a duplicate of another active team is refused (case, spaces); its own name in a new case is fine', () async {
      final first = await teamWithSquad('First XI', const []);
      final second = await teamWithSquad('Second XI', const []);
      final before = saves();
      expect(await ctrl().updateDetails(second.id, ' first   XI '), CreateTeamError.duplicateName);
      expect(saves(), before);
      expect(await ctrl().updateDetails(first.id, 'FIRST XI'), isNull);
      expect(ctrl().byId(first.id)!.name, 'FIRST XI');
      // An archived team's name is free again.
      await c.read(teamRepositoryProvider).archive(first.id);
      expect(await ctrl().updateDetails(second.id, 'First XI'), isNull);
      expect(ctrl().byId(second.id)!.name, 'First XI');
    });

    test('a squad and captaincy changed elsewhere since loading are kept, not overwritten', () async {
      final ids = await addMembers(4);
      final team = await teamWithSquad('First XI', ids.take(2).toList());
      // "Another device": a different squad and captain, straight to the database.
      await c
          .read(teamRepositoryProvider)
          .save(
            team.copyWith(
              members: [for (final id in ids.skip(1)) TeamMember(playerId: id, selection: SelectionRole.playing)],
              captainId: ids[3],
              viceCaptainId: ids[2],
            ),
          );
      expect(
        ctrl().byId(team.id)!.members.map((m) => m.playerId),
        ids.take(2),
        reason: 'this app still shows the old squad',
      );

      expect(await ctrl().updateDetails(team.id, 'Renamed XI'), isNull);
      expect(stored(team.id), ids.skip(1));
      expect(row(team.id)['captain_member_id'], ids[3]);
      expect(row(team.id)['vice_captain_member_id'], ids[2]);
      final after = ctrl().byId(team.id)!;
      expect(after.name, 'Renamed XI');
      expect(after.members.map((m) => m.playerId), ids.skip(1));
      expect(after.captainId, ids[3]);
    });

    test('a duplicate name already taken on another device is listed by the re-read and refused', () async {
      final team = await teamWithSquad('First XI', const []);
      await c.read(teamRepositoryProvider).create(clubId: club.id, name: 'Lions', format: MatchFormat.t20);
      expect(ctrl().byId(team.id), isNotNull);
      expect(c.read(teamsProvider).value!.any((t) => t.name == 'Lions'), isFalse, reason: 'not loaded yet');
      expect(await ctrl().updateDetails(team.id, 'lions'), CreateTeamError.duplicateName);
      expect(row(team.id)['name'], 'First XI');
    });

    test('an archived team can\'t be edited', () async {
      final team = await teamWithSquad('First XI', const []);
      await c.read(teamRepositoryProvider).archive(team.id);
      await expectLater(
        ctrl().updateDetails(team.id, 'Renamed'),
        throwsA(isA<TeamRuleException>().having((e) => e.message, 'message', contains('no longer available'))),
      );
      expect(row(team.id)['name'], 'First XI');
    });

    test('not the owner: nothing is changed', () async {
      final team = await teamWithSquad('First XI', const []);
      signIn('intruder@example.com'); // the app still holds the owner's teams
      await expectLater(ctrl().updateDetails(team.id, 'Hijacked'), throwsA(isA<AccountException>()));
      // Straight to the database: save_team checks the owner.
      await expectLater(
        c.read(teamRepositoryProvider).save(team.copyWith(name: 'Hijacked')),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(row(team.id)['name'], 'First XI');
    });
  });

  group('updateDetails when the database refuses the name', () {
    setUp(() => setUpOwner(race: true));

    test('a name taken between the re-read and the save: the database\'s duplicate error, nothing changed', () async {
      final ids = await addMembers(2);
      final team = await teamWithSquad('First XI', ids);
      racing!.armed = true;
      await expectLater(
        ctrl().updateDetails(team.id, 'Lions'),
        throwsA(isA<TeamRuleException>().having((e) => e.message, 'message', CreateTeamError.duplicateName.message)),
      );
      expect(row(team.id)['name'], 'First XI');
      expect(stored(team.id), ids, reason: 'the squad is untouched');
      expect(ctrl().byId(team.id)!.name, 'First XI');
    });
  });
}
