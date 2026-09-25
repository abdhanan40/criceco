import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 9, 23, 10);

Future<ProviderContainer> _pumpOwner(WidgetTester tester,
    {double width = 375, String clubName = 'Shalimar Cricket Club'}) async {
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

void main() {
  group('Club Owner Dashboard', () {
    testWidgets('hero, stats and next match come from real club state', (tester) async {
      await _pumpOwner(tester);
      expect(find.text('Club Owner'), findsOneWidget);
      expect(find.text('Shalimar Cricket Club'), findsOneWidget);
      expect(find.textContaining('35HLWZ', findRichText: true), findsOneWidget);
      // Members 1 · Teams 2 · Requests 3 (seed).
      for (final (value, label) in [('1', 'MEMBERS'), ('2', 'TEAMS'), ('3', 'REQUESTS')]) {
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

    testWidgets('quick actions reach real routes and stay in Club context', (tester) async {
      final c = await _pumpOwner(tester);
      for (final (label, route) in [
        ('Requests', Routes.joinRequests),
        ('Members', Routes.members),
        ('Teams', Routes.teams),
        ('Challenges', Routes.challenges),
        ('Open Player', Routes.playerHunt),
        ('Upcoming Matches', Routes.matchManagement()),
        ('Tournament', Routes.tournamentHub),
      ]) {
        await _go(tester, c, Routes.clubHome);
        await _tap(tester, find.bySemanticsLabel(label).first);
        expect(_loc(c), route, reason: label);
        expect(c.read(activeRoleProvider), UserRole.clubOwner);
      }
    });
  });

  group('Teams', () {
    testWidgets('Create Team validates inline and stores format + custom overs', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.teams);
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
      await tester.scrollUntilVisible(find.text('Team A (First XI)'), 150, scrollable: find.byType(Scrollable).first);
      expect(find.text('0 players · Custom · 15 overs'), findsOneWidget);
    });
  });

  group('Team Squad and Add Players', () {
    testWidgets('draft survives leaving; Save commits XI/Sub; locks and caps enforced', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.teams);
      await _tap(tester, find.text('BS CS XI'));
      expect(_loc(c), Routes.teamSquad('team_cs'));
      expect(find.text('0 players in squad'), findsOneWidget);
      expect(find.text('No players in this squad yet.'), findsOneWidget);

      await _tap(tester, _button('Add Players'));
      expect(_loc(c), Routes.addTeamPlayers('team_cs'));
      expect(find.text('0/11', skipOffstage: false), findsOneWidget);

      await _tap(tester, find.bySemanticsLabel(RegExp('^Ali Raza, ')));
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
      await _tap(tester, _button('Add Players'));
      expect(find.text('1/11', skipOffstage: false), findsOneWidget, reason: 'unsaved draft restored');

      // Tapping again cycles Playing → Sub.
      await _tap(tester, find.bySemanticsLabel(RegExp('^Ali Raza, ')));
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
      expect(find.text('No Bowler in this squad.'), findsOneWidget);
    });

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
      expect(find.bySemanticsLabel('1 members'), findsOneWidget);

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

    testWidgets('My Club (Profile tab) shows club identity, stats and members', (tester) async {
      final c = await _pumpOwner(tester);
      await tester.tap(find.bySemanticsLabel('Profile').last);
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myClub);
      expect(find.text('Club 35HLWZ · Islamabad'), findsOneWidget);
      expect(find.textContaining('Established'), findsOneWidget);
      expect(find.text('Members'), findsWidgets);
      expect(find.text('Aman Ali'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
    });
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
        // Custom format field + validation errors on Teams.
        await _go(tester, c, Routes.teams);
        await tester.tap(find.text('Custom'));
        await tester.pump();
        await _tap(tester, _button('Create Team'));
        expect(tester.takeException(), isNull, reason: 'teams errors @ $width');
        // Stats sheet.
        await _go(tester, c, Routes.addTeamPlayers('team_cs'));
        await _tap(tester, find.bySemanticsLabel('Stats for Ali Raza'));
        expect(tester.takeException(), isNull, reason: 'stats sheet @ $width');
      });
    }
  });
}
