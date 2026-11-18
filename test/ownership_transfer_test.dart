// Club ownership transfer (migration 16) in Supabase mode over fakes that
// apply the database functions' rules: offer, duplicate / ineligible /
// unauthorized refusals, decline, cancel, expiry, accept (the session moves:
// the new owner gains the Club Owner profile, the old owner loses it and its
// owner functions), memberships / teams unchanged, account-deletion
// eligibility afterwards, and the screens. No network, no database.
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/account_privacy.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/club/ownership/ownership_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'membership_fakes.dart';
import 'ownership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

const _password = 'Cricket@123';

/// Account deletion on the server: deletes once the password is right.
class _Privacy implements AccountPrivacyGateway {
  bool deleted = false;
  @override
  Future<bool> fetchPhoneSharing() async => false;
  @override
  Future<void> setPhoneSharing(bool share) async {}
  @override
  Future<void> deleteAccount({required String password}) async => deleted = true;
}

class _World {
  late FakeDb db;
  late FakeAuth auth;
  late FakeClubDb clubs;
  late FakeMembershipDb memberships;
  late FakeTeamDb teams;
  late FakeOwnershipDb ownership;
  late _Privacy privacy;
  late ProviderContainer c;
  late AuthUser owner, a, b, other, incomplete;
  late Club club;
  late Map<String, String> memberIds; // email → club member id

  AuthUser user(String email, {String? name}) {
    final u = auth.addUser(email, _password);
    db.completeProfile(u.id);
    if (name != null) db.profiles[u.id]!['full_name'] = name;
    db.players[u.id] = {
      'user_id': u.id,
      'player_role': 'all_rounder',
      'batting_style': 'right_handed',
      'bowling_style': 'right_arm_fast',
      'is_wicketkeeper': false,
    };
    return u;
  }

  Future<void> signInAs(AuthUser u) async {
    if (c.read(sessionProvider).isAuthenticated) c.read(sessionProvider.notifier).logout();
    expect(await c.read(sessionProvider.notifier).signIn(identifier: u.email!, password: _password), isTrue);
  }

  OwnershipActions get actions => c.read(ownershipActionsProvider.notifier);
  OwnershipTransferRepository get repo => c.read(ownershipTransferRepositoryProvider);

  Future<void> build() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    clubs = FakeClubDb(db);
    memberships = FakeMembershipDb(db, clubs);
    teams = FakeTeamDb(memberships);
    ownership = FakeOwnershipDb(memberships);
    privacy = _Privacy();
    c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        backendConfigProvider.overrideWithValue(_supabase),
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(clubs),
        membershipGatewayProvider.overrideWithValue(memberships),
        teamGatewayProvider.overrideWithValue(teams),
        ownershipGatewayProvider.overrideWithValue(ownership),
        accountPrivacyGatewayProvider.overrideWithValue(privacy),
        locationGatewayProvider.overrideWithValue(FakeLocationGateway()),
        membershipsEnabledProvider.overrideWithValue(true),
        accountPrivacyEnabledProvider.overrideWithValue(true),
      ],
    );
    owner = user('owner@example.com', name: 'Omar Owner');
    a = user('a@example.com', name: 'Ali Member');
    b = user('b@example.com', name: 'Bilal Member');
    other = user('other@example.com', name: 'Owais Otherclub');
    incomplete = user('c@example.com', name: 'Chand Incomplete');

    // Another club, owned by "other".
    await signInAs(other);
    await c.read(sessionProvider.notifier).createClub(name: 'Other Club', city: 'Karachi', type: ClubType.professional);
    // The club being transferred, with four members and a team.
    await signInAs(owner);
    club = await c
        .read(sessionProvider.notifier)
        .createClub(name: 'Lahore Lions', city: 'Lahore', type: ClubType.corporate);
    for (final u in [a, b, other, incomplete]) {
      memberships.requestAs(u, club.code);
    }
    auth.current = owner;
    final clubRepo = c.read(clubRepositoryProvider);
    for (final r in await clubRepo.joinRequests(club.id)) {
      if (r.isPending) await clubRepo.decideJoinRequest(club.id, r.id, approve: true, at: DateTime(2026));
    }
    memberIds = {
      for (final m in memberships.members.where((m) => m['club_id'] == club.id))
        db.profiles[m['user_id']]!['full_name'] as String: m['id'] as String,
    };
    db.profiles[incomplete.id]!['profile_completed'] = false;
    final team = await c
        .read(teamRepositoryProvider)
        .create(clubId: club.id, name: 'First XI', format: MatchFormat.t20);
    await c
        .read(teamRepositoryProvider)
        .save(
          team.copyWith(
            members: [
              TeamMember(playerId: memberIds['Ali Member']!, selection: SelectionRole.playing),
              TeamMember(playerId: memberIds['Bilal Member']!, selection: SelectionRole.playing),
            ],
            captainId: memberIds['Ali Member'],
            viceCaptainId: memberIds['Bilal Member'],
          ),
        );
  }

  ClubMember member(String name) {
    final id = memberIds[name]!;
    return ClubMember(id: id, name: name, role: MemberRole.player);
  }
}

void main() {
  late _World w;

  setUp(() async {
    w = _World();
    await w.build();
    addTearDown(w.c.dispose);
  });

  group('offers', () {
    test('the owner offers; nothing changes until the member answers', () async {
      final offer = await w.actions.offer(member: w.member('Ali Member'), formerOwnerRole: MemberRole.manager);
      expect(offer.status, OwnershipTransferStatus.pending);
      expect(w.clubs.clubs[w.owner.id]?['id'], w.club.id, reason: 'still the owner');
      expect(w.c.read(sessionProvider).ownClub?.id, w.club.id);
      final history = await w.c.read(clubOwnershipTransfersProvider.future);
      expect(history.single.isPending, isTrue);
      expect(history.single.toName, 'Ali Member');
      expect(history.single.fromMe, isTrue);
    });

    test('a second open offer is refused; after cancelling, a new one is allowed', () async {
      final first = await w.actions.offer(member: w.member('Ali Member'), formerOwnerRole: MemberRole.manager);
      await expectLater(
        w.actions.offer(member: w.member('Bilal Member'), formerOwnerRole: MemberRole.manager),
        throwsA(
          isA<OwnershipTransferException>().having((e) => e.message, 'message', contains('open ownership offer')),
        ),
      );
      expect((await w.actions.cancel(first.id)).status, OwnershipTransferStatus.cancelled);
      expect(
        (await w.actions.offer(member: w.member('Bilal Member'), formerOwnerRole: MemberRole.coach)).isPending,
        isTrue,
      );
    });

    test('ineligible members are refused with the reason', () async {
      await expectLater(
        w.actions.offer(member: w.member('Owais Otherclub'), formerOwnerRole: MemberRole.manager),
        throwsA(isA<OwnershipTransferException>().having((e) => e.message, 'm', contains('already owns a club'))),
      );
      await expectLater(
        w.actions.offer(member: w.member('Chand Incomplete'), formerOwnerRole: MemberRole.manager),
        throwsA(isA<OwnershipTransferException>().having((e) => e.message, 'm', contains('completed their profile'))),
      );
      final ownerRow = w.memberships.members.firstWhere((m) => m['user_id'] == w.owner.id && m['club_id'] == w.club.id);
      await expectLater(
        w.repo.offer(clubId: w.club.id, memberId: ownerRow['id'] as String, previousOwnerRole: MemberRole.manager),
        throwsA(isA<OwnershipTransferException>().having((e) => e.message, 'm', contains('already own'))),
      );
      await expectLater(
        w.repo.offer(clubId: w.club.id, memberId: 'nobody', previousOwnerRole: MemberRole.manager),
        throwsA(isA<OwnershipTransferException>()),
      );
      await expectLater(
        w.repo.offer(clubId: w.club.id, memberId: w.memberIds['Ali Member']!, previousOwnerRole: MemberRole.owner),
        throwsA(isA<OwnershipTransferException>()),
      );
      expect(w.ownership.transfers, isEmpty);
    });

    test('a member or an outsider cannot offer the club', () async {
      await w.signInAs(w.a);
      await expectLater(
        w.repo.offer(clubId: w.club.id, memberId: w.memberIds['Bilal Member']!, previousOwnerRole: MemberRole.manager),
        throwsA(isA<PermissionDeniedException>()),
      );
      expect(w.ownership.transfers, isEmpty);
    });
  });

  group('answers', () {
    late OwnershipTransfer offer;
    setUp(() async {
      offer = await w.actions.offer(member: w.member('Ali Member'), formerOwnerRole: MemberRole.manager);
    });

    test('only the recipient sees the offer; someone else can\'t answer it', () async {
      await w.signInAs(w.b);
      expect(await w.c.read(myOwnershipOffersProvider.future), isEmpty);
      await expectLater(w.repo.accept(offer.id), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.repo.reject(offer.id), throwsA(isA<PermissionDeniedException>()));
      await w.signInAs(w.a);
      final mine = await w.c.read(myOwnershipOffersProvider.future);
      expect(mine.single.clubName, 'Lahore Lions');
      expect(mine.single.fromName, 'Omar Owner');
      await expectLater(
        w.repo.cancel(offer.id),
        throwsA(isA<PermissionDeniedException>()),
        reason: 'the recipient declines, the owner cancels',
      );
    });

    test('decline: nothing changes; the offer can\'t be accepted afterwards', () async {
      await w.signInAs(w.a);
      expect((await w.actions.decline(offer.id)).status, OwnershipTransferStatus.rejected);
      await expectLater(
        w.repo.accept(offer.id),
        throwsA(isA<OwnershipTransferException>().having((e) => e.message, 'm', contains('already been answered'))),
      );
      expect(w.clubs.clubs[w.owner.id]?['id'], w.club.id);
      expect(await w.c.read(myOwnershipOffersProvider.future), isEmpty);
    });

    test('an expired offer: not listed, accepting it changes nothing', () async {
      w.ownership.now = w.ownership.now.add(const Duration(days: 8));
      await w.signInAs(w.a);
      expect(await w.c.read(myOwnershipOffersProvider.future), isEmpty);
      expect((await w.actions.accept(offer.id)).status, OwnershipTransferStatus.expired);
      expect(w.clubs.clubs[w.owner.id]?['id'], w.club.id);
      expect(w.c.read(sessionProvider).ownClub, isNull, reason: 'still not an owner');
    });

    test('accept: the club, roles and permissions move; members and teams are unchanged; '
        'the former owner can delete their account, the new one can\'t', () async {
      final membersBefore = w.memberships.members.where((m) => m['club_id'] == w.club.id).length;
      final squadBefore = w.teams.players.length;
      await w.signInAs(w.a);
      final accepted = await w.actions.accept(offer.id);
      expect(accepted.status, OwnershipTransferStatus.accepted);

      // The new owner: the session has the club now.
      final session = w.c.read(sessionProvider);
      expect(session.hasClubOwnerProfile, isTrue);
      expect(session.ownClub?.id, w.club.id);
      expect(w.c.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner), isA<GoToLocation>());
      expect((await w.c.read(clubRepositoryProvider).members(w.club.id)).length, membersBefore);

      // Roles: one owner (the new one); the former owner is a manager.
      final rows = w.memberships.members.where((m) => m['club_id'] == w.club.id).toList();
      expect(rows.where((m) => m['member_role'] == 'owner').single['user_id'], w.a.id);
      expect(rows.firstWhere((m) => m['user_id'] == w.owner.id)['member_role'], 'manager');
      expect(rows.length, membersBefore);
      expect(w.teams.players.length, squadBefore);
      final team = w.teams.teams.single;
      expect(team['captain_member_id'], w.memberIds['Ali Member']);
      expect(team['vice_captain_member_id'], w.memberIds['Bilal Member']);
      await expectLater(
        w.c.read(accountRepositoryProvider).deleteAccount(w.a.id, password: _password),
        throwsA(isA<ClubOwnershipTransferRequiredException>()),
      );

      // The former owner: no club, no owner functions, may delete the account.
      await w.signInAs(w.owner);
      expect(w.c.read(sessionProvider).hasClubOwnerProfile, isFalse);
      expect(w.c.read(sessionProvider).ownClub, isNull);
      await expectLater(w.c.read(clubRepositoryProvider).members(w.club.id), throwsA(isA<PermissionDeniedException>()));
      final history = await w.c.read(clubOwnershipTransfersProvider.future);
      expect(history, isEmpty, reason: 'no own club to read the history of');
      await w.c.read(accountRepositoryProvider).deleteAccount(w.owner.id, password: _password);
      expect(w.privacy.deleted, isTrue);
    });
  });

  test('without the server side (demo, or before migration 16): nothing listed, changes not available', () async {
    const off = UnavailableOwnershipTransferRepository();
    expect(await off.myOffers(), isEmpty);
    expect(await off.clubTransfers('c1'), isEmpty);
    await expectLater(
      off.offer(clubId: 'c1', memberId: 'm1', previousOwnerRole: MemberRole.manager),
      throwsA(isA<ModuleUnavailableException>()),
    );
    final demo = ProviderContainer();
    addTearDown(demo.dispose);
    expect(demo.read(ownershipTransferAvailableProvider), isFalse);
  });

  group('screens', () {
    Future<void> pumpApp(WidgetTester tester, UserRole role) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(container: w.c, child: const CricEcoApp()));
      await tester.pumpAndSettle();
      final nav = w.c.read(roleControllerProvider.notifier).continueAs(role);
      w.c.read(routerProvider).go((nav as GoToLocation).location);
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    /// The confirmation sheet's button (the sheet is on top: the last match).
    Future<void> confirm(WidgetTester tester, String label) => tap(tester, find.text(label).last);

    testWidgets('owner: pick a member and a role, send; the open offer can be cancelled; history', (tester) async {
      await pumpApp(tester, UserRole.clubOwner);
      w.c.read(routerProvider).go(Routes.myClub);
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('myClub.transferOwnership')));
      expect(w.c.read(routerProvider).state.uri.path, Routes.transferOwnership);
      expect(find.text('Transfer Ownership'), findsWidgets);
      await tap(tester, find.byKey(Key('ownership.member.${w.memberIds['Ali Member']}')));
      await tap(tester, find.byKey(const Key('ownership.role.coach')));
      await tap(tester, find.byKey(const Key('ownership.send')));
      await confirm(tester, 'Send Offer');
      expect(find.byKey(const Key('ownership.pending')), findsOneWidget);
      expect(w.ownership.transfers.single['previous_owner_role'], 'coach');
      expect(w.clubs.clubs[w.owner.id]?['id'], w.club.id, reason: 'an offer moves nothing');

      await tap(tester, find.byKey(const Key('ownership.cancel')));
      await confirm(tester, 'Cancel Offer');
      expect(find.byKey(const Key('ownership.pending')), findsNothing);
      expect(
        find.byKey(Key('ownership.history.${w.ownership.transfers.single['id']}')),
        findsOneWidget,
        reason: 'in the history',
      );
      expect(w.ownership.transfers.single['status'], 'cancelled');
      expect(find.byKey(const Key('ownership.send')), findsOneWidget, reason: 'a new offer can be made');
    });

    testWidgets('recipient: the dashboard banner, accept → Club Owner home with the club', (tester) async {
      await w.actions.offer(member: w.member('Ali Member'), formerOwnerRole: MemberRole.manager);
      await w.signInAs(w.a);
      await pumpApp(tester, UserRole.player);
      expect(find.byKey(const Key('player.ownershipOffer')), findsOneWidget);
      await tap(tester, find.byKey(const Key('player.ownershipOffer')));
      expect(w.c.read(routerProvider).state.uri.path, Routes.ownershipOffers);
      final id = w.ownership.transfers.single['id'];
      await tap(tester, find.byKey(Key('offers.accept.$id')));
      await confirm(tester, 'Accept Ownership');
      expect(w.c.read(sessionProvider).ownClub?.id, w.club.id);
      expect(w.c.read(activeRoleProvider), UserRole.clubOwner);
      expect(w.c.read(routerProvider).state.uri.path, Routes.clubHome);
    });

    testWidgets('former owner (still signed in when it was accepted): "now the owner" → Continue as a player', (
      tester,
    ) async {
      final offer = await w.actions.offer(member: w.member('Ali Member'), formerOwnerRole: MemberRole.manager);
      // The member accepts on their own phone.
      w.auth.current = w.a;
      await w.ownership.accept(offer.id);
      w.auth.current = w.owner;
      await pumpApp(tester, UserRole.clubOwner);
      w.c.invalidate(clubOwnershipTransfersProvider);
      w.c.read(routerProvider).go(Routes.transferOwnership);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ownership.moved')), findsOneWidget);
      await tap(tester, find.byKey(const Key('ownership.continue')));
      await tester.pumpAndSettle();
      expect(w.c.read(sessionProvider).ownClub, isNull);
      expect(w.c.read(activeRoleProvider), UserRole.player);
      expect(w.c.read(routerProvider).state.uri.path, Routes.playerHome);
    });

    testWidgets('Delete Account for an owner offers Transfer Ownership', (tester) async {
      await pumpApp(tester, UserRole.clubOwner);
      w.c.read(routerProvider).go(Routes.deleteAccount);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('deleteAccount.ownershipRequired')), findsOneWidget);
      await tap(tester, find.text('Transfer Ownership'));
      expect(w.c.read(routerProvider).state.uri.path, Routes.transferOwnership);
    });
  });
}
