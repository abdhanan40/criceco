import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/teams/teams_controller.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/features/matches/lineup_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 25, 9);
const _m2 = MatchLineupTarget('m_2'); // confirmed, in the future (seed: BS CS XI, no players yet)

Future<ProviderContainer> _owner() async {
  final c = await makeContainer(clock: TestClock(_now));
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  await c.read(clubMatchesProvider.future);
  await c.read(teamsProvider.future);
  return c;
}

/// Picks the first 15 available pool players: 11 playing, then 4 subs.
Future<List<SquadPlayer>> _pickFullSquad(ProviderContainer c, LineupTarget t) async {
  final pool = await c.read(clubPlayerPoolProvider.future);
  final open = pool.where((p) => !p.locked).take(15).toList();
  for (final p in open) {
    c.read(lineupDraftProvider(t).notifier).cycle(p);
  }
  return open;
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

Future<void> _clearToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10)); // the barrier above the sheet
  await tester.pumpAndSettle();
}

/// Gives a seed team a real squad: [playing] in the XI, the next [subs] as subs.
Future<void> _fillTeam(ProviderContainer c, String teamId, {int playing = 11, int subs = 2, int skip = 0}) async {
  final pool = await c.read(clubPlayerPoolProvider.future);
  await c.read(teamsProvider.future);
  await c.read(teamsProvider.notifier).saveMembers(teamId, [
    for (final (i, p) in pool.where((p) => !p.locked).skip(skip).take(playing + subs).indexed)
      TeamMember(playerId: p.id, selection: i < playing ? SelectionRole.playing : SelectionRole.sub),
  ]);
}

/// m_2 without a line-up (Case A: no team selected yet).
Future<void> _clearLineup(ProviderContainer c) async {
  await c.read(clubMatchesProvider.future);
  final m = c.read(clubMatchProvider('m_2'))!;
  await c.read(clubMatchesProvider.notifier).save(ClubMatch(
      id: m.id, opponentClubId: m.opponentClubId, status: m.status, format: m.format,
      city: m.city, groundId: m.groundId, startsAt: m.startsAt));
}

/// Team rosters as plain data, to prove the sheet never edits a team.
Future<Map<String, List<(String, SelectionRole)>>> _rosters(ProviderContainer c) async => {
      for (final t in await c.read(teamsProvider.future))
        t.id: [for (final m in t.members) (m.playerId, m.selection)],
    };

void main() {
  group('Line-up rules', () {
    test('shares the squad pick rule: locked players refused, 11 + 4 caps', () async {
      final c = await _owner();
      final pool = await c.read(clubPlayerPoolProvider.future);
      final ctrl = c.read(lineupDraftProvider(_m2).notifier);
      final injured = pool.firstWhere((p) => p.availability == PlayerAvailability.injured);
      expect(ctrl.cycle(injured), PickOutcome.locked);
      await _pickFullSquad(c, _m2);
      final d = c.read(lineupDraftProvider(_m2));
      expect((d.playing, d.subs, d.isComplete), (11, 4, true));
      final extra = pool.where((p) => !p.locked).elementAt(15);
      expect(ctrl.cycle(extra), PickOutcome.full);
    });

    test('confirm needs exactly 11 + 4, then the line-up is saved on the match', () async {
      final c = await _owner();
      final ctrl = c.read(lineupDraftProvider(_m2).notifier);
      ctrl.startNew();
      final pool = await c.read(clubPlayerPoolProvider.future);
      ctrl.cycle(pool.firstWhere((p) => !p.locked));
      expect(await ctrl.confirmBuilt(), 'Select 10 more players for Playing XI');

      ctrl.discard();
      ctrl.startNew();
      final picked = await _pickFullSquad(c, _m2);
      expect(await ctrl.confirmBuilt(), isNull);
      final saved = c.read(clubMatchProvider('m_2'))!.lineup!;
      expect(saved.name, Lineup.newMatchDaySquadName);
      expect(saved.members.map((m) => m.playerId), picked.map((p) => p.id));
      expect(saved.members.where((m) => m.selection == SelectionRole.playing), hasLength(11));
      expect(c.read(lineupDraftProvider(_m2)).dirty, isFalse);
      // Nothing was added to My Teams (architecture §7).
      expect(c.read(teamsProvider).value!.map((t) => t.name), ['BS CS XI', 'BS IT XI']);
    });

    test('unsaved picks persist; startNew/startEdit keep them; discard restores the saved line-up', () async {
      final c = await _owner();
      final ctrl = c.read(lineupDraftProvider(_m2).notifier);
      ctrl.startNew();
      final pool = await c.read(clubPlayerPoolProvider.future);
      ctrl.cycle(pool.firstWhere((p) => !p.locked));
      ctrl.startNew();
      ctrl.startEdit();
      expect(c.read(lineupDraftProvider(_m2)).playing, 1, reason: 'unsaved picks kept');
      ctrl.discard();
      expect(c.read(lineupDraftProvider(_m2)).picks, isEmpty);
      expect(c.read(lineupDraftProvider(_m2)).name, 'BS CS XI', reason: 'seeded from the saved line-up');
    });

    test('Select Existing Team snapshots the team XI / subs and leaves locked players out', () async {
      final c = await _owner();
      final pool = await c.read(clubPlayerPoolProvider.future);
      final open = pool.where((p) => !p.locked).take(12).toList();
      final injured = pool.firstWhere((p) => p.locked);
      await c.read(teamsProvider.notifier).saveMembers('team_it', [
        for (final (i, p) in open.indexed)
          TeamMember(playerId: p.id, selection: i < 11 ? SelectionRole.playing : SelectionRole.sub),
        TeamMember(playerId: injured.id, selection: SelectionRole.sub),
      ]);
      final team = c.read(teamProvider('team_it'))!;
      final leftOut = await c.read(lineupDraftProvider(_m2).notifier).useTeam(team);
      expect(leftOut, 1);
      final saved = c.read(clubMatchProvider('m_2'))!.lineup!;
      expect((saved.name, saved.sourceTeamId, saved.members.length), ('BS IT XI', 'team_it', 12));
    });

    test('editable only for a confirmed, not-yet-started match', () async {
      final c = await _owner();
      expect(c.read(lineupEditableProvider('m_2')), isTrue);
      expect(c.read(lineupEditableProvider('m_1')), isFalse, reason: 'completed');
      expect(c.read(lineupEditableProvider('m_3')), isFalse, reason: 'pending');
    });
  });

  group('Line-up screens', () {
    testWidgets('Scheduled card opens the line-up sheet (no new screen); Select Team: Back returns to Scheduled',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.matchManagement(MatchTab.scheduled));
      await _tap(tester, find.text('View / Edit Line-up'));
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled), reason: 'a sheet, not a route');
      expect(find.byKey(const Key('lineupSheet.current')), findsOneWidget);
      await _closeSheet(tester);

      await _go(tester, c, Routes.matchLineup('m_2'));
      expect(find.text('Confirmed Line-up'), findsOneWidget);
      expect(find.text('BS CS XI'), findsOneWidget);
      expect(find.text('No players picked yet'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled));

      await _go(tester, c, Routes.matchLineup('m_2'));
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled));
    });

    testWidgets('Booking Confirmed "Select Your Playing XI" opens the real flow', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.bookingConfirmed('m_2'));
      await _tap(tester, _button('Select Your Playing XI'));
      expect(_loc(c), Routes.matchLineup('m_2'));
      expect(find.text('Select Team'), findsOneWidget);
    });

    testWidgets('builder: picks persist after leaving; confirm validates; saved line-up shows on reopen',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.matchLineup('m_2'));
      await _tap(tester, find.bySemanticsLabel('Create New Team'));
      expect(_loc(c), Routes.matchLineupBuild('m_2'));
      expect(find.text('0/11'), findsOneWidget);

      await _tap(tester, find.bySemanticsLabel(RegExp('^Ali Raza, ')));
      await _tap(tester, find.bySemanticsLabel(RegExp('^Usman Tariq, ')));
      expect(find.text("Usman Tariq is injured and can't be selected"), findsOneWidget);
      await _clearToast(tester);

      // Leave and come back: the pick is still there.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.matchLineup('m_2'));
      expect(find.text('You have unsaved line-up picks.'), findsOneWidget);
      await _tap(tester, find.text('Continue'));
      expect(c.read(lineupDraftProvider(_m2)).playing, 1);

      await _tap(tester, _button('Confirm Team'));
      expect(find.text('Select 10 more players for Playing XI'), findsOneWidget);

      // Fill the rest, then confirm from the screen.
      final pool = await c.read(clubPlayerPoolProvider.future);
      for (final p in pool.where((p) => !p.locked).skip(1).take(14)) {
        c.read(lineupDraftProvider(_m2).notifier).cycle(p);
      }
      await tester.pumpAndSettle();
      await _tap(tester, _button('Confirm Team'));
      expect(find.text('Team confirmed!'), findsOneWidget);
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled));
      expect(find.text(Lineup.newMatchDaySquadName), findsOneWidget, reason: '"Playing: …" on the card');

      await _tap(tester, find.text('View / Edit Line-up'));
      expect(find.byKey(const Key('lineupSheet.current')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('lineupSheet.currentTeam')), matching: find.text('11 Playing XI · 4 Subs')),
          findsOneWidget);
      await _tap(tester, _button('Edit Line-up'));
      expect(_loc(c), Routes.matchLineupBuild('m_2'));
      expect(find.text('11/11', skipOffstage: false), findsOneWidget);
      expect(find.text('4/4', skipOffstage: false), findsOneWidget);
    });

    testWidgets('Select Existing Team: validation, then the team becomes the line-up', (tester) async {
      final c = await _pumpOwner(tester);
      final pool = await c.read(clubPlayerPoolProvider.future);
      await c.read(teamsProvider.future);
      await c.read(teamsProvider.notifier).saveMembers('team_it', [
        for (final (i, p) in pool.where((p) => !p.locked).take(13).indexed)
          TeamMember(playerId: p.id, selection: i < 11 ? SelectionRole.playing : SelectionRole.sub),
      ]);
      c.read(clubMatchesProvider.notifier); // ensure loaded
      await c.read(clubMatchesProvider.future);
      final m = c.read(clubMatchProvider('m_2'))!;
      await c.read(clubMatchesProvider.notifier).save(
          ClubMatch(id: m.id, opponentClubId: m.opponentClubId, status: m.status, format: m.format,
              city: m.city, groundId: m.groundId, startsAt: m.startsAt)); // no line-up yet
      await _go(tester, c, Routes.matchLineup('m_2'));
      expect(find.text('Booking Confirmed!'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('Select Existing Team'));
      expect(_loc(c), Routes.matchLineupPick('m_2'));
      await _tap(tester, _button('Confirm Team'));
      expect(find.text('Please select a team'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel(RegExp('^BS CS XI, No players yet')));
      await _tap(tester, _button('Confirm Team'));
      expect(find.text('BS CS XI has no players yet — add players in My Teams first'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel(RegExp('^BS IT XI, 11 Playing XI · 2 Subs')));
      await _tap(tester, _button('Confirm Team'));
      expect(find.text('Team confirmed!'), findsOneWidget);
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled));
      final lineup = c.read(clubMatchProvider('m_2'))!.lineup!;
      expect((lineup.name, lineup.members.length), ('BS IT XI', 13));
    });

    testWidgets('locked and not-confirmed matches cannot be edited', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.matchLineup('m_1'));
      expect(find.text('This match has started, so its line-up is locked.'), findsOneWidget);
      expect(_button('Edit Playing XI'), findsNothing);
      expect(find.bySemanticsLabel('Create New Team'), findsNothing);
      await _go(tester, c, Routes.matchLineupBuild('m_1'));
      expect(find.text('Line-up locked'), findsOneWidget);
      await _go(tester, c, Routes.matchLineup('m_3'));
      expect(find.text('Booking not confirmed yet'), findsOneWidget);
    });
  });

  group('Scheduled line-up sheet', () {
    Future<void> openSheet(WidgetTester tester, ProviderContainer c) async {
      await _go(tester, c, Routes.matchManagement(MatchTab.scheduled));
      await _tap(tester, find.textContaining(RegExp(r'^(View / Edit Line-up|Select Your Playing XI)$')));
    }

    testWidgets('Case A: no team yet → Select Team lists teams; the chosen team becomes the line-up', (tester) async {
      final c = await _pumpOwner(tester);
      await _fillTeam(c, 'team_it');
      await _clearLineup(c);
      final before = await _rosters(c);
      await openSheet(tester, c);
      final sheet = find.byKey(const Key('lineupSheet.select'));
      expect(sheet, findsOneWidget);
      expect(_loc(c), Routes.matchManagement(MatchTab.scheduled), reason: 'no new route');
      // Each team: name, squad size and Playing XI status.
      final it = find.byKey(const Key('lineupSheet.team.team_it'));
      final cs = find.byKey(const Key('lineupSheet.team.team_cs'));
      expect(find.descendant(of: it, matching: find.text('BS IT XI')), findsOneWidget);
      expect(find.descendant(of: it, matching: find.text('11 Playing XI · 2 Subs · T20')), findsOneWidget);
      expect(find.descendant(of: it, matching: find.text('XI READY')), findsOneWidget);
      expect(find.descendant(of: cs, matching: find.text('No players yet · T20')), findsOneWidget);
      expect(find.descendant(of: cs, matching: find.text('XI 0/11')), findsOneWidget);

      // Nothing chosen / an empty team: refused with a reason.
      await _tap(tester, _button('Select Team'));
      expect(find.text('Please select a team'), findsOneWidget);
      await _tap(tester, cs);
      await _tap(tester, _button('Select Team'));
      expect(find.text('BS CS XI has no players yet — add players in My Teams first'), findsOneWidget);
      expect(c.read(clubMatchProvider('m_2'))!.lineup, isNull);

      await _tap(tester, it);
      await _tap(tester, _button('Select Team'));
      final lineup = c.read(clubMatchProvider('m_2'))!.lineup!;
      expect((lineup.name, lineup.sourceTeamId, lineup.members.length), ('BS IT XI', 'team_it', 13));
      // Same sheet, now Case B: continue to line-up editing from here.
      expect(find.byKey(const Key('lineupSheet.current')), findsOneWidget);
      expect(find.text('BS IT XI selected for this match.'), findsOneWidget);
      expect(await _rosters(c), before, reason: 'teams are never modified');
      await _tap(tester, _button('Edit Line-up'));
      expect(_loc(c), Routes.matchLineupBuild('m_2'));
      expect(find.text('11/11', skipOffstage: false), findsOneWidget);
    });

    testWidgets('Case B: Replace Team lists the other teams and asks before replacing', (tester) async {
      final c = await _pumpOwner(tester);
      await _fillTeam(c, 'team_it', playing: 11, subs: 4);
      final before = await _rosters(c);
      await openSheet(tester, c);
      expect(find.byKey(const Key('lineupSheet.current')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('lineupSheet.currentTeam')), matching: find.text('BS CS XI')),
          findsOneWidget);
      expect(_button('Edit Line-up'), findsOneWidget);

      await _tap(tester, _button('Replace Team'));
      expect(find.byKey(const Key('lineupSheet.replace')), findsOneWidget);
      expect(find.byKey(const Key('lineupSheet.team.team_cs')), findsNothing, reason: 'the current team is not offered');
      await _tap(tester, find.byKey(const Key('lineupSheet.team.team_it')));
      await _tap(tester, _button('Replace Team'));
      // Confirmation first; Cancel keeps the current team.
      expect(find.text('Replace current team?'), findsOneWidget);
      expect(find.text('This will replace the currently selected team for this match.'), findsOneWidget);
      await _tap(tester, _button('Cancel').last);
      expect(c.read(clubMatchProvider('m_2'))!.lineup!.sourceTeamId, 'team_cs');

      await _tap(tester, _button('Replace Team'));
      await _tap(tester, _button('Replace Team').last);
      final lineup = c.read(clubMatchProvider('m_2'))!.lineup!;
      expect((lineup.name, lineup.sourceTeamId, lineup.members.length), ('BS IT XI', 'team_it', 15));
      expect(find.byKey(const Key('lineupSheet.current')), findsOneWidget);
      expect(find.text('BS IT XI now plays this match.'), findsOneWidget);
      expect(await _rosters(c), before, reason: 'teams are never modified or deleted');
      expect((await c.read(teamsProvider.future)).length, 2);

      // The Scheduled card shows the new team.
      await _closeSheet(tester);
      expect(find.text('BS IT XI'), findsOneWidget);
    });

    testWidgets('Replace Team: Cancel goes back to the current team; an empty team is refused', (tester) async {
      final c = await _pumpOwner(tester);
      await openSheet(tester, c);
      await _tap(tester, _button('Replace Team'));
      await _tap(tester, find.byKey(const Key('lineupSheet.team.team_it')));
      await _tap(tester, _button('Replace Team'));
      expect(find.text('BS IT XI has no players yet — add players in My Teams first'), findsOneWidget);
      expect(find.text('Replace current team?'), findsNothing, reason: 'refused before asking');
      await _tap(tester, _button('Cancel'));
      expect(find.byKey(const Key('lineupSheet.current')), findsOneWidget);
    });

    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('line-up sheet fits at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        await _fillTeam(c, 'team_it');
        await openSheet(tester, c);
        expect(tester.takeException(), isNull, reason: 'current @ $width');
        await _tap(tester, _button('Replace Team'));
        expect(tester.takeException(), isNull, reason: 'replace @ $width');
        await _closeSheet(tester);
        await _clearLineup(c);
        await tester.pumpAndSettle();
        await openSheet(tester, c);
        expect(find.byKey(const Key('lineupSheet.select')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'select @ $width');
      });
    }
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 7 screens render without overflow at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        await c.read(clubPlayerPoolProvider.future);
        c.read(lineupDraftProvider(_m2).notifier).startNew();
        await _pickFullSquad(c, _m2);
        await c.read(lineupDraftProvider(_m2).notifier).confirmBuilt();
        await c.read(teamsProvider.future);
        await c.read(teamsProvider.notifier).create(
            name: 'Extraordinarily Long Development Squad Name', format: MatchFormat.custom, customOvers: 25);
        for (final loc in [
          Routes.matchManagement(MatchTab.scheduled),
          Routes.matchLineup('m_2'),
          Routes.matchLineupBuild('m_2'),
          Routes.matchLineupPick('m_2'),
          Routes.matchLineup('m_1'),
        ]) {
          await _go(tester, c, loc);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 12; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
      });
    }
  });
}
