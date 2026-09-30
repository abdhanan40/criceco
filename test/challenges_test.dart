import 'package:clock/clock.dart';
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/challenges/challenges_controller.dart';
import 'package:criceco/features/club/club_providers.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

final _now = DateTime(2026, 9, 24, 11);

Future<ProviderContainer> _owner({TestClock? clock}) async {
  final c = await makeContainer(clock: clock ?? TestClock(_now));
  final s = c.read(sessionProvider.notifier);
  await s.signIn(identifier: 'x', password: 'y');
  await s.createClub(name: 'Shalimar Cricket Club', city: 'Islamabad', type: ClubType.professional);
  await c.read(challengesProvider.future);
  await c.read(clubMatchesProvider.future);
  return c;
}

Future<ProviderContainer> _pumpOwner(
  WidgetTester tester, {
  double width = 375,
  bool demo = true,
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
  if (!demo) c.read(demoModeProvider.notifier).set(false);
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

/// Lets a toast clear so it can't cover the next tap target.
Future<void> _clearToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

const _day = 'Wed, 30 Sep 2026';

bool _enabled(WidgetTester tester, String label) => tester.widget<CeButton>(_button(label)).onPressed != null;

Future<void> _pickFormat(WidgetTester tester, String format) async {
  await tester.tap(find.widgetWithText(CeChip, format).last);
  await tester.pumpAndSettle();
}

Future<void> _pickGround(WidgetTester tester, String ground) async {
  await _tap(tester, find.byKey(const Key('challenge.ground')));
  await tester.tap(find.textContaining(ground).last);
  await tester.pumpAndSettle();
}

Future<void> _pickDate(WidgetTester tester, [String day = _day]) async {
  await _tap(tester, find.byKey(const Key('challenge.date')));
  await _tap(tester, find.bySemanticsLabel(day));
}

/// Completes the setup sheet (Match Format → Ground → Date) and opens Review.
Future<void> _setupAndReview(WidgetTester tester, {String format = 'T20', String ground = 'KRL Ground'}) async {
  await _pickFormat(tester, format);
  await _pickGround(tester, ground);
  await _pickDate(tester);
  await _tap(tester, _button('Review'));
}

/// A row of the review summary: its label and value sit on one line.
void _expectSummary(WidgetTester tester, Map<String, String> rows) {
  final summary = find.byKey(const Key('challenge.summary'));
  for (final e in rows.entries) {
    expect(find.descendant(of: summary, matching: find.text(e.key)), findsOneWidget, reason: e.key);
    expect(find.descendant(of: summary, matching: find.text(e.value)), findsOneWidget, reason: e.value);
  }
}

/// Scrolls to the top, then down until [text] is visible (lazy lists).
Future<void> _expectVisible(WidgetTester tester, String text) async {
  await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text(text), 120, scrollable: find.byType(Scrollable).first);
  expect(find.text(text), findsOneWidget, reason: text);
}

void main() {
  group('Challenge rules', () {
    test('Demo ON: a sent challenge is accepted instantly and creates ONE pending match', () async {
      final c = await _owner();
      expect(c.read(demoModeProvider), isTrue);
      final before = c.read(clubMatchesProvider).value!.length;

      final ch = await c.read(challengesProvider.notifier).send('club_kk');
      expect(ch.status, ChallengeStatus.accepted);
      expect(ch.direction, ChallengeDirection.sent);
      expect(ch.matchId, isNotNull);
      final matches = c.read(clubMatchesProvider).value!;
      expect(matches.length, before + 1);
      final m = matches.singleWhere((x) => x.id == ch.matchId);
      expect(m.status, MatchStatus.pending);
      expect(m.opponentClubId, 'club_kk');
      expect(m.format, MatchFormat.t20, reason: 'KK prefers T20 / ODI');

      // Accepting again is a no-op: still exactly one match for this challenge.
      await c.read(challengesProvider.notifier).accept(ch.id);
      expect(c.read(clubMatchesProvider).value!.length, before + 1);
    });

    test('Demo OFF: a sent challenge stays pending (Sent), then expires after the window', () async {
      final clock = TestClock(_now);
      final c = await _owner(clock: clock);
      c.read(demoModeProvider.notifier).set(false);
      final before = c.read(clubMatchesProvider).value!.length;

      final ch = await c.read(challengesProvider.notifier).send('club_iu', format: MatchFormat.odi);
      expect(ch.status, ChallengeStatus.pending);
      expect(ch.expiresAt, _now.add(Challenge.responseWindow));
      expect(c.read(myChallengeSectionsProvider).sent.map((x) => x.id), [ch.id]);
      expect(c.read(pendingSentClubIdsProvider), contains('club_iu'));
      expect(c.read(clubMatchesProvider).value!.length, before, reason: 'no match until accepted');

      clock.advance(const Duration(days: 8));
      expect(ch.statusAt(clock.now), ChallengeStatus.expired);
      final result = await c.read(challengesProvider.notifier).accept(ch.id);
      expect(result!.status, ChallengeStatus.expired, reason: 'an expired challenge cannot be accepted');
      expect(c.read(clubMatchesProvider).value!.length, before);
    });

    test('Received: Accept creates one match; Decline creates none; overdue ones load as expired', () async {
      final clock = TestClock(_now);
      final c = await _owner(clock: clock);
      final ctrl = c.read(challengesProvider.notifier);
      final before = c.read(clubMatchesProvider).value!.length;

      final declined = await ctrl.decline('ch_gc');
      expect(declined!.status, ChallengeStatus.declined);
      expect(declined.respondedAt, _now);
      expect(c.read(clubMatchesProvider).value!.length, before);

      final accepted = await ctrl.accept('ch_db');
      expect(accepted!.status, ChallengeStatus.accepted);
      await ctrl.accept('ch_db');
      expect(c.read(clubMatchesProvider).value!.length, before + 1);
      final m = c.read(clubMatchesProvider).value!.last;
      expect((m.opponentClubId, m.format, m.status), ('club_db', MatchFormat.t20, MatchStatus.pending));

      final sections = c.read(myChallengeSectionsProvider);
      expect(sections.awaitingDecision, isEmpty);
      expect(sections.resolved.map((x) => x.id), containsAll(['ch_db', 'ch_gc', 'ch_gt']));

      // A received challenge whose proposed date has passed loads as expired.
      final c2 = await _owner(clock: clock);
      clock.advance(const Duration(days: 30));
      c2.invalidate(challengesProvider);
      final list = await c2.read(challengesProvider.future);
      expect(list.firstWhere((x) => x.id == 'ch_gc').status, ChallengeStatus.expired);
    });
  });

  group('Challenges screens (Demo ON)', () {
    testWidgets('hub Challenge: format → ground → date → review → send; then Challenge Accepted → Waiting',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.challenges);
      expect(find.text('Karachi Kings CC'), findsOneWidget);
      expect(find.text('Islamabad United XI'), findsOneWidget);
      // Create Availability Slot lives in Find Opponent only.
      expect(find.textContaining('Create Availability Slot', findRichText: true), findsNothing);

      // Challenge → setup sheet; Cancel sends nothing.
      final before = c.read(challengesProvider).value!.length;
      await _tap(tester, _button('Challenge').first);
      expect(find.text('Challenge Karachi Kings CC'), findsOneWidget);
      expect(_enabled(tester, 'Review'), isFalse, reason: 'nothing chosen yet');
      await _tap(tester, _button('Cancel'));
      expect(c.read(challengesProvider).value!.length, before, reason: 'cancelled: nothing sent');
      expect(_loc(c), Routes.challenges);

      // Review stays disabled until format, ground AND date are chosen.
      await _tap(tester, _button('Challenge').first);
      await _pickFormat(tester, 'ODI');
      expect(_enabled(tester, 'Review'), isFalse, reason: 'ground and date missing');
      await _pickGround(tester, 'National Stadium');
      expect(_enabled(tester, 'Review'), isFalse, reason: 'date missing');
      await _pickDate(tester);
      expect(_enabled(tester, 'Review'), isTrue);
      expect(c.read(challengesProvider).value!.length, before, reason: 'still nothing sent');

      await _tap(tester, _button('Review'));
      expect(find.text('Send Challenge?'), findsOneWidget);
      _expectSummary(tester, {
        'Opponent': 'Karachi Kings CC',
        'Format': 'ODI',
        'Ground': 'National Stadium',
        'Date': _day,
      });
      expect(find.text('Are you sure you want to send this challenge?'), findsOneWidget);
      // Edit returns to the details with the choices kept.
      await _tap(tester, find.text('Edit'));
      expect(_enabled(tester, 'Review'), isTrue);
      await _tap(tester, _button('Review'));
      await _tap(tester, _button('Send Challenge'));

      final ch = c.read(challengesProvider).value!.last;
      expect((ch.format, ch.groundName, ch.proposedAt), (MatchFormat.odi, 'National Stadium', DateTime(2026, 9, 30)),
          reason: 'the chosen format, ground and date are sent');
      expect(_loc(c), Routes.challengeAccepted(ch.id));
      expect(find.text('Challenge Accepted!'), findsOneWidget);
      expect(find.text('Challenge sent to Karachi Kings CC!'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing, reason: 'terminal screen');

      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(_loc(c), Routes.matchManagement(MatchTab.waiting));
      expect(c.read(activeRoleProvider), UserRole.clubOwner);
    });

    testWidgets('My Challenges has no Accept / Decline; the Club Profile answers a pending challenge', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.myChallenges);
      expect(find.text('Awaiting your Decision'), findsOneWidget);
      expect(find.text('DHA Bulls CC'), findsOneWidget);
      expect(find.text('NEW'), findsNWidgets(2));
      expect(find.text('ACCEPTED'), findsOneWidget); // Gulberg Tigers, resolved
      expect(find.text('2'), findsWidgets, reason: 'My Challenges tab counts decisions awaiting');
      for (final label in ['Accept Challenge', 'Accept', 'Decline']) {
        expect(_button(label), findsNothing, reason: 'no $label button on the list cards');
      }

      // Pending incoming challenge → its club profile shows Decline / Accept.
      await _tap(tester, find.text('GOR Challengers'));
      expect(_loc(c), Routes.clubProfile('club_gc', challengeId: 'ch_gc'));
      expect(_button('Decline'), findsOneWidget);
      expect(_button('Accept'), findsOneWidget);
      expect(_button('Challenge This Club'), findsNothing, reason: 'replaced by the decision');
      expect(tester.getRect(_button('Accept')).bottom, lessThanOrEqualTo(812), reason: 'pinned at the bottom');

      await _tap(tester, _button('Decline'));
      expect(find.text('Decline this challenge?'), findsOneWidget, reason: 'confirms first');
      await _tap(tester, _button('Decline Challenge'));
      expect(find.text('Challenge declined'), findsOneWidget);
      expect(c.read(challengeProvider('ch_gc'))!.status, ChallengeStatus.declined);
      // Resolved: the status, no actions and no duplicate CTA.
      expect(find.text('You declined this challenge'), findsOneWidget);
      expect(find.text('DECLINED'), findsOneWidget);
      expect(_button('Accept'), findsNothing);
      expect(_button('Decline'), findsNothing);
      expect(_button('Challenge This Club'), findsNothing);

      await _clearToast(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.myChallenges);
      expect(find.text('DECLINED'), findsOneWidget);
      expect(find.text('NEW'), findsOneWidget);

      // Accept asks first; Cancel changes nothing.
      final before = c.read(clubMatchesProvider).value!.length;
      await _tap(tester, find.text('DHA Bulls CC'));
      expect(_loc(c), Routes.clubProfile('club_db', challengeId: 'ch_db'));
      await _tap(tester, _button('Accept'));
      expect(find.text('Accept Challenge?'), findsOneWidget);
      expect(find.text('Are you sure you want to accept this match challenge?'), findsOneWidget);
      await _tap(tester, _button('Cancel'));
      expect(c.read(challengeProvider('ch_db'))!.status, ChallengeStatus.pending);
      expect(c.read(clubMatchesProvider).value!.length, before);

      await _tap(tester, _button('Accept'));
      await _tap(tester, _button('Accept Challenge'));
      expect(find.text('Challenge accepted!'), findsOneWidget);
      expect(_loc(c), Routes.matchManagement(MatchTab.waiting));
      expect(c.read(clubMatchesProvider).value!.length, before + 1);

      // A resolved challenge opened from its card shows its status only.
      await _clearToast(tester);
      await _go(tester, c, Routes.clubProfile('club_gt', challengeId: 'ch_gt'));
      expect(find.text('Your challenge was accepted'), findsOneWidget);
      expect(_button('Accept'), findsNothing);
      expect(_button('Challenge This Club'), findsNothing);
    });

    testWidgets('Club Profile opened from the Challenges list still answers a pending incoming challenge',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.clubProfile('club_db'));
      expect(_button('Accept'), findsOneWidget);
      expect(_button('Decline'), findsOneWidget);
      expect(_button('Challenge This Club'), findsNothing, reason: 'no crossing challenge');
    });

    testWidgets('Find Opponent: derived count; Send Match Request needs details and a final confirmation',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.findMatch);
      expect(find.text('Find Opponent'), findsNWidgets(2), reason: 'screen title and tab');
      expect(find.textContaining('Find Match'), findsNothing);
      expect(find.textContaining('Create Availability Slot', findRichText: true), findsOneWidget);
      expect(find.text('Teams Looking for Opponents · 2 Teams'), findsOneWidget);
      expect(find.text('Rawalpindi Rams'), findsOneWidget, reason: 'seed name fixed (was "Riders")');

      final before = c.read(challengesProvider).value!.length;
      await _tap(tester, _button('Send Match Request').last);
      expect(c.read(challengesProvider).value!.length, before, reason: 'not sent on tap');
      expect(find.text('Match request to Rawalpindi Rams'), findsOneWidget);
      // The listing fixes the format and date; its venue is not a listed ground.
      expect(_enabled(tester, 'Review'), isFalse, reason: 'ground missing');
      await _pickGround(tester, 'KRL Ground');
      await _tap(tester, _button('Review'));
      expect(find.text('Send Match Request?'), findsOneWidget);
      _expectSummary(tester, {'Opponent': 'Rawalpindi Rams', 'Format': 'T20', 'Ground': 'KRL Ground'});
      expect(find.text('Are you sure you want to send this match request?'), findsOneWidget);
      await _tap(tester, _button('Cancel'));
      expect(c.read(challengesProvider).value!.length, before, reason: 'cancelled at the confirmation');

      await _tap(tester, _button('Send Match Request').last);
      await _pickGround(tester, 'KRL Ground');
      await _tap(tester, _button('Review'));
      await _tap(tester, _button('Send Request'));
      final ch = c.read(challengesProvider).value!.last;
      expect((ch.opponentClubId, ch.format, ch.groundName), ('club_rr', MatchFormat.t20, 'KRL Ground'));
      expect(ch.proposedAt, isNotNull);
      expect(find.text('Challenge Accepted!'), findsOneWidget);
    });

    testWidgets('Find Opponent → Club Profile: CTA is "Send Match Request" with the same details + confirmation',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.findMatch);
      await _tap(tester, find.text('Rawalpindi Rams'));
      expect(_loc(c), Routes.clubProfile('club_rr', fromFind: true));
      expect(_button('Send Match Request'), findsOneWidget);
      expect(_button('Challenge This Club'), findsNothing);

      final before = c.read(challengesProvider).value!.length;
      await _tap(tester, _button('Send Match Request'));
      expect(_enabled(tester, 'Review'), isFalse);
      await _setupAndReview(tester, format: 'T10', ground: 'Pindi Cricket Ground');
      expect(find.text('Send Match Request?'), findsOneWidget);
      _expectSummary(tester, {
        'Opponent': 'Rawalpindi Rams',
        'Format': 'T10',
        'Ground': 'Pindi Cricket Ground',
        'Date': _day,
      });
      expect(c.read(challengesProvider).value!.length, before);
      await _tap(tester, _button('Send Request'));
      final ch = c.read(challengesProvider).value!.last;
      expect((ch.opponentClubId, ch.format, ch.groundName, ch.proposedAt),
          ('club_rr', MatchFormat.t10, 'Pindi Cricket Ground', DateTime(2026, 9, 30)));
      expect(find.text('Challenge Accepted!'), findsOneWidget);
    });

    testWidgets('tabs switch sections; Club Profile shows Owner / Coach (no About) → Challenge This Club',
        (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.challenges);
      await _tap(tester, find.text('My Challenges'));
      expect(_loc(c), Routes.myChallenges);
      expect(find.text('Find Match'), findsNothing);
      await _tap(tester, find.text('Find Opponent'));
      expect(_loc(c), Routes.findMatch);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(_loc(c), Routes.challenges);

      await _tap(tester, find.text('Faisalabad Wolves'));
      expect(_loc(c), Routes.clubProfile('club_fw'));
      // The CTA is pinned in a compact bar; the profile scrolls above it.
      expect(tester.getSize(find.byKey(const Key('clubProfile.actions'))).height, lessThan(120));
      expect(tester.getRect(_button('Challenge This Club')).bottom, lessThanOrEqualTo(812));
      final club = (await c.read(clubDirectoryProvider.future))['club_fw']!;
      await tester.scrollUntilVisible(find.text('Club Coach'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('About'), findsNothing);
      expect(find.text(club.about), findsNothing, reason: 'the caption is gone');
      expect(find.text('Club Owner'), findsOneWidget);
      expect(find.text('Club Coach'), findsOneWidget);
      // No owner / coach is on record for this club: said plainly, nothing invented.
      expect((club.ownerName, club.coachName), (null, null));
      expect(find.text('Not listed'), findsNWidgets(2));
      await tester.scrollUntilVisible(find.textContaining('Key Players'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Club Captain', skipOffstage: false), findsOneWidget);

      await _tap(tester, _button('Challenge This Club'));
      await _setupAndReview(tester);
      await _tap(tester, _button('Send Challenge'));
      expect(find.text('Challenge Accepted!'), findsOneWidget);
      expect(find.text('Faisalabad Wolves'), findsWidgets);
    });

    testWidgets('Club Profile lists the Club Owner and Club Coach by name only when they are on record',
        (tester) async {
      final c = await _pumpOwner(tester, overrides: [
        clubDirectoryProvider.overrideWith((ref) async {
          final clubs = await ref.read(clubRepositoryProvider).otherClubs();
          return {
            for (final x in clubs)
              x.id: x.id != 'club_fw'
                  ? x
                  : ClubSummary(
                      id: x.id,
                      abbr: x.abbr,
                      name: x.name,
                      city: x.city,
                      level: x.level,
                      meta: x.meta,
                      established: x.established,
                      squadSize: x.squadSize,
                      formats: x.formats,
                      homeGround: x.homeGround,
                      captain: x.captain,
                      keyPlayers: x.keyPlayers,
                      recentForm: x.recentForm,
                      winRate: x.winRate,
                      wins: x.wins,
                      losses: x.losses,
                      played: x.played,
                      about: x.about,
                      color: x.color,
                      ownerName: 'Test Owner',
                    ),
          };
        }),
      ]);
      await _go(tester, c, Routes.clubProfile('club_fw'));
      await tester.scrollUntilVisible(find.text('Club Coach'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Test Owner'), findsOneWidget);
      expect(find.text('Not listed'), findsOneWidget, reason: 'coach missing: handled, not invented');
    });

    testWidgets('Create Availability Slot: inline validation, post, list on Find Opponent, remove', (tester) async {
      final c = await _pumpOwner(tester);
      await _go(tester, c, Routes.findMatch);
      await _tap(tester, find.textContaining('Create Availability Slot', findRichText: true));
      expect(_loc(c), Routes.createAvailabilitySlot);

      await _tap(tester, _button('Post Availability Slot'));
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();
      for (final e in ['Please select a format', 'Please select a city', 'Please pick a date', 'Please pick a time slot']) {
        await tester.scrollUntilVisible(find.text(e), 120, scrollable: find.byType(Scrollable).first);
        expect(find.text(e), findsOneWidget, reason: e);
      }
      await tester.fling(find.byType(Scrollable).first, const Offset(0, 3000), 4000);
      await tester.pumpAndSettle();

      await _tap(tester, find.text('Custom Overs'));
      await _tap(tester, _button('Post Availability Slot'));
      await _expectVisible(tester, 'Please enter the number of overs');
      await tester.enterText(find.byKey(const Key('slot.overs')), '15');
      await _tap(tester, find.byKey(const Key('slot.city')));
      await _tap(tester, find.text('Lahore').last);
      await _tap(tester, find.bySemanticsLabel('Date, not set'));
      await _tap(tester, find.bySemanticsLabel('Wed, 30 Sep 2026'));
      await _tap(tester, find.text('4pm – 6pm'));
      await _tap(tester, _button('Post Availability Slot'));

      expect(find.text('Availability slot posted!'), findsOneWidget);
      expect(_loc(c), Routes.findMatch);
      final slot = c.read(availabilitySlotsProvider).value!.single;
      expect((slot.format, slot.customOvers, slot.city, slot.date), (MatchFormat.custom, 15, 'Lahore', DateTime(2026, 9, 30)));
      expect(find.text('Your Open Slot'), findsOneWidget);
      expect(find.text('Custom · 15 overs'), findsOneWidget);

      await _clearToast(tester);
      await _tap(tester, find.text('Remove'));
      await _tap(tester, find.widgetWithText(CeButton, 'Remove Slot'));
      expect(find.text('Availability slot removed'), findsOneWidget);
      expect(find.text('Your Open Slot'), findsNothing);
    });
  });

  group('Challenges screens (Demo OFF)', () {
    testWidgets('Challenge stays pending: Sent section, "Challenge Sent" button, status screen', (tester) async {
      final c = await _pumpOwner(tester, demo: false);
      await _go(tester, c, Routes.challenges);
      await _tap(tester, _button('Challenge').first);
      await _setupAndReview(tester, ground: 'Model Town Ground');
      await _tap(tester, _button('Send Challenge'));
      expect(find.text('Challenge sent to Karachi Kings CC — awaiting their reply'), findsOneWidget);
      expect(_loc(c), Routes.myChallenges);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('AWAITING REPLY'), findsOneWidget);
      // The sent card carries what was proposed, and opens the profile (no resend).
      expect(find.text('Model Town Ground'), findsOneWidget);
      await _clearToast(tester);
      await _tap(tester, find.text('Karachi Kings CC'));
      final sent = c.read(challengesProvider).value!.last;
      expect(_loc(c), Routes.clubProfile('club_kk', challengeId: sent.id));
      expect(_button('Challenge Sent'), findsOneWidget);
      expect(_button('Challenge This Club'), findsNothing);

      await _go(tester, c, Routes.challenges);
      expect(_button('Challenge Sent'), findsOneWidget, reason: 'no duplicate challenge while pending');

      final ch = c.read(challengesProvider).value!.last;
      await _go(tester, c, Routes.challengeAccepted(ch.id));
      expect(find.text('Challenge Sent'), findsWidgets);
      expect(find.text('Challenge Accepted!'), findsNothing);
    });
  });

  group('Responsive', () {
    for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
      testWidgets('Phase 5 screens render without overflow at ${width.toInt()} px', (tester) async {
        final c = await _pumpOwner(tester, width: width);
        final ctrl = c.read(challengesProvider.notifier);
        final accepted = await ctrl.send('club_kk');
        c.read(demoModeProvider.notifier).set(false);
        final pending = await ctrl.send('club_iu');
        await ctrl.decline('ch_gc');
        await c.read(availabilitySlotsProvider.notifier).post(AvailabilitySlot(
              id: 'slot_x',
              format: MatchFormat.custom,
              customOvers: 25,
              city: 'Rahim Yar Khan',
              groundId: 'g_national',
              date: DateTime(2026, 10, 3),
              slot: TimeSlot.standard.last,
              notes: 'Looking for a competitive weekend friendly with a well-drilled side from the region.',
            ));
        for (final loc in [
          Routes.challenges,
          Routes.myChallenges,
          Routes.findMatch,
          Routes.createAvailabilitySlot,
          Routes.clubProfile('club_kk'),
          Routes.clubProfile('club_db'), // pending incoming: Decline / Accept
          Routes.clubProfile('club_gc', challengeId: 'ch_gc'), // declined: status
          Routes.clubProfile('club_iu', challengeId: pending.id), // sent, awaiting
          Routes.clubProfile('club_rr', fromFind: true), // Send Match Request
          Routes.challengeAccepted(accepted.id),
          Routes.challengeAccepted(pending.id),
          Routes.challengeAccepted('ch_gc'),
        ]) {
          await _go(tester, c, loc);
          final scrollable = find.byType(Scrollable).first;
          for (var i = 0; i < 10; i++) {
            await tester.drag(scrollable, const Offset(0, -400), warnIfMissed: false);
            await tester.pump();
          }
          expect(tester.takeException(), isNull, reason: '$loc @ $width');
        }
        // Accept confirmation on the club profile.
        await _go(tester, c, Routes.clubProfile('club_db'));
        await _tap(tester, _button('Accept'));
        expect(find.text('Accept Challenge?'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'accept confirmation @ $width');
        await _tap(tester, _button('Cancel'));

        // Setup sheet: details (calendar open), then the review summary.
        for (final (loc, confirm) in [
          (Routes.clubProfile('club_fw'), 'Send Challenge'),
          (Routes.clubProfile('club_rr', fromFind: true), 'Send Request'),
        ]) {
          await _go(tester, c, loc);
          final actions = find.byKey(const Key('clubProfile.actions'));
          expect(tester.getSize(actions).height, lessThan(120), reason: 'pinned bar stays compact @ $width');
          await _tap(tester, find.descendant(of: actions, matching: find.byType(CeButton)));
          expect(tester.takeException(), isNull, reason: 'setup sheet @ $width');
          await _pickFormat(tester, 'Test');
          await _pickGround(tester, 'Pindi Cricket Ground');
          await _tap(tester, find.byKey(const Key('challenge.date')));
          expect(tester.takeException(), isNull, reason: 'setup calendar @ $width');
          await _tap(tester, find.bySemanticsLabel(_day));
          await _tap(tester, _button('Review'));
          expect(_button(confirm), findsOneWidget);
          expect(tester.takeException(), isNull, reason: 'review @ $width');
          await _tap(tester, _button('Cancel'));
        }

        // Validation errors + open calendar on the slot form.
        await _go(tester, c, Routes.createAvailabilitySlot);
        await _tap(tester, find.text('Custom Overs'));
        await _tap(tester, _button('Post Availability Slot'));
        await _tap(tester, find.bySemanticsLabel('Date, not set'));
        expect(tester.takeException(), isNull, reason: 'slot form errors @ $width');
      });
    }
  });
}
