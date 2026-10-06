import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/role_destinations.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/tokens.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/hunt/player_hunt_controller.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/fitness/fitness_providers.dart';
import 'package:criceco/features/membership/join_club_controller.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/features/player/screens/availability_screen.dart';
import 'package:criceco/features/player/screens/performance_screens.dart';
import 'package:criceco/features/player/screens/performance_workspace.dart';
import 'package:criceco/features/player/screens/player_match_workspace.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/media/share_service.dart';
import 'package:criceco/shared/navigation/role_shells.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:criceco/shared/widgets/ce_inputs.dart';
import 'package:criceco/shared/widgets/ce_match_widgets.dart';
import 'package:criceco/shared/widgets/ce_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wednesday 23 Sep 2026, 10:00 — seed "tomorrow" match is Thu 24 Sep 08:00.
final _now = DateTime(2026, 9, 23, 10);

Future<ProviderContainer> _pumpPlayer(
  WidgetTester tester, {
  double width = 375,
  String? fullName,
  List<dynamic> overrides = const [],
}) async {
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
  await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
  if (fullName != null) {
    await c.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(fullName: fullName));
  }
  final nav = c.read(roleControllerProvider.notifier).continueAs(UserRole.player);
  c.read(routerProvider).go((nav as GoToLocation).location);
  await tester.pumpAndSettle();
  return c;
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String loc) async {
  c.read(routerProvider).go(loc);
  await tester.pumpAndSettle();
}

/// The screen's main (vertical) list — workspace tab rows scroll sideways.
final _mainList = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

/// Scrolls the screen's main list until [f] is built and on screen, then taps it.
Future<void> _tap(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150, scrollable: _mainList);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);
Finder _navTab(String label) => find.descendant(of: find.byType(CeBottomNav), matching: find.bySemanticsLabel(label));

/// Stands in for the device photo picker: returns [result] (a path, `null`
/// for "cancelled") or throws it when it is an exception.
class FakePhotoPicker implements PhotoPicker {
  FakePhotoPicker([this.result]);
  Object? result;
  final sources = <PhotoSource>[];

  @override
  Future<String?> pick(PhotoSource source) async {
    sources.add(source);
    final r = result;
    if (r is Exception) throw r;
    return r as String?;
  }
}

/// Stands in for the native share sheet: records what was shared.
class FakeShareService implements ShareService {
  final shared = <String>[];
  bool available = true;

  @override
  Future<bool> share({required String text, String? subject, String? imagePath}) async {
    if (!available) return false;
    shared.add(text);
    return true;
  }
}

/// An [Image] showing the local file at [path].
Finder _fileImage(String path) =>
    find.byWidgetPredicate((w) => w is Image && w.image is FileImage && (w.image as FileImage).file.path == path);

/// The Player Dashboard quick-action tiles (by their spoken label).
Finder _quickAction(String label) => find.descendant(
    of: find.byKey(const Key('player.quickActions')), matching: find.bySemanticsLabel(label));

void main() {
  group('Player Dashboard', () {
    testWidgets('shows account, club, stats and next match from real state', (tester) async {
      await _pumpPlayer(tester);
      expect(find.byKey(const Key('player.greeting')), findsOneWidget);
      expect(find.text('Aman Ali'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('CONFIRMED'), 150, scrollable: find.byType(Scrollable).first);
      expect(find.text('Falcons CC'), findsOneWidget);
      expect(find.text('Playing: '), findsOneWidget);
      expect(find.text('BS CS XI'), findsOneWidget);
      // Countdown derived from startsAt − now: Thu 08:00 − Wed 10:00 = 22 h.
      expect(find.text('22h : 00m : 00s'), findsOneWidget);
    });

    testWidgets('availability pill toggles the shared availability record', (tester) async {
      final c = await _pumpPlayer(tester);
      expect(find.text('Available'), findsOneWidget);
      await tester.tap(find.text('Available'));
      await tester.pumpAndSettle();
      expect(c.read(playerAvailabilityProvider).status, PlayerAvailability.unavailable);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('quick actions navigate to real routes; the bell opens the panel in place', (tester) async {
      final c = await _pumpPlayer(tester);
      await _tap(tester, _quickAction('Playing Opportunities'));
      expect(_loc(c), Routes.openMatches);
      // Same name everywhere: quick action, screen title and sidebar.
      expect(find.descendant(of: find.byType(CeTopBar), matching: find.text('Playing Opportunities')), findsOneWidget);
      expect(find.text('Open Matches'), findsNothing);
      final sidebar = [for (final g in RoleDestinations.player) for (final d in g.items) d.label];
      expect(sidebar, contains('Playing Opportunities'));
      expect(sidebar, isNot(contains('Open Matches')));

      await _go(tester, c, Routes.playerHome);
      // The branch keeps its scroll offset; bring the hero back into view.
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      expect(find.byTooltip(RegExp(r'^Notifications, [1-9]')), findsOneWidget, reason: 'bell shows the unread badge');
      await tester.tap(find.byTooltip(RegExp('^Notifications')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notifications.panel')), findsOneWidget);
      expect(_loc(c), Routes.playerHome, reason: 'no route change');
    });

    testWidgets('Quick Actions: Playing Opportunities, My Matches, Match Availability, Performance in a 2 × 2 grid',
        (tester) async {
      for (final width in [320.0, 375.0, 414.0]) {
        await _pumpPlayer(tester, width: width);
        final grid = find.byKey(const Key('player.quickActions'));
        final tiles = [
          for (final s in tester.widgetList<Semantics>(find.descendant(of: grid, matching: find.byType(Semantics))))
            if (s.properties.button == true && s.properties.label != null) s.properties.label!,
        ];
        expect(tiles, ['Playing Opportunities', 'My Matches', 'Match Availability', 'Performance']);
        for (final not in [
          'Upcoming Matches', 'Join Club', 'Club', 'Share Profile', 'Matches', 'Availability', 'My Performance', //
          'Profile', 'Settings', 'Fitness Meter', 'Match History',
        ]) {
          expect(_quickAction(not), findsNothing, reason: '$not is not a quick action');
        }
        // Balanced 2 × 2 at every width.
        double top(String l) => tester.getTopLeft(_quickAction(l)).dy;
        double left(String l) => tester.getTopLeft(_quickAction(l)).dx;
        expect(top('Playing Opportunities'), top('My Matches'), reason: 'row 1 @ $width');
        expect(top('Match Availability'), top('Performance'), reason: 'row 2 @ $width');
        expect(top('Match Availability'), greaterThan(top('Playing Opportunities')));
        expect(left('Playing Opportunities'), left('Match Availability'), reason: 'column 1 @ $width');
        expect(left('My Matches'), left('Performance'), reason: 'column 2 @ $width');
        expect(tester.getRect(_quickAction('Performance')).right, closeTo(width - CeSpace.gutter, 1));
        // Every label shows in full (no ellipsis, no word split across lines).
        for (final p in tester.renderObjectList<RenderParagraph>(find.descendant(of: grid, matching: find.byType(RichText)))) {
          expect(p.didExceedMaxLines, isFalse, reason: '${p.text.toPlainText()} @ $width');
        }
        expect(tester.takeException(), isNull, reason: 'grid @ $width');
      }
    });

    testWidgets('Season stats card is gone; My Matches opens the Matches area on its default view', (tester) async {
      final c = await _pumpPlayer(tester);
      for (final label in ['UPCOMING MATCHES', 'PERFORMANCE RATING', 'MATCHES PLAYED']) {
        expect(find.text(label, skipOffstage: false), findsNothing, reason: '$label card removed');
      }
      expect(find.byType(CeStatGroup), findsNothing);
      // Quick Actions follow the header directly (no empty gap).
      final headerBottom = tester.getRect(find.byKey(const Key('player.hero'))).bottom;
      expect(tester.getTopLeft(find.text('Quick Actions')).dy - headerBottom, lessThan(40));

      await _tap(tester, _quickAction('My Matches'));
      expect(_loc(c), Routes.myMatches);
      expect(find.text('Shalimar CC vs Falcons CC'), findsOneWidget, reason: 'the upcoming match');
      expect(find.byType(CeBottomNav), findsOneWidget, reason: 'the existing Matches tab');
    });

    testWidgets('Bottom nav: Home · Matches · [Status] · Club · Profile; Club is a sheet; Profile also via header and sidebar',
        (tester) async {
      final c = await _pumpPlayer(tester);
      final nav = find.byType(CeBottomNav);
      final labels = [for (final i in tester.widget<CeBottomNav>(nav).items) i.label];
      expect(labels, ['Home', 'Matches', 'Status', 'Club', 'Profile']);
      expect([for (final i in tester.widget<CeBottomNav>(nav).items) i.center], [false, false, true, false, false]);
      Finder tab(String l) => find.descendant(of: nav, matching: find.bySemanticsLabel(l));
      int selected() => tester.widget<CeBottomNav>(nav).currentIndex;
      expect(selected(), 0);
      for (final (label, route, index) in [
        ('Matches', Routes.myMatches, 1),
        ('Profile', Routes.playerProfile, 4),
        ('Home', Routes.playerHome, 0),
      ]) {
        await tester.tap(tab(label));
        await tester.pumpAndSettle();
        expect(_loc(c), route, reason: label);
        expect(selected(), index, reason: '$label highlighted');
        expect(find.byType(CeBottomNav), findsOneWidget, reason: '$label keeps the bottom nav');
      }
      expect(find.text('My Profile'), findsNothing, reason: 'Home returns to the dashboard');

      // Club: a sheet over the current screen (no route change, never highlighted).
      await tester.tap(tab('Club'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('joinClub.code')), findsOneWidget, reason: 'not in a club → Join a Club');
      expect(_loc(c), Routes.playerHome);
      expect(selected(), 0);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Availability and Performance keep their screens (sidebar); no tab is highlighted there.
      for (final (item, route) in [('Availability', Routes.availability), ('My Performance', Routes.myPerformance)]) {
        await tester.tap(find.byTooltip('Open menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text(item)));
        await tester.pumpAndSettle();
        expect(_loc(c), route, reason: item);
        expect(selected(), -1, reason: '$item is not a bottom-nav tab');
        await _go(tester, c, Routes.playerHome);
      }

      // Profile: the dashboard avatar / name ...
      await tester.fling(_mainList, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Open my profile, Aman Ali')), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const Key('player.header')), matching: find.text('Aman Ali')));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile);
      expect(find.text('My Profile'), findsOneWidget);
      expect(find.byType(CeBottomNav), findsOneWidget);

      // ... and the sidebar.
      await _go(tester, c, Routes.playerHome);
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('My Profile')));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile);
      // Legacy edit link still lands on the profile in edit mode.
      await _go(tester, c, Routes.editProfile);
      expect(_loc(c), '${Routes.playerProfile}?edit=1');
      expect(find.text('Edit Details'), findsOneWidget);

      // Sidebar → Edit Profile: My Profile straight in edit mode.
      await _go(tester, c, Routes.playerHome);
      await tester.fling(_mainList, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Edit Profile')));
      await tester.pumpAndSettle();
      expect(_loc(c), '${Routes.playerProfile}?edit=1');
      expect(find.byKey(const Key('edit.name')), findsOneWidget, reason: 'editable at once');
      await tester.enterText(find.byKey(const Key('edit.name')), 'Aman Ullah');
      await _tap(tester, _button('Save Changes'));
      expect(c.read(currentAccountProvider)!.fullName, 'Aman Ullah');
    });

    testWidgets('Share Profile (sidebar): player card from real data in a sheet; shares a clean text summary',
        (tester) async {
      final share = FakeShareService();
      final c = await _pumpPlayer(tester, overrides: [shareServiceProvider.overrideWithValue(share)]);
      final account = c.read(currentAccountProvider)!;
      final p = account.playerProfile;
      final perf = await c.read(performanceProvider.future);
      expect(c.read(currentClubProvider), isNull, reason: 'this player has not joined or created a club');

      expect(_quickAction('Share Profile'), findsNothing, reason: 'no longer a Quick Action');
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      final item = find.descendant(of: find.byType(Drawer), matching: find.text('Share Profile'));
      expect(item, findsOneWidget, reason: 'in the Player sidebar');
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing, reason: 'the sidebar closes');
      expect(_loc(c), Routes.playerHome, reason: 'a sheet, not a new screen');
      final card = find.byKey(const Key('shareProfile.card'));
      expect(card, findsOneWidget);
      Finder inCard(String t) => find.descendant(of: card, matching: find.text(t));
      expect(inCard(account.fullName), findsOneWidget);
      expect(inCard(p.battingStyle!.label), findsOneWidget);
      expect(inCard(p.bowlingStyle!.label), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Club')), findsNothing, reason: 'no club → no club line');
      expect(inCard('Club KRC001'), findsNothing, reason: 'placeholder code is not shared');
      expect(inCard(perf.rating), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining(p.role!.label)), findsWidgets);
      expect(find.byKey(const Key('edit.name')), findsNothing, reason: 'share only, no editing');

      await _tap(tester, _button('Share Profile'));
      expect(share.shared, hasLength(1));
      final text = share.shared.single;
      expect(text, startsWith('${account.fullName} — CricEco Player'));
      expect(text, contains('Role: ${p.role!.label}'));
      expect(text, contains('Batting: ${p.battingStyle!.label}'));
      expect(text, contains('Bowling: ${p.bowlingStyle!.label}'));
      expect(text, contains('Rating ${perf.rating}'));
      expect(text, isNot(contains('acc_')), reason: 'no internal ids');
      expect(text, isNot(contains('Club')), reason: 'KRC001 on the dashboard is a placeholder, not their club');

      // Share unavailable → told so; the sheet stays.
      share.available = false;
      await _tap(tester, _button('Share Profile'));
      expect(find.textContaining('Sharing isn’t available'), findsOneWidget);
      await _tap(tester, _button('Close'));
      expect(find.byKey(const Key('shareProfile.card')), findsNothing);
    });

    testWidgets('Club tab: not in a club → Join a Club (code → preview → the existing request); pending; then My Club',
        (tester) async {
      final c = await _pumpPlayer(tester);
      Future<void> open() async {
        await _go(tester, c, Routes.playerHome);
        await tester.tap(_navTab('Club'));
        await tester.pumpAndSettle();
      }

      bool sendEnabled() => tester.widget<CeButton>(_button('Send Join Request')).onPressed != null;
      Future<void> enter(String code) async {
        await tester.enterText(find.byKey(const Key('joinClub.code')), code);
        await tester.pumpAndSettle();
      }

      await open();
      expect(_loc(c), Routes.playerHome, reason: 'a sheet, not the standalone Join route');
      expect(sendEnabled(), isFalse);

      // Unknown code: said plainly, nothing to send.
      await enter('ZZZZ99');
      expect(find.byKey(const Key('joinClub.notFound')), findsOneWidget);
      expect(find.byKey(const Key('joinClub.preview')), findsNothing);
      expect(sendEnabled(), isFalse);

      // A real club: its facts from the club data (name, city, type, members).
      final members = await c.read(clubRepositoryProvider).members(SeedData.ownClubId);
      await enter('35hlwz');
      expect(find.byKey(const Key('joinClub.preview')), findsOneWidget);
      expect(find.text('Shalimar Cricket Club'), findsOneWidget);
      expect(find.text('Islamabad · Professional · ${members.length} members · 35HLWZ'), findsOneWidget);
      expect(sendEnabled(), isTrue);

      // The demo club: only what the data has (no type / size invented).
      await enter('KRC001');
      expect(find.text(SeedData.demoJoinClubName), findsOneWidget);
      expect(find.text('Islamabad · KRC001'), findsOneWidget);

      // Cancel sends nothing.
      await _tap(tester, _button('Cancel'));
      expect(c.read(joinClubProvider), isNull);

      // Send → the same request the standalone flow creates.
      await open();
      await enter('KRC001');
      await _tap(tester, _button('Send Join Request'));
      expect(find.text('Join request sent to ${SeedData.demoJoinClubName}'), findsOneWidget);
      final request = c.read(joinClubProvider)!;
      expect((request.clubCode, request.clubName, request.status),
          (SeedData.demoJoinCode, SeedData.demoJoinClubName, JoinRequestStatus.pending));

      // Pending: the sheet shows it instead of allowing a duplicate.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await open();
      expect(find.byKey(const Key('joinClub.pending')), findsOneWidget);
      expect(find.byKey(const Key('joinClub.code')), findsNothing);
      expect(_button('Send Join Request'), findsNothing);
      // (The status screen animates continuously: pump frames, don't settle.)
      await tester.tap(_button('View Request'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(_loc(c), Routes.waitingApproval, reason: 'the existing request status screen');
      expect(find.text('Waiting for Approval'), findsOneWidget);

      // Approved while the sheet is open → it turns into My Club straight away.
      await open();
      expect(find.byKey(const Key('joinClub.pending')), findsOneWidget);
      await c.read(joinClubProvider.notifier).approve(MemberRole.player);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('joinClub.pending')), findsNothing);
      expect(find.byKey(const Key('joinClub.code')), findsNothing, reason: 'no join form for a member');
      final card = find.byKey(const Key('club.sheet.joined.KRC001'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text(SeedData.demoJoinClubName)), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Islamabad')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('club.sheet.row.Your role'))).data, 'Player');
      expect(tester.widget<Text>(find.byKey(const Key('club.sheet.row.Club code'))).data, 'KRC001');
      expect(find.byKey(const Key('club.sheet.row.Members')), findsNothing, reason: 'size unknown → not invented');
      expect(find.byKey(const Key('club.sheet.row.Owner')), findsNothing, reason: 'owner unknown → not invented');
      expect(find.byType(CeTextField), findsNothing, reason: 'read-only: nothing to edit');
      await _tap(tester, _button('Close'));

      // The standalone join route is still there.
      await _go(tester, c, Routes.enterClubCode);
      expect(find.text('Enter Club Code'), findsOneWidget);
    });

    testWidgets('center Status button: raised above the bar, opens Set Your Status (no route)', (tester) async {
      final c = await _pumpPlayer(tester);
      final button = find.byKey(const Key('nav.center'));
      final nav = find.byType(CeBottomNav);
      expect(button, findsOneWidget);
      // Raised: it starts above the bar's other items, centred between Matches and Club.
      final home = tester.getRect(_navTab('Home'));
      final rect = tester.getRect(button);
      expect(rect.top, lessThan(home.top));
      expect(rect.center.dx, closeTo(tester.getRect(nav).center.dx, 1));
      expect(rect.left, greaterThan(tester.getRect(_navTab('Matches')).right));
      expect(rect.right, lessThan(tester.getRect(_navTab('Club')).left));
      expect(tester.getRect(nav).top, lessThanOrEqualTo(rect.top), reason: 'inside the nav (never over page content)');

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('status.sheet')), findsOneWidget);
      expect(find.text('Set Your Status'), findsOneWidget);
      expect(_loc(c), Routes.playerHome, reason: 'a sheet, not a route');
      expect(tester.widget<CeBottomNav>(nav).currentIndex, 0, reason: 'never a selected tab');
    });


    for (final (device, width, inset) in [('iPhone', 375.0, 34.0), ('Android gesture bar', 360.0, 24.0), ('small phone', 320.0, 48.0)]) {
      testWidgets('bottom nav respects the $device safe area (${inset.toInt()} px) and the status sheet fits', (tester) async {
        await _pumpPlayer(tester, width: width);
        tester.view.padding = FakeViewPadding(bottom: inset * 3);
        await tester.pumpAndSettle();
        final screenBottom = tester.view.physicalSize.height / tester.view.devicePixelRatio;
        for (final l in ['Home', 'Matches', 'Club', 'Profile']) {
          expect(tester.getRect(_navTab(l)).bottom, lessThanOrEqualTo(screenBottom - inset + 0.5), reason: '$l above the inset');
        }
        expect(tester.getRect(find.text('Status')).bottom, lessThanOrEqualTo(screenBottom - inset + 0.5));
        await tester.tap(find.byKey(const Key('nav.center')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('status.sheet')), findsOneWidget);
        expect(tester.getRect(find.byKey(const Key('status.openForMatches'))).bottom,
            lessThanOrEqualTo(screenBottom - inset + 0.5), reason: 'sheet content above the inset');
        expect(tester.takeException(), isNull, reason: '$device @ $width');
      });
    }
    testWidgets('Set Your Status: Available This Week and Open for Matches use the existing availability record',
        (tester) async {
      final c = await _pumpPlayer(tester);
      Switch sw(String key) =>
          tester.widget<Switch>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Switch)));
      Future<void> open() async {
        await tester.tap(find.byKey(const Key('nav.center')));
        await tester.pumpAndSettle();
      }

      // Opens on the saved state.
      expect(c.read(playerAvailabilityProvider).status, PlayerAvailability.available);
      expect(c.read(playerAvailabilityProvider).openToOffers, isFalse);
      await open();
      expect(sw('status.available').value, isTrue);
      expect(sw('status.openForMatches').value, isFalse);

      // OFF → Unavailable until this weekend (the Availability screen's "This Weekend").
      await tester.tap(find.descendant(of: find.byKey(const Key('status.available')), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      var r = c.read(playerAvailabilityProvider);
      expect((r.status, r.until, r.untilDate), (PlayerAvailability.unavailable, AvailabilityUntil.weekend, DateTime(2026, 9, 26)));
      expect(find.text('Saved · Marked unavailable this week'), findsOneWidget);
      expect(sw('status.available').value, isFalse);

      // Open for Matches → the existing listing (clubs' Available Players).
      await tester.tap(find.descendant(of: find.byKey(const Key('status.openForMatches')), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(c.read(playerAvailabilityProvider).openToOffers, isTrue);
      expect((await c.read(openPlayersProvider.future)).where((p) => p.isMe), hasLength(1));
      expect(find.text('Saved · You’re open for matches'), findsOneWidget);

      // Closed and reopened: the saved state; the Availability screen agrees.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await open();
      expect((sw('status.available').value, sw('status.openForMatches').value), (false, true));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _go(tester, c, Routes.availability);
      expect(find.text('Unavailable'), findsWidgets);

      // A detailed status (Injured) shows as OFF with its name; ON makes them Available.
      c.read(playerAvailabilityProvider.notifier).update(status: PlayerAvailability.injured, notes: 'Hamstring');
      await _go(tester, c, Routes.playerHome);
      await open();
      expect(sw('status.available').value, isFalse);
      expect(find.text('Currently: Injured'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const Key('status.available')), matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      r = c.read(playerAvailabilityProvider);
      expect((r.status, r.openToOffers), (PlayerAvailability.available, true), reason: 'listing untouched');
    });

    testWidgets('Performance quick action: a sheet with the real summary; View Full Performance opens the screen',
        (tester) async {
      final c = await _pumpPlayer(tester);
      final p = await c.read(performanceProvider.future);
      await _tap(tester, _quickAction('Performance'));
      final sheet = find.byKey(const Key('performance.sheet'));
      expect(sheet, findsOneWidget);
      expect(_loc(c), Routes.playerHome, reason: 'a sheet, not the Performance screen');
      expect(find.descendant(of: sheet, matching: find.text('Player Performance')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('performance.rating')), matching: find.text(p.rating)), findsOneWidget);
      String cell(String label) => tester
          .widget<Text>(find.descendant(of: find.byKey(Key('performance.cell.$label')), matching: find.byType(Text)).first)
          .data!;
      String snap(String l) => p.snapshot.firstWhere((t) => t.label == l).value;
      expect(
        {for (final l in ['Matches', 'Runs', 'Wickets', 'Bat Avg', 'Strike Rate', 'Best Score']) l: cell(l)},
        {
          'Matches': '${p.matches}',
          'Runs': '${p.runs}',
          'Wickets': '${p.wickets}',
          'Bat Avg': p.battingAverage,
          'Strike Rate': snap('Strike Rate'),
          'Best Score': snap('Best Score'),
        },
      );
      expect(find.descendant(of: sheet, matching: find.byType(FormChip)), findsNWidgets(p.recentForm.length));
      expect(tester.widget<Text>(find.byKey(const Key('performance.formRecord'))).data,
          '${p.recentWins}W - ${p.recentLosses}L');

      await _tap(tester, _button('View Full Performance'));
      expect(find.byKey(const Key('performance.sheet')), findsNothing);
      expect(_loc(c), Routes.myPerformance, reason: 'the existing Performance screen');
    });

    testWidgets('Club tab for a player who owns a club: My Club with the real club data, read-only', (tester) async {
      final c = await _pumpPlayer(tester);
      await c.read(sessionProvider.notifier)
          .createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
      await tester.pumpAndSettle();
      final club = c.read(currentClubProvider)!;
      final members = await c.read(clubMembersProvider.future);
      final teams = await c.read(teamsProvider.future);
      await tester.tap(_navTab('Club'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome, reason: 'a sheet over the dashboard');
      final card = find.byKey(Key('club.sheet.own.${club.code}'));
      expect(card, findsOneWidget);
      expect(find.byKey(const Key('joinClub.code')), findsNothing);
      expect(find.descendant(of: card, matching: find.text('Shalimar Cricket Club')), findsOneWidget);
      String row(String label) => tester.widget<Text>(find.byKey(Key('club.sheet.row.$label'))).data!;
      expect(row('Your role'), 'Club Owner');
      expect(row('Club code'), club.code);
      expect(row('Owner'), members.firstWhere((m) => m.role == MemberRole.owner).name);
      expect(row('Coach'), members.firstWhere((m) => m.role == MemberRole.coach).name);
      expect(row('Members'), '${members.length}');
      expect(row('Teams'), '${teams.length} · ${teams.map((t) => t.name).join(', ')}');
      expect(find.byType(CeTextField), findsNothing, reason: 'nothing to edit from here');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(card, findsNothing);
    });

    testWidgets('Match Availability: current status → Change Status (inline, every status) → notes → Save',
        (tester) async {
      final c = await _pumpPlayer(tester);
      final before = c.read(playerAvailabilityProvider);
      expect(before.status, PlayerAvailability.available);
      // Open the Availability screen first so its (kept-alive) form exists.
      await _go(tester, c, Routes.availability);
      await _go(tester, c, Routes.playerHome);

      await _tap(tester, _quickAction('Match Availability'));
      expect(_loc(c), Routes.playerHome, reason: 'a sheet, not the Availability screen');
      expect(find.text('Current Status'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('matchAvailability.current')), matching: find.text('Available')),
          findsOneWidget);
      // Only what the quick flow needs: no dates, reasons or extra settings.
      for (final gone in ['Tomorrow', 'This Weekend', 'Select Date', 'Injury', 'Unavailable until']) {
        expect(find.textContaining(gone), findsNothing, reason: '$gone is on the full screen only');
      }
      expect(find.byKey(const Key('matchAvailability.unavailable')), findsNothing, reason: 'collapsed until asked');
      expect(tester.widget<CeButton>(_button('Save')).onPressed, isNull, reason: 'nothing changed yet');

      // Change Status expands inline with every existing status.
      await _tap(tester, find.byKey(const Key('matchAvailability.change')));
      expect(_loc(c), Routes.playerHome);
      for (final s in PlayerAvailability.values) {
        expect(find.byKey(Key('matchAvailability.${s.name}')), findsOneWidget, reason: s.label);
      }
      // Cancel: nothing changes.
      await _tap(tester, find.byKey(const Key('matchAvailability.limited')));
      await _tap(tester, _button('Cancel'));
      expect(identical(c.read(playerAvailabilityProvider), before), isTrue);

      // Injured + a note (notes optional, but kept when given).
      await _tap(tester, _quickAction('Match Availability'));
      await _tap(tester, find.byKey(const Key('matchAvailability.change')));
      await _tap(tester, find.byKey(const Key('matchAvailability.injured')));
      await tester.enterText(find.byKey(const Key('matchAvailability.note')), 'Hamstring strain');
      await tester.pumpAndSettle();
      await _tap(tester, _button('Save'));
      expect(find.text('Availability updated'), findsOneWidget);
      final saved = c.read(playerAvailabilityProvider);
      expect((saved.status, saved.notes, saved.untilDate), (PlayerAvailability.injured, 'Hamstring strain', null));

      // The Availability screen (sidebar) shows it at once — status card and form.
      await tester.fling(_mainList, const Offset(0, 3000), 4000); // the menu is in the hero
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Availability')));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.availability);
      expect(find.text('Injured'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Hamstring strain'), 200, scrollable: _mainList);
      expect(find.text('Hamstring strain'), findsOneWidget, reason: 'the form follows the saved note');

      // Status without notes (notes optional): back to Available.
      await tester.tap(find.descendant(of: find.byType(CeBottomNav), matching: find.bySemanticsLabel('Home')));
      await tester.pumpAndSettle();
      await _tap(tester, _quickAction('Match Availability'));
      expect(find.descendant(of: find.byKey(const Key('matchAvailability.current')), matching: find.text('Injured')),
          findsOneWidget);
      await _tap(tester, find.byKey(const Key('matchAvailability.change')));
      await _tap(tester, find.byKey(const Key('matchAvailability.available')));
      await tester.enterText(find.byKey(const Key('matchAvailability.note')), '');
      await tester.pumpAndSettle();
      await _tap(tester, _button('Save'));
      expect((c.read(playerAvailabilityProvider).status, c.read(playerAvailabilityProvider).notes),
          (PlayerAvailability.available, ''));
    });

    testWidgets('Add Workout: sheet → save → Fitness Meter, chart and day detail update; Cancel changes nothing',
        (tester) async {
      final c = await _pumpPlayer(tester);
      final before = c.read(playerFitnessProvider)!;
      final add = find.byKey(const Key('fitness.addWorkout'));
      await tester.scrollUntilVisible(add, 200, scrollable: _mainList);
      expect(find.text('Add Workout'), findsOneWidget, reason: 'beside the Fitness Meter header');

      // Cancel: nothing logged.
      await _tap(tester, add);
      expect(_loc(c), Routes.playerHome, reason: 'a sheet, no new screen');
      expect(find.text('Gym / Strength'), findsOneWidget);
      expect(tester.widget<CeButton>(_button('Save Workout')).onPressed, isNull, reason: 'duration required');
      await tester.enterText(find.byKey(const Key('workout.minutes')), '0');
      await tester.pumpAndSettle();
      expect(tester.widget<CeButton>(_button('Save Workout')).onPressed, isNull, reason: 'must be > 0');
      await _tap(tester, _button('Cancel'));
      expect(c.read(playerWorkoutsProvider), isEmpty);

      // Save a 90-minute high-intensity gym session today.
      await _tap(tester, add);
      await _tap(tester, find.text('Gym / Strength'));
      await tester.enterText(find.byKey(const Key('workout.minutes')), '90');
      await tester.pumpAndSettle();
      await _tap(tester, find.text('High'));
      await tester.enterText(find.byKey(const Key('workout.notes')), 'Leg day');
      await _tap(tester, _button('Save Workout'));
      expect(find.text('Workout added'), findsOneWidget);
      final w = c.read(playerWorkoutsProvider).single;
      expect((w.type, w.minutes, w.intensity, w.notes, w.date), (WorkoutType.gym, 90, WorkoutIntensity.high, 'Leg day', DateTime(2026, 9, 23)));

      // The meter counts it: +2.25 points of load (1.5 h × 1.5).
      final after = c.read(playerFitnessProvider)!;
      expect((after.trainingSessions, after.trainingLoad), (1, 2.25));
      expect(after.matches, before.matches, reason: 'not a match');
      expect(after.score, lessThanOrEqualTo(before.score));
      expect(find.textContaining('1 training session'), findsOneWidget, reason: 'summary');
      // Today's bar has a training part, and the day detail lists the workout.
      await tester.ensureVisible(find.byKey(const Key('fitness.gauge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fitness.day.6')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fitness.bar.training')), findsOneWidget);
      expect(find.text('Training'), findsWidgets, reason: 'legend');
      expect(find.descendant(of: find.byKey(const Key('fitness.dayDetail')), matching: find.text('Gym / Strength · 90 min · High')),
          findsOneWidget);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Club, Performance, Match Availability and Add Workout sheets fit at ${width.toInt()} px', (tester) async {
        final c = await _pumpPlayer(tester, width: width, fullName: 'Muhammad Abdul Rehman Chaudhry Al-Pakistani the Third');
        expect(tester.takeException(), isNull, reason: 'bottom nav @ $width');
        await tester.tap(_navTab('Club'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('joinClub.code')), '35HLWZ');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'join preview @ $width');
        await tester.enterText(find.byKey(const Key('joinClub.code')), 'NOPE99');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'join not found @ $width');
        await _tap(tester, _button('Cancel'));
        await _go(tester, c, Routes.playerHome);
        await _tap(tester, _quickAction('Performance'));
        expect(find.byKey(const Key('performance.sheet')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'performance sheet @ $width');
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav.center')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('status.sheet')), findsOneWidget);
        await tester.tap(find.descendant(of: find.byKey(const Key('status.available')), matching: find.byType(Switch)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'status sheet @ $width');
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await _tap(tester, _quickAction('Match Availability'));
        await _tap(tester, find.byKey(const Key('matchAvailability.change')));
        expect(tester.takeException(), isNull, reason: 'availability sheet expanded @ $width');
        await _tap(tester, _button('Cancel'));
        await _go(tester, c, Routes.playerHome);
        final add = find.byKey(const Key('fitness.addWorkout'));
        await tester.scrollUntilVisible(add, 200, scrollable: _mainList);
        expect(tester.takeException(), isNull, reason: 'fitness header @ $width');
        await _tap(tester, add);
        await _tap(tester, find.byKey(const Key('workout.date')));
        expect(tester.takeException(), isNull, reason: 'workout sheet + calendar @ $width');
        await _tap(tester, _button('Cancel'));
        expect(tester.takeException(), isNull, reason: 'dashboard @ $width');
      });
    }

    testWidgets('Hero: greeting + first name, glass player card with real styles, chips and 4 stats; card opens My Profile',
        (tester) async {
      final c = await _pumpPlayer(tester);
      final perf = await c.read(performanceProvider.future);
      final account = c.read(currentAccountProvider)!;
      final p = account.playerProfile;
      final hero = find.byKey(const Key('player.hero'));
      final card = find.byKey(const Key('player.card'));
      // Top row: menu · greeting / first name · notifications.
      expect(find.byTooltip('Open menu'), findsOneWidget);
      expect(find.text('Good morning'), findsOneWidget, reason: '10:00 on the test clock');
      expect(find.descendant(of: hero, matching: find.text('Aman')), findsOneWidget);
      expect(find.byTooltip(RegExp(r'^Notifications, [1-9]')), findsOneWidget, reason: 'unread badge kept');
      // Glass card: avatar, name, role · batting · bowling (real profile data).
      expect(find.descendant(of: card, matching: find.text(account.fullName)), findsOneWidget);
      expect(
          find.descendant(
              of: card, matching: find.text('${p.role!.label} · RHB · ${p.bowlingStyle!.label}')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Available')), findsOneWidget, reason: 'availability chip');
      expect(find.descendant(of: card, matching: find.text('Wicket Keeper')), findsNothing, reason: 'not a keeper');
      expect(find.descendant(of: card, matching: find.textContaining('KRC001')), findsNothing,
          reason: 'no club joined: no placeholder club');
      // Four stats from the performance summary.
      final stats = find.byKey(const Key('player.stats'));
      for (final (value, label) in [
        ('${perf.matches}', 'Matches'),
        ('${perf.runs}', 'Runs'),
        ('${perf.wickets}', 'Wickets'),
        (perf.battingAverage, 'Bat Avg'),
      ]) {
        expect(find.descendant(of: stats, matching: find.text(label)), findsOneWidget, reason: label);
        expect(find.descendant(of: stats, matching: find.text(value)), findsOneWidget, reason: label);
      }
      expect(tester.getRect(hero).bottom, lessThan(tester.getTopLeft(find.text('Quick Actions')).dy));
      expect(find.text('Performance snapshot', skipOffstage: false), findsNothing, reason: 'replaced by the stats row');

      // The card still opens My Profile; the bell opens the notifications panel.
      await tester.tap(find.descendant(of: card, matching: find.text(account.fullName)));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile);
      await _go(tester, c, Routes.playerHome);
      await tester.fling(_mainList, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RegExp('^Notifications')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notifications.panel')), findsOneWidget);
      expect(_loc(c), Routes.playerHome, reason: 'no route change');
    });

    testWidgets('Hero chips: wicket keeper and a joined club come from real data', (tester) async {
      final c = await _pumpPlayer(tester);
      await c.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(
            playerProfile: a.playerProfile.copyWith(isWicketkeeper: true),
            memberships: [
              const ClubMembership(clubId: 'club_krc001', clubName: 'Karachi Ravians CC', clubCode: 'KRC001', role: MemberRole.player),
            ],
          ));
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('player.card'));
      expect(find.descendant(of: card, matching: find.text('Wicket Keeper')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Karachi Ravians CC')), findsOneWidget);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('hero fits at ${width.toInt()} px with a long name and every chip', (tester) async {
        final c = await _pumpPlayer(tester, width: width, fullName: 'Muhammad Abdul Rehman Chaudhry Al-Pakistani the Third');
        await c.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(
              playerProfile: a.playerProfile.copyWith(isWicketkeeper: true, bowlingStyle: BowlingStyle.leftArmChinaman),
              memberships: [
                const ClubMembership(
                    clubId: 'club_x', clubName: 'Royal Rawalpindi Gymkhana Cricket Club', clubCode: 'RRG001', role: MemberRole.player),
              ],
            ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'hero @ $width');
        final tops = {
          for (final l in ['Matches', 'Runs', 'Wickets', 'Bat Avg'])
            tester.getTopLeft(find.descendant(of: find.byKey(const Key('player.stats')), matching: find.text(l))).dy,
        };
        expect(tops, hasLength(1), reason: 'four stats in one row @ $width');
        // Menu and bell share the top row.
        expect(tester.getCenter(find.byTooltip('Open menu')).dy,
            closeTo(tester.getCenter(find.byTooltip(RegExp('^Notifications'))).dy, 1));
      });
    }

    testWidgets('Recent Form is gone from the dashboard but still in Performance', (tester) async {
      final c = await _pumpPlayer(tester);
      final perf = await c.read(performanceProvider.future);
      expect(perf.recentForm, isNotEmpty, reason: 'the data is untouched');
      await tester.scrollUntilVisible(find.byKey(const Key('fitness.card')), 150, scrollable: _mainList);
      expect(find.text('Recent form', skipOffstage: false), findsNothing);
      expect(find.text('Recent Form', skipOffstage: false), findsNothing);
      expect(find.bySemanticsLabel(RegExp('^Recent form')), findsNothing);

      await _go(tester, c, Routes.myPerformance);
      await tester.scrollUntilVisible(find.text('Recent Form').last, 150, scrollable: _mainList);
      expect(find.text('Recent Form'), findsWidgets);
      expect(find.text('${perf.recentWins}W - ${perf.recentLosses}L'), findsOneWidget);
    });

    testWidgets('My Profile: add, change and remove the profile picture; cancel and errors change nothing',
        (tester) async {
      final picker = FakePhotoPicker();
      final c = await _pumpPlayer(tester, overrides: [photoPickerProvider.overrideWithValue(picker)]);
      await _go(tester, c, Routes.playerProfile);
      final photo = find.byKey(const Key('profile.photo'));
      expect(find.bySemanticsLabel('Add profile picture'), findsOneWidget);

      // Cancel at the sheet, then cancel in the picker: nothing changes.
      await _tap(tester, photo);
      expect(find.text('Choose from gallery'), findsOneWidget);
      expect(find.text('Take a photo'), findsOneWidget);
      expect(find.text('Remove picture'), findsNothing, reason: 'nothing to remove yet');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _tap(tester, photo);
      await _tap(tester, find.text('Choose from gallery'));
      expect(picker.sources, [PhotoSource.gallery]);
      expect(c.read(currentAccountProvider)!.photoPath, isNull, reason: 'picker cancelled');

      // Pick from the gallery: shown at once, kept on the account.
      picker.result = '/photos/me.jpg';
      await _tap(tester, photo);
      await _tap(tester, find.text('Choose from gallery'));
      expect(find.text('Profile picture updated'), findsOneWidget);
      expect(c.read(currentAccountProvider)!.photoPath, '/photos/me.jpg');
      expect(c.read(currentAccountProvider)!.hasPhoto, isTrue);
      expect(_fileImage('/photos/me.jpg'), findsOneWidget);
      expect(find.bySemanticsLabel('Change profile picture'), findsOneWidget);

      // Change it with the camera.
      picker.result = '/photos/selfie.jpg';
      await _tap(tester, photo);
      await _tap(tester, find.text('Take a photo'));
      expect(picker.sources.last, PhotoSource.camera);
      expect(_fileImage('/photos/selfie.jpg'), findsOneWidget);
      expect(_fileImage('/photos/me.jpg'), findsNothing);

      // Denied permission: explained, the picture is kept.
      picker.result = PlatformException(code: 'photo_access_denied');
      await _tap(tester, photo);
      await _tap(tester, find.text('Choose from gallery'));
      expect(find.textContaining('Allow access in Settings'), findsOneWidget);
      expect(c.read(currentAccountProvider)!.photoPath, '/photos/selfie.jpg');

      // Also shown on the dashboard and in the sidebar.
      await _go(tester, c, Routes.playerHome);
      expect(_fileImage('/photos/selfie.jpg'), findsOneWidget);

      // Remove it: back to the initial.
      await _go(tester, c, Routes.playerProfile);
      await _tap(tester, photo);
      await _tap(tester, find.text('Remove picture'));
      expect(c.read(currentAccountProvider)!.photoPath, isNull);
      expect(c.read(currentAccountProvider)!.hasPhoto, isFalse);
      expect(find.bySemanticsLabel('Add profile picture'), findsOneWidget);
      expect(_fileImage('/photos/selfie.jpg'), findsNothing);
    });
  });

  group('My Matches, Match Details, Scorecard', () {
    testWidgets('tabs filter by status and live in the URL', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.myMatches);
      expect(find.text('Shalimar CC vs Falcons CC'), findsOneWidget);
      expect(find.text('Shalimar CC vs Titans CC'), findsNothing);

      await tester.tap(find.text('Past'));
      await tester.pumpAndSettle();
      expect(_loc(c), '${Routes.myMatches}?tab=past');
      expect(find.text('Shalimar CC vs Titans CC'), findsOneWidget);
      expect(find.text('Shalimar CC vs Warriors CC'), findsOneWidget);

      await tester.tap(find.text('Cancelled'));
      await tester.pumpAndSettle();
      expect(find.text('Reason: Rain'), findsOneWidget);
    });

    testWidgets('past card → details → scorecard → back to details', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, '${Routes.myMatches}?tab=past');
      await _tap(tester, find.text('Shalimar CC vs Titans CC'));
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      expect(find.text('Won by 24 runs'), findsOneWidget);
      expect(find.text('Your Availability'), findsNothing, reason: 'past matches have no availability action');

      await _tap(tester, _button('View Scorecard'));
      expect(_loc(c), PlayerMatchView.scorecard.location('pm_2'));
      expect(find.text('Shalimar CC won by 24 runs'), findsOneWidget);
      expect(find.text('Ali Raza\n64 runs'), findsOneWidget);
      expect(find.text('U. Tariq\n3 wkts'), findsOneWidget);
      expect(find.text('BATTER'), findsWidgets);

      // Tabs switch in place: back and forth never adds history entries.
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      expect(find.text('Won by 24 runs'), findsOneWidget);
      await tester.tap(find.text('Scorecard'));
      await tester.pumpAndSettle();
      expect(_loc(c), PlayerMatchView.scorecard.location('pm_2'));
      expect(find.text('Shalimar CC won by 24 runs'), findsOneWidget);

      // Android system Back from Scorecard → Details (same as the top-bar Back).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      await _tap(tester, _button('View Scorecard'));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), startsWith(Routes.myMatches));
    });

    testWidgets('upcoming details shows countdown and Update Availability', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.playerMatchDetails('pm_1'));
      expect(find.text('Match starts in'), findsOneWidget);
      expect(find.text('22h : 00m : 00s'), findsOneWidget);
      await _tap(tester, _button('Update Availability'));
      expect(_loc(c), Routes.availability);
    });

    testWidgets('cancelled details shows the reason; unknown ids show not found', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.playerMatchDetails('pm_4'));
      expect(find.textContaining('Reason: Rain'), findsOneWidget);
      await _go(tester, c, Routes.playerMatchDetails('nope'));
      expect(find.text('Match not found'), findsOneWidget);
      // No scorecard for an upcoming or cancelled match: Details only, no
      // tab row, even when the Scorecard is asked for.
      for (final id in ['pm_1', 'pm_4']) {
        await _go(tester, c, Routes.matchScorecard(id));
        expect(_loc(c), PlayerMatchView.scorecard.location(id), reason: 'legacy route → workspace');
        expect(find.text('Match Details'), findsOneWidget, reason: id);
        expect(find.text('Scorecard'), findsNothing, reason: id);
        expect(find.text('Details'), findsNothing, reason: id);
      }
      expect(find.textContaining('Reason: Rain'), findsOneWidget);
    });

    testWidgets('legacy scorecard route opens the Match workspace on the Scorecard tab', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.matchScorecard('pm_2'));
      expect(_loc(c), PlayerMatchView.scorecard.location('pm_2'));
      expect(find.text('Shalimar CC won by 24 runs'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget, reason: 'tab row shown');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerMatchDetails('pm_2'), reason: 'Back → Details, not a loop');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), startsWith(Routes.myMatches));
      expect(c.read(activeRoleProvider), UserRole.player);
    });
  });

  group('Performance and History', () {
    testWidgets('stat tabs switch tiles; View All opens History; filters work', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.myPerformance);
      expect(find.text('3W - 2L'), findsOneWidget);
      expect(find.text('Runs Scored'), findsOneWidget);
      await tester.tap(find.text('Bowling'));
      await tester.pumpAndSettle();
      expect(find.text('Wickets Taken'), findsOneWidget);
      expect(find.text('Runs Scored'), findsNothing);

      await _tap(tester, find.text('View All'));
      expect(_loc(c), PerformanceView.history.location);
      expect(find.byType(PerMatchChart), findsOneWidget);
      final log = c.read(performanceProvider).value!.matchLog;
      final losses = log.where((m) => m.result == MatchResult.lost).length;
      await tester.tap(find.text('Lost').last);
      await tester.pumpAndSettle();
      final pills = tester.widgetList<CeResultPill>(find.byType(CeResultPill)).toList();
      expect(pills, isNotEmpty);
      expect(pills.every((p) => !p.won), isTrue);
      expect(losses, greaterThan(0));
      expect(find.byType(MatchLogCard), findsWidgets);
      expect(c.read(historyFilterProvider), HistoryFilter.lost);

      // Switching tabs keeps the filter; the tab lives in the URL.
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myPerformance);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(_loc(c), PerformanceView.history.location);
      expect(c.read(historyFilterProvider), HistoryFilter.lost);
      expect(tester.widgetList<CeResultPill>(find.byType(CeResultPill)).every((p) => !p.won), isTrue);

      // Back from History → Overview; Back from Overview → Dashboard.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myPerformance);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome);
    });

    testWidgets('Overview and History agree: matches, runs and wickets come from the same season log',
        (tester) async {
      final c = await _pumpPlayer(tester);
      final p = c.read(performanceProvider).value!;
      final log = p.matchLog;
      expect(log.length, p.matches, reason: 'History total = Overview matches');
      expect(log.fold<int>(0, (s, m) => s + m.runs), p.runs);
      expect(log.fold<int>(0, (s, m) => s + m.wickets), p.wickets);
      expect([for (final m in log.take(p.recentForm.length)) (m.opponentAbbr, m.runs, m.result)],
          [for (final f in p.recentForm) (f.opponentAbbr, f.runs, f.result)],
          reason: 'Recent Form = the latest log entries');

      await _go(tester, c, Routes.myPerformance);
      expect(find.text('${p.matches}'), findsWidgets);
      await _go(tester, c, PerformanceView.history.location);
      expect(find.text('${log.length}'), findsWidgets);
      expect(find.text('Total'), findsOneWidget);
    });

    testWidgets('legacy history route opens the Performance workspace on History', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.matchHistory);
      expect(_loc(c), PerformanceView.history.location);
      expect(find.byType(PerMatchChart), findsOneWidget);
      expect(find.byType(MatchLogCard), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myPerformance, reason: 'system Back → Overview');
      expect(find.text('Runs Scored'), findsOneWidget);
    });
  });

  group('Open Matches', () {
    testWidgets('role gate, ranked search, interest and listing', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.openMatches);
      expect(find.text('Select a role above to see open requests'), findsOneWidget);
      expect(find.text('Choose a role to get started'), findsOneWidget);

      await tester.tap(find.text('Bowler'));
      await tester.pumpAndSettle();
      expect(find.text('1 open request'), findsOneWidget);
      expect(find.text('Karachi Kings CC'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'isl');
      await tester.pumpAndSettle();
      expect(find.text('0 open requests'), findsOneWidget);
      expect(find.text('No results for "isl".'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'kar');
      await tester.pumpAndSettle();
      expect(find.text('1 open request'), findsOneWidget);

      await _tap(tester, _button("I'm Interested"));
      expect(c.read(huntInterestProvider), contains('hunt_1002'));
      expect(_button('Interest Sent'), findsOneWidget);
      expect(find.text("You're on the list — the club will be notified"), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(c.read(playerAvailabilityProvider).openToOffers, isTrue);
      final open = await c.read(huntRepositoryProvider).openPlayers();
      final me = open.where((p) => p.isMe).single;
      expect(me.city, 'Islamabad', reason: 'listed with the account city (fix)');
      expect(me.name, 'Aman Ali');
    });
  });

  group('Availability', () {
    test('resolveUntil: weekend is the coming Saturday; a week ahead on Saturday', () {
      final wed = DateTime(2026, 9, 23, 15);
      expect(resolveUntil(AvailabilityUntil.today, wed, null), DateTime(2026, 9, 23));
      expect(resolveUntil(AvailabilityUntil.tomorrow, wed, null), DateTime(2026, 9, 24));
      expect(resolveUntil(AvailabilityUntil.weekend, wed, null), DateTime(2026, 9, 26));
      expect(resolveUntil(AvailabilityUntil.weekend, DateTime(2026, 9, 26), null), DateTime(2026, 10, 3));
      expect(resolveUntil(AvailabilityUntil.custom, wed, null), isNull);
    });

    testWidgets('Reason/Until hidden for Available; Injured + Tomorrow commits', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.availability);
      expect(find.text('Unavailable Until'), findsNothing);

      await _tap(tester, find.bySemanticsLabel('Injured'));
      expect(find.text('Unavailable Until'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('Tomorrow'));
      await tester.enterText(find.byType(TextField).last, 'Hamstring');
      await _tap(tester, _button('Update Availability'));

      final r = c.read(playerAvailabilityProvider);
      expect(r.status, PlayerAvailability.injured);
      expect(r.untilDate, DateTime(2026, 9, 24));
      expect(r.notes, 'Hamstring');
      expect(r.since, _now);
      expect(find.text('Availability updated'), findsOneWidget);

      // Dashboard pill reflects the same record.
      await _go(tester, c, Routes.playerHome);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('Select Date requires a date; picking one from the calendar commits it', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.availability);
      await _tap(tester, find.bySemanticsLabel('Unavailable'));
      await _tap(tester, _button('Update Availability'));
      expect(find.text('Select a date'), findsWidgets);
      expect(c.read(playerAvailabilityProvider).status, PlayerAvailability.available, reason: 'nothing committed');

      // Past days are disabled; pick the 30th of the current month.
      final day = find.bySemanticsLabel('Wed, 30 Sep 2026');
      await _tap(tester, day);
      await _tap(tester, _button('Update Availability'));
      expect(c.read(playerAvailabilityProvider).untilDate, DateTime(2026, 9, 30));
    });

    testWidgets('Change Status scrolls to the status picker; info shows a tip', (tester) async {
      await _pumpPlayer(tester);
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
      await _go(tester, c, Routes.availability);
      await tester.tap(find.byTooltip('About availability'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Set your status so your coach can plan squads around you'), findsOneWidget);
      await _tap(tester, _button('Got it'));
      await tester.pumpAndSettle();
      await _tap(tester, _button('Change Status'));
      expect(tester.getTopLeft(find.text('Choose your Status')).dy, lessThan(300));
    });
  });

  group('Player Profile', () {
    testWidgets('shows account details and routes to performance, availability, edit', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.playerProfile);
      expect(find.text('0312 9020000'), findsOneWidget);
      expect(find.text('KRC001'), findsOneWidget);
      expect(find.text('AVAILABLE'), findsOneWidget);

      await _tap(tester, _button('View Full Performance'));
      expect(_loc(c), Routes.myPerformance);

      await _go(tester, c, Routes.playerProfile);
      await _tap(tester, _button('Update Availability'));
      expect(_loc(c), Routes.availability);

      // Edit is a mode of the same screen, not a new route.
      await _go(tester, c, Routes.playerProfile);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile);
      expect(find.byKey(const Key('edit.name')), findsOneWidget);
      // The top-bar Cancel (always on screen, whatever the body's scroll).
      await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit.name')), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('legacy edit route opens inline edit; Back leaves edit mode, not the screen', (tester) async {
      final c = await _pumpPlayer(tester);
      await _go(tester, c, Routes.editProfile);
      expect(_loc(c), '${Routes.playerProfile}?edit=1');
      expect(tester.widget<EditableText>(find.descendant(
              of: find.byKey(const Key('edit.name')), matching: find.byType(EditableText))).controller.text,
          'Aman Ali', reason: 'prefilled from the account');
      await tester.enterText(find.byKey(const Key('edit.name')), 'Discarded Name');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerProfile);
      expect(find.byKey(const Key('edit.name')), findsNothing);
      expect(c.read(currentAccountProvider)!.fullName, 'Aman Ali', reason: 'Back discards unsaved edits');
      expect(find.text('Aman Ali'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.playerHome);
    });

    testWidgets('Career stats come from the same source as Dashboard and My Performance', (tester) async {
      final c = await _pumpPlayer(tester);
      final perf = c.read(performanceProvider).value!;
      Future<void> expectCareer() async {
        await _go(tester, c, Routes.playerProfile);
        for (final v in ['${perf.matches}', '${perf.runs}', perf.battingAverage, perf.rating]) {
          expect(find.text(v, skipOffstage: false), findsWidgets, reason: 'Profile career $v');
        }
        await _go(tester, c, Routes.playerHome);
        await tester.fling(_mainList, const Offset(0, 3000), 4000);
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byKey(const Key('player.stats')), matching: find.text('${perf.runs}')),
            findsOneWidget, reason: 'Dashboard runs');
        await _go(tester, c, Routes.myPerformance);
        expect(find.text('${perf.runs}', skipOffstage: false), findsWidgets, reason: 'Performance runs');
      }

      await expectCareer();
      // Renaming the account never changes the stats.
      await c.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(fullName: 'Aman Ullah Khan'));
      await tester.pumpAndSettle();
      final after = c.read(performanceProvider).value!;
      expect((after.matches, after.runs, after.battingAverage, after.rating),
          (perf.matches, perf.runs, perf.battingAverage, perf.rating));
      await expectCareer();
    });
  });

  testWidgets('regression: CeStatusChip ellipsizes a long label in a narrow parent', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: SizedBox(width: 90, child: Row(children: [Expanded(child: CeStatusChip('Limited Availability'))]))),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('LIMITED AVAILABILITY'), findsOneWidget);
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 2 screens render without overflow at ${width.toInt()} px (long content)', (tester) async {
        final c = await _pumpPlayer(tester,
            width: width, fullName: 'Muhammad Abdul Rehman Chaudhry Al-Pakistani the Third');
        c.read(playerAvailabilityProvider.notifier).update(
              status: PlayerAvailability.limited,
              reason: AvailabilityReason.familyEmergency,
              untilDate: DateTime(2026, 12, 31),
            );
        c.read(openMatchesRoleProvider.notifier).select(HuntRole.batsman);
        for (final loc in [
          Routes.playerHome,
          Routes.availability,
          Routes.openMatches,
          Routes.myMatches,
          '${Routes.myMatches}?tab=past',
          '${Routes.myMatches}?tab=cancelled',
          Routes.playerMatchDetails('pm_1'),
          Routes.playerMatchDetails('pm_2'),
          Routes.playerMatchDetails('pm_4'),
          PlayerMatchView.scorecard.location('pm_2'),
          PlayerMatchView.scorecard.location('pm_3'),
          Routes.myPerformance,
          PerformanceView.history.location,
          Routes.playerProfile,
          '${Routes.playerProfile}?edit=1',
        ]) {
          await _go(tester, c, loc);
          // Scroll through the whole screen so every section lays out.
          final scrollable = _mainList;
          for (var i = 0; i < 12; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        // Availability with Reason / Until / calendar open.
        await _go(tester, c, Routes.availability);
        await _tap(tester, find.bySemanticsLabel('Select Date'));
        expect(tester.takeException(), isNull, reason: 'availability calendar @ $width');

        // The Share Profile sheet (from the sidebar).
        await _go(tester, c, Routes.playerHome);
        await tester.fling(_mainList, const Offset(0, 3000), 4000);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Open menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Share Profile')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('shareProfile.card')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'share sheet @ $width');
        await _tap(tester, _button('Close'));
        expect(tester.takeException(), isNull, reason: 'quick actions @ $width');

        // A profile picture on the profile hero, dashboard and the picture sheet.
        await c.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(hasPhoto: true, photoPath: '/p/me.jpg'));
        await _go(tester, c, Routes.playerProfile);
        await _tap(tester, find.byKey(const Key('profile.photo')));
        expect(find.text('Remove picture'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'picture sheet @ $width');
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await _go(tester, c, Routes.playerHome);
        expect(tester.takeException(), isNull, reason: 'dashboard with picture @ $width');
      });
    }
  });
}
