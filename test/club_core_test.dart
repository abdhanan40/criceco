import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/formatters.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/requests/join_requests_controller.dart';
import 'package:criceco/features/club/screens/join_requests_screen.dart';
import 'package:criceco/features/club/screens/members_screen.dart';
import 'package:criceco/features/club/teams/team_suggestion.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/club/widgets/club_insights.dart';
import 'package:criceco/features/club/widgets/squad_widgets.dart';
import 'package:criceco/features/fitness/fitness_providers.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/features/matches/screens/match_management_screen.dart';
import 'package:criceco/features/notifications/notifications_controller.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/navigation/role_shells.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 9, 23, 10);

Future<ProviderContainer> _pumpOwner(WidgetTester tester,
    {double width = 375, String clubName = 'Shalimar Cricket Club', List<dynamic> overrides = const []}) async {
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
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: clubName, city: 'Islamabad', type: ClubType.professional);
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

/// The Create Team sheet's vertical list (not its horizontal chip rows).
final _sheetList = find
    .descendant(
        of: find.byKey(const Key('createTeam.sheet')),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down))
    .first;

class _Picker implements PhotoPicker {
  _Picker(this.onPick);
  final Future<String?> Function() onPick;

  @override
  Future<String?> pick(PhotoSource source) => onPick();
}

Finder _fileImage(String path) =>
    find.byWidgetPredicate((w) => w is Image && w.image is FileImage && (w.image as FileImage).file.path == path);

void main() {
  group('Club Owner Dashboard', () {
    testWidgets('hero: greeting, glass club card with real identity, chips and the match record; next match', (tester) async {
      final c = await _pumpOwner(tester);
      final club = c.read(currentClubProvider)!;
      final hero = find.byKey(const Key('club.hero'));
      final card = find.byKey(const Key('club.card'));
      // Top row: menu · greeting / owner's first name · notifications.
      expect(find.byTooltip('Open menu'), findsOneWidget);
      expect(find.descendant(of: hero, matching: find.text('Good morning')), findsOneWidget, reason: '10:00 test clock');
      expect(find.descendant(of: hero, matching: find.text('Aman')), findsOneWidget);
      expect(find.byTooltip(RegExp('^Notifications')), findsOneWidget);
      // Card: club name, City · Type · Est., chips.
      expect(find.descendant(of: card, matching: find.text('Shalimar Cricket Club')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Islamabad · ${club.type.label} · Est. ${club.establishedYear}')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Club Owner')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Code 35HLWZ')), findsOneWidget);
      expect(find.textContaining('Verified'), findsNothing, reason: 'no verified state exists');
      // The match record from completed club matches (seed: one, "Won by 18 runs").
      final stats = find.byKey(const Key('club.stats'));
      expect([for (final t in tester.widgetList<Text>(find.descendant(of: stats, matching: find.byType(Text)))) t.data],
          ['1', 'Played', '1', 'Won', '0', 'Lost', '100%', 'Win Rate']);
      // Members 21 · Teams 2 · Requests 3 sit above the quick actions (seed: owner, 18 players, 2 staff).
      for (final (label, value) in [('Members', '21'), ('Teams', '2'), ('Requests', '3')]) {
        expect(find.bySemanticsLabel('$label, $value'), findsOneWidget, reason: label);
      }
      expect(tester.getTopLeft(find.byKey(const Key('club.overview'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const Key('club.quickActions'))).dy));
      expect(find.byType(CeStatGroup), findsNothing, reason: 'the old summary card moved into the hero');
      await tester.scrollUntilVisible(find.text('BS CS XI'), 150, scrollable: find.byType(Scrollable).first);
      expect(find.text('Shalimar Cricket Club vs Karachi Kings CC'), findsOneWidget);
      expect(find.text('BS CS XI'), findsOneWidget);
    });

    testWidgets('the club code chip copies the code to share with players', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await _pumpOwner(tester);
      await tester.tap(find.byKey(const Key('club.code')));
      await tester.pump();
      expect(copied, '35HLWZ');
      expect(find.text('Club code copied!'), findsOneWidget);
    });

    testWidgets('Requests: banner and tile open the Requests sheet; accept from the sheet; no new screen', (tester) async {
      final c = await _pumpOwner(tester);
      final home = _loc(c);
      final sheet = find.byKey(const Key('requests.sheet'));
      expect(find.bySemanticsLabel('3 join requests waiting. Review'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('3 join requests waiting. Review'));
      expect(sheet, findsOneWidget);
      expect(_loc(c), home, reason: 'a sheet over the dashboard');
      expect(find.descendant(of: sheet, matching: find.byType(JoinRequestRow)), findsNWidgets(3));
      await tester.tap(find.descendant(of: sheet, matching: find.byTooltip(RegExp('^Accept'))).first);
      await tester.pumpAndSettle();
      expect(find.text('Approve this request?'), findsOneWidget);
      await _tap(tester, _button('Approve'));
      expect(c.read(pendingJoinRequestCountProvider), 2);
      expect(find.descendant(of: sheet, matching: find.byType(JoinRequestRow)), findsNWidgets(2));
      await _tap(tester, find.descendant(of: sheet, matching: find.text('Approved')));
      expect(find.descendant(of: sheet, matching: find.byType(JoinRequestRow)), findsOneWidget, reason: 'tabs in the sheet');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      // The tile opens the same sheet.
      await _tap(tester, find.bySemanticsLabel('Requests, 2'));
      expect(sheet, findsOneWidget);
      expect(_loc(c), home);
    });


    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('dashboard sheets (Members, member, Teams, Requests, club profile, challenge) fit at ${width.toInt()} px',
          (tester) async {
        final c = await _pumpOwner(tester, width: width, clubName: 'Royal Rawalpindi Gymkhana Cricket & Sports Club of Excellence');
        expect(tester.takeException(), isNull, reason: 'dashboard @ $width');
        Future<void> close() async {
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();
        }

        await _tap(tester, find.byKey(const Key('club.overview.Members')));
        expect(tester.takeException(), isNull, reason: 'members @ $width');
        await tester.tap(find.byTooltip(RegExp('^Filter members')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'member filters @ $width');
        await close();
        await tester.tap(find.byType(MemberRow).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'member profile @ $width');
        await close();
        await close();
        await _tap(tester, find.byKey(const Key('club.overview.Teams')));
        expect(tester.takeException(), isNull, reason: 'teams @ $width');
        await close();
        await _tap(tester, find.byKey(const Key('club.overview.Requests')));
        expect(tester.takeException(), isNull, reason: 'requests @ $width');
        await close();
        await tester.tap(find.descendant(of: find.byType(CeBottomNav), matching: find.bySemanticsLabel('Profile')));
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const Key('clubProfile.editButton')));
        await tester.enterText(find.byKey(const Key('clubProfile.name')), '');
        await _tap(tester, _button('Save Changes'));
        expect(tester.takeException(), isNull, reason: 'club profile edit @ $width');
        await close();
        await _go(tester, c, Routes.myChallenges);
        await _tap(tester, find.text('DHA Bulls CC'));
        expect(tester.takeException(), isNull, reason: 'challenge sheet @ $width');
      });
    }
    testWidgets('Members tile: the members list in a sheet; a member opens their profile in a sheet', (tester) async {
      final c = await _pumpOwner(tester);
      final home = _loc(c);
      final members = await c.read(clubMembersProvider.future);
      await _tap(tester, find.bySemanticsLabel('Members, ${members.length}'));
      final sheet = find.byKey(const Key('members.sheet'));
      expect(sheet, findsOneWidget);
      expect(_loc(c), home, reason: 'no Members screen');
      // Search narrows the list (same rules as before).
      await tester.enterText(find.descendant(of: sheet, matching: find.byType(TextField)), 'Kamran');
      await tester.pumpAndSettle();
      expect(find.descendant(of: sheet, matching: find.byType(MemberRow)), findsOneWidget);
      // The fitness filters open as a sheet too.
      await tester.tap(find.byTooltip(RegExp('^Filter members')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('members.filters')), findsOneWidget);
      await _tap(tester, _button('Apply'));
      // A member → their profile, on top.
      final row = find.descendant(of: sheet, matching: find.byType(MemberRow));
      final name = tester.widget<MemberRow>(row).member.name;
      await tester.tap(row);
      await tester.pumpAndSettle();
      final profile = find.byKey(const Key('memberProfile.sheet'));
      expect(profile, findsOneWidget);
      expect(find.descendant(of: profile, matching: find.text(name)), findsWidgets);
      expect(_loc(c), home);
      // The Members screen still exists for old links.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _go(tester, c, Routes.members);
      expect(find.text('Members'), findsWidgets);
    });

    testWidgets('Teams tile: teams in a sheet; New Team offers T20, ODI, Test, Custom', (tester) async {
      final c = await _pumpOwner(tester);
      final home = _loc(c);
      await _tap(tester, find.bySemanticsLabel('Teams, 2'));
      final sheet = find.byKey(const Key('teams.sheet'));
      expect(sheet, findsOneWidget);
      expect(_loc(c), home);
      expect(find.descendant(of: sheet, matching: find.text('BS CS XI')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('BS IT XI')), findsOneWidget);
      await _tap(tester, find.descendant(of: sheet, matching: find.bySemanticsLabel(RegExp('^Create New Team'))));
      final chips = [
        for (final f in ['T20', 'ODI', 'Test', 'Custom']) tester.getTopLeft(find.widgetWithText(CeChip, f)),
      ];
      // Reading order (the row may wrap at narrow widths): top-to-bottom, then left-to-right.
      final reading = [...chips]..sort((a, b) => a.dy != b.dy ? a.dy.compareTo(b.dy) : a.dx.compareTo(b.dx));
      expect(chips, orderedEquals(reading), reason: 'in this order');
      expect(find.widgetWithText(CeChip, 'T10'), findsNothing);
      await tester.enterText(find.byKey(const Key('teams.name')), 'Weekend XI');
      await _tap(tester, find.widgetWithText(CeChip, 'ODI'));
      await _tap(tester, _button('Create Team'));
      final made = (await c.read(teamsProvider.future)).firstWhere((t) => t.name == 'Weekend XI');
      expect(made.format, MatchFormat.odi);
    });

    testWidgets('hero card and Profile tab open the club profile sheet; Edit saves the club', (tester) async {
      final c = await _pumpOwner(tester);
      final home = _loc(c);
      await tester.tap(find.descendant(of: find.byKey(const Key('club.header')), matching: find.text('Shalimar Cricket Club')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clubProfile.view')), findsOneWidget);
      expect(_loc(c), home, reason: 'a sheet, not My Club');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      final nav = find.byType(CeBottomNav);
      await tester.tap(find.descendant(of: nav, matching: find.bySemanticsLabel('Profile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clubProfile.view')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('clubProfile.editButton')));
      expect(find.byKey(const Key('clubProfile.edit')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('clubProfile.name')), '');
      await tester.enterText(find.byKey(const Key('clubProfile.year')), '1700');
      await tester.enterText(find.byKey(const Key('clubProfile.email')), 'not-an-email');
      await _tap(tester, _button('Save Changes'));
      expect(find.text('Club name is required'), findsOneWidget);
      expect(find.textContaining('Enter a year between 1850'), findsOneWidget);
      expect(find.text('Enter a valid email address'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('clubProfile.name')), 'Shalimar Lions CC');
      await tester.enterText(find.byKey(const Key('clubProfile.year')), '2015');
      await tester.enterText(find.byKey(const Key('clubProfile.email')), 'hello@shalimar.pk');
      await tester.enterText(find.byKey(const Key('clubProfile.address')), 'G-9 Markaz, Islamabad');
      await _tap(tester, _button('Save Changes'));
      expect(find.text('Club profile updated'), findsOneWidget);
      final club = c.read(currentClubProvider)!;
      expect((club.name, club.establishedYear, club.email, club.address, club.code),
          ('Shalimar Lions CC', 2015, 'hello@shalimar.pk', 'G-9 Markaz, Islamabad', '35HLWZ'));
      expect(find.byKey(const Key('clubProfile.view')), findsOneWidget, reason: 'back to the profile');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const Key('club.card')), matching: find.text('Shalimar Lions CC')), findsOneWidget);
      expect(_loc(c), home);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('club hero fits at ${width.toInt()} px with a long club name', (tester) async {
        await _pumpOwner(tester, width: width, clubName: 'Royal Rawalpindi Gymkhana Cricket & Sports Club of Excellence');
        expect(tester.takeException(), isNull, reason: 'hero @ $width');
        final stats = find.byKey(const Key('club.stats'));
        final tops = {
          for (final l in ['Played', 'Won', 'Lost', 'Win Rate'])
            tester.getTopLeft(find.descendant(of: stats, matching: find.text(l))).dy,
        };
        expect(tops, hasLength(1), reason: 'four stats in one row @ $width');
        expect(tester.getCenter(find.byTooltip('Open menu')).dy,
            closeTo(tester.getCenter(find.byTooltip(RegExp('^Notifications'))).dy, 1));
      });
    }

    testWidgets('join request Decline asks for a reason first; Cancel keeps it pending', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.joinRequests);
      final declines = find.byTooltip(RegExp('^Decline'));
      expect(declines, findsWidgets);
      await tester.tap(declines.first);
      await tester.pumpAndSettle();
      expect(find.text('Decline Request?'), findsOneWidget);
      expect(find.text('Our squad is currently full.'), findsWidgets);
      await _tap(tester, _button('Cancel'));
      expect(c.read(pendingJoinRequestCountProvider), 3, reason: 'nothing declined');
      await tester.tap(declines.first);
      await tester.pumpAndSettle();
      await _tap(tester, _button('Decline Request'));
      expect(c.read(pendingJoinRequestCountProvider), 2);
    });

    testWidgets('quick actions reach real routes and stay in Club context', (tester) async {
      final c = await _pumpOwner(tester);
      final grid = find.byKey(const Key('club.quickActions'));
      final tiles = [
        for (final s in tester.widgetList<Semantics>(find.descendant(of: grid, matching: find.byType(Semantics))))
          if (s.properties.button == true && s.properties.label != null) s.properties.label!,
      ];
      expect(tiles, ['Challenges', 'Find Player', 'Tournament', 'Announcement']);
      for (final nav in ['Requests', 'Members', 'Teams', 'Upcoming Matches']) {
        expect(tiles, isNot(contains(nav)), reason: '$nav is not a quick action');
      }
      // Four tiles: a balanced 2 × 2.
      Finder tile(String l) => find.descendant(of: grid, matching: find.bySemanticsLabel(l));
      final firstRow = tester.getTopLeft(tile('Challenges')).dy;
      expect(tester.getTopLeft(tile('Find Player')).dy, firstRow);
      final secondRow = tester.getTopLeft(tile('Tournament')).dy;
      expect(secondRow, greaterThan(firstRow));
      expect(tester.getTopLeft(tile('Announcement')).dy, secondRow);
      for (final (label, route) in [
        ('Challenges', Routes.challenges),
        ('Find Player', Routes.playerHunt),
        ('Tournament', Routes.tournamentHub),
      ]) {
        await _go(tester, c, Routes.clubHome);
        await _tap(tester, find.descendant(of: find.byKey(const Key('club.quickActions')), matching: find.bySemanticsLabel(label)));
        expect(_loc(c), route, reason: label);
        expect(c.read(activeRoleProvider), UserRole.clubOwner);
      }
    });

    testWidgets('Member Growth: members per month from join dates, "+N since <month>"', (tester) async {
      final c = await _pumpOwner(tester);
      final chart = find.byKey(const Key('club.memberGrowth'));
      await _tap(tester, chart);
      // Seed (demo join dates): 3 founders + 18 players two weeks apart; the
      // 10:00 23 Sep clock shows Apr–Sep.
      expect(find.descendant(of: chart, matching: find.text('+11')), findsOneWidget);
      expect(find.descendant(of: chart, matching: find.text('since April')), findsOneWidget);
      expect(find.descendant(of: chart, matching: find.text('21 members')), findsOneWidget);
      final bars = [
        for (var i = 0; i < 6; i++)
          [
            for (final t in tester.widgetList<Text>(
                find.descendant(of: find.byKey(Key('club.memberGrowth.bar.$i')), matching: find.byType(Text))))
              t.data,
          ],
      ];
      expect(bars, [
        ['12', 'Apr'], ['14', 'May'], ['16', 'Jun'], ['18', 'Jul'], ['20', 'Aug'], ['21', 'Sep'],
      ]);
      // Bars grow with the count, all on one baseline.
      final heights = [
        for (var i = 0; i < 6; i++)
          tester.getSize(find.descendant(of: find.byKey(Key('club.memberGrowth.bar.$i')), matching: find.byType(Container)).last).height,
      ];
      expect(heights, orderedEquals([...heights]..sort()));
      expect({
        for (var i = 0; i < 6; i++)
          tester.getBottomLeft(find.descendant(of: find.byKey(Key('club.memberGrowth.bar.$i')), matching: find.byType(Container)).last).dy,
      }, hasLength(1));

      // An approval is a real join today: this month's bar and the total grow.
      final pending = (await c.read(joinRequestsProvider.future)).firstWhere((r) => r.isPending);
      await c.read(joinRequestsProvider.notifier).approve(pending.id);
      await tester.pumpAndSettle();
      final joined = (await c.read(clubMembersProvider.future)).firstWhere((m) => m.name == pending.name);
      expect(joined.joinedAt, _now);
      expect(find.descendant(of: chart, matching: find.text('+12')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('club.memberGrowth.bar.5')), matching: find.text('22')), findsOneWidget);
    });

    test('MemberGrowth: a member without a join date counts as a founding member', () {
      final growth = MemberGrowth.of([
        const ClubMember(id: 'a', name: 'A', role: MemberRole.owner),
        ClubMember(id: 'b', name: 'B', role: MemberRole.player, joinedAt: DateTime(2026, 8, 10)),
        ClubMember(id: 'c', name: 'C', role: MemberRole.player, joinedAt: DateTime(2026, 2, 1)),
      ], _now);
      expect([for (final b in growth.bars) b.$2], [2, 2, 2, 2, 3, 3]);
      expect((growth.before, growth.current, growth.gained), (2, 3, 1));
    });

    testWidgets('Match Results: donut of completed club matches — Won / Lost / Draw-NR with counts and %',
        (tester) async {
      final c = await _pumpOwner(tester);
      final chart = find.byKey(const Key('club.matchResults'));
      await _tap(tester, chart);
      Finder row(String label) => find.byKey(Key('club.matchResults.$label'));
      List<String?> texts(String label) =>
          [for (final t in tester.widgetList<Text>(find.descendant(of: row(label), matching: find.byType(Text)))) t.data];
      // Seed: one completed match, "Won by 18 runs".
      expect(find.descendant(of: chart, matching: find.text('1')), findsWidgets);
      expect(tester.widget<Text>(find.byKey(const Key('club.matchResults.total'))).data, '1');
      expect(texts('Won'), ['Won', '1', '100%']);
      expect(texts('Lost'), ['Lost', '0', '0%']);
      expect(texts('Draw / NR'), ['Draw / NR', '0', '0%']);

      // More results recorded → the chart follows the data.
      final matches = c.read(clubMatchesProvider.notifier);
      final base = c.read(clubMatchProvider('m_1'))!;
      for (final (id, result) in [('r_1', 'Lost by 5 runs'), ('r_2', 'Match tied'), ('r_3', 'No result (rain)')]) {
        await matches.save(ClubMatch(
            id: id, opponentClubId: base.opponentClubId, status: MatchStatus.completed, format: base.format,
            city: base.city, startsAt: base.startsAt, resultText: result));
      }
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('club.matchResults.total'))).data, '4');
      expect(texts('Won'), ['Won', '1', '25%']);
      expect(texts('Lost'), ['Lost', '1', '25%']);
      expect(texts('Draw / NR'), ['Draw / NR', '2', '50%']);
    });

    test('MatchResultsSummary counts completed matches only', () {
      ClubMatch m(MatchStatus s, String? r) => ClubMatch(id: '$s$r', opponentClubId: 'x', status: s, resultText: r);
      final s = MatchResultsSummary.of([
        m(MatchStatus.completed, 'Won by 3 wickets'),
        m(MatchStatus.completed, 'won by 1 run'),
        m(MatchStatus.completed, 'Lost by 20 runs'),
        m(MatchStatus.completed, null),
        m(MatchStatus.confirmed, 'Won by 9 runs'),
        m(MatchStatus.pending, null),
      ]);
      expect((s.won, s.lost, s.drawn, s.total), (2, 1, 1, 4));
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Member Growth and Match Results fit at ${width.toInt()} px', (tester) async {
        await _pumpOwner(tester, width: width);
        await _tap(tester, find.byKey(const Key('club.matchResults')));
        expect(tester.takeException(), isNull, reason: 'charts @ $width');
        final growth = find.byKey(const Key('club.memberGrowth'));
        final results = find.byKey(const Key('club.matchResults'));
        expect(tester.getTopLeft(results).dy, greaterThan(tester.getBottomLeft(growth).dy), reason: 'results under growth');
        for (final f in [growth, results]) {
          expect(tester.getSize(f).width, lessThanOrEqualTo(width), reason: "within the screen (incl. gutters)");
        }
        expect(tester.getSize(results).height, lessThan(140), reason: 'compact');
        expect(tester.getSize(growth).height, lessThan(200), reason: 'compact');
      });
    }
  });

  group('Teams', () {
    testWidgets('team card: squad stats and avatars; Add Players (Back → Teams); View Team', (tester) async {
      final c = await _pumpOwner(tester);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final open = pool.where((p) => !p.locked).toList();
      await c.read(teamsProvider.notifier).saveMembers('team_cs', [
        for (final (i, p) in open.take(8).indexed)
          TeamMember(playerId: p.id, selection: i < 6 ? SelectionRole.playing : SelectionRole.sub),
      ]);
      await _go(tester, c, Routes.teams);
      expect(find.text('8/15'), findsOneWidget);
      expect(find.text('6/11'), findsOneWidget);
      expect(find.text('2/4'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget, reason: '5 avatars, then +3');
      await tester.scrollUntilVisible(find.text('T20 · 0 players'), 150, scrollable: find.byType(Scrollable).first);
      expect(find.text('T20 · 0 players'), findsOneWidget, reason: 'BS IT XI is empty');
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();

      await _tap(tester, find.bySemanticsLabel('Add Players to BS CS XI'));
      expect(_loc(c), Routes.addTeamPlayers('team_cs'));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.teams);

      await _tap(tester, _button('View Team').first);
      expect(_loc(c), Routes.teamSquad('team_cs'));
    });

    testWidgets('Create Team (bottom sheet) validates inline and stores format + custom overs', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.teams);
      // The team list comes first; the form opens in a sheet.
      expect(find.text('BS CS XI'), findsOneWidget);
      expect(find.byKey(const Key('teams.name')), findsNothing);
      await _tap(tester, find.bySemanticsLabel(RegExp('^Create New Team')));
      expect(find.byKey(const Key('teams.name')), findsOneWidget);
      // Cancel closes without creating anything.
      final before = c.read(teamsProvider).value!.length;
      await _tap(tester, _button('Cancel'));
      expect(find.byKey(const Key('teams.name')), findsNothing);
      expect(c.read(teamsProvider).value!.length, before);
      await _tap(tester, find.bySemanticsLabel(RegExp('^Create New Team')));
      await _tap(tester, _button('Create Team'));
      expect(find.text('Please enter a team name'), findsOneWidget);
      expect(find.text('Please select a format'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('teams.name')), 'bs cs xi');
      await tester.tap(find.text('T20').first);
      await _tap(tester, _button('Create Team'));
      expect(find.text('A team with this name already exists'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('teams.name')), 'Team A (First XI)');
      await tester.tap(find.text('Custom'));
      await tester.pump();
      await _tap(tester, _button('Create Team'));
      expect(find.text('Please enter the number of overs'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('teams.overs')), '15');
      await _tap(tester, _button('Create Team'));

      final created = c.read(teamsProvider).value!.last;
      expect(created.name, 'Team A (First XI)');
      expect(created.format, MatchFormat.custom);
      expect(created.customOvers, 15);
      expect(find.text('Team created!'), findsOneWidget);
      expect(find.byKey(const Key('teams.name')), findsNothing, reason: 'sheet closes on success');
      expect(_loc(c), Routes.teams);
      await tester.scrollUntilVisible(find.text('Team A (First XI)'), 150, scrollable: find.byType(Scrollable).first);
      expect(find.text('Custom · 15 overs · 0 players'), findsOneWidget);
    });
  });

  group('Team Squad and Add Players', () {
    testWidgets('draft survives leaving; Save commits XI/Sub; locks and caps enforced', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.teams);
      await _tap(tester, find.text('BS CS XI'));
      expect(_loc(c), Routes.teamSquad('team_cs'));
      expect(find.text('0 players in squad'), findsOneWidget);
      expect(find.text('No players in this squad yet'), findsOneWidget);

      await _tap(tester, _button('Add Players').first);
      expect(_loc(c), Routes.addTeamPlayers('team_cs'));
      expect(find.text('0/11'), findsOneWidget);

      // Tapping a player never adds them: the Add Player sheet asks for the
      // squad position first.
      await _tap(tester, find.bySemanticsLabel(RegExp('^Ali Raza, ')));
      expect(c.read(squadEditorProvider('team_cs')).picks, isEmpty, reason: 'not added on tap');
      expect(find.text('SQUAD POSITION'), findsOneWidget);
      expect(tester.widget<CeButton>(_button('Add Player')).onPressed, isNull, reason: 'a position must be chosen');
      await _tap(tester, _button('Cancel'));
      expect(c.read(squadEditorProvider('team_cs')).picks, isEmpty, reason: 'Cancel adds nothing');

      await _tap(tester, find.bySemanticsLabel(RegExp('^Ali Raza, ')));
      await _tap(tester, find.byKey(const Key('addPlayer.playing')));
      await _tap(tester, _button('Add Player'));
      expect(c.read(squadEditorProvider('team_cs')).playing, 1);
      await _tap(tester, find.bySemanticsLabel(RegExp('^Usman Tariq, ')));
      expect(find.text("Usman Tariq is injured and can't be added"), findsOneWidget);
      expect(c.read(squadEditorProvider('team_cs')).playing, 1, reason: 'locked player not added');

      // Stats sheet.
      await _tap(tester, find.bySemanticsLabel('Stats for Hamza Sheikh'));
      expect(find.text('Rating'), findsOneWidget);
      expect(find.text('BATTING'), findsOneWidget);
      await _tap(tester, _button('Close'));

      // Leave without saving → nothing committed, draft kept (P5).
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.teamSquad('team_cs'));
      expect(find.text('0 players in squad'), findsOneWidget);
      await _tap(tester, _button('Add Players').first);
      expect(find.text('1/11', skipOffstage: false), findsOneWidget, reason: 'unsaved draft restored');

      // A picked player opens the same sheet to move (or remove) them.
      await _tap(tester, find.bySemanticsLabel(RegExp('^Ali Raza, ')));
      expect(find.byKey(const Key('addPlayer.remove')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('addPlayer.sub')));
      await _tap(tester, _button('Update Player'));
      expect(c.read(squadEditorProvider('team_cs')).playing, 0);
      expect(c.read(squadEditorProvider('team_cs')).subs, 1);
      await _tap(tester, _button('Save Squad'));
      expect(find.text('Squad updated!'), findsOneWidget);
      expect(_loc(c), Routes.teamSquad('team_cs'));
      expect(find.text('1 player in squad'), findsOneWidget);
      expect(find.text('SUB'), findsOneWidget);
      final team = c.read(teamProvider('team_cs'))!;
      expect(team.members.single.selection, SelectionRole.sub);

      // Filter chips.
      await tester.tap(find.text('Bowler'));
      await tester.pumpAndSettle();
      expect(find.text('No Bowler in this squad'), findsOneWidget);
    });

    testWidgets('Squad: XI/Sub counters, row opens stats; Add Players search, pinned Save, unsaved flag',
        (tester) async {
      final c = await _pumpOwner(tester);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final editor = c.read(squadEditorProvider('team_cs').notifier);
      final open = pool.where((p) => !p.locked).toList();
      editor.cycle(open[0]); // Playing
      editor.cycle(open[1]); // Playing
      await editor.save();

      await _go(tester, c, Routes.teamSquad('team_cs'));
      expect(find.text('2/11'), findsOneWidget);
      expect(find.text('0/4'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel(RegExp('^${open[0].name}, .*View stats')));
      expect(find.text('BATTING'), findsOneWidget, reason: 'stats sheet, no extra screen');
      expect(_loc(c), Routes.teamSquad('team_cs'));
      await _tap(tester, _button('Close'));

      await _tap(tester, _button('Add Players').first);
      expect(find.text('Unsaved changes'), findsNothing);
      // Save Squad is pinned: visible without scrolling the pool.
      expect(tester.getRect(_button('Save Squad')).bottom, lessThanOrEqualTo(812));
      await tester.enterText(find.byType(TextField), open[2].name.split(' ').first);
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'^\d+ of \d+ players$')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^${open[2].name}, ')), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'of \d+ players$')), findsNothing, reason: 'cleared');
      await _tap(tester, find.bySemanticsLabel(RegExp('^${open[2].name}, ')));
      await _tap(tester, find.byKey(const Key('addPlayer.playing')));
      await _tap(tester, _button('Add Player'));
      expect(find.text('Unsaved changes'), findsOneWidget);
      await _tap(tester, _button('Save Squad'));
      expect(c.read(teamProvider('team_cs'))!.members, hasLength(3));
    });

    testWidgets('Add Player sheet: real role, XI / Substitute limits, move and remove', (tester) async {
      final c = await _pumpOwner(tester);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final members = await c.read(clubMembersProvider.future);
      final editor = c.read(squadEditorProvider('team_cs').notifier);
      final open = pool.where((p) => !p.locked).toList();
      for (final p in open.take(11)) {
        expect(editor.assign(p, SelectionRole.playing), PickOutcome.changed);
      }
      expect(editor.assign(open[11], SelectionRole.playing), PickOutcome.full, reason: 'XI is capped at 11');
      expect(c.read(squadEditorProvider('team_cs')).playing, 11);

      await _go(tester, c, Routes.addTeamPlayers('team_cs'));
      final next = open[11];
      await _tap(tester, find.bySemanticsLabel(RegExp('^${next.name}, ')));
      // The role shown is the player's own profile role, not a placeholder.
      final member = members.singleWhere((m) => m.poolPlayerId == next.id);
      expect(find.text(member.roleLine), findsWidgets);
      expect(find.text(next.position), findsWidgets);
      expect(find.text('Full'), findsOneWidget, reason: 'Playing XI has no room');
      await tester.tap(find.byKey(const Key('addPlayer.playing')));
      await tester.pumpAndSettle();
      expect(tester.widget<CeButton>(_button('Add Player')).onPressed, isNull, reason: 'a full XI cannot be chosen');
      await _tap(tester, find.byKey(const Key('addPlayer.sub')));
      await _tap(tester, _button('Add Player'));
      expect(c.read(squadEditorProvider('team_cs')).picks[next.id], SelectionRole.sub);
      expect(c.read(squadEditorProvider('team_cs')).playing, 11);

      // Remove from the squad through the same sheet.
      await _tap(tester, find.bySemanticsLabel(RegExp('^${next.name}, ')));
      await _tap(tester, find.byKey(const Key('addPlayer.remove')));
      await _tap(tester, _button('Update Player'));
      expect(c.read(squadEditorProvider('team_cs')).picks.containsKey(next.id), isFalse);

      // Substitutes are capped too; a full squad refuses another player.
      for (final p in open.skip(11).take(4)) {
        expect(editor.assign(p, SelectionRole.sub), PickOutcome.changed);
      }
      expect(editor.assign(open[15], SelectionRole.sub), PickOutcome.full);
      await tester.pumpAndSettle();
      await _tap(tester, find.bySemanticsLabel(RegExp('^${open[15].name}, ')));
      expect(find.text('Playing XI and substitutes are full'), findsOneWidget);
      expect(find.text('SQUAD POSITION'), findsNothing);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Add Player sheet fits at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        final pool = await c.read(clubPlayerPoolProvider.future);
        final open = pool.where((p) => !p.locked).toList();
        c.read(squadEditorProvider('team_cs').notifier).assign(open.first, SelectionRole.playing);
        await _go(tester, c, Routes.addTeamPlayers('team_cs'));
        for (final p in [open.first, open[1]]) {
          await _tap(tester, find.bySemanticsLabel(RegExp('^${p.name}, ')));
          expect(find.text('SQUAD POSITION'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '${p.name} sheet @ $width');
          await _tap(tester, find.byKey(const Key('addPlayer.sub')));
          expect(tester.takeException(), isNull, reason: 'choice @ $width');
          await _tap(tester, _button('Cancel'));
        }
      });
    }

    testWidgets('caps: 12th pick becomes a sub; 16th is refused', (tester) async {
      final c = await _pumpOwner(tester);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final editor = c.read(squadEditorProvider('team_cs').notifier);
      final open = pool.where((p) => !p.locked).toList();
      for (final p in open.take(15)) {
        expect(editor.cycle(p), PickOutcome.changed);
      }
      expect(c.read(squadEditorProvider('team_cs')).playing, 11);
      expect(c.read(squadEditorProvider('team_cs')).subs, open.length >= 15 ? 4 : open.length - 11);
      if (open.length > 15) expect(editor.cycle(open[15]), PickOutcome.full);
    });
  });

  group('Members and My Club', () {
    testWidgets('Members: owner row is the account; search is live and ranked', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.members);
      expect(find.text('Aman Ali'), findsOneWidget);
      expect(find.text('OWNER'), findsOneWidget);
      expect(find.bySemanticsLabel('21 members'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pumpAndSettle();
      expect(find.text('No members found'), findsOneWidget);
      expect(find.text('No results for "zz".'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'ali');
      await tester.pumpAndSettle();
      expect(find.text('Aman Ali'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '0312');
      await tester.pumpAndSettle();
      expect(find.text('Aman Ali'), findsOneWidget, reason: 'phone is a secondary search field');
    });

    testWidgets('My Club: add, change and remove the club picture; cancel and errors change nothing', (tester) async {
      String? result;
      Object? error;
      final picker = _Picker(() async {
        if (error != null) throw error;
        return result;
      });
      final c = await _pumpOwner(tester, overrides: [photoPickerProvider.overrideWithValue(picker)]);
      await _go(tester, c, Routes.myClub);
      final photo = find.byKey(const Key('club.photo'));
      expect(find.bySemanticsLabel('Add club picture'), findsOneWidget);

      await _tap(tester, photo);
      expect(find.text('Club picture'), findsOneWidget);
      expect(find.text('Remove picture'), findsNothing);
      await _tap(tester, find.text('Choose from gallery')); // picker cancelled
      expect(c.read(currentClubProvider)!.logoPath, isNull);

      result = '/photos/club.png';
      await _tap(tester, photo);
      await _tap(tester, find.text('Choose from gallery'));
      expect(find.text('Club picture updated'), findsOneWidget);
      final club = c.read(currentClubProvider)!;
      expect((club.logoPath, club.hasLogo), ('/photos/club.png', true));
      expect((club.name, club.code, club.city), ('Shalimar Cricket Club', '35HLWZ', 'Islamabad'), reason: 'rest unchanged');
      expect(_fileImage('/photos/club.png'), findsOneWidget);
      expect(find.bySemanticsLabel('Change club picture'), findsOneWidget);

      // The club dashboard shows it too.
      await _go(tester, c, Routes.clubHome);
      expect(_fileImage('/photos/club.png'), findsOneWidget);

      await _go(tester, c, Routes.myClub);
      error = PlatformException(code: 'camera_access_denied');
      await _tap(tester, photo);
      await _tap(tester, find.text('Take a photo'));
      expect(find.textContaining('access your camera'), findsOneWidget);
      expect(c.read(currentClubProvider)!.logoPath, '/photos/club.png', reason: 'kept on error');

      error = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await _tap(tester, photo);
      await _tap(tester, find.text('Remove picture'));
      expect(c.read(currentClubProvider)!.logoPath, isNull);
      expect(c.read(currentClubProvider)!.hasLogo, isFalse);
      expect(find.bySemanticsLabel('Add club picture'), findsOneWidget);

      for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
        tester.view.physicalSize = Size(width * 3, 812 * 3);
        await c.read(sessionProvider.notifier).updateClub((x) => x.withLogo('/photos/club.png'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'My Club with picture @ $width');
      }
    });

    testWidgets('My Club (from the sidebar) shows club identity, stats and members', (tester) async {
      final c = await _pumpOwner(tester);
      expect(find.bySemanticsLabel(RegExp(r'^Open club profile, Shalimar Cricket Club')), findsOneWidget);
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('My Club')));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myClub);
      expect(find.text('Club 35HLWZ · Islamabad'), findsOneWidget);
      expect(find.textContaining('Established'), findsOneWidget);
      expect(find.text('Members'), findsWidgets);
      expect(find.text('Aman Ali'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
    });
  });

  group('Club Owner navigation', () {
    testWidgets('center "+": a raised button that opens the Create Team sheet (no route change)', (tester) async {
      final c = await _pumpOwner(tester);
      final home = _loc(c);
      final nav = find.byType(CeBottomNav);
      final plus = find.byKey(const Key('nav.center'));
      Finder tab(String l) => find.descendant(of: nav, matching: find.bySemanticsLabel(l));
      expect(plus, findsOneWidget);
      final rect = tester.getRect(plus);
      expect(rect.top, lessThan(tester.getRect(tab('Home')).top), reason: 'raised');
      expect(rect.left, greaterThan(tester.getRect(tab('Matches')).right));
      expect(rect.right, lessThan(tester.getRect(tab('Teams')).left));
      expect(tester.getRect(nav).top, lessThanOrEqualTo(rect.top), reason: 'inside the nav, never over content');
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('createTeam.sheet')), findsOneWidget);
      expect(_loc(c), home);
      expect(tester.widget<CeBottomNav>(nav).currentIndex, 0, reason: 'never a selected tab');
    });

    testWidgets('Create Team sheet: name + format, pick XI / Sub with the squad limits, Suggest Team, create', (tester) async {
      final c = await _pumpOwner(tester);
      final pool = await c.read(clubPlayerPoolProvider.future);
      final before = (await c.read(teamsProvider.future)).length;
      await tester.tap(find.byKey(const Key('nav.center')));
      await tester.pumpAndSettle();
      bool createEnabled() => tester.widget<CeButton>(find.byKey(const Key('createTeam.create'))).onPressed != null;
      Finder choice(SquadPlayer p, String which) => find.byKey(Key('createTeam.choice.${p.id}.$which'));
      Future<void> pick(SquadPlayer p, String which) async {
        // Hit-testable: on screen in the list, not hidden behind the pinned buttons.
        final f = choice(p, which).hitTestable();
        await tester.dragUntilVisible(f, _sheetList, const Offset(0, -120));
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      String pill(String label) => (tester.widget<SquadPill>(find.byKey(Key('createTeam.balance.$label')))).label;

      // Disabled until the team has a name (T20 is preselected).
      expect(createEnabled(), isFalse);
      await tester.enterText(find.byKey(const Key('createTeam.name')), 'Weekend XI');
      await tester.pumpAndSettle();
      expect(createEnabled(), isTrue);
      // Custom needs valid overs.
      await _tap(tester, find.widgetWithText(CeChip, 'Custom'));
      expect(createEnabled(), isFalse);
      await tester.enterText(find.byKey(const Key('createTeam.overs')), '25');
      await tester.pumpAndSettle();
      expect(createEnabled(), isTrue);
      await _tap(tester, find.widgetWithText(CeChip, 'ODI'));

      // Pick directly: Playing XI / Substitute / Not selected, with live counts and balance.
      final open = pool.where((p) => !p.locked).toList();
      final locked = pool.firstWhere((p) => p.locked);
      await pick(open[0], 'playing');
      await pick(open[1], 'sub');
      String footer() => tester.widget<Text>(find.byKey(const Key('createTeam.footerSummary'))).data!;
      expect(footer(), 'XI 1/11 · Subs 1/4');
      final firstCat = switch (open[0].category) {
        SquadCategory.batsman => 'Batsmen',
        SquadCategory.bowler => 'Bowlers',
        SquadCategory.allRounder => 'All-Rounders',
      };
      await tester.drag(_sheetList, const Offset(0, 3000)); // back up to Squad Setup
      await tester.pumpAndSettle();
      expect(pill(firstCat), contains(RegExp(r'[12]$')));
      await pick(open[1], 'none');
      expect(footer(), 'XI 1/11 · Subs 0/4');
      // Injured / unavailable can't be picked (existing rule).
      await pick(locked, 'playing');
      expect(find.textContaining("can't be selected"), findsOneWidget);

      // Suggest Team pre-fills 11 + 2 for review; the XI cap holds.
      await tester.drag(_sheetList, const Offset(0, 3000));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Suggest Team'));
      expect(footer(), 'XI 11/11 · Subs 2/4');
      final s = TeamSuggestion.build(pool,
          stats: {for (final p in pool) p.id: c.read(squadPlayerStatsProvider((p.name, p.position, p.availability)))},
          fitness: c.read(poolFitnessProvider));
      final notPicked = open.firstWhere((p) => !s.picks.containsKey(p.id));
      await pick(notPicked, 'playing');
      expect(find.textContaining('Playing XI is full'), findsOneWidget);

      await tester.tap(find.byKey(const Key('createTeam.create')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('createTeam.sheet')), findsNothing);
      expect(find.text('Team created!'), findsOneWidget);
      final teams = await c.read(teamsProvider.future);
      expect(teams, hasLength(before + 1));
      final made = teams.last;
      expect((made.name, made.format, made.playingCount, made.subCount), ('Weekend XI', MatchFormat.odi, 11, 2));
      // The Teams list shows it at once; the Teams screen is unchanged.
      await _go(tester, c, Routes.teams);
      expect(find.bySemanticsLabel(RegExp('^Create New Team')), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Weekend XI'), 200,
          scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first);
      expect(find.text('Weekend XI'), findsOneWidget);
    });

    testWidgets('Create Team sheet: a duplicate name is refused inline; Cancel creates nothing', (tester) async {
      final c = await _pumpOwner(tester);
      final before = (await c.read(teamsProvider.future)).length;
      await tester.tap(find.byKey(const Key('nav.center')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('createTeam.name')), 'bs cs xi');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('createTeam.create')));
      await tester.pumpAndSettle();
      expect(find.text('A team with this name already exists'), findsOneWidget);
      expect(find.byKey(const Key('createTeam.sheet')), findsOneWidget);
      await tester.tap(_button('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('createTeam.sheet')), findsNothing);
      expect((await c.read(teamsProvider.future)).length, before);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('club nav and Create Team sheet fit at ${width.toInt()} px', (tester) async {
        await _pumpOwner(tester, width: width);
        tester.view.padding = const FakeViewPadding(bottom: 34 * 3);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'nav @ $width');
        await tester.tap(find.byKey(const Key('nav.center')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CeChip, 'Custom'));
        await tester.pumpAndSettle();
        await tester.drag(_sheetList, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'create team sheet @ $width');
        final screenBottom = tester.view.physicalSize.height / tester.view.devicePixelRatio;
        expect(tester.getRect(find.byKey(const Key('createTeam.create'))).bottom, lessThanOrEqualTo(screenBottom - 34 + 0.5),
            reason: 'Create Team above the home indicator');
      });
    }

    testWidgets('Bottom nav: Home · Matches · [+] · Teams · Profile (a sheet); Matches is Match Management; My Club via sidebar',
        (tester) async {
      final c = await _pumpOwner(tester);
      final nav = find.byType(CeBottomNav);
      expect([for (final i in tester.widget<CeBottomNav>(nav).items) i.label], ['Home', 'Matches', 'New Team', 'Teams', 'Profile']);
      expect([for (final i in tester.widget<CeBottomNav>(nav).items) i.center], [false, false, true, false, false]);
      Finder tab(String l) => find.descendant(of: nav, matching: find.bySemanticsLabel(l));
      expect(tab('Members'), findsNothing);

      await tester.tap(tab('Matches'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.matchManagement());
      expect(find.byType(MatchManagementScreen), findsOneWidget, reason: 'the existing Match Management workspace');
      expect(find.byType(CeBottomNav), findsOneWidget, reason: 'a tab, so the bottom nav stays');
      // Match links elsewhere land on the same tab.
      await _go(tester, c, Routes.matchManagement(MatchTab.waiting));
      expect(find.byType(MatchManagementScreen), findsOneWidget);
      expect(find.byType(CeBottomNav), findsOneWidget);

      for (final (label, route) in [('Teams', Routes.teams), ('Home', Routes.clubHome)]) {
        await tester.tap(tab(label));
        await tester.pumpAndSettle();
        expect(_loc(c), route, reason: label);
      }
      // Profile: the club profile sheet over the current tab (never highlighted).
      await tester.tap(tab('Profile'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clubProfile.view')), findsOneWidget);
      expect(_loc(c), Routes.clubHome);
      expect(tester.widget<CeBottomNav>(nav).currentIndex, 0);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Sidebar: no Members / Find Player / Challenges / Match Management /
      // Tournaments / Requests; Edit Club opens the profile sheet in edit mode.
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      final drawer = find.byType(Drawer);
      for (final gone in ['Members', 'Find Player', 'Challenges', 'Match Management', 'Tournaments', 'Requests']) {
        expect(find.descendant(of: drawer, matching: find.text(gone)), findsNothing, reason: gone);
      }
      await tester.tap(find.descendant(of: drawer, matching: find.text('Edit Club')));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.byKey(const Key('clubProfile.edit')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('clubProfile.owner')), 'Aman Ali Khan');
      await _tap(tester, _button('Save Changes'));
      expect(c.read(currentClubProvider)!.ownerName, 'Aman Ali Khan');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // My Club from the sidebar (and the header — see the My Club test).
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('My Club')));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myClub);
      expect(find.text('Club 35HLWZ · Islamabad'), findsOneWidget);
    });
  });

  group('Club announcements', () {
    Future<void> openSheet(WidgetTester tester) async {
      await _tap(tester, find.descendant(
          of: find.byKey(const Key('club.quickActions')), matching: find.bySemanticsLabel('Announcement')));
      expect(find.text('Create Announcement'), findsOneWidget);
    }

    testWidgets('publish needs a title and message; audience sets the recipients', (tester) async {
      final c = await _pumpOwner(tester);
      await openSheet(tester);
      expect(_loc(c), Routes.clubHome, reason: 'a sheet, not a new screen');
      bool publishEnabled() => tester.widget<CeButton>(_button('Publish')).onPressed != null;
      expect(publishEnabled(), isFalse, reason: 'empty');
      await tester.enterText(find.byKey(const Key('announcement.title')), 'Training update');
      await tester.pumpAndSettle();
      expect(publishEnabled(), isFalse, reason: 'message missing');
      await tester.enterText(find.byKey(const Key('announcement.message')), '   ');
      await tester.pumpAndSettle();
      expect(publishEnabled(), isFalse, reason: 'blank message');
      await tester.enterText(find.byKey(const Key('announcement.message')), 'Training session tomorrow at 5:00 PM.');
      await tester.pumpAndSettle();
      expect(publishEnabled(), isTrue);

      final members = await c.read(clubMembersProvider.future);
      final players = members.where((m) => m.plays).length;
      final staff = members.length - players;
      expect(find.text('Goes to ${members.length} members'), findsOneWidget, reason: 'All Club Members by default');
      await _tap(tester, find.text('Players Only'));
      expect(find.text('Goes to $players members'), findsOneWidget);
      await _tap(tester, find.text('Staff Only'));
      expect(find.text('Goes to $staff members'), findsOneWidget);

      // Cancel publishes nothing.
      await _tap(tester, _button('Cancel'));
      expect(find.text('Create Announcement'), findsNothing);
      final inbox = await c.read(notificationRepositoryProvider).forRole(UserRole.player);
      expect(inbox.where((n) => n.target is AnnouncementTarget), isEmpty);
    });

    testWidgets('publishing notifies exactly the selected members; the count is real', (tester) async {
      final c = await _pumpOwner(tester);
      final members = await c.read(clubMembersProvider.future);
      final staffIds = {for (final m in members) if (!m.plays) m.id};
      await openSheet(tester);
      await tester.enterText(find.byKey(const Key('announcement.title')), 'Staff meeting');
      await tester.enterText(find.byKey(const Key('announcement.message')), 'Coaches and managers: 6 PM at the pavilion.');
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Staff Only'));
      await _tap(tester, _button('Publish'));
      expect(find.text('Create Announcement'), findsNothing);
      expect(find.text('Announcement published to ${staffIds.length} members.'), findsOneWidget);

      final sent = (await c.read(notificationRepositoryProvider).forRole(UserRole.player))
          .where((n) => n.target is AnnouncementTarget)
          .toList();
      expect({for (final n in sent) n.recipientMemberId}, staffIds, reason: 'staff only');
      expect(sent.every((n) => n.title == 'Club Announcement'), isTrue);
      expect(sent.first.subtitle, 'Shalimar Cricket Club · Staff meeting — Coaches and managers: 6 PM at the pavilion.');
      final a = await c.read(announcementRepositoryProvider).byId((sent.first.target! as AnnouncementTarget).announcementId);
      expect((a!.title, a.audience, a.clubId, a.createdBy), ('Staff meeting', AnnouncementAudience.staff, c.read(currentClubProvider)!.id, c.read(currentAccountProvider)!.id));
      // The owner is not staff: nothing in their own (player-side) inbox.
      final ownInbox = await c.read(roleNotificationsProvider(UserRole.player).future);
      expect(ownInbox.where((n) => n.target is AnnouncementTarget), isEmpty);
    });

    testWidgets('a member reads the announcement from the dashboard notifications panel (in a sheet)', (tester) async {
      final c = await _pumpOwner(tester);
      final members = await c.read(clubMembersProvider.future);
      await openSheet(tester);
      await tester.enterText(find.byKey(const Key('announcement.title')), 'Training update');
      await tester.enterText(find.byKey(const Key('announcement.message')), 'Training session tomorrow at 5:00 PM.');
      await tester.pumpAndSettle();
      await _tap(tester, _button('Publish'));
      expect(find.text('Announcement published to ${members.length} members.'), findsOneWidget);

      // The owner is also a playing member of the club: switch to the Player
      // side and open the notifications panel from the dashboard bell.
      final nav = c.read(roleControllerProvider.notifier).switchTo(UserRole.player);
      final home = (nav as GoToLocation).location;
      await _go(tester, c, home);
      await tester.tap(find.byTooltip(RegExp('^Notifications')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notifications.panel')), findsOneWidget);
      // Type, club name and a short preview in the inbox row.
      expect(find.text('Club Announcement'), findsOneWidget);
      expect(find.text('Shalimar Cricket Club · Training update — Training session tomorrow at 5:00 PM.'), findsOneWidget);
      await tester.tap(find.text('Club Announcement'));
      await tester.pumpAndSettle();
      expect(_loc(c), home, reason: 'read in place, no new screen');
      // Full announcement: club name, title, full message, date and time.
      final now = c.read(clockProvider).now();
      expect(find.text('Training update'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('announcement.club')), matching: find.text('Shalimar Cricket Club')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('announcement.when')),
              matching: find.text('${CeFormat.dayDate(now)} · ${CeFormat.time(now)}')),
          findsOneWidget);
      expect(find.byKey(const Key('announcement.body')), findsOneWidget);
      expect(find.text('Training session tomorrow at 5:00 PM.'), findsOneWidget);
      expect(c.read(notificationReadProvider), contains(startsWith('n_ann_')), reason: 'marked read');
      await _tap(tester, _button('Close'));
      expect(find.byKey(const Key('notifications.panel')), findsOneWidget, reason: 'back to the panel');
      expect(_loc(c), home);

      // Club Owner inbox: announcements are for members, not the owner inbox.
      final club = await c.read(roleNotificationsProvider(UserRole.clubOwner).future);
      expect(club.where((n) => n.target is AnnouncementTarget), isEmpty);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('announcement sheets and the new dashboard fit at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        expect(tester.takeException(), isNull, reason: 'dashboard @ $width');
        await openSheet(tester);
        await tester.enterText(find.byKey(const Key('announcement.title')), 'A' * 60);
        await tester.enterText(find.byKey(const Key('announcement.message')), 'Long message ' * 20);
        await tester.pumpAndSettle();
        await _tap(tester, find.text('Staff Only'));
        expect(tester.takeException(), isNull, reason: 'create sheet @ $width');
        await _tap(tester, _button('Publish'));
        final nav = c.read(roleControllerProvider.notifier).switchTo(UserRole.player);
        await _go(tester, c, (nav as GoToLocation).location);
        c.read(roleControllerProvider.notifier).switchTo(UserRole.clubOwner);
        await _go(tester, c, Routes.matchManagement());
        expect(tester.takeException(), isNull, reason: 'Matches tab @ $width');
      });
    }
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 3 screens render without overflow at ${width.toInt()} px (long content)', (tester) async {
        final c = await _pumpOwner(tester,
            width: width, clubName: 'Royal Rawalpindi Gymkhana Cricket & Sports Club of Excellence');
        await c.read(teamsProvider.future);
        await c
            .read(teamsProvider.notifier)
            .create(name: 'Extraordinarily Long Development Squad Name', format: MatchFormat.custom, customOvers: 25);
        final pool = await c.read(clubPlayerPoolProvider.future);
        final editor = c.read(squadEditorProvider('team_cs').notifier);
        for (final p in pool.where((p) => !p.locked).take(15)) {
          editor.cycle(p);
        }
        await editor.save();
        for (final loc in [
          Routes.clubHome,
          Routes.teams,
          Routes.teamSquad('team_cs'),
          Routes.addTeamPlayers('team_cs'),
          Routes.members,
          Routes.myClub,
        ]) {
          await _go(tester, c, loc);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 14; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        // Create Team sheet: Custom format field + validation errors.
        await _go(tester, c, Routes.teams);
        // The Teams list keeps its scroll offset; the banner is at the top.
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
        await tester.pumpAndSettle();
        await _tap(tester, find.bySemanticsLabel(RegExp('^Create New Team')));
        await tester.tap(find.text('Custom'));
        await tester.pump();
        await _tap(tester, _button('Create Team'));
        expect(tester.takeException(), isNull, reason: 'teams errors @ $width');
        await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
        await tester.pumpAndSettle();
        // Stats sheet.
        await _go(tester, c, Routes.addTeamPlayers('team_cs'));
        await _tap(tester, find.bySemanticsLabel('Stats for Ali Raza'));
        expect(tester.takeException(), isNull, reason: 'stats sheet @ $width');
      });
    }
  });
}
