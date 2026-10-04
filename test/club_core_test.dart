import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/club/requests/join_requests_controller.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/matches/screens/match_management_screen.dart';
import 'package:criceco/features/notifications/notifications_controller.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/navigation/role_shells.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
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
    testWidgets('hero, stats and next match come from real club state', (tester) async {
      await _pumpOwner(tester);
      expect(find.text('Club Owner'), findsOneWidget);
      expect(find.text('Shalimar Cricket Club'), findsOneWidget);
      expect(find.textContaining('35HLWZ', findRichText: true), findsOneWidget);
      // Members 21 · Teams 2 · Requests 3 (seed: owner, 18 players, 2 staff).
      for (final (value, label) in [('21', 'MEMBERS'), ('2', 'TEAMS'), ('3', 'REQUESTS')]) {
        expect(find.text(label), findsOneWidget);
        expect(find.text(value), findsWidgets);
      }
      await tester.scrollUntilVisible(find.text('BS CS XI'), 150, scrollable: find.byType(Scrollable).first);
      expect(find.text('Shalimar Cricket Club vs Karachi Kings CC'), findsOneWidget);
      expect(find.text('BS CS XI'), findsOneWidget);
    });

    testWidgets('"Share with players" copies the club code', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await _pumpOwner(tester);
      await tester.tap(find.text('Share with players'));
      await tester.pump();
      expect(copied, '35HLWZ');
      expect(find.text('Club code copied!'), findsOneWidget);
    });

    testWidgets('pending requests banner and tappable stats open their lists', (tester) async {
      final c = await _pumpOwner(tester);
      expect(find.bySemanticsLabel('3 join requests waiting. Review'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('3 join requests waiting. Review'));
      expect(_loc(c), Routes.joinRequests);
      for (final (label, route) in [
        ('MEMBERS', Routes.members),
        ('TEAMS', Routes.teams),
        ('REQUESTS', Routes.joinRequests),
      ]) {
        await _go(tester, c, Routes.clubHome);
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000); // branch keeps its offset
        await tester.pumpAndSettle();
        await _tap(tester, find.text(label));
        expect(_loc(c), route, reason: label);
      }
    });

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
      expect(tiles, ['Requests', 'Challenges', 'Open Player', 'Tournament', 'Announcement']);
      for (final nav in ['Members', 'Teams', 'Upcoming Matches']) {
        expect(tiles, isNot(contains(nav)), reason: '$nav is a bottom-nav tab');
      }
      // Five tiles lay out 3 + 2 (never 4 + a lone tile).
      Finder tile(String l) => find.descendant(of: grid, matching: find.bySemanticsLabel(l));
      final firstRow = tester.getTopLeft(tile('Requests')).dy;
      expect([for (final l in ['Challenges', 'Open Player']) tester.getTopLeft(tile(l)).dy], [firstRow, firstRow]);
      final secondRow = tester.getTopLeft(tile('Tournament')).dy;
      expect(secondRow, greaterThan(firstRow));
      expect(tester.getTopLeft(tile('Announcement')).dy, secondRow);
      for (final (label, route) in [
        ('Requests', Routes.joinRequests),
        ('Challenges', Routes.challenges),
        ('Open Player', Routes.playerHunt),
        ('Tournament', Routes.tournamentHub),
      ]) {
        await _go(tester, c, Routes.clubHome);
        await _tap(tester, find.descendant(of: find.byKey(const Key('club.quickActions')), matching: find.bySemanticsLabel(label)));
        expect(_loc(c), route, reason: label);
        expect(c.read(activeRoleProvider), UserRole.clubOwner);
      }
    });
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

    testWidgets('My Club (from the dashboard header) shows club identity, stats and members', (tester) async {
      final c = await _pumpOwner(tester);
      expect(find.bySemanticsLabel('Open My Club, Shalimar Cricket Club'), findsOneWidget);
      await tester.tap(find.byKey(const Key('club.header')));
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
    testWidgets('Bottom nav: Home · Matches · Teams · Members; Matches is Match Management; My Club via sidebar',
        (tester) async {
      final c = await _pumpOwner(tester);
      final nav = find.byType(CeBottomNav);
      expect([for (final i in tester.widget<CeBottomNav>(nav).items) i.label], ['Home', 'Matches', 'Teams', 'Members']);
      Finder tab(String l) => find.descendant(of: nav, matching: find.bySemanticsLabel(l));
      expect(tab('Profile'), findsNothing);

      await tester.tap(tab('Matches'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.matchManagement());
      expect(find.byType(MatchManagementScreen), findsOneWidget, reason: 'the existing Match Management workspace');
      expect(find.byType(CeBottomNav), findsOneWidget, reason: 'a tab, so the bottom nav stays');
      // Match links elsewhere land on the same tab.
      await _go(tester, c, Routes.matchManagement(MatchTab.waiting));
      expect(find.byType(MatchManagementScreen), findsOneWidget);
      expect(find.byType(CeBottomNav), findsOneWidget);

      for (final (label, route) in [('Teams', Routes.teams), ('Members', Routes.members), ('Home', Routes.clubHome)]) {
        await tester.tap(tab(label));
        await tester.pumpAndSettle();
        expect(_loc(c), route, reason: label);
      }

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
      expect(sent.every((n) => n.title == 'New Club Announcement'), isTrue);
      expect(sent.first.subtitle, 'Shalimar Cricket Club · Coaches and managers: 6 PM at the pavilion.');
      final a = await c.read(announcementRepositoryProvider).byId((sent.first.target! as AnnouncementTarget).announcementId);
      expect((a!.title, a.audience, a.clubId, a.createdBy), ('Staff meeting', AnnouncementAudience.staff, c.read(currentClubProvider)!.id, c.read(currentAccountProvider)!.id));
      // The owner is not staff: nothing in their own (player-side) inbox.
      final ownInbox = await c.read(roleNotificationsProvider(UserRole.player).future);
      expect(ownInbox.where((n) => n.target is AnnouncementTarget), isEmpty);
    });

    testWidgets('a member reads the announcement from Notifications (in a sheet)', (tester) async {
      final c = await _pumpOwner(tester);
      final members = await c.read(clubMembersProvider.future);
      await openSheet(tester);
      await tester.enterText(find.byKey(const Key('announcement.title')), 'Training update');
      await tester.enterText(find.byKey(const Key('announcement.message')), 'Training session tomorrow at 5:00 PM.');
      await tester.pumpAndSettle();
      await _tap(tester, _button('Publish'));
      expect(find.text('Announcement published to ${members.length} members.'), findsOneWidget);

      // The owner is also a playing member of the club: switch to the Player
      // side and open Notifications.
      final nav = c.read(roleControllerProvider.notifier).switchTo(UserRole.player);
      await _go(tester, c, (nav as GoToLocation).location);
      await _go(tester, c, Routes.notifications);
      expect(find.text('New Club Announcement'), findsOneWidget);
      await tester.tap(find.text('New Club Announcement'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.notifications, reason: 'read in place, no new screen');
      expect(find.text('Training update'), findsOneWidget);
      expect(find.byKey(const Key('announcement.body')), findsOneWidget);
      expect(find.text('Training session tomorrow at 5:00 PM.'), findsOneWidget);
      expect(find.textContaining('Shalimar Cricket Club ·'), findsWidgets);
      expect(c.read(notificationReadProvider), contains(startsWith('n_ann_')), reason: 'marked read');
      await _tap(tester, _button('Close'));

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
