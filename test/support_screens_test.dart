import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/role_destinations.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:criceco/features/club/hunt/player_hunt_controller.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/matches/lineup_controller.dart';
import 'package:criceco/features/notifications/notifications_controller.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/features/settings/settings_screens.dart';
import 'package:criceco/features/tournaments/registration_draft.dart';
import 'package:criceco/features/tournaments/tournament_demo_actions.dart';
import 'package:criceco/features/tournaments/tournaments_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_rows.dart';
import 'package:criceco/shared/widgets/ce_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 25, 9);

Future<ProviderContainer> _signedIn({bool club = false}) async {
  final c = await makeContainer(clock: TestClock(_now));
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'secret1');
  if (club) {
    await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  }
  c.read(roleControllerProvider.notifier).continueAs(club ? UserRole.clubOwner : UserRole.player);
  return c;
}

/// A full 11 + 4 squad confirmed for [tournamentId], rules agreed.
Future<TournamentRegistration> _register(ProviderContainer c, String tournamentId) async {
  await c.read(tournamentRegistrationsProvider.future);
  final pool = await c.read(clubPlayerPoolProvider.future);
  final ctrl = c.read(lineupDraftProvider(TournamentEntryTarget(tournamentId)).notifier)..startNew();
  for (final p in pool.where((p) => !p.locked).take(15)) {
    ctrl.cycle(p);
  }
  await ctrl.confirmBuilt();
  c.read(registrationDraftProvider(tournamentId).notifier).setAgreed(true);
  return (await c.read(tournamentRegistrationsProvider.notifier).submit(tournamentId)).registration!;
}

// ---- Widget harness -------------------------------------------------------

Future<ProviderContainer> _pump(WidgetTester tester,
    {bool club = false, double width = 375, List<dynamic> overrides = const []}) async {
  tester.view.physicalSize = Size(width * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    clockProvider.overrideWithValue(Clock.fixed(_now)),
    nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ...overrides.cast(),
  ]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
  await tester.pumpAndSettle();
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'secret1');
  if (club) await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  final nav = c.read(roleControllerProvider.notifier).continueAs(club ? UserRole.clubOwner : UserRole.player);
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
    await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _clearToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

void main() {
  group('Notifications', () {
    test('every seeded row targets a real entity inside its own role', () async {
      final c = await _signedIn(club: true);
      for (final role in UserRole.values) {
        final items = await c.read(roleNotificationsProvider(role).future);
        expect(items, isNotEmpty);
        expect(items.map((n) => n.role), everyElement(role), reason: 'inboxes never mix roles');
        final times = items.map((n) => n.createdAt).toList();
        expect(times, [...times]..sort((a, b) => b.compareTo(a)), reason: 'newest first');
        for (final n in items) {
          final loc = notificationLocation(n.target);
          if (loc == null) continue;
          expect(role == UserRole.player ? Routes.isPlayerLocation(loc) : Routes.isClubLocation(loc), isTrue,
              reason: '${n.id} → $loc');
        }
      }
      final club = {for (final n in await c.read(roleNotificationsProvider(UserRole.clubOwner).future)) n.id: n};
      expect(notificationLocation(club['n_c1']!.target), Routes.joinRequestProfile('jr_1'));
      expect(club['n_c2']!.title, 'Challenge received from DHA Bulls CC', reason: 'names the seeded received challenge');
      expect(club['n_c3']!.subtitle, 'National Stadium booking confirmed', reason: 'names the confirmed booking');
      expect(notificationLocation(club['n_c4']!.target), Routes.myRegistrationsIn(RegistrationStatus.approved));
      final player = {for (final n in await c.read(roleNotificationsProvider(UserRole.player).future)) n.id: n};
      expect(notificationLocation(player['n_p1']!.target), Routes.playerMatchDetails('pm_1'));
      expect(player['n_p4']!.target, isNull, reason: 'P16: non-navigating');
    });

    test('tournament events raise specific notifications (decisions and incoming requests)', () async {
      final c = await _signedIn(club: true);
      final reg = await _register(c, 't_1');
      await c.read(tournamentDemoActionsProvider).organizerDecides(reg.id, approve: true);
      final hosted = await c.read(tournamentsProvider.notifier).create(TournamentInput(
            name: 'Shalimar Cup',
            city: 'Islamabad',
            ground: 'Pindi Cricket Ground',
            format: MatchFormat.t20,
            type: TournamentType.knockout,
            startDate: _now.add(const Duration(days: 20)),
            endDate: _now.add(const Duration(days: 25)),
            registrationDeadline: _now.add(const Duration(days: 15)),
            maxTeams: 8,
          ));
      final items = await c.read(roleNotificationsProvider(UserRole.clubOwner).future);
      final approved = items.firstWhere((n) => n.id == 'n_reg_${reg.id}');
      expect(approved.title, 'Tournament registration approved');
      expect(notificationLocation(approved.target), Routes.registrationDetails(reg.id));
      final requests = items.where((n) => n.target is TournamentRequestTarget).toList();
      expect(requests, hasLength(3));
      expect(notificationLocation(requests.first.target), startsWith('${Routes.tournamentDetails(hosted.id)}/teams/requests/'));
      expect(await c.read(roleNotificationsProvider(UserRole.player).future), everyElement(
          predicate<NotificationItem>((n) => n.role == UserRole.player)));
    });

    test('read state drives the unread badge', () async {
      final c = await _signedIn();
      final items = await c.read(roleNotificationsProvider(UserRole.player).future);
      expect(c.read(unreadNotificationCountProvider(UserRole.player)), items.length);
      c.read(notificationReadProvider.notifier).markRead(items.first.id);
      expect(c.read(unreadNotificationCountProvider(UserRole.player)), items.length - 1);
      c.read(notificationReadProvider.notifier).markAllRead(items.map((n) => n.id));
      expect(c.read(unreadNotificationCountProvider(UserRole.player)), 0);
    });
  });

  group('Account & security', () {
    test('password change checks the current password, then sign-in requires the new one', () async {
      final c = await _signedIn();
      final s = c.read(sessionProvider.notifier);
      expect(await s.changePassword(current: 'wrong-pass', next: 'Newpass@123'), isFalse);
      expect(c.read(currentAccountProvider)!.settings.passwordChangedAt, isNull);
      expect(await s.changePassword(current: 'secret1', next: 'Newpass@123'), isTrue);
      expect(c.read(currentAccountProvider)!.settings.passwordChangedAt, _now);
      s.logout();
      expect(await s.signIn(identifier: 'x', password: 'secret1'), isFalse, reason: 'old password no longer works');
      expect(await s.signIn(identifier: 'x', password: 'Newpass@123'), isTrue);
    });

    test('new-password rules', () {
      expect(validateNewPassword('', 'secret1'), 'Enter a new password');
      expect(validateNewPassword('short', 'secret1'), 'Password must be at least 8 characters');
      expect(validateNewPassword('secret12', 'secret1'), 'Add an uppercase letter (A–Z)', reason: 'strong rules apply');
      expect(validateNewPassword('Cricket@123', 'Cricket@123'), 'Choose a password different from the current one');
      expect(validateNewPassword('Cricket@123', 'secret1'), isNull);
    });

    test('Privacy → Public profile off hides the listed player from clubs', () async {
      final c = await _signedIn(club: true);
      await c.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
      expect((await c.read(openPlayersProvider.future)).where((p) => p.isMe), hasLength(1));
      await c.read(sessionProvider.notifier).updateSettings((s) => s.copyWith(publicProfile: false));
      expect((await c.read(openPlayersProvider.future)).where((p) => p.isMe), isEmpty);
    });
  });

  group('Player Hunt', () {
    test('posting needs a role; posts belong to my club and reach players; remove', () async {
      final c = await _signedIn(club: true);
      await c.read(playerHuntProvider.future);
      final hunt = c.read(playerHuntProvider.notifier);
      expect(await hunt.publish(const HuntDraft()), 'Please select the role you need');
      final draft = c.read(huntDraftProvider.notifier);
      for (var i = 0; i < 15; i++) {
        draft.step(1);
      }
      expect(c.read(huntDraftProvider).playersNeeded, PlayerHuntPost.maxPlayers);
      expect(await hunt.publish(const HuntDraft(role: HuntRole.bowler, playersNeeded: 2, location: 'Lahore')), isNull);
      final mine = c.read(myHuntPostsProvider);
      expect(mine.map((p) => (p.role, p.clubId, p.playersNeeded)).take(2).toList(),
          [(HuntRole.bowler, SeedData.ownClubId, 2), (HuntRole.batsman, SeedData.ownClubId, 2)]);
      expect((await c.read(huntPostsProvider.future)).first.role, HuntRole.bowler, reason: 'players see it in Open Matches');
      await hunt.remove(mine.first.id);
      expect(c.read(myHuntPostsProvider).map((p) => p.role), [HuntRole.batsman]);
      await hunt.remove('hunt_1002'); // another club's post: never removable
      expect((await c.read(huntPostsProvider.future)).any((p) => p.id == 'hunt_1002'), isTrue);
    });

    test('an invite is sent once, is recorded for the club and survives a rebuild', () async {
      final c = await _signedIn(club: true);
      final inv = c.read(invitedPlayersProvider.notifier);
      expect(inv.invite('op_1'), isTrue);
      expect(inv.invite('op_1'), isFalse);
      final clubId = c.read(currentClubProvider)!.id;
      expect(c.read(huntRepositoryProvider).invitedPlayerIds(clubId), {'op_1'}, reason: 'stored in the repository');
      c.invalidate(invitedPlayersProvider);
      expect(c.read(invitedPlayersProvider), {'op_1'}, reason: 'not lost when the provider rebuilds');
      expect(c.read(invitedPlayersProvider.notifier).invite('op_1'), isFalse);
    });
  });

  group('Support screens', () {
    testWidgets('Player: bell opens the panel over the dashboard → the match; P16 row stays put; Mark all read',
        (tester) async {
      final c = await _pump(tester);
      final home = _loc(c);
      final panel = find.byKey(const Key('notifications.panel'));
      await tester.tap(find.byTooltip(RegExp('^Notifications, 4')));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(_loc(c), home, reason: 'a panel over the dashboard, no route change');
      expect(find.descendant(of: panel, matching: find.text('4 new')), findsOneWidget);

      // A non-navigating row is marked read and the panel stays (P16).
      await _tap(tester, find.bySemanticsLabel(RegExp('Tournament update: Spring Cup')));
      expect(_loc(c), home, reason: 'non-navigating (P16)');
      expect(panel, findsOneWidget);
      expect(find.descendant(of: panel, matching: find.text('3 new')), findsOneWidget);
      expect(find.byKey(const Key('notifications.panel.dot.n_p4')), findsNothing);

      // A navigating row closes the panel and opens its destination.
      await _tap(tester, find.bySemanticsLabel(RegExp('Match request from Shalimar CC')));
      expect(panel, findsNothing);
      expect(_loc(c), Routes.playerMatchDetails('pm_1'));
      expect(c.read(activeRoleProvider), UserRole.player, reason: 'role context kept');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myMatches, reason: 'Back → the match\'s logical parent');

      // Mark all read: dots and "N new" go, the bell badge updates, the panel stays open.
      await _go(tester, c, home);
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RegExp('^Notifications')));
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('notifications.panel.markAll')));
      expect(c.read(unreadNotificationCountProvider(UserRole.player)), 0);
      expect(panel, findsOneWidget, reason: 'stays open');
      expect(find.byKey(const Key('notifications.panel.newBadge')), findsNothing);
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('notifications.panel.dot.')),
          findsNothing);
      expect(tester.widget<TextButton>(find.byKey(const Key('notifications.panel.markAll'))).onPressed, isNull);
      expect(find.byTooltip('Notifications'), findsOneWidget, reason: 'bell badge cleared');

      // Tap outside closes it; the dashboard is where it was.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(_loc(c), home);

      // The Notifications screen stays for the sidebar / deep links.
      await _go(tester, c, Routes.notifications);
      expect(find.text('Match request from Shalimar CC'), findsOneWidget);
    });

    testWidgets('Club Owner: bell opens the same panel; join request, challenge and fixture rows still open', (tester) async {
      final c = await _pump(tester, club: true);
      final home = _loc(c);
      final panel = find.byKey(const Key('notifications.panel'));
      Future<void> openPanel() async {
        await _go(tester, c, home);
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(RegExp('^Notifications')));
        await tester.pumpAndSettle();
        expect(panel, findsOneWidget);
        expect(_loc(c), home);
      }

      await openPanel();
      final unread = c.read(unreadNotificationCountProvider(UserRole.clubOwner));
      expect(find.descendant(of: panel, matching: find.text('$unread new')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Match request')), findsNothing, reason: 'no Player items');
      await _tap(tester, find.bySemanticsLabel(RegExp('New join request from Bilal Ahmed')));
      expect(panel, findsNothing);
      expect(_loc(c), Routes.joinRequestProfile('jr_1'));

      await openPanel();
      expect(find.descendant(of: panel, matching: find.text('${unread - 1} new')), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel(RegExp('Challenge received from DHA Bulls CC')));
      expect(_loc(c), Routes.myChallenges);

      await openPanel();
      await _tap(tester, find.bySemanticsLabel(RegExp('Opponent completed their payment share')));
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled));
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
    });

    testWidgets('Club Owner: notifications open the join request and My Challenges', (tester) async {
      final c = await _pump(tester, club: true);
      await _go(tester, c, Routes.notifications);
      expect(find.bySemanticsLabel(RegExp('Match request')), findsNothing, reason: 'no Player items');
      await _tap(tester, find.bySemanticsLabel(RegExp('New join request from Bilal Ahmed')));
      expect(_loc(c), Routes.joinRequestProfile('jr_1'));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.joinRequests);

      await _go(tester, c, Routes.notifications);
      await _tap(tester, find.bySemanticsLabel(RegExp('Challenge received from DHA Bulls CC')));
      expect(_loc(c), Routes.myChallenges);
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
    });


    testWidgets('notifications panel: empty state, no navigation', (tester) async {
      final c = await _pump(tester, overrides: [
        roleNotificationsProvider.overrideWith((ref, role) async => const <NotificationItem>[]),
      ]);
      final home = _loc(c);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notifications.panel.empty')), findsOneWidget);
      expect(find.text('No notifications yet'), findsOneWidget);
      expect(find.text("You're all caught up."), findsOneWidget);
      expect(find.byKey(const Key('notifications.panel.newBadge')), findsNothing);
      expect(tester.widget<TextButton>(find.byKey(const Key('notifications.panel.markAll'))).onPressed, isNull);
      expect(_loc(c), home);
      await tester.binding.handlePopRoute(); // system Back closes the panel
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notifications.panel')), findsNothing);
      expect(_loc(c), home);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('notifications panel fits at ${width.toInt()} px: many long items scroll, header stays', (tester) async {
        final c = await _pump(tester, width: width, club: width.toInt().isEven);
        final role = c.read(activeRoleProvider)!;
        await c.read(notificationRepositoryProvider).deliver([
          for (var i = 0; i < 24; i++)
            NotificationItem(
              id: 'n_long_$i',
              role: role,
              icon: 'swords',
              title: 'Royal Rawalpindi Gymkhana Cricket & Sports Club of Excellence challenged you to a match $i',
              subtitle: 'T20 · Sat, 3 Oct · Away at the Extraordinarily Long Named Cricket Ground, Islamabad',
              createdAt: _now.subtract(Duration(minutes: i)),
              tone: NotificationTone.green,
            ),
        ]);
        c.invalidate(roleNotificationsProvider(role));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(RegExp('^Notifications')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'panel @ $width');
        final panel = find.byKey(const Key('notifications.panel'));
        final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
        expect(tester.getSize(panel).height, lessThanOrEqualTo(screen * 0.78 + 0.5), reason: 'max ~78% of the screen');
        // Title, "N new" and Mark all read share one line.
        final titleY = tester.getCenter(find.descendant(of: panel, matching: find.text('Notifications'))).dy;
        expect(tester.getCenter(find.byKey(const Key('notifications.panel.newBadge'))).dy, closeTo(titleY, 2));
        expect(tester.getCenter(find.byKey(const Key('notifications.panel.markAll'))).dy, closeTo(titleY, 2));
        // The list scrolls under a fixed header.
        final list = find.byKey(const Key('notifications.panel.list'));
        await tester.drag(list, const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scrolled @ $width');
        expect(tester.getCenter(find.descendant(of: panel, matching: find.text('Notifications'))).dy, closeTo(titleY, 0.5));
        expect(find.textContaining('match 0', findRichText: true), findsNothing, reason: 'scrolled past the top');
      });
    }
    testWidgets('Settings: role-aware Account, profile switch, Demo Mode, Log out', (tester) async {
      final c = await _pump(tester, club: true);
      await _go(tester, c, Routes.settings);
      await _tap(tester, find.text('Account').last);
      expect(_loc(c), Routes.myClub, reason: 'Club Owner account → My Club');

      await _go(tester, c, Routes.settings);
      expect(find.text('Prototype controls'), findsOneWidget);
      await _tap(tester, find.text('Demo Mode'));
      expect(c.read(demoModeProvider), isFalse);
      await _clearToast(tester);
      await _tap(tester, find.text('Demo Mode'));
      expect(c.read(demoModeProvider), isTrue);
      await _clearToast(tester);

      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Active profile'));
      await _tap(tester, find.text('Switch to Player profile'));
      expect(c.read(activeRoleProvider), UserRole.player);
      expect(_loc(c), Routes.playerHome);

      await _go(tester, c, Routes.settings);
      await _tap(tester, find.text('Account').last);
      expect(_loc(c), Routes.playerProfile, reason: 'Player account → My Profile');

      await _go(tester, c, Routes.settings);
      await _tap(tester, _button('Log out'));
      expect(find.text('Log out?'), findsOneWidget, reason: 'asks first');
      await _tap(tester, _button('Log out').last);
      expect(_loc(c), Routes.login);
      expect(c.read(sessionProvider).isAuthenticated, isFalse);
    });

    testWidgets('Privacy toggles and Password & security are real state', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.settings);
      expect(find.text('Show phone number'), findsNothing, reason: 'Privacy starts collapsed');
      await _tap(tester, find.text('Privacy'));
      expect(_loc(c), Routes.settings, reason: 'expands in place, no new route');
      await _tap(tester, find.text('Show phone number'));
      expect(c.read(currentAccountProvider)!.settings.showPhone, isTrue);
      await _tap(tester, find.text('Privacy'));
      expect(find.text('Show phone number'), findsNothing, reason: 'collapses again');

      // The legacy Privacy route opens Settings with the section expanded,
      // showing the saved state.
      await _go(tester, c, Routes.privacySettings);
      expect(_loc(c), SettingsScreen.privacyLocation);
      expect(find.text('Settings'), findsOneWidget);
      final phone = find.ancestor(of: find.text('Show phone number'), matching: find.byType(CeToggleRow));
      expect(tester.widget<CeToggleRow>(phone).value, isTrue);

      await _go(tester, c, Routes.settings);
      await _tap(tester, find.text('Password & security'));
      // Update Password stays off until the new password is strong.
      expect(tester.widget<CeButton>(_button('Update Password')).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('security.new')), 'short');
      await tester.pumpAndSettle();
      expect(find.text('Password must be at least 8 characters'), findsOneWidget);
      expect(tester.widget<CeButton>(_button('Update Password')).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('security.new')), 'Newpass@123');
      await _tap(tester, _button('Update Password'));
      expect(find.text('Enter your current password'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('security.current')), 'wrong-one');
      await _tap(tester, _button('Update Password'));
      expect(find.text('Current password is incorrect'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('security.current')), 'secret1');
      await _tap(tester, _button('Update Password'));
      expect(find.text('Password updated'), findsOneWidget);
      expect(_loc(c), Routes.settings);
      await _clearToast(tester);
      await _tap(tester, find.text('Password & security'));
      expect(find.text('Last changed 25 Sep 2026'), findsOneWidget);
      await _tap(tester, find.text('Two-step verification'));
      expect(c.read(currentAccountProvider)!.settings.twoStep, isTrue);
    });

    testWidgets('Password & security: "Forgot current password?" resets it by code; you stay signed in',
        (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.securitySettings);
      expect(find.text('Last changed 25 Sep 2026'), findsNothing);
      await _tap(tester, find.byKey(const Key('security.forgot')));
      expect(_loc(c), Routes.securitySettings, reason: 'a bottom sheet, no new screen');

      // Locked to the signed-in account's own number.
      final id = find.descendant(of: find.byKey(const Key('reset.identifier')), matching: find.byType(TextField));
      expect(tester.widget<TextField>(id).controller!.text, '0312 9020000');
      expect(tester.widget<TextField>(id).readOnly, isTrue);
      await _tap(tester, _button('Send Code'));
      expect(find.textContaining('0312 ••••• 00'), findsOneWidget);
      expect(find.text('Change number or email'), findsNothing);
      await _tap(tester, find.widgetWithText(OutlinedButton, 'Use code'));
      await _tap(tester, _button('Verify Code'));

      // Same strong rules as this screen, listed live by the field.
      expect(find.text('Use 8+ characters with upper- and lowercase letters, a number and a special character.'),
          findsOneWidget);
      await tester.enterText(find.byKey(const Key('reset.password')), 'short12');
      await tester.enterText(find.byKey(const Key('reset.confirm')), 'short12');
      await tester.pumpAndSettle();
      expect(find.text('Password must be at least 8 characters'), findsOneWidget);
      expect(tester.widget<CeButton>(_button('Reset Password')).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('reset.password')), 'Brandnew#99');
      await tester.enterText(find.byKey(const Key('reset.confirm')), 'Brandnew#99');
      await _tap(tester, _button('Reset Password'));

      expect(find.text('Password reset. Use your new password next time you log in.'), findsOneWidget);
      expect(_loc(c), Routes.securitySettings);
      expect(c.read(sessionProvider).isAuthenticated, isTrue, reason: 'still signed in');
      expect(find.text('Last changed 25 Sep 2026'), findsOneWidget);

      // The new password is now the current one; the old one is not.
      final s = c.read(sessionProvider.notifier);
      expect(await s.changePassword(current: 'secret1', next: 'Another@999'), isFalse);
      s.logout();
      expect(await s.signIn(identifier: 'x', password: 'secret1'), isFalse);
      expect(await s.signIn(identifier: 'x', password: 'Brandnew#99'), isTrue);
    });

    testWidgets('Edit Profile validates, saves to the account and returns to My Profile', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, Routes.playerProfile);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile, reason: 'inline edit mode, same route');
      await tester.enterText(find.byKey(const Key('edit.name')), '');
      await tester.enterText(find.byKey(const Key('edit.phone')), '12345');
      await _tap(tester, _button('Save Changes'));
      expect(find.text('Full name is required'), findsOneWidget);
      expect(find.text('Enter a valid mobile number (03XX-XXXXXXX)'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('edit.name')), 'Aman Ullah');
      await tester.enterText(find.byKey(const Key('edit.phone')), '0300-1234567');
      await _tap(tester, find.byKey(const Key('edit.city')));
      await _tap(tester, find.text('Lahore'));
      await _tap(tester, _button('Save Changes'));
      final a = c.read(currentAccountProvider)!;
      expect((a.fullName, a.phone, a.city), ('Aman Ullah', '0300 1234567', 'Lahore'));
      expect(_loc(c), Routes.playerProfile);
      expect(find.text('Profile updated'), findsOneWidget);
      expect(find.text('Aman Ullah'), findsOneWidget);
      expect(find.byKey(const Key('edit.name')), findsNothing, reason: 'back in view mode');
    });

    testWidgets('Privacy (inline in Settings): Public profile off hides me from Player Hunt', (tester) async {
      final c = await _pump(tester);
      await c.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
      expect((await c.read(openPlayersProvider.future)).where((p) => p.isMe), hasLength(1));
      await _go(tester, c, SettingsScreen.privacyLocation);
      await _tap(tester, find.text('Public profile'));
      expect(c.read(currentAccountProvider)!.settings.publicProfile, isFalse);
      expect((await c.read(openPlayersProvider.future)).where((p) => p.isMe), isEmpty);
      expect(find.text("Hidden: clubs won't see you under Find Player → Available Players, even when you're available."),
          findsOneWidget);
      expect(find.text('Clubs can find you in Find Player'), findsOneWidget);
      expect(find.textContaining('Player Hunt'), findsNothing, reason: 'same name as the club side');
      expect(c.read(activeRoleProvider), UserRole.player, reason: 'no role change');
    });

    testWidgets('Player Hunt: post a requirement, remove it; browse and invite available players', (tester) async {
      final c = await _pump(tester, club: true);
      await _go(tester, c, Routes.playerHunt);
      // Same name as the dashboard quick action; the posting tab is "Post Requirement".
      expect(find.descendant(of: find.byType(CeTopBar), matching: find.text('Find Player')), findsOneWidget);
      expect(find.text('Post Requirement'), findsOneWidget);
      expect(find.text('Open Players'), findsNothing);
      final sidebar = [for (final g in RoleDestinations.club) for (final d in g.items) d.label];
      // Find Player is a dashboard quick action now, not a sidebar entry.
      expect(sidebar, isNot(contains('Find Player')));
      expect(sidebar, isNot(contains('Player Hunt')));
      await _tap(tester, _button('Post Player Requirement'));
      expect(find.text('Please select the role you need'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('Wicket-Keeper'));
      await _tap(tester, find.byTooltip('More players'));
      await _tap(tester, _button('Post Player Requirement'));
      expect(find.text('Player requirement posted!'), findsOneWidget);
      await _clearToast(tester);
      expect(find.text('Looking for 2 Wicket-Keepers', skipOffstage: false), findsOneWidget);
      await _tap(tester, _button('Remove Slot').first);
      expect(find.text('Remove this slot?'), findsOneWidget, reason: 'destructive action confirms first');
      await _tap(tester, _button('Remove Slot').last);
      expect(find.text('Looking for 2 Wicket-Keepers', skipOffstage: false), findsNothing);
      await _clearToast(tester);

      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Available Players'));
      expect(_loc(c), '${Routes.playerHunt}?tab=available');
      expect(find.text('Choose a city and role'), findsOneWidget);
      c.read(openPlayersCityProvider.notifier).select('Islamabad');
      c.read(openPlayersRoleProvider.notifier).select(HuntRole.batsman);
      await tester.pumpAndSettle();
      expect(find.text('Ali Hassan'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilledButton, 'Invite'));
      expect(find.text('Invite sent to Ali Hassan'), findsOneWidget);
      expect(find.text('INVITED'), findsOneWidget);
      // Demo Mode says plainly that nothing is delivered yet.
      expect(find.textContaining('the player is not messaged yet', skipOffstage: false), findsOneWidget);
    });

    testWidgets('an unknown location shows Not found with a way home', (tester) async {
      final c = await _pump(tester);
      await _go(tester, c, '/nowhere');
      expect(find.text('Screen not found'), findsOneWidget);
      await _tap(tester, _button('Go to dashboard'));
      expect(_loc(c), Routes.playerHome);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 9 screens render without overflow at ${width.toInt()} px', (tester) async {
        final c = await _pump(tester, club: true, width: width);
        await c.read(playerHuntProvider.future);
        await c.read(playerHuntProvider.notifier).publish(const HuntDraft(
              role: HuntRole.wicketKeeper,
              format: MatchFormat.custom,
              playersNeeded: 11,
              location: 'Dera Ghazi Khan',
              time: '14:30',
              budget: HuntBudget.from2000to5000,
            ));
        c.read(openPlayersCityProvider.notifier).select('Islamabad');
        c.read(openPlayersRoleProvider.notifier).select(HuntRole.batsman);
        await c.read(sessionProvider.notifier).changePassword(current: 'secret1', next: 'Newpass@123');
        Future<void> sweep(List<String> locations) async {
          for (final loc in locations) {
            await _go(tester, c, loc);
            final scrollable = find.byType(Scrollable).first;
            for (var i = 0; i < 10; i++) {
              await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
              await tester.pump();
            }
            expect(tester.takeException(), isNull, reason: '$loc @ $width');
          }
        }

        await sweep([
          Routes.notifications,
          Routes.settings,
          SettingsScreen.privacyLocation,
          Routes.securitySettings,
          Routes.playerHunt,
          '${Routes.playerHunt}?tab=available',
          '/nowhere',
        ]);
        c.read(roleControllerProvider.notifier).switchTo(UserRole.player);
        await sweep([Routes.notifications, Routes.settings, SettingsScreen.privacyLocation, '${Routes.playerProfile}?edit=1']);
      });
    }
  });
}
