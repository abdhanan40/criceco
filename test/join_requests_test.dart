import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/requests/join_requests_controller.dart';
import 'package:criceco/features/club/screens/members_screen.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 24, 11);

Future<ProviderContainer> _ownerContainer() async {
  final c = await makeContainer(clock: TestClock(_now));
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  await c.read(joinRequestsProvider.future);
  return c;
}

Future<ProviderContainer> _pumpOwner(WidgetTester tester, {double width = 375}) async {
  tester.view.physicalSize = Size(width * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    clockProvider.overrideWithValue(Clock.fixed(_now)),
    nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  final nav = c.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

void main() {
  group('Join request rules (controller + repository)', () {
    test('approve as Coach creates a Coach club membership only — never ownership', () async {
      final c = await _ownerContainer();
      final accountBefore = c.read(currentAccountProvider)!;
      final ctrl = c.read(joinRequestsProvider.notifier);

      final decided = await ctrl.approve('jr_2', role: MemberRole.coach);
      expect(decided!.review, JoinRequestReview.approved);
      expect(decided.assignedRole, MemberRole.coach);
      expect(decided.decidedAt, _now);

      final members = await c.read(clubMembersProvider.future);
      final hamza = members.singleWhere((m) => m.name == 'Hamza Sheikh');
      expect(hamza.role, MemberRole.coach);
      expect(members.where((m) => m.role == MemberRole.owner), hasLength(1), reason: 'still one owner');

      // The signed-in account and the active role are untouched.
      final accountAfter = c.read(currentAccountProvider)!;
      expect(accountAfter.memberships.length, accountBefore.memberships.length);
      expect(accountAfter.hasClubOwnerProfile, accountBefore.hasClubOwnerProfile);

      // Ownership can never be granted through a request.
      await expectLater(
        c.read(clubRepositoryProvider).decideJoinRequest(SeedData.ownClubId, 'jr_1',
            approve: true, role: MemberRole.owner, at: _now),
        throwsArgumentError,
      );
    });

    test('decline adds no member; deciding twice is idempotent; counts update', () async {
      final c = await _ownerContainer();
      final ctrl = c.read(joinRequestsProvider.notifier);
      expect(c.read(pendingJoinRequestCountProvider), 3);

      final declined = await ctrl.decline('jr_3');
      expect(declined!.review, JoinRequestReview.declined);
      expect(declined.assignedRole, isNull);
      expect((await c.read(clubMembersProvider.future)).any((m) => m.name == 'Usman Tariq'), isFalse);

      await ctrl.approve('jr_1');
      await ctrl.approve('jr_1'); // double tap
      final members = await c.read(clubMembersProvider.future);
      expect(members.where((m) => m.name == 'Bilal Ahmed'), hasLength(1));
      expect(members.singleWhere((m) => m.name == 'Bilal Ahmed').role, MemberRole.player);

      expect(c.read(pendingJoinRequestCountProvider), 1);
      expect(c.read(joinRequestsByReviewProvider(JoinRequestReview.approved)).map((r) => r.id), ['jr_1']);
      expect(c.read(joinRequestsByReviewProvider(JoinRequestReview.declined)).map((r) => r.id), ['jr_3']);
      expect(c.read(joinRequestsByReviewProvider(JoinRequestReview.pending)).map((r) => r.id), ['jr_2']);
    });
  });

  group('Requests screen', () {
    testWidgets('row Accept asks "Approve this request?" then approves as Player; dashboard, tabs and Members update', (tester) async {
      final c = await _pumpOwner(tester);
      expect(find.bySemanticsLabel('Requests, 3'), findsOneWidget); // dashboard Requests tile
      await _go(tester, c, Routes.joinRequests); // the Requests screen (request links)
      expect(_loc(c), Routes.joinRequests);
      expect(find.bySemanticsLabel('3 pending requests'), findsOneWidget);
      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('Batsman · Applied 2 days ago'), findsOneWidget);

      // Approve is never immediate: Cancel leaves the request pending.
      await tester.tap(find.byTooltip('Accept Bilal Ahmed'));
      await tester.pumpAndSettle();
      expect(find.text('Approve this request?'), findsOneWidget);
      expect(find.textContaining('Are you sure you want to approve this player'), findsOneWidget);
      await _tap(tester, _button('Cancel'));
      expect(c.read(pendingJoinRequestCountProvider), 3, reason: 'nothing approved');
      expect(find.text('Bilal Ahmed'), findsOneWidget);

      await tester.tap(find.byTooltip('Accept Bilal Ahmed'));
      await tester.pumpAndSettle();
      await _tap(tester, _button('Approve'));
      expect(find.text('Bilal Ahmed added to the club as Player'), findsOneWidget);
      expect(find.text('Bilal Ahmed'), findsNothing, reason: 'moved out of Pending');
      expect(find.bySemanticsLabel('2 pending requests'), findsOneWidget);

      await _tap(tester, find.text('Approved'));
      expect(_loc(c), '${Routes.joinRequests}?tab=approved');
      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('PLAYER'), findsOneWidget);

      await _go(tester, c, Routes.members);
      expect(find.text('Bilal Ahmed'), findsOneWidget);
      // Approved as a Player: the applicant's cricket role and a Fitness Meter score.
      expect(find.bySemanticsLabel(RegExp(r'^Bilal Ahmed, Batsman, Fitness 10 out of 10')), findsOneWidget);
      expect(find.bySemanticsLabel('22 members'), findsOneWidget);

      await _go(tester, c, Routes.clubHome);
      expect(c.read(pendingJoinRequestCountProvider), 2);
      expect(find.bySemanticsLabel('Requests, 2', skipOffstage: false), findsOneWidget);
    });

    testWidgets('row ✕ asks for a reason, then declines; Declined tab lists it; Pending empties with the prototype copy',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.joinRequests);
      // Not immediate: the sheet offers a suggested reason and a short message.
      await tester.tap(find.byTooltip('Decline Usman Tariq'));
      await tester.pumpAndSettle();
      expect(find.text('Decline Request?'), findsOneWidget);
      expect(find.text('Our squad is currently full.'), findsWidgets);
      await _tap(tester, _button('Cancel'));
      expect(c.read(pendingJoinRequestCountProvider), 3, reason: 'nothing declined');
      for (final name in ['Usman Tariq', 'Hamza Sheikh', 'Bilal Ahmed']) {
        await tester.tap(find.byTooltip('Decline $name'));
        await tester.pumpAndSettle();
        if (name == 'Hamza Sheikh') {
          await tester.enterText(find.byKey(const Key('joinRequest.declineReason')), '  Trials reopen in March. ');
          await tester.pumpAndSettle();
        }
        await _tap(tester, _button('Decline Request')); // reason sheet
        expect(find.text('Request from $name declined'), findsOneWidget);
      }
      // Suggested reason by default; a custom short message when typed.
      expect(c.read(joinRequestProvider('jr_3'))!.declineReason, 'Our squad is currently full.');
      expect(c.read(joinRequestProvider('jr_2'))!.declineReason, 'Trials reopen in March.');
      expect(find.text('No pending requests'), findsOneWidget);
      expect(find.text('All requests have been reviewed'), findsOneWidget);
      await _tap(tester, find.text('Declined'));
      expect(find.text('DECLINED'), findsNWidgets(3));
      expect((await c.read(clubMembersProvider.future)).length, 21, reason: 'no one added');
    });
  });

  group('Requester profile', () {
    testWidgets('shows details + performance; approve as Coach from the role sheet', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.joinRequests);
      await _tap(tester, find.text('Hamza Sheikh'));
      expect(_loc(c), Routes.joinRequestProfile('jr_2'));
      expect(find.text('Bowler · Islamabad'), findsOneWidget);
      expect(find.text('Left-handed'), findsOneWidget);
      expect(find.text('0333-9876543'), findsOneWidget);
      expect(find.text('23'), findsOneWidget); // wickets

      await _tap(tester, find.byKey(const Key('joinRequest.role')));
      await tester.tap(find.text('Coach').last);
      await tester.pumpAndSettle();
      await _tap(tester, _button('Approve'));
      expect(find.text('Approve this request?'), findsOneWidget);
      expect(find.textContaining('will be added as Coach'), findsOneWidget);
      expect(c.read(joinRequestProvider('jr_2'))!.isPending, isTrue, reason: 'not approved before confirming');
      await _tap(tester, _button('Approve').last);
      expect(_loc(c), Routes.joinRequests, reason: 'back to Requests like the prototype');
      expect(find.text('Hamza Sheikh added to the club as Coach'), findsOneWidget);

      final member = (await c.read(clubMembersProvider.future)).singleWhere((m) => m.name == 'Hamza Sheikh');
      expect(member.role, MemberRole.coach);
      expect(c.read(activeRoleProvider), UserRole.clubOwner);

      // Reviewed profile: outcome, no review controls.
      await _go(tester, c, Routes.joinRequestProfile('jr_2'));
      expect(find.textContaining('Approved as Coach'), findsOneWidget);
      expect(_button('Approve'), findsNothing);
      await tester.pump(const Duration(seconds: 2)); // let the approval toast clear
      await tester.pumpAndSettle();
      await _tap(tester, _button('View Members'));
      expect(_loc(c), Routes.members);
      await tester.enterText(find.byType(TextField), 'Hamza');
      await tester.pumpAndSettle();
      // A Coach is club staff: role shown, no fitness score.
      expect(find.descendant(of: find.byType(MemberRow), matching: find.text('Coach')), findsOneWidget);
      expect(find.text('Club Staff · 1'), findsOneWidget);
    });

    testWidgets('Reject from profile; no-performance and not-found states', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.joinRequests);
      await _tap(tester, find.text('Usman Tariq'));
      expect(find.text('No performance data available yet.'), findsOneWidget);
      await _tap(tester, _button('Reject'));
      expect(find.text('Decline Request?'), findsOneWidget);
      expect(c.read(joinRequestProvider('jr_3'))!.isPending, isTrue, reason: 'not declined before confirming');
      await _tap(tester, find.text('Trials are closed for this season.'));
      await _tap(tester, _button('Decline Request'));
      expect(find.text('Request from Usman Tariq declined'), findsOneWidget);
      expect(c.read(joinRequestProvider('jr_3'))!.declineReason, 'Trials are closed for this season.');
      expect(c.read(joinRequestProvider('jr_3'))!.review, JoinRequestReview.declined);

      await _go(tester, c, Routes.joinRequestProfile('jr_3'));
      expect(find.textContaining('Request declined'), findsOneWidget);
      expect(find.textContaining('Reason: Trials are closed for this season.'), findsOneWidget);
      expect(_button('Reject'), findsNothing);

      await _go(tester, c, Routes.joinRequestProfile('nope'));
      expect(find.text('Request not found'), findsOneWidget);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 4 screens render without overflow at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        final ctrl = c.read(joinRequestsProvider.notifier);
        await ctrl.approve('jr_1', role: MemberRole.manager);
        await ctrl.decline('jr_3', reason: 'Our squad is currently full.');
        // Review sheets: decline reason (list) and approve confirmation (profile).
        await _go(tester, c, Routes.joinRequests);
        await tester.tap(find.byTooltip('Decline Hamza Sheikh'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'decline sheet @ $width');
        await _tap(tester, _button('Cancel'));
        await _go(tester, c, Routes.joinRequestProfile('jr_2'));
        await _tap(tester, _button('Approve'));
        expect(tester.takeException(), isNull, reason: 'approve sheet @ $width');
        await _tap(tester, _button('Cancel'));
        for (final loc in [
          Routes.joinRequests,
          '${Routes.joinRequests}?tab=approved',
          '${Routes.joinRequests}?tab=declined',
          Routes.joinRequestProfile('jr_2'), // pending, with performance
          Routes.joinRequestProfile('jr_1'), // approved
          Routes.joinRequestProfile('jr_3'), // declined, no performance
          Routes.members,
          Routes.clubHome,
        ]) {
          await _go(tester, c, loc);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 8; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
      });
    }
  });
}
