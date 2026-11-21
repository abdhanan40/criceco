// M1 P4: the Challenges screens on the server (Supabase + the memberships
// and matches switches) — opponent directory, sending, My Challenges,
// accept / decline — through the real controllers and repositories on
// FakeMatchDb. No network, no database. The demo flows keep their own tests
// (challenges_test.dart, production_demo_mode_test.dart).
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/config/demo_mode.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/challenges/challenges_controller.dart';
import 'package:criceco/features/challenges/screens/challenges_hub_screen.dart';
import 'package:criceco/features/challenges/widgets/challenge_widgets.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'match_fakes.dart';
import 'membership_fakes.dart';
import 'supabase_fakes.dart';

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

/// 2026-11-20 11:00 in Pakistan: "tomorrow" is the 21st.
final _now = DateTime.utc(2026, 11, 20, 6);

class _World {
  _World._(
    this.auth,
    this.clubDb,
    this.mdb,
    this.ownerA,
    this.ownerB,
    this.ownerC,
    this.clubA,
    this.clubB,
    this.clubC,
  );

  final FakeAuth auth;
  final FakeClubDb clubDb;
  final FakeMatchDb mdb;
  final AuthUser ownerA, ownerB, ownerC;
  final String clubA, clubB, clubC;

  static _World create() {
    final db = FakeDb();
    final auth = FakeAuth(db);
    final clubDb = FakeClubDb(db);
    final mdb = FakeMatchDb(auth, clubDb);
    final a = auth.addUser('a@example.com', 'Cricket@123');
    final b = auth.addUser('b@example.com', 'Cricket@123');
    final c = auth.addUser('c@example.com', 'Cricket@123');
    final w = _World._(
      auth,
      clubDb,
      mdb,
      a,
      b,
      c,
      mdb.addClub(a.id, 'Lahore Lions', shortName: 'LL'),
      mdb.addClub(b.id, 'Karachi Kings', city: 'Karachi', shortName: 'KK'),
      mdb.addClub(c.id, 'Ravi Riders'),
    );
    auth.current = a;
    return w;
  }

  Club get ownClub => Club(
    id: clubA,
    name: 'Lahore Lions',
    city: 'Lahore',
    type: ClubType.corporate,
    code: 'ABC001',
  );

  /// A challenge from [from] to club A (sent as that owner, then A is signed in again).
  String challengeFrom(
    AuthUser from,
    String fromClub, {
    String date = '2026-11-23',
    String? message,
  }) {
    auth.current = from;
    mdb.challenges.add({
      'id': 'ch-in-${mdb.challenges.length}',
      'from_club_id': fromClub,
      'to_club_id': clubA,
      'format': 'odi',
      'custom_overs': null,
      'proposed_date': date,
      'venue_name': 'National Stadium',
      'message': message,
      'status': 'pending',
      'expires_at': DateTime.parse('${date}T00:00:00+05:00')
          .toUtc()
          .toIso8601String(),
      'decided_at': null,
      'decided_by': null,
      'match_id': null,
      'created_at': _now.toIso8601String(),
    });
    auth.current = ownerA;
    return mdb.challenges.last['id'] as String;
  }

  Future<List<Override>> overrides() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      backendConfigProvider.overrideWithValue(_supabase),
      membershipsEnabledProvider.overrideWithValue(true),
      matchesEnabledProvider.overrideWithValue(true),
      clockProvider.overrideWithValue(Clock.fixed(_now)),
      authGatewayProvider.overrideWithValue(auth),
      clubGatewayProvider.overrideWithValue(clubDb),
      membershipGatewayProvider.overrideWithValue(
        FakeMembershipDb(clubDb.db, clubDb),
      ),
      matchGatewayProvider.overrideWithValue(mdb),
      currentAccountProvider.overrideWithValue(null),
      currentClubProvider.overrideWithValue(ownClub),
    ];
  }

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: await overrides());
    addTearDown(c.dispose);
    return c;
  }

  int calls(String fn) => mdb.calls.where((x) => x.fn == fn).length;
}

void main() {
  // ---------------------------------------------------------------------------
  // Controllers and providers
  // ---------------------------------------------------------------------------
  group('opponent directory (server)', () {
    test('real clubs, own club excluded, public fields only — no invented statistics', () async {
      final w = _World.create();
      final c = await w.container();
      expect(c.read(challengesLiveProvider), isTrue);
      final clubs = await c.read(
        opponentDirectoryProvider((search: '', city: '')).future,
      );
      expect(
        clubs.map((x) => x.name),
        unorderedEquals(['Karachi Kings', 'Ravi Riders']),
      );
      final kings = clubs.firstWhere((x) => x.id == w.clubB);
      expect(kings.summary, isNull);
      expect(kings.abbr, 'KK');
      expect(kings.meta, 'Karachi · Corporate Club');
      expect(kings.meta, isNot(contains('W')), reason: 'no wins / losses');
      expect(
        clubs.firstWhere((x) => x.id == w.clubC).abbr,
        'RR',
        reason: 'initials without a short name',
      );
    });

    test(
      'search and city filter are sent trimmed; empty filters as null',
      () async {
        final w = _World.create();
        final c = await w.container();
        final kings = await c.read(
          opponentDirectoryProvider((search: ' kings ', city: '')).future,
        );
        expect(kings.single.id, w.clubB);
        expect(w.mdb.calls.last.params, {'p_search': 'kings', 'p_city': null});
        final lahore = await c.read(
          opponentDirectoryProvider((search: '', city: ' Lahore ')).future,
        );
        expect(lahore.single.id, w.clubC);
        expect(w.mdb.calls.last.params, {'p_search': null, 'p_city': 'Lahore'});
        expect(
          await c.read(
            opponentDirectoryProvider((search: 'zzz', city: '')).future,
          ),
          isEmpty,
        );
      },
    );

    test('one request per query while it is shown', () async {
      final w = _World.create();
      final c = await w.container();
      const q = (search: 'kings', city: '');
      final sub = c.listen(opponentDirectoryProvider(q), (_, _) {});
      addTearDown(sub.close);
      await c.read(opponentDirectoryProvider(q).future);
      await c.read(opponentDirectoryProvider(q).future);
      expect(w.calls('match_club_directory'), 1);
    });

    test('a network failure is an error; retry loads', () async {
      final w = _World.create();
      final c = await w.container();
      const q = (search: '', city: '');
      w.mdb.failOn['match_club_directory'] = const GatewayNetworkException();
      final sub = c.listen(opponentDirectoryProvider(q), (_, _) {});
      addTearDown(sub.close);
      await _settled(() => c.read(opponentDirectoryProvider(q)).hasError);
      expect(
        c.read(opponentDirectoryProvider(q)).error,
        isA<BackendUnavailableException>(),
      );
      w.mdb.failOn.clear();
      c.invalidate(opponentDirectoryProvider(q));
      expect(await c.read(opponentDirectoryProvider(q).future), hasLength(2));
    });
  });

  group('sending a challenge (server)', () {
    test('valid: one pending challenge, the list reloaded with the opponent\'s name; no match created', () async {
      final w = _World.create();
      final c = await w.container();
      await c.read(challengesProvider.future);
      final sent = await c
          .read(challengesProvider.notifier)
          .send(
            w.clubB,
            format: MatchFormat.custom,
            customOvers: 15,
            groundName: ' Gaddafi Stadium ',
            proposedAt: DateTime(2026, 11, 23),
            message: ' Friendly? ',
          );
      expect(sent.status, ChallengeStatus.pending);
      expect(sent.opponentName, 'Karachi Kings');
      expect(w.mdb.calls.where((x) => x.fn == 'send_challenge').single.params, {
        'p_from_club_id': w.clubA,
        'p_to_club_id': w.clubB,
        'p_format': 'custom',
        'p_custom_overs': 15,
        'p_proposed_date': '2026-11-23',
        'p_venue_name': 'Gaddafi Stadium',
        'p_message': 'Friendly?',
      });
      expect(c.read(myChallengeSectionsProvider).sent.single.id, sent.id);
      expect(c.read(pendingSentClubIdsProvider), {w.clubB});
      expect(w.mdb.matches, isEmpty);
      expect(c.read(demoModeProvider), isFalse);
    });

    Future<void> blocked(
      ProviderContainer c,
      _World w,
      String fragment, {
      MatchFormat? format = MatchFormat.t20,
      int? overs,
      DateTime? date,
      String? venue = 'Venue',
      String? message,
    }) async {
      await expectLater(
        c
            .read(challengesProvider.notifier)
            .send(
              w.clubB,
              format: format,
              customOvers: overs,
              proposedAt: date ?? DateTime(2026, 11, 23),
              groundName: venue,
              message: message,
            ),
        throwsA(
          isA<ChallengeBlockedException>().having(
            (e) => e.message,
            'message',
            contains(fragment),
          ),
        ),
      );
    }

    test(
      'invalid details are refused before any call (Pakistan date rule)',
      () async {
        final w = _World.create();
        final c = await w.container();
        await c.read(challengesProvider.future);
        await blocked(
          c,
          w,
          'from tomorrow',
          date: DateTime(2026, 11, 20),
        ); // today in Pakistan
        await blocked(
          c,
          w,
          'from tomorrow',
          date: DateTime(2027, 11, 21),
        ); // more than a year ahead
        await blocked(c, w, 'match format', format: null);
        await blocked(c, w, '1 and 50 overs', format: MatchFormat.custom);
        await blocked(
          c,
          w,
          '1 and 50 overs',
          format: MatchFormat.custom,
          overs: 51,
        );
        await blocked(c, w, 'venue', venue: '  ');
        await blocked(c, w, '280', message: 'm' * 281);
        expect(w.calls('send_challenge'), 0);
        expect(
          ChallengeRules.firstDate(DateTime.utc(2026, 11, 20, 19)),
          DateTime(2026, 11, 22),
          reason: 'after 00:00 in Pakistan the next day counts',
        );
      },
    );

    test(
      'a second send while one is running is refused (one request)',
      () async {
        final w = _World.create();
        final c = await w.container();
        await c.read(challengesProvider.future);
        final ctrl = c.read(challengesProvider.notifier);
        final first = ctrl.send(
          w.clubB,
          format: MatchFormat.t20,
          groundName: 'V',
          proposedAt: DateTime(2026, 11, 23),
        );
        await expectLater(
          ctrl.send(
            w.clubB,
            format: MatchFormat.t20,
            groundName: 'V',
            proposedAt: DateTime(2026, 11, 23),
          ),
          throwsA(
            isA<ChallengeBlockedException>().having(
              (e) => e.message,
              'message',
              contains('already being sent'),
            ),
          ),
        );
        await first;
        expect(w.calls('send_challenge'), 1);
      },
    );

    test('the server\'s refusals arrive readable (a challenge already open the other way)', () async {
      final w = _World.create();
      w.challengeFrom(w.ownerB, w.clubB);
      final c = await w.container();
      await c.read(challengesProvider.future);
      await expectLater(
        c
            .read(challengesProvider.notifier)
            .send(
              w.clubB,
              format: MatchFormat.t20,
              groundName: 'V',
              proposedAt: DateTime(2026, 11, 24),
            ),
        throwsA(
          isA<MatchRuleException>().having(
            (e) => e.message,
            'message',
            contains('already an open challenge'),
          ),
        ),
      );
    });
  });

  group('My Challenges and answers (server)', () {
    test('incoming and outgoing lists with the server\'s fields', () async {
      final w = _World.create();
      w.challengeFrom(w.ownerB, w.clubB, message: 'Saturday?');
      final c = await w.container();
      await c
          .read(challengesProvider.notifier)
          .send(
            w.clubC,
            format: MatchFormat.t20,
            groundName: 'Minto Park',
            proposedAt: DateTime(2026, 11, 25),
          );
      final s = c.read(myChallengeSectionsProvider);
      final incoming = s.awaitingDecision.single;
      expect(incoming.opponentName, 'Karachi Kings');
      expect(incoming.opponentCity, 'Karachi');
      expect(incoming.message, 'Saturday?');
      expect(incoming.groundName, 'National Stadium');
      expect(incoming.format, MatchFormat.odi);
      expect(incoming.proposedAt, DateTime(2026, 11, 23));
      expect(incoming.expiresAt, isNotNull);
      expect(s.sent.single.opponentName, 'Ravi Riders');
      expect(c.read(challengesLiveProvider), isTrue);
    });

    test('loading error, then retry', () async {
      final w = _World.create();
      w.mdb.failOn['club_challenges'] = const GatewayNetworkException();
      final c = await w.container();
      final sub = c.listen(challengesProvider, (_, _) {});
      addTearDown(sub.close);
      await _settled(() => c.read(challengesProvider).hasError);
      expect(
        c.read(challengesProvider).error,
        isA<BackendUnavailableException>(),
      );
      w.mdb.failOn.clear();
      c.invalidate(challengesProvider);
      expect(await c.read(challengesProvider.future), isEmpty);
    });

    test('accept: the server-created match id; exactly one match; nothing created client-side', () async {
      final w = _World.create();
      final id = w.challengeFrom(w.ownerB, w.clubB);
      final c = await w.container();
      await c.read(challengesProvider.future);
      final accepted = await c.read(challengesProvider.notifier).accept(id);
      expect(accepted!.status, ChallengeStatus.accepted);
      expect(w.mdb.matches, hasLength(1));
      expect(accepted.matchId, w.mdb.matches.single['id']);
      expect(w.calls('respond_to_challenge'), 1);
      expect(c.read(myChallengeSectionsProvider).awaitingDecision, isEmpty);
      expect(
        c.read(myChallengeSectionsProvider).resolved.single.status,
        ChallengeStatus.accepted,
      );
      // The match is the server's pending match (P5 schedules it).
      final matches = await c.read(matchRepositoryProvider).clubMatches();
      expect(matches.single.id, accepted.matchId);
      expect(matches.single.status, MatchStatus.pending);
    });

    test('repeated taps: one request; the second does nothing', () async {
      final w = _World.create();
      final id = w.challengeFrom(w.ownerB, w.clubB);
      final c = await w.container();
      await c.read(challengesProvider.future);
      final ctrl = c.read(challengesProvider.notifier);
      final first = ctrl.accept(id);
      expect(c.read(respondingChallengesProvider), contains(id));
      expect(await ctrl.accept(id), isNull);
      expect(await ctrl.decline(id), isNull);
      await first;
      expect(c.read(respondingChallengesProvider), isEmpty);
      expect(w.calls('respond_to_challenge'), 1);
      expect(w.mdb.matches, hasLength(1));
    });

    test('decline: declined, no match', () async {
      final w = _World.create();
      final id = w.challengeFrom(w.ownerB, w.clubB);
      final c = await w.container();
      await c.read(challengesProvider.future);
      final declined = await c.read(challengesProvider.notifier).decline(id);
      expect(declined!.status, ChallengeStatus.declined);
      expect(w.mdb.matches, isEmpty);
    });

    test('expired: comes back expired, no match', () async {
      final w = _World.create();
      final id = w.challengeFrom(w.ownerB, w.clubB, date: '2026-11-21');
      final c = await w.container();
      await c.read(challengesProvider.future);
      w.mdb.now = DateTime.utc(
        2026,
        11,
        20,
        20,
      ); // past the start of the 21st in Pakistan
      final r = await c.read(challengesProvider.notifier).accept(id);
      expect(r!.status, ChallengeStatus.expired);
      expect(w.mdb.matches, isEmpty);
    });

    test(
      'already decided: refused readably, and the list shows the real status',
      () async {
        final w = _World.create();
        final id = w.challengeFrom(w.ownerB, w.clubB);
        final c = await w.container();
        await c.read(challengesProvider.future);
        // Decided elsewhere (another device) after this list was loaded.
        w.mdb.challenges.single
          ..['status'] = 'declined'
          ..['decided_at'] = _now.toIso8601String();
        await expectLater(
          c.read(challengesProvider.notifier).accept(id),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              contains('already been answered'),
            ),
          ),
        );
        expect(c.read(challengeProvider(id))!.status, ChallengeStatus.declined);
        expect(c.read(respondingChallengesProvider), isEmpty);
      },
    );

    test(
      'unauthorized: answering your own sent challenge is refused',
      () async {
        final w = _World.create();
        final c = await w.container();
        final sent = await c
            .read(challengesProvider.notifier)
            .send(
              w.clubB,
              format: MatchFormat.t20,
              groundName: 'V',
              proposedAt: DateTime(2026, 11, 23),
            );
        await expectLater(
          c.read(challengesProvider.notifier).accept(sent.id),
          throwsA(isA<PermissionDeniedException>()),
        );
        expect(w.mdb.matches, isEmpty);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Screens
  // ---------------------------------------------------------------------------
  group('Challenges screens (server)', () {
    Future<_World> pump(
      WidgetTester tester,
      String location, {
      void Function(_World w)? before,
    }) async {
      final w = _World.create();
      before?.call(w);
      final overrides = await w.overrides();
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: Routes.challenges,
            builder: (_, s) => ChallengesWorkspace(
              tab: ChallengesSection.parse(s.uri.queryParameters['tab']),
            ),
          ),
          GoRoute(
            path: Routes.clubHome,
            builder: (_, _) => const Scaffold(body: Text('club home')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp.router(
            theme: AppTheme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return w;
    }

    testWidgets(
      'Find Opponent: the directory, search with debounce, empty state; no demo listings',
      (tester) async {
        final w = await pump(tester, Routes.findMatch);
        expect(find.text('Karachi Kings'), findsOneWidget);
        expect(find.text('Ravi Riders'), findsOneWidget);
        expect(
          find.text('Lahore Lions'),
          findsNothing,
          reason: 'own club excluded',
        );
        expect(find.text('Karachi · Corporate Club'), findsOneWidget);
        expect(find.textContaining('W0'), findsNothing);
        expect(
          find.textContaining('Teams Looking for Opponents'),
          findsNothing,
        );
        expect(find.textContaining('Create Availability Slot'), findsNothing);

        final before = w.calls('match_club_directory');
        await tester.enterText(find.byKey(const Key('opponents.search')), 'k');
        await tester.enterText(
          find.byKey(const Key('opponents.search')),
          'kin',
        );
        await tester.enterText(
          find.byKey(const Key('opponents.search')),
          'kings',
        );
        await tester.pump(kOpponentSearchDebounce);
        await tester.pumpAndSettle();
        expect(
          w.calls('match_club_directory'),
          before + 1,
          reason: 'one request after typing settles',
        );
        expect(find.text('Karachi Kings'), findsOneWidget);
        expect(find.text('Ravi Riders'), findsNothing);

        await tester.enterText(
          find.byKey(const Key('opponents.search')),
          'zzz',
        );
        await tester.pump(kOpponentSearchDebounce);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('opponents.empty')), findsOneWidget);
        expect(find.text('No clubs found'), findsOneWidget);
      },
    );

    testWidgets('Find Opponent: an error with Retry', (tester) async {
      final w = await pump(
        tester,
        Routes.findMatch,
        before: (w) => w.mdb.failOn['match_club_directory'] =
            const GatewayNetworkException(),
      );
      expect(find.byKey(const Key('opponents.error')), findsOneWidget);
      w.mdb.failOn.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Karachi Kings'), findsOneWidget);
      expect(w.calls('match_club_directory'), greaterThanOrEqualTo(2));
    });

    testWidgets(
      'send from the Challenges tab: venue, custom overs, message, review, sent once',
      (tester) async {
        final w = await pump(tester, Routes.challenges);
        await tester.tap(
          find.descendant(
            of: find.byKey(Key('opponent.${w.clubB}')),
            matching: find.text('Challenge'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('challenge.venue')), findsOneWidget);
        expect(
          find.byKey(const Key('challenge.ground')),
          findsNothing,
          reason: 'no listed grounds on the server',
        );
        final review = find.byKey(const Key('challenge.review'));
        expect(
          tester.widget<CeButton>(review).onPressed,
          isNull,
          reason: 'Review waits for every detail',
        );

        // The sheet is taller than the test screen: bring each field into view.
        Future<void> enter(String key, String text) async {
          await tester.ensureVisible(find.byKey(Key(key)));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(Key(key)), text);
          await tester.pumpAndSettle();
        }

        await tester.tap(find.byKey(const Key('challenge.format.custom')));
        await tester.pumpAndSettle();
        await enter('challenge.overs', '15');
        await enter('challenge.venue', 'Gaddafi Stadium');
        await tester.ensureVisible(find.byKey(const Key('challenge.date')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('challenge.date')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('23').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('23').last);
        await tester.pumpAndSettle();
        await enter('challenge.message', 'Friendly?');
        await tester.ensureVisible(review);
        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(find.text('Custom · 15 overs'), findsOneWidget);
        expect(find.text('Gaddafi Stadium'), findsOneWidget);
        expect(find.text('Friendly?'), findsOneWidget);
        await tester.tap(find.byKey(const Key('challenge.send')));
        await tester.pumpAndSettle();

        expect(w.calls('send_challenge'), 1);
        expect(w.mdb.challenges.single['proposed_date'], '2026-11-23');
        expect(w.mdb.challenges.single['custom_overs'], 15);
        expect(w.mdb.matches, isEmpty);
        expect(find.textContaining('awaiting their reply'), findsOneWidget);
        // On My Challenges now, under Sent.
        expect(find.text('Sent'), findsOneWidget);
        expect(find.text('Karachi Kings'), findsOneWidget);
        expect(find.text('Challenge Sent'), findsNothing);
      },
    );

    testWidgets(
      'My Challenges: an incoming challenge with its details; Accept → one match',
      (tester) async {
        late String id;
        final w = await pump(
          tester,
          Routes.myChallenges,
          before: (w) =>
              id = w.challengeFrom(w.ownerB, w.clubB, message: 'Saturday?'),
        );
        expect(find.text('Karachi Kings'), findsOneWidget);
        expect(find.text('Saturday?'), findsOneWidget);
        expect(find.text('National Stadium'), findsOneWidget);
        expect(find.textContaining('Karachi'), findsWidgets);
        expect(find.text('Tap to accept or decline'), findsOneWidget);

        await tester.tap(find.byKey(Key('challenge.card.$id')));
        await tester.pumpAndSettle();
        expect(
          find.text('View Club Profile'),
          findsNothing,
          reason: 'no server club profiles',
        );
        expect(find.text('Venue'), findsOneWidget);
        await tester.tap(find.byKey(const Key('challenge.accept')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Accept Challenge'));
        await tester.pumpAndSettle();

        expect(w.mdb.matches, hasLength(1));
        expect(w.calls('respond_to_challenge'), 1);
        expect(find.textContaining('Challenge accepted'), findsOneWidget);
        expect(find.text('ACCEPTED'), findsOneWidget);
        expect(find.text('Tap to accept or decline'), findsNothing);
      },
    );

    testWidgets(
      'My Challenges: Decline; an already-answered challenge shows the server\'s reason',
      (tester) async {
        late String first, second;
        final w = await pump(
          tester,
          Routes.myChallenges,
          before: (w) {
            first = w.challengeFrom(w.ownerB, w.clubB);
            second = w.challengeFrom(w.ownerC, w.clubC, date: '2026-11-24');
          },
        );
        await tester.tap(find.byKey(Key('challenge.card.$first')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('challenge.decline')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Decline Challenge'));
        await tester.pumpAndSettle();
        expect(find.text('Challenge declined'), findsOneWidget);
        expect(find.text('DECLINED'), findsOneWidget);
        expect(w.mdb.matches, isEmpty);

        w.mdb.challenges.firstWhere((x) => x['id'] == second)
          ..['status'] = 'accepted'
          ..['decided_at'] = _now.toIso8601String();
        await tester.tap(find.byKey(Key('challenge.card.$second')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('challenge.accept')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Accept Challenge'));
        await tester.pumpAndSettle();
        expect(find.textContaining('already been answered'), findsOneWidget);
        expect(w.mdb.matches, isEmpty);
      },
    );
  });
}

/// Waits (real time, briefly) until [done] — for provider states that
/// change between retries.
Future<void> _settled(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
