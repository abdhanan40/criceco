// Club memberships (migration 11) through SupabaseClubRepository, on fakes
// that apply the database functions' rules: join by code, duplicates, the
// request lifecycle (pending → approved / rejected / cancelled), the owner's
// decisions and removals, authorization, network failures — and the
// behaviour without the memberships switch. No network, no database.
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_club_overlay.dart';
import 'package:criceco/data/supabase/membership_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'membership_fakes.dart';
import 'supabase_fakes.dart';

void main() {
  late SharedPreferences prefs;
  late FakeDb db;
  late FakeAuth auth;
  late FakeClubDb clubs;
  late FakeMembershipDb members;
  late SupabaseClubRepository repo;

  SupabaseClubRepository newRepo({bool switchOn = true}) => SupabaseClubRepository(
        auth: auth,
        db: clubs,
        overlay: LocalClubOverlay(prefs),
        local: InMemoryClubRepository(SeedData(DateTime(2026, 11, 16))),
        membership: switchOn ? members : null,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    clubs = FakeClubDb(db);
    members = FakeMembershipDb(db, clubs);
    repo = newRepo();
  });

  AuthUser signIn(String email, {bool profileDone = true, String? playerRole = 'batsman'}) {
    final u = auth.addUser(email, 'Cricket@123');
    auth.current = u;
    if (profileDone) db.completeProfile(u.id);
    if (playerRole != null) {
      db.players[u.id] = {
        'user_id': u.id,
        'player_role': playerRole,
        'batting_style': playerRole == 'bowler' ? null : 'right_handed',
        'bowling_style': playerRole == 'batsman' ? null : 'right_arm_fast',
        'is_wicketkeeper': false,
      };
    }
    return u;
  }

  /// An owner with a club; returns (owner, club). Leaves the owner signed in.
  Future<(AuthUser, Club)> ownerWithClub([String email = 'owner@example.com']) async {
    final owner = signIn(email);
    final club = await repo.createClub(accountId: owner.id, name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);
    return (owner, club);
  }

  group('join by code', () {
    test('a valid code previews the club (no owner data, no code from the server)', () async {
      final (_, club) = await ownerWithClub();
      signIn('player@example.com');
      final preview = await repo.findClubByCode(club.code.toLowerCase());
      expect(preview, isNotNull);
      expect(preview!.name, 'Lahore Lions CC');
      expect(preview.city, 'Lahore');
      expect(preview.type, ClubType.corporate);
      expect(preview.code, club.code); // the typed code, upper-cased
      expect(preview.memberCount, 1); // the owner
    });

    test('an unknown or malformed code finds nothing', () async {
      await ownerWithClub();
      signIn('player@example.com');
      expect(await repo.findClubByCode('ZZZZZZ'), isNull);
      expect(await repo.findClubByCode('abc'), isNull);
      expect(await repo.findClubByCode(''), isNull);
    });

    test('sending creates one pending request, readable by the applicant', () async {
      final (_, club) = await ownerWithClub();
      signIn('player@example.com');
      final sent = await repo.requestToJoin(club.code);
      expect(sent.status, JoinRequestStatus.pending);
      expect(sent.clubName, 'Lahore Lions CC');
      expect(sent.id, isNotNull);
      final mine = await repo.myJoinRequest();
      expect(mine?.id, sent.id);
      expect(members.requests.where((r) => r['status'] == 'pending'), hasLength(1));
    });

    test('a second request while one is pending is refused', () async {
      final (_, club) = await ownerWithClub();
      signIn('player@example.com');
      await repo.requestToJoin(club.code);
      await expectLater(
        repo.requestToJoin(club.code),
        throwsA(isA<ClubMembershipException>().having((e) => e.message, 'message', contains('pending'))),
      );
      expect(members.requests, hasLength(1));
    });

    test('an unknown code, the own club and an incomplete profile are refused', () async {
      final (owner, club) = await ownerWithClub();
      await expectLater(repo.requestToJoin(club.code),
          throwsA(isA<ClubMembershipException>().having((e) => e.message, 'message', contains('own club'))));
      expect(owner.id, isNotEmpty);
      signIn('player@example.com');
      await expectLater(repo.requestToJoin('QQQQQQ'), throwsA(isA<ClubCodeNotFoundException>()));
      signIn('fresh@example.com', profileDone: false);
      await expectLater(repo.requestToJoin(club.code),
          throwsA(isA<ClubMembershipException>().having((e) => e.message, 'message', contains('profile'))));
    });

    test('one pending request per person, across clubs', () async {
      final (_, club) = await ownerWithClub();
      final other = signIn('other-owner@example.com');
      final club2 = await repo.createClub(accountId: other.id, name: 'Karachi Kings', city: 'Karachi', type: ClubType.professional);
      signIn('player@example.com');
      await repo.requestToJoin(club.code);
      await expectLater(repo.requestToJoin(club2.code),
          throwsA(isA<ClubMembershipException>().having((e) => e.message, 'message', contains('pending'))));
      final mine = (await repo.myJoinRequest())!;
      await repo.cancelJoinRequest(mine);
      expect((await repo.requestToJoin(club2.code)).clubName, 'Karachi Kings');
    });

    test('brute force: 10 failed codes in 15 minutes, then "too many attempts"', () async {
      final (_, club) = await ownerWithClub();
      signIn('prober@example.com');
      // Valid lookups don't count.
      for (var i = 0; i < 12; i++) {
        expect(await repo.findClubByCode(club.code), isNotNull);
      }
      for (var i = 0; i < 9; i++) {
        expect(await repo.findClubByCode('ZZZZ${i}A'), isNull);
      }
      // A request with an unknown code is a failed attempt too (the 10th).
      await expectLater(repo.requestToJoin('QQQQQQ'), throwsA(isA<ClubCodeNotFoundException>()));
      await expectLater(repo.findClubByCode(club.code), throwsA(isA<TooManyRequestsException>()));
      await expectLater(repo.requestToJoin(club.code), throwsA(isA<TooManyRequestsException>()));
      expect(members.requests, isEmpty);
      // 15 minutes later the window has passed.
      members.now = members.now.add(const Duration(minutes: 16));
      expect(await repo.findClubByCode(club.code), isNotNull);
    });

    test('the applicant can cancel a pending request, once', () async {
      final (_, club) = await ownerWithClub();
      signIn('player@example.com');
      final sent = await repo.requestToJoin(club.code);
      final cancelled = await repo.cancelJoinRequest(sent);
      expect(cancelled.status, JoinRequestStatus.cancelled);
      expect(await repo.myJoinRequest(), isNull); // a withdrawn request isn't shown again
      await expectLater(repo.cancelJoinRequest(sent), throwsA(isA<ClubMembershipException>()));
      // A new request is allowed after cancelling.
      expect((await repo.requestToJoin(club.code)).status, JoinRequestStatus.pending);
    });
  });

  group('owner decisions', () {
    test('the owner sees the applicant, approves, and the member appears once', () async {
      final (owner, club) = await ownerWithClub();
      final player = signIn('player@example.com');
      await repo.requestToJoin(club.code);
      auth.current = owner;

      final requests = await repo.joinRequests(club.id);
      expect(requests, hasLength(1));
      final r = requests.single;
      expect(r.name, 'Test Owner'); // FakeDb.completeProfile's name
      expect(r.city, 'Lahore');
      expect(r.age, 26); // born 2000-05-01; the owner never gets the date itself
      expect(members.calls, contains('clubJoinRequests'));
      expect(r.role, PlayerRole.batsman);
      expect(r.performance, isNull); // no match history — never made up
      expect(r.isPending, isTrue);

      final decided = await repo.decideJoinRequest(club.id, r.id, approve: true, at: DateTime(2026, 11, 16));
      expect(decided.review, JoinRequestReview.approved);
      expect(decided.assignedRole, MemberRole.player);

      // Deciding again returns it unchanged: no duplicate membership.
      final again = await repo.decideJoinRequest(club.id, r.id, approve: false, at: DateTime(2026, 11, 16));
      expect(again.review, JoinRequestReview.approved);
      final list = await repo.members(club.id);
      expect(list.where((m) => m.role == MemberRole.player), hasLength(1));
      expect(list.first.role, MemberRole.owner);

      // The player now sees the membership (and the club's code).
      auth.current = player;
      final mine = await repo.myMemberships();
      expect(mine.single.clubName, 'Lahore Lions CC');
      expect(mine.single.clubCode, club.code);
      expect((await repo.myJoinRequest())?.status, JoinRequestStatus.approved);
    });

    test('approval can give coach / manager, never owner', () async {
      final (owner, club) = await ownerWithClub();
      signIn('coach@example.com', playerRole: null);
      await repo.requestToJoin(club.code);
      auth.current = owner;
      final r = (await repo.joinRequests(club.id)).single;
      expect(
        () => repo.decideJoinRequest(club.id, r.id, approve: true, role: MemberRole.owner, at: DateTime(2026)),
        throwsArgumentError,
      );
      final decided = await repo.decideJoinRequest(club.id, r.id, approve: true, role: MemberRole.coach, at: DateTime(2026));
      expect(decided.assignedRole, MemberRole.coach);
      final coach = (await repo.members(club.id)).firstWhere((m) => m.role == MemberRole.coach);
      expect(coach.plays, isFalse); // no player profile → staff, not in the pool
      final pool = await repo.playerPool(club.id);
      expect(pool.map((p) => p.id), isNot(contains(coach.id)));
      // The owner has a player profile, so the owner can be picked.
      expect(pool.map((p) => p.id), [(await repo.members(club.id)).first.id]);
    });

    test('declining keeps the reason and adds no member', () async {
      final (owner, club) = await ownerWithClub();
      final player = signIn('player@example.com');
      await repo.requestToJoin(club.code);
      auth.current = owner;
      final r = (await repo.joinRequests(club.id)).single;
      final decided =
          await repo.decideJoinRequest(club.id, r.id, approve: false, reason: '  Squad is full  ', at: DateTime(2026));
      expect(decided.review, JoinRequestReview.declined);
      expect(decided.declineReason, 'Squad is full');
      expect((await repo.members(club.id)).where((m) => m.role != MemberRole.owner), isEmpty);
      auth.current = player;
      final mine = await repo.myJoinRequest();
      expect(mine?.status, JoinRequestStatus.declined);
      expect(mine?.declineReason, 'Squad is full');
    });

    test('someone who doesn\'t own the club can\'t see or decide its requests', () async {
      final (_, club) = await ownerWithClub();
      signIn('player@example.com');
      await repo.requestToJoin(club.code);
      final requestId = members.requests.single['id'] as String;
      signIn('intruder@example.com');
      await expectLater(repo.joinRequests(club.id), throwsA(isA<PermissionDeniedException>()));
      await expectLater(
        repo.decideJoinRequest(club.id, requestId, approve: true, at: DateTime(2026)),
        throwsA(isA<PermissionDeniedException>()),
      );
      await expectLater(repo.members(club.id), throwsA(isA<PermissionDeniedException>()));
      expect(members.requests.single['status'], 'pending');
    });
  });

  group('members', () {
    Future<(AuthUser, Club, AuthUser)> withMember() async {
      final (owner, club) = await ownerWithClub();
      final player = signIn('player@example.com');
      await repo.requestToJoin(club.code);
      auth.current = owner;
      final r = (await repo.joinRequests(club.id)).single;
      await repo.decideJoinRequest(club.id, r.id, approve: true, at: DateTime(2026));
      return (owner, club, player);
    }

    test('the player pool is the members who play, with their own ids', () async {
      final (_, club, _) = await withMember();
      final pool = await repo.playerPool(club.id);
      final list = await repo.members(club.id);
      final player = list.firstWhere((m) => m.role == MemberRole.player);
      expect(pool.map((p) => p.id), contains(player.id));
      expect(player.poolPlayerId, player.id);
      expect(pool.firstWhere((p) => p.id == player.id).position, 'Batsman');
      expect(await repo.memberActivity(club.id), isEmpty); // no match history stored
    });

    test('the owner removes a member; the owner row can\'t be removed', () async {
      final (_, club, _) = await withMember();
      final list = await repo.members(club.id);
      final member = list.firstWhere((m) => m.role == MemberRole.player);
      final ownerRow = list.firstWhere((m) => m.role == MemberRole.owner);
      await repo.removeMember(club.id, member.id);
      expect((await repo.members(club.id)).map((m) => m.id), isNot(contains(member.id)));
      await expectLater(repo.removeMember(club.id, ownerRow.id), throwsA(isA<PermissionDeniedException>()));
    });

    test('a removed member can ask again; approval re-activates the same row', () async {
      final (owner, club, player) = await withMember();
      final member = (await repo.members(club.id)).firstWhere((m) => m.role == MemberRole.player);
      await repo.removeMember(club.id, member.id);
      auth.current = player;
      expect(await repo.myMemberships(), isEmpty);
      await repo.requestToJoin(club.code);
      auth.current = owner;
      final r = (await repo.joinRequests(club.id)).firstWhere((x) => x.isPending);
      await repo.decideJoinRequest(club.id, r.id, approve: true, at: DateTime(2026));
      final again = (await repo.members(club.id)).firstWhere((m) => m.role == MemberRole.player);
      expect(again.id, member.id); // one row per (club, person)
      expect(members.members.where((m) => m['user_id'] == player.id), hasLength(1));
    });

    test('a non-owner can\'t remove members', () async {
      final (_, club, player) = await withMember();
      final memberId = members.members.firstWhere((m) => m['user_id'] == player.id)['id'] as String;
      signIn('intruder@example.com');
      await expectLater(repo.removeMember(club.id, memberId), throwsA(isA<PermissionDeniedException>()));
    });
  });

  group('failures', () {
    test('offline → BackendUnavailableException, nothing written', () async {
      final (_, club) = await ownerWithClub();
      signIn('player@example.com');
      members.failNext = const GatewayNetworkException();
      await expectLater(repo.requestToJoin(club.code), throwsA(isA<BackendUnavailableException>()));
      expect(members.requests, isEmpty);
    });

    test('signed out → NotSignedInException', () async {
      final (_, club) = await ownerWithClub();
      auth.current = null;
      await expectLater(repo.findClubByCode(club.code), throwsA(isA<NotSignedInException>()));
    });
  });

  group('without the memberships switch', () {
    test('join by code isn\'t offered, removal isn\'t either; nothing simulated', () async {
      final off = newRepo(switchOn: false);
      final owner = signIn('owner@example.com');
      final club = await off.createClub(accountId: owner.id, name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);
      await expectLater(off.findClubByCode(club.code), throwsA(isA<ClubJoinUnavailableException>()));
      await expectLater(off.requestToJoin(club.code), throwsA(isA<ClubJoinUnavailableException>()));
      await expectLater(off.removeMember(club.id, 'x'), throwsA(isA<ClubJoinUnavailableException>()));
      expect(await off.myJoinRequest(), isNull);
      expect(await off.myMemberships(), isEmpty);
      expect(await off.members(club.id), isEmpty);
      expect(members.calls, isEmpty);
    });

    test('other clubs are never the demo\'s clubs (either way)', () async {
      expect(await newRepo(switchOn: false).otherClubs(), isEmpty);
      expect(await repo.otherClubs(), isEmpty);
      expect(await repo.clubSummary(SeedData.ownClubId), isNull);
    });
  });

  group('row mapping', () {
    test('phone, age and applied label', () {
      expect(MembershipRowMapper.displayPhone('+923001234567'), '03001234567');
      expect(MembershipRowMapper.ageOn(DateTime(2000, 5, 1), DateTime(2026, 4, 30)), 25);
      expect(MembershipRowMapper.ageOn(DateTime(2000, 5, 1), DateTime(2026, 5, 1)), 26);
      expect(MembershipRowMapper.ageOn(null, DateTime(2026)), 0);
      final now = DateTime(2026, 11, 16, 12);
      expect(MembershipRowMapper.appliedLabel(DateTime(2026, 11, 16, 9), now), 'Applied today');
      expect(MembershipRowMapper.appliedLabel(DateTime(2026, 11, 15, 23), now), 'Applied 1 day ago');
      expect(MembershipRowMapper.appliedLabel(DateTime(2026, 11, 11), now), 'Applied 5 days ago');
    });

    test('request status codes', () {
      expect(MembershipRowMapper.requestStatusFromCode('pending'), JoinRequestStatus.pending);
      expect(MembershipRowMapper.requestStatusFromCode('approved'), JoinRequestStatus.approved);
      expect(MembershipRowMapper.requestStatusFromCode('rejected'), JoinRequestStatus.declined);
      expect(MembershipRowMapper.requestStatusFromCode('cancelled'), JoinRequestStatus.cancelled);
    });
  });
}
