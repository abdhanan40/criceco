// M1 P5: scheduling and cancelling server matches (migration 17) from Match
// Management — propose, accept / decline, reschedule, cancel — through the
// real controller and repository on FakeMatchDb. No network, no database.
// The demo's booking-based flow keeps its own tests (booking_flow_test.dart).
import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/matches/club_matches_controller.dart';
import 'package:criceco/features/matches/screens/match_management_screen.dart';
import 'package:criceco/features/matches/widgets/match_schedule_sheet.dart';
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

/// 2026-11-20 11:00 in Pakistan.
final _now = DateTime.utc(2026, 11, 20, 6);

class _World {
  _World._(
    this.auth,
    this.clubDb,
    this.mdb,
    this.ownerA,
    this.ownerB,
    this.clubA,
    this.clubB,
    this.clubC,
  );

  final FakeAuth auth;
  final FakeClubDb clubDb;
  final FakeMatchDb mdb;
  final AuthUser ownerA, ownerB;
  final String clubA, clubB, clubC;

  static _World create() {
    final db = FakeDb();
    final auth = FakeAuth(db);
    final clubDb = FakeClubDb(db);
    final mdb = FakeMatchDb(auth, clubDb)..now = _now;
    final a = auth.addUser('a@example.com', 'Cricket@123');
    final b = auth.addUser('b@example.com', 'Cricket@123');
    final c = auth.addUser('c@example.com', 'Cricket@123');
    final w = _World._(
      auth,
      clubDb,
      mdb,
      a,
      b,
      mdb.addClub(a.id, 'Lahore Lions'),
      mdb.addClub(b.id, 'Karachi Kings', city: 'Karachi'),
      mdb.addClub(c.id, 'Ravi Riders'),
    );
    auth.current = a;
    return w;
  }

  /// A match row (club_a = the challenger). Times as UTC ISO strings.
  String addMatch({
    String? a,
    String? b,
    String status = 'pending',
    String? startsAt,
    String? venue,
    String? proposedAt,
    String? proposedVenue,
    String? proposedBy,
    int version = 0,
    String format = 't20',
  }) {
    final id = 'match-${mdb.matches.length + 1}';
    mdb.matches.add({
      'id': id,
      'challenge_id': null,
      'club_a_id': a ?? clubB,
      'club_b_id': b ?? clubA,
      'format': format,
      'custom_overs': null,
      'status': status,
      'starts_at': startsAt,
      'venue_name': venue,
      'city': null,
      'proposed_starts_at': proposedAt,
      'proposed_venue_name': proposedVenue,
      'proposed_city': null,
      'proposed_by_club_id': proposedBy,
      'proposal_version': version,
      'cancelled_at': null,
      'cancelled_by_club_id': null,
      'cancel_reason': null,
      'created_at': _now.toIso8601String(),
      'last_updated_at': _now.toIso8601String(),
    });
    return id;
  }

  Map<String, dynamic> row(String id) =>
      mdb.matches.firstWhere((m) => m['id'] == id);

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
      currentClubProvider.overrideWithValue(
        Club(
          id: clubA,
          name: 'Lahore Lions',
          city: 'Lahore',
          type: ClubType.corporate,
          code: 'ABC001',
        ),
      ),
    ];
  }

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: await overrides());
    addTearDown(c.dispose);
    await c.read(clubMatchesProvider.future);
    return c;
  }

  int calls(String fn) => mdb.calls.where((x) => x.fn == fn).length;
}

const _b23 = '2026-11-23T05:00:00.000Z'; // 23 Nov, 10:00 in Pakistan

void main() {
  group('MatchScheduleRules', () {
    test('proposal: a future time within a year, a venue, a short city', () {
      String? p(DateTime? t, {String venue = 'V', String city = ''}) =>
          MatchScheduleRules.proposal(
            startsAt: t,
            venue: venue,
            city: city,
            now: _now,
          );
      expect(p(null), contains('date'));
      expect(p(_now), contains('future'));
      expect(p(_now.add(const Duration(days: 366))), contains('within a year'));
      expect(
        p(_now.add(const Duration(days: 2)), venue: ' '),
        contains('venue'),
      );
      expect(
        p(_now.add(const Duration(days: 2)), venue: 'v' * 101),
        contains('100'),
      );
      expect(
        p(_now.add(const Duration(days: 2)), city: 'c' * 61),
        contains('60'),
      );
      expect(p(_now.add(const Duration(days: 2))), isNull);
    });

    test('reason: 1–200 characters; started matches are closed', () {
      expect(MatchScheduleRules.reason('  '), isNotNull);
      expect(MatchScheduleRules.reason('r' * 201), contains('200'));
      expect(MatchScheduleRules.reason('Rain'), isNull);
      final started = ClubMatch(
        id: 'm',
        opponentClubId: 'x',
        status: MatchStatus.confirmed,
        startsAt: _now.subtract(const Duration(hours: 1)),
      );
      expect(MatchScheduleRules.started(started, _now), isTrue);
      expect(MatchTab.history.includes(MatchStatus.cancelled), isTrue);
    });
  });

  group('ClubMatchesController on the server', () {
    test('propose: sent as UTC; the list shows our proposal (with the opponent\'s name)', () async {
      final w = _World.create();
      final id = w.addMatch();
      final c = await w.container();
      expect(c.read(matchesLiveProvider), isTrue);
      final start = DateTime.utc(2026, 11, 24, 9, 30);
      final m = await c
          .read(clubMatchesProvider.notifier)
          .proposeSchedule(
            id,
            startsAt: start,
            venueName: 'Gaddafi Stadium',
            city: 'Lahore',
          );
      expect(
        w.mdb.calls
            .where((x) => x.fn == 'propose_match_schedule')
            .single
            .params,
        {
          'p_match_id': id,
          'p_starts_at': '2026-11-24T09:30:00.000Z',
          'p_venue_name': 'Gaddafi Stadium',
          'p_city': 'Lahore',
        },
      );
      expect(m!.proposal!.byMe, isTrue);
      expect(m.proposal!.version, 1);
      expect(m.opponentName, 'Karachi Kings');
      expect(m.status, MatchStatus.pending);
    });

    test(
      'accept the other club\'s proposal → confirmed; decline → cleared',
      () async {
        final w = _World.create();
        final one = w.addMatch(
          proposedAt: _b23,
          proposedVenue: 'National Stadium',
          proposedBy: w.clubB,
          version: 1,
        );
        final two = w.addMatch(
          a: w.clubA,
          b: w.clubB,
          proposedAt: '2026-11-25T05:00:00.000Z',
          proposedVenue: 'V',
          proposedBy: w.clubB,
          version: 1,
        );
        final c = await w.container();
        final ctrl = c.read(clubMatchesProvider.notifier);
        final confirmed = await ctrl.respondToSchedule(
          one,
          proposalVersion: 1,
          accept: true,
        );
        expect(confirmed!.status, MatchStatus.confirmed);
        expect(confirmed.startsAt!.toUtc(), DateTime.parse(_b23));
        expect(confirmed.venueName, 'National Stadium');
        expect(confirmed.proposal, isNull);
        expect(MatchTab.scheduled.includes(confirmed.status), isTrue);
        final declined = await ctrl.respondToSchedule(
          two,
          proposalVersion: 1,
          accept: false,
        );
        expect(declined!.status, MatchStatus.pending);
        expect(declined.proposal, isNull);
      },
    );

    test(
      'a proposal changed meanwhile: refused readably, and the new one shows',
      () async {
        final w = _World.create();
        final id = w.addMatch(
          proposedAt: _b23,
          proposedVenue: 'National Stadium',
          proposedBy: w.clubB,
          version: 1,
        );
        final c = await w.container();
        w.row(id)
          ..['proposed_starts_at'] = '2026-11-26T05:00:00.000Z'
          ..['proposed_venue_name'] = 'Arbab Niaz'
          ..['proposal_version'] = 2;
        await expectLater(
          c
              .read(clubMatchesProvider.notifier)
              .respondToSchedule(id, proposalVersion: 1, accept: true),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              contains('changed the proposal'),
            ),
          ),
        );
        final now = c.read(clubMatchProvider(id))!;
        expect(now.proposal!.version, 2);
        expect(now.proposal!.venueName, 'Arbab Niaz');
        expect(now.status, MatchStatus.pending);
        expect(c.read(busyMatchesProvider), isEmpty);
      },
    );

    test('a schedule clash is refused readably', () async {
      final w = _World.create();
      final id = w.addMatch(
        proposedAt: _b23,
        proposedVenue: 'V',
        proposedBy: w.clubB,
        version: 1,
      );
      final c = await w.container();
      w.mdb.failNext = FakeMatchDb.err('23P01', 'match: schedule clash');
      await expectLater(
        c
            .read(clubMatchesProvider.notifier)
            .respondToSchedule(id, proposalVersion: 1, accept: true),
        throwsA(
          isA<MatchRuleException>().having(
            (e) => e.message,
            'message',
            contains('already has a confirmed match'),
          ),
        ),
      );
    });

    test('cancel: cancelled by us, with the reason; under History', () async {
      final w = _World.create();
      final id = w.addMatch(
        status: 'confirmed',
        startsAt: _b23,
        venue: 'Gaddafi Stadium',
      );
      final c = await w.container();
      final m = await c
          .read(clubMatchesProvider.notifier)
          .cancel(id, reason: 'Ground flooded');
      expect(m!.status, MatchStatus.cancelled);
      expect(m.cancellation!.byMe, isTrue);
      expect(m.cancellation!.reason, 'Ground flooded');
      expect(MatchTab.history.includes(m.status), isTrue);
      await expectLater(
        c
            .read(clubMatchesProvider.notifier)
            .proposeSchedule(
              id,
              startsAt: DateTime.utc(2026, 11, 28),
              venueName: 'V',
            ),
        throwsA(
          isA<MatchRuleException>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('repeated taps: one request at a time per match', () async {
      final w = _World.create();
      final id = w.addMatch();
      final c = await w.container();
      final ctrl = c.read(clubMatchesProvider.notifier);
      final first = ctrl.proposeSchedule(
        id,
        startsAt: DateTime.utc(2026, 11, 24, 5),
        venueName: 'V',
      );
      expect(c.read(busyMatchesProvider), contains(id));
      expect(
        await ctrl.proposeSchedule(
          id,
          startsAt: DateTime.utc(2026, 11, 24, 5),
          venueName: 'V',
        ),
        isNull,
      );
      expect(await ctrl.cancel(id, reason: 'x'), isNull);
      await first;
      expect(w.calls('propose_match_schedule'), 1);
      expect(w.calls('cancel_match'), 0);
      expect(c.read(busyMatchesProvider), isEmpty);
    });

    test('a match of other clubs: no permission', () async {
      final w = _World.create();
      final foreign = w.addMatch(a: w.clubB, b: w.clubC);
      final c = await w.container();
      expect(
        c.read(clubMatchProvider(foreign)),
        isNull,
        reason: 'not in our list',
      );
      await expectLater(
        c.read(clubMatchesProvider.notifier).cancel(foreign, reason: 'x'),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  group('Match Management on the server', () {
    Future<_World> pump(
      WidgetTester tester,
      MatchTab tab, {
      void Function(_World w)? before,
    }) async {
      final w = _World.create();
      before?.call(w);
      final overrides = await w.overrides();
      final router = GoRouter(
        initialLocation: Routes.matchManagement(tab),
        routes: [
          GoRoute(
            path: Routes.matchManagementPath,
            builder: (_, s) => MatchManagementScreen(
              tab: MatchManagementScreen.parseTab(s.uri.queryParameters['tab']),
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

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'Waiting: the other club\'s proposal → Review → Accept → confirmed under Scheduled',
      (tester) async {
        late String id;
        final w = await pump(
          tester,
          MatchTab.waiting,
          before: (w) => id = w.addMatch(
            proposedAt: _b23,
            proposedVenue: 'National Stadium',
            proposedBy: w.clubB,
            version: 1,
          ),
        );
        expect(find.text('vs Karachi Kings'), findsOneWidget);
        expect(find.text('REPLY NEEDED'), findsOneWidget);
        expect(find.text('Review Proposal'), findsOneWidget);
        expect(find.textContaining('Karachi Kings proposed'), findsOneWidget);
        expect(
          find.text('Set Up Match'),
          findsNothing,
          reason: 'no booking on the server',
        );

        await tester.tap(find.byKey(Key('match.card.$id')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('schedule.proposal')), findsOneWidget);
        await tapKey(tester, 'schedule.accept');
        expect(find.textContaining('Match confirmed for'), findsOneWidget);
        expect(w.row(id)['status'], 'confirmed');
        expect(
          find.text('vs Karachi Kings'),
          findsNothing,
          reason: 'left Waiting',
        );

        await tester.tap(find.textContaining('Scheduled'));
        await tester.pumpAndSettle();
        expect(find.text('vs Karachi Kings'), findsOneWidget);
        expect(find.text('CONFIRMED'), findsOneWidget);
        expect(find.textContaining('National Stadium'), findsOneWidget);
      },
    );

    testWidgets(
      'Waiting: propose a time (date, start time, venue) → awaiting their reply',
      (tester) async {
        late String id;
        final w = await pump(
          tester,
          MatchTab.waiting,
          before: (w) => id = w.addMatch(),
        );
        expect(find.text('TIME NEEDED'), findsOneWidget);
        await tester.tap(find.byKey(Key('match.card.$id')));
        await tester.pumpAndSettle();
        await tapKey(tester, 'schedule.propose');
        final send = find.byKey(const Key('schedule.send'));
        await tapKey(tester, 'schedule.date');
        await tester.ensureVisible(find.text('24').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('24').last);
        await tester.pumpAndSettle();
        await tapKey(tester, 'schedule.time');
        await tester.tap(find.text('OK')); // the picker's 10:00
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('schedule.venue')));
        await tester.enterText(
          find.byKey(const Key('schedule.venue')),
          'Gaddafi Stadium',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(send);
        await tester.pumpAndSettle();
        await tester.tap(send);
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Proposal sent to Karachi Kings'),
          findsOneWidget,
        );
        expect(w.calls('propose_match_schedule'), 1);
        expect(
          DateTime.parse(w.row(id)['proposed_starts_at'] as String),
          DateTime(2026, 11, 24, 10).toUtc(),
        );
        expect(w.row(id)['proposed_venue_name'], 'Gaddafi Stadium');
        expect(find.text('AWAITING REPLY'), findsOneWidget);
        expect(find.text('Waiting for Karachi Kings'), findsOneWidget);
      },
    );

    testWidgets(
      'Scheduled: cancel with a reason → under History with the reason',
      (tester) async {
        late String id;
        final w = await pump(
          tester,
          MatchTab.scheduled,
          before: (w) => id = w.addMatch(
            status: 'confirmed',
            startsAt: _b23,
            venue: 'Gaddafi Stadium',
          ),
        );
        expect(find.text('CONFIRMED'), findsOneWidget);
        await tester.tap(find.byKey(Key('match.card.$id')));
        await tester.pumpAndSettle();
        await tapKey(tester, 'schedule.cancel');
        final confirm = find.byKey(const Key('schedule.confirmCancel'));
        expect(
          tester.widget<CeButton>(confirm).onPressed,
          isNull,
          reason: 'a reason is required',
        );
        await tester.enterText(
          find.byKey(const Key('schedule.reason')),
          'Ground flooded',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(find.text('Match cancelled'), findsOneWidget);
        expect(w.row(id)['status'], 'cancelled');

        await tester.tap(find.textContaining('History'));
        await tester.pumpAndSettle();
        expect(find.text('CANCELLED'), findsOneWidget);
        expect(
          find.textContaining('Cancelled by your club: Ground flooded'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a refusal stays in the sheet, which shows the new proposal', (
      tester,
    ) async {
      late String id;
      final w = await pump(
        tester,
        MatchTab.waiting,
        before: (w) => id = w.addMatch(
          proposedAt: _b23,
          proposedVenue: 'National Stadium',
          proposedBy: w.clubB,
          version: 1,
        ),
      );
      await tester.tap(find.byKey(Key('match.card.$id')));
      await tester.pumpAndSettle();
      w.row(id)
        ..['proposed_venue_name'] = 'Arbab Niaz'
        ..['proposal_version'] = 2;
      await tapKey(tester, 'schedule.accept');
      expect(find.byKey(const Key('schedule.error')), findsOneWidget);
      expect(find.textContaining('changed the proposal'), findsOneWidget);
      expect(find.textContaining('Arbab Niaz'), findsWidgets);
      expect(w.row(id)['status'], 'pending');
    });
  });
}
