// M1 P3: the matches data layer (migrations 17–19) — row mappers, error
// mapping, the Supabase repositories on FakeMatchDb, and which repository
// each build uses. No network, no database.
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/backend_modules.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_club_overlay.dart';
import 'package:criceco/data/supabase/match_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_availability_repository.dart';
import 'package:criceco/data/supabase/supabase_challenge_repository.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_match_repository.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'match_fakes.dart';
import 'supabase_fakes.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Row mappers
  // ---------------------------------------------------------------------------
  group('MatchRowMapper', () {
    test('Pakistan dates: the calendar date at UTC+5, across UTC midnight', () {
      expect(
        MatchRowMapper.karachiDate(DateTime.utc(2026, 11, 20, 18, 59)),
        DateTime(2026, 11, 20),
      );
      expect(
        MatchRowMapper.karachiDate(DateTime.utc(2026, 11, 20, 19, 0)),
        DateTime(2026, 11, 21),
      );
      expect(
        MatchRowMapper.karachiDate(DateTime.utc(2026, 12, 31, 19, 30)),
        DateTime(2027, 1, 1),
      );
    });

    test('dates are calendar dates: read and sent without any shift', () {
      expect(
        MatchRowMapper.optDate({'d': '2026-11-23'}, 'd'),
        DateTime(2026, 11, 23),
      );
      expect(
        MatchRowMapper.dateCode(DateTime(2026, 3, 5, 23, 59)),
        '2026-03-05',
      );
      expect(MatchRowMapper.optDate({'d': null}, 'd'), isNull);
      expect(
        () => MatchRowMapper.optDate({'d': '23/11/2026'}, 'd'),
        throwsA(isA<MatchRowFormatException>()),
      );
    });

    test(
      'timestamps: parsed as instants (UTC offset honoured), sent as UTC',
      () {
        final t = MatchRowMapper.time({'t': '2026-11-23T10:00:00+05:00'}, 't');
        expect(t.toUtc(), DateTime.utc(2026, 11, 23, 5));
        expect(
          MatchRowMapper.instantCode(DateTime.utc(2026, 11, 23, 5)),
          '2026-11-23T05:00:00.000Z',
        );
        expect(
          () => MatchRowMapper.time({'t': null}, 't'),
          throwsA(isA<MatchRowFormatException>()),
        );
        expect(
          () => MatchRowMapper.time({'t': 'soon'}, 't'),
          throwsA(isA<MatchRowFormatException>()),
        );
      },
    );

    test('unknown status / format / direction: refused, never guessed', () {
      expect(
        () => MatchRowMapper.matchStatus('postponed'),
        throwsA(isA<MatchRowFormatException>()),
      );
      expect(
        () => MatchRowMapper.format('t30'),
        throwsA(isA<MatchRowFormatException>()),
      );
      expect(
        () => MatchRowMapper.direction(null),
        throwsA(isA<MatchRowFormatException>()),
      );
      expect(
        () => MatchRowMapper.challengeStatus('withdrawn'),
        throwsA(isA<MatchRowFormatException>()),
      );
      expect(MatchRowMapper.matchStatus('cancelled'), MatchStatus.cancelled);
    });

    test('an unknown OPTIONAL value (availability reason) reads as none', () {
      expect(MatchRowMapper.reason('jury_duty'), isNull);
      expect(
        MatchRowMapper.reason('family_emergency'),
        AvailabilityReason.familyEmergency,
      );
      expect(MatchRowMapper.reasonCode(AvailabilityReason.restDay), 'rest_day');
    });

    test('club_matches row: one-sided, proposal and cancellation mapped', () {
      final m = MatchRowMapper.matchFromListRow({
        'match_id': 'm1',
        'challenge_id': 'c1',
        'opponent_club_id': 'club-b',
        'opponent_name': 'Karachi Kings',
        'challenged_by_me': true,
        'format': 'custom',
        'custom_overs': 15,
        'status': 'pending',
        'starts_at': null,
        'venue_name': null,
        'city': null,
        'proposed_starts_at': '2026-11-23T05:00:00Z',
        'proposed_venue_name': 'Gaddafi Stadium',
        'proposed_city': null,
        'proposed_by_me': false,
        'proposal_version': 2,
        'cancelled_at': null,
        'cancelled_by_me': null,
        'cancel_reason': null,
      });
      expect(m.id, 'm1');
      expect(m.opponentClubId, 'club-b');
      expect(m.opponentName, 'Karachi Kings');
      expect(m.challengedByMe, isTrue);
      expect(m.format, MatchFormat.custom);
      expect(m.customOvers, 15);
      expect(m.status, MatchStatus.pending);
      expect(m.startsAt, isNull);
      expect(m.proposal!.startsAt.toUtc(), DateTime.utc(2026, 11, 23, 5));
      expect(m.proposal!.byMe, isFalse);
      expect(m.proposal!.version, 2);
      expect(m.cancellation, isNull);
    });

    test('a cancelled row without its cancellation details is refused', () {
      expect(
        () => MatchRowMapper.matchFromListRow({
          'match_id': 'm1',
          'opponent_club_id': 'b',
          'challenged_by_me': true,
          'format': 't20',
          'status': 'cancelled',
          'proposal_version': 0,
        }),
        throwsA(isA<MatchRowFormatException>()),
      );
    });

    test(
      'matches table row: seen from the own club; a foreign row is refused',
      () {
        final row = {
          'id': 'm1',
          'club_a_id': 'a',
          'club_b_id': 'b',
          'format': 't20',
          'status': 'cancelled',
          'proposal_version': 3,
          'cancelled_at': '2026-11-21T10:00:00Z',
          'cancelled_by_club_id': 'b',
          'cancel_reason': 'Rain',
        };
        final fromB = MatchRowMapper.matchFromTableRow(row, ownClubId: 'b');
        expect(fromB.opponentClubId, 'a');
        expect(fromB.challengedByMe, isFalse);
        expect(fromB.status, MatchStatus.cancelled);
        expect(fromB.cancellation!.byMe, isTrue);
        expect(fromB.cancellation!.reason, 'Rain');
        expect(
          MatchRowMapper.matchFromTableRow(
            row,
            ownClubId: 'a',
          ).cancellation!.byMe,
          isFalse,
        );
        expect(
          () => MatchRowMapper.matchFromTableRow(row, ownClubId: 'z'),
          throwsA(isA<MatchRowFormatException>()),
        );
      },
    );

    test('challenge rows: list shape and table shape', () {
      final listed = MatchRowMapper.challengeFromListRow({
        'challenge_id': 'c1',
        'direction': 'received',
        'opponent_club_id': 'a',
        'opponent_name': 'Lahore Lions',
        'format': 't20',
        'custom_overs': 12, // ignored: not custom
        'proposed_date': '2026-11-23',
        'venue_name': 'Gaddafi Stadium',
        'message': null,
        'status': 'expired',
        'created_at': '2026-11-20T06:00:00Z',
        'expires_at': '2026-11-22T19:00:00Z',
        'decided_at': null,
        'match_id': null,
      });
      expect(listed.direction, ChallengeDirection.received);
      expect(listed.status, ChallengeStatus.expired);
      expect(listed.customOvers, isNull);
      expect(listed.proposedAt, DateTime(2026, 11, 23));
      expect(listed.groundName, 'Gaddafi Stadium');
      expect(listed.opponentName, 'Lahore Lions');

      final table = {
        'id': 'c2',
        'from_club_id': 'a',
        'to_club_id': 'b',
        'format': 'odi',
        'proposed_date': '2026-11-24',
        'venue_name': 'V',
        'status': 'accepted',
        'created_at': '2026-11-20T06:00:00Z',
        'expires_at': '2026-11-23T19:00:00Z',
        'decided_at': '2026-11-20T07:00:00Z',
        'match_id': 'm9',
      };
      final asA = MatchRowMapper.challengeFromTableRow(table, ownClubId: 'a');
      expect(asA.direction, ChallengeDirection.sent);
      expect(asA.opponentClubId, 'b');
      expect(asA.matchId, 'm9');
      expect(
        MatchRowMapper.challengeFromTableRow(table, ownClubId: 'b').direction,
        ChallengeDirection.received,
      );
    });

    test(
      'availability: since = updated_at; "available" carries no reason or date',
      () {
        final r = MatchRowMapper.availabilityFromRow({
          'status': 'injured',
          'reason': 'injury',
          'until_date': '2026-11-30',
          'notes': 'Hamstring',
          'updated_at': '2026-11-20T06:00:00Z',
        });
        expect(r.status, PlayerAvailability.injured);
        expect(r.reason, AvailabilityReason.injury);
        expect(r.untilDate, DateTime(2026, 11, 30));
        expect(r.notes, 'Hamstring');
        expect(r.since.toUtc(), DateTime.utc(2026, 11, 20, 6));

        final params = MatchRowMapper.availabilityParams(
          PlayerAvailabilityRecord(
            status: PlayerAvailability.available,
            since: DateTime(2026),
            reason: AvailabilityReason.travel,
            untilDate: DateTime(2026, 12, 1),
            notes: '  ',
          ),
        );
        expect(params, {
          'p_status': 'available',
          'p_reason': null,
          'p_until_date': null,
          'p_notes': null,
        });
        expect(
          params.containsKey('p_user_id'),
          isFalse,
          reason: 'never a user id',
        );
      },
    );

    test('lineup rows: grouped by club, players in position order; empty lineup row', () {
      final lineups = MatchRowMapper.lineupsFromRows('m1', [
        {
          'club_id': 'a',
          'lineup_name': 'XI',
          'saved_at': '2026-11-20T06:00:00Z',
          'member_id': 'p2',
          'selection': 'sub',
          'position': 2,
          'full_name': 'B',
          'member_role': 'player',
        },
        {
          'club_id': 'a',
          'lineup_name': 'XI',
          'saved_at': '2026-11-20T06:00:00Z',
          'member_id': 'p1',
          'selection': 'playing',
          'position': 1,
          'full_name': 'A',
          'member_role': 'owner',
        },
        {
          'club_id': 'b',
          'lineup_name': 'Empty',
          'saved_at': '2026-11-20T06:00:00Z',
          'member_id': null,
        },
      ]);
      expect(lineups, hasLength(2));
      expect(lineups.first.players.map((p) => p.memberId), ['p1', 'p2']);
      expect(lineups.first.players.first.role, MemberRole.owner);
      expect(lineups.last.players, isEmpty);
      expect(
        lineups.first.asLineup.members.first.selection,
        SelectionRole.playing,
      );
    });

    test('directory entry: public fields; a row without a name is refused', () {
      final e = MatchRowMapper.directoryEntry({
        'club_id': 'x',
        'name': 'Ravi Riders',
        'short_name': null,
        'city': 'Lahore',
        'club_type': 'college_university',
      });
      expect(e.type, ClubType.collegeUniversity);
      expect(e.shortName, isNull);
      expect(
        () => MatchRowMapper.directoryEntry({'club_id': 'x', 'city': 'Lahore'}),
        throwsA(isA<MatchRowFormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Error mapping
  // ---------------------------------------------------------------------------
  group('SupabaseErrorMapper: migrations 17–19', () {
    Exception map(String sqlState, String message) => SupabaseErrorMapper.map(
      GatewayConstraintException(sqlState: sqlState, message: message),
    );

    void rule(Exception e, String fragment) {
      expect(e, isA<MatchRuleException>());
      expect((e as MatchRuleException).message, contains(fragment));
    }

    test('challenge: refusals → what to do next', () {
      rule(
        map('23505', 'challenge: already pending'),
        'already an open challenge',
      );
      rule(map('P0001', 'challenge: too many pending'), '20 open challenges');
      rule(map('P0001', 'challenge: own club'), 'your own club');
      rule(map('22023', 'challenge: invalid date'), 'from tomorrow');
      rule(map('22023', 'challenge: invalid venue'), 'venue');
      rule(map('22023', 'challenge: invalid message'), '280');
      rule(map('P0001', 'challenge: not pending'), 'already been answered');
      rule(map('P0002', 'challenge: club not found'), 'club no longer exists');
      rule(map('P0002', 'challenge: not found'), 'challenge no longer exists');
      rule(map('22023', 'challenge: invalid'), 'Custom needs 1–50 overs');
    });

    test('match: refusals', () {
      rule(
        map('23P01', 'match: schedule clash'),
        'already has a confirmed match',
      );
      rule(map('P0001', 'match: proposal changed'), 'changed the proposal');
      rule(map('P0001', 'match: no proposal'), 'no open proposal');
      rule(map('P0001', 'match: not open'), 'closed');
      rule(map('P0001', 'match: already started'), 'already started');
      rule(map('22023', 'match: invalid time'), 'in the future');
      rule(map('22023', 'match: invalid reason'), 'reason');
      rule(map('22023', 'match: invalid city'), '60');
      rule(map('23514', 'match: invalid transition'), "aren't valid");
    });

    test('lineup: refusals (the availability rule included)', () {
      rule(
        map('23514', 'lineup: invalid squad'),
        '11 players and 4 substitutes',
      );
      rule(
        map('P0001', 'lineup: player unavailable'),
        'injured or unavailable',
      );
      rule(map('23514', 'lineup: player not in club'), 'active members');
      rule(map('22023', 'lineup: invalid captain'), 'captain');
      rule(map('22023', 'lineup: invalid vice-captain'), 'vice-captain');
      rule(map('P0001', 'lineup: match not confirmed'), 'confirmed matches');
      rule(map('P0001', 'lineup: match started'), 'locked');
      rule(map('P0001', 'lineup: team archived'), 'deleted');
      rule(map('22023', 'lineup: invalid'), "aren't valid");
    });

    test('availability: refusals', () {
      rule(map('22023', 'availability: invalid status'), 'status');
      rule(map('22023', 'availability: invalid notes'), '200');
      rule(map('22023', 'availability: invalid date'), 'from today');
      rule(map('22023', 'availability: invalid reason'), 'reason');
    });

    test('42501: "not authenticated" → sign in again; "not allowed" → no permission', () {
      for (final p in ['challenge', 'match', 'lineup', 'availability']) {
        expect(
          map('42501', '$p: not authenticated'),
          isA<NotSignedInException>(),
        );
        expect(
          map('42501', '$p: not allowed'),
          isA<PermissionDeniedException>(),
        );
      }
    });

    test(
      'an unknown reason gets a generic text — never the raw database message',
      () {
        final e = map(
          'P0001',
          'match: secret internal detail 42',
        ) as MatchRuleException;
        expect(e.message, isNot(contains('secret')));
        expect(e.message, contains("aren't valid"));
      },
    );

    test('existing prefixes are unchanged', () {
      expect(map('23505', 'team: duplicate name'), isA<TeamRuleException>());
      expect(
        map('P0001', 'club_join: already member'),
        isA<ClubMembershipException>(),
      );
      expect(
        map('P0001', 'ownership: not pending'),
        isA<OwnershipTransferException>(),
      );
      expect(
        map('23514', 'new row violates check constraint "clubs_email_check"'),
        isA<ProfileValidationException>(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Repositories on FakeMatchDb
  // ---------------------------------------------------------------------------
  group('Supabase match repositories', () {
    late FakeDb db;
    late FakeAuth auth;
    late FakeClubDb clubDb;
    late FakeMatchDb mdb;
    late SupabaseMatchRepository matches;
    late SupabaseChallengeRepository challenges;
    late SupabaseAvailabilityRepository availability;
    late AuthUser ownerA, ownerB, ownerC, player;
    late String clubA, clubB, clubC;
    final at = DateTime.utc(2026, 11, 20, 6);

    setUp(() {
      db = FakeDb();
      auth = FakeAuth(db);
      clubDb = FakeClubDb(db);
      mdb = FakeMatchDb(auth, clubDb);
      final lookup = OwnClubLookup(auth: auth, clubs: clubDb);
      matches = SupabaseMatchRepository(db: mdb, ownClub: lookup);
      challenges = SupabaseChallengeRepository(db: mdb, ownClub: lookup);
      availability = SupabaseAvailabilityRepository(db: mdb);
      ownerA = auth.addUser('a@example.com', 'Cricket@123');
      ownerB = auth.addUser('b@example.com', 'Cricket@123');
      ownerC = auth.addUser('c@example.com', 'Cricket@123');
      player = auth.addUser('p@example.com', 'Cricket@123');
      clubA = mdb.addClub(ownerA.id, 'Lahore Lions', shortName: 'LL');
      clubB = mdb.addClub(ownerB.id, 'Karachi Kings', city: 'Karachi');
      clubC = mdb.addClub(ownerC.id, 'Ravi Riders');
    });

    void signInAs(AuthUser u) => auth.current = u;

    Future<Challenge> challengeAtoB() {
      signInAs(ownerA);
      return challenges.send(
        opponentClubId: clubB,
        format: MatchFormat.t20,
        groundName: '  Gaddafi Stadium ',
        proposedAt: DateTime(2026, 11, 23),
        at: at,
        message: '  Friendly? ',
      );
    }

    test('send: own club resolved from the session; date sent as the calendar date', () async {
      final c = await challengeAtoB();
      final call = mdb.calls.last;
      expect(call.fn, 'send_challenge');
      expect(call.params, {
        'p_from_club_id': clubA,
        'p_to_club_id': clubB,
        'p_format': 't20',
        'p_custom_overs': null,
        'p_proposed_date': '2026-11-23',
        'p_venue_name': 'Gaddafi Stadium',
        'p_message': 'Friendly?',
      });
      expect(c.direction, ChallengeDirection.sent);
      expect(c.status, ChallengeStatus.pending);
      expect(c.opponentClubId, clubB);
      expect(c.proposedAt, DateTime(2026, 11, 23));
      expect(c.message, 'Friendly?');
    });

    test(
      'send: missing format / date / venue refused before any call',
      () async {
        signInAs(ownerA);
        await expectLater(
          challenges.send(
            opponentClubId: clubB,
            groundName: 'V',
            proposedAt: DateTime(2026, 11, 23),
            at: at,
          ),
          throwsA(isA<MatchRuleException>()),
        );
        await expectLater(
          challenges.send(
            opponentClubId: clubB,
            format: MatchFormat.t20,
            groundName: 'V',
            at: at,
          ),
          throwsA(isA<MatchRuleException>()),
        );
        await expectLater(
          challenges.send(
            opponentClubId: clubB,
            format: MatchFormat.t20,
            groundName: ' ',
            proposedAt: DateTime(2026, 11, 23),
            at: at,
          ),
          throwsA(isA<MatchRuleException>()),
        );
        expect(mdb.calls, isEmpty);
      },
    );

    test(
      'send: a player without a club → no permission; server refusals mapped',
      () async {
        signInAs(player);
        await expectLater(
          challenges.send(
            opponentClubId: clubB,
            format: MatchFormat.t20,
            groundName: 'V',
            proposedAt: DateTime(2026, 11, 23),
            at: at,
          ),
          throwsA(isA<PermissionDeniedException>()),
        );
        await challengeAtoB();
        signInAs(ownerB);
        await expectLater(
          challenges.send(
            opponentClubId: clubA,
            format: MatchFormat.odi,
            groundName: 'V',
            proposedAt: DateTime(2026, 11, 24),
            at: at,
          ),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              contains('already an open challenge'),
            ),
          ),
        );
        signInAs(ownerA);
        await expectLater(
          challenges.send(
            opponentClubId: clubC,
            format: MatchFormat.t20,
            groundName: 'V',
            proposedAt: DateTime(2026, 11, 20),
            at: at,
          ),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              contains('from tomorrow'),
            ),
          ),
        );
      },
    );

    test(
      'challenges(): sent and received, effective status, opponent names',
      () async {
        await challengeAtoB();
        signInAs(ownerB);
        final received = await challenges.challenges();
        expect(received.single.direction, ChallengeDirection.received);
        expect(received.single.opponentName, 'Lahore Lions');
        expect(mdb.calls.last.params, {'p_club_id': clubB});
        signInAs(player);
        expect(
          await challenges.challenges(),
          isEmpty,
          reason: 'no club: nothing, no call',
        );
        expect(mdb.calls.last.fn, 'club_challenges');
      },
    );

    test('accept: the server creates exactly ONE match and returns its id; nothing created client-side', () async {
      final sent = await challengeAtoB();
      signInAs(ownerB);
      final accepted = await challenges.accept(sent.id, at: at);
      expect(accepted.status, ChallengeStatus.accepted);
      expect(accepted.matchId, isNotNull);
      expect(mdb.matches, hasLength(1));
      expect(mdb.matches.single['id'], accepted.matchId);
      expect(
        mdb.calls.where((c) => c.fn == 'respond_to_challenge'),
        hasLength(1),
      );
      await expectLater(
        challenges.accept(sent.id, at: at),
        throwsA(
          isA<MatchRuleException>().having(
            (e) => e.message,
            'message',
            contains('already been answered'),
          ),
        ),
      );
      expect(
        mdb.matches,
        hasLength(1),
        reason: 'accepting twice never duplicates',
      );
      await expectLater(
        matches.createPendingMatch(opponentClubId: clubA),
        throwsA(isA<ModuleUnavailableException>()),
      );
      await expectLater(
        challenges.save(accepted),
        throwsA(isA<ModuleUnavailableException>()),
      );
      expect(mdb.matches, hasLength(1));
    });

    test('accept / decline: only the receiving owner; decline creates no match; expired comes back expired', () async {
      final sent = await challengeAtoB();
      await expectLater(
        challenges.accept(sent.id, at: at),
        throwsA(isA<PermissionDeniedException>()),
      );
      signInAs(ownerC);
      await expectLater(
        challenges.decline(sent.id, at: at),
        throwsA(isA<PermissionDeniedException>()),
      );
      signInAs(ownerB);
      final declined = await challenges.decline(sent.id, at: at);
      expect(declined.status, ChallengeStatus.declined);
      expect(mdb.matches, isEmpty);

      signInAs(ownerC);
      final second = await challenges.send(
        opponentClubId: clubB,
        format: MatchFormat.t10,
        groundName: 'V',
        proposedAt: DateTime(2026, 11, 22),
        at: at,
      );
      mdb.now = DateTime.utc(
        2026,
        11,
        21,
        20,
      ); // past its expiry (the start of the 22nd in Pakistan)
      signInAs(ownerB);
      final expired = await challenges.accept(second.id, at: at);
      expect(expired.status, ChallengeStatus.expired);
      expect(expired.matchId, isNull);
      expect(mdb.matches, isEmpty);
    });

    Future<ClubMatch> acceptedMatch() async {
      final sent = await challengeAtoB();
      signInAs(ownerB);
      final accepted = await challenges.accept(sent.id, at: at);
      return (await matches.clubMatches()).singleWhere(
        (m) => m.id == accepted.matchId,
      );
    }

    test('clubMatches: the pending match with A\'s proposal (the challenge date, 10:00 PKT)', () async {
      final m = await acceptedMatch(); // read as owner B
      expect(m.status, MatchStatus.pending);
      expect(m.challengedByMe, isFalse);
      expect(m.opponentName, 'Lahore Lions');
      expect(m.proposal!.byMe, isFalse);
      expect(m.proposal!.version, 1);
      expect(m.proposal!.venueName, 'Gaddafi Stadium');
      expect(m.proposal!.startsAt.toUtc(), DateTime.utc(2026, 11, 23, 5));
      signInAs(player);
      expect(await matches.clubMatches(), isEmpty);
    });

    test(
      'schedule: counter-proposal, stale version refused, accept confirms',
      () async {
        final m = await acceptedMatch();
        final start = DateTime.utc(2026, 11, 24, 9, 30);
        final proposed = await matches.proposeSchedule(
          m.id,
          startsAt: start,
          venueName: 'National Stadium',
          city: 'Karachi',
        );
        expect(mdb.calls.last.params, {
          'p_match_id': m.id,
          'p_starts_at': '2026-11-24T09:30:00.000Z',
          'p_venue_name': 'National Stadium',
          'p_city': 'Karachi',
        });
        expect(proposed.proposal!.byMe, isTrue);
        expect(proposed.proposal!.version, 2);
        await expectLater(
          matches.respondToSchedule(m.id, proposalVersion: 2, accept: true),
          throwsA(isA<PermissionDeniedException>()),
          reason: 'B can\'t accept B\'s own proposal',
        );
        signInAs(ownerA);
        await expectLater(
          matches.respondToSchedule(m.id, proposalVersion: 1, accept: true),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              contains('changed the proposal'),
            ),
          ),
        );
        final confirmed = await matches.respondToSchedule(
          m.id,
          proposalVersion: 2,
          accept: true,
        );
        expect(confirmed.status, MatchStatus.confirmed);
        expect(confirmed.startsAt!.toUtc(), start);
        expect(confirmed.venueName, 'National Stadium');
        expect(confirmed.proposal, isNull);
        expect(confirmed.challengedByMe, isTrue);
        expect(confirmed.opponentClubId, clubB);
      },
    );

    test('schedule: decline clears the proposal; outsiders refused', () async {
      final m = await acceptedMatch();
      signInAs(ownerC);
      await expectLater(
        matches.proposeSchedule(
          m.id,
          startsAt: DateTime.utc(2026, 11, 25),
          venueName: 'X',
        ),
        throwsA(isA<PermissionDeniedException>()),
      );
      signInAs(ownerB);
      final declined = await matches.respondToSchedule(
        m.id,
        proposalVersion: 1,
        accept: false,
      );
      expect(declined.status, MatchStatus.pending);
      expect(declined.proposal, isNull);
    });

    test('cancel: either owner, with a reason; then closed', () async {
      final m = await acceptedMatch();
      await expectLater(
        matches.cancelMatch(m.id, reason: ' '),
        throwsA(
          isA<MatchRuleException>().having(
            (e) => e.message,
            'message',
            contains('reason'),
          ),
        ),
      );
      final cancelled = await matches.cancelMatch(
        m.id,
        reason: 'Ground flooded',
      );
      expect(cancelled.status, MatchStatus.cancelled);
      expect(cancelled.cancellation!.byMe, isTrue);
      expect(cancelled.cancellation!.reason, 'Ground flooded');
      signInAs(ownerA);
      await expectLater(
        matches.proposeSchedule(
          m.id,
          startsAt: DateTime.utc(2026, 11, 25),
          venueName: 'X',
        ),
        throwsA(
          isA<MatchRuleException>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
      expect((await matches.clubMatches()).single.cancellation!.byMe, isFalse);
    });

    test(
      'lineups: save 11 + 4 (member ids), read own club only, refusals mapped',
      () async {
        final m = await acceptedMatch();
        await matches.respondToSchedule(
          m.id,
          proposalVersion: 1,
          accept: true,
        ); // B confirms A's proposal
        signInAs(ownerA);
        final ids = [
          for (var i = 0; i < 15; i++)
            mdb.addMember(clubA, 'user-a$i', 'Player A$i'),
        ];
        final lineup = Lineup(
          name: 'Lions XI',
          members: [
            for (final (i, id) in ids.indexed)
              TeamMember(
                playerId: id,
                selection: i < 11 ? SelectionRole.playing : SelectionRole.sub,
              ),
          ],
        );
        final saved = await matches.saveLineup(
          m.id,
          lineup,
          captainMemberId: ids[0],
          viceCaptainMemberId: ids[1],
        );
        final params = mdb.calls.last.params;
        expect(mdb.calls.last.fn, 'save_match_lineup');
        expect(params['p_players'], hasLength(15));
        expect((params['p_players'] as List).first, {
          'member_id': ids[0],
          'selection': 'playing',
        });
        expect(params['p_captain_member_id'], ids[0]);
        expect(params['p_vice_member_id'], ids[1]);
        expect(saved.clubId, clubA);
        expect(
          saved.players.map((p) => p.position),
          List.generate(15, (i) => i + 1),
        );

        final read = await matches.lineup(m.id);
        expect(read!.clubId, clubA);
        expect(read.players.first.name, 'Player A0');
        expect(read.captainMemberId, ids[0]);

        signInAs(ownerB);
        expect(
          await matches.lineup(m.id),
          isNull,
          reason: 'B never sees A\'s lineup',
        );
        signInAs(ownerC);
        await expectLater(
          matches.lineup(m.id),
          throwsA(isA<PermissionDeniedException>()),
        );

        signInAs(ownerA);
        final short = Lineup(
          name: 'Short',
          members: lineup.members.take(14).toList(),
        );
        await expectLater(
          matches.saveLineup(m.id, short),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              contains('11 players and 4'),
            ),
          ),
        );
      },
    );

    test('lineups: a pending match refuses lineups', () async {
      final m = await acceptedMatch();
      signInAs(ownerA);
      await expectLater(
        matches.saveLineup(m.id, const Lineup(name: 'XI', members: [])),
        throwsA(
          isA<MatchRuleException>().having(
            (e) => e.message,
            'message',
            contains('confirmed matches'),
          ),
        ),
      );
    });

    test(
      'availability: own record only, no user id sent; owner view; refusals',
      () async {
        signInAs(player);
        expect(await availability.mine(), isNull);
        final saved = await availability.setMine(
          PlayerAvailabilityRecord(
            status: PlayerAvailability.injured,
            since: DateTime(2026),
            reason: AvailabilityReason.injury,
            untilDate: DateTime(2026, 11, 30),
            notes: ' Hamstring ',
          ),
        );
        expect(mdb.calls.last.params, {
          'p_status': 'injured',
          'p_reason': 'injury',
          'p_until_date': '2026-11-30',
          'p_notes': 'Hamstring',
        });
        expect(saved.status, PlayerAvailability.injured);
        expect((await availability.mine())!.untilDate, DateTime(2026, 11, 30));

        mdb.addMember(clubA, player.id, 'Pat Player');
        signInAs(ownerA);
        final list = await availability.clubAvailability(clubA);
        final me = list.singleWhere((x) => x.userId == player.id);
        expect(me.locksSelection, isTrue);
        expect(me.status, PlayerAvailability.injured);
        expect(
          list.singleWhere((x) => x.role == MemberRole.owner).record,
          isNull,
          reason: 'no record: available',
        );

        signInAs(ownerB);
        await expectLater(
          availability.clubAvailability(clubA),
          throwsA(isA<PermissionDeniedException>()),
        );

        signInAs(player);
        await expectLater(
          availability.setMine(
            PlayerAvailabilityRecord(
              status: PlayerAvailability.limited,
              since: DateTime(2026),
              notes: 'n' * 201,
            ),
          ),
          throwsA(
            isA<MatchRuleException>().having(
              (e) => e.message,
              'message',
              contains('200'),
            ),
          ),
        );
      },
    );

    test('errors: offline, lost session, malformed rows', () async {
      signInAs(ownerA);
      mdb.failNext = const GatewayNetworkException();
      await expectLater(
        challenges.challenges(),
        throwsA(isA<BackendUnavailableException>()),
      );
      mdb.failNext = const GatewayPermissionException();
      await expectLater(
        matches.clubMatches(),
        throwsA(isA<NotSignedInException>()),
      );
      mdb.rowsNext = [
        {
          'match_id': 'm',
          'opponent_club_id': 'x',
          'challenged_by_me': true,
          'format': 't20',
          'status': 'postponed',
        },
      ];
      await expectLater(
        matches.clubMatches(),
        throwsA(isA<BackendOperationException>()),
      );
      mdb.rowNext = {'user_id': 'x', 'status': 'injured'}; // no updated_at
      signInAs(player);
      await expectLater(
        availability.mine(),
        throwsA(isA<BackendOperationException>()),
      );
      auth.current = null;
      await expectLater(
        matches.clubMatches(),
        throwsA(isA<NotSignedInException>()),
      );
    });

    test('no player matches, scorecards or stats on the server yet: empty, never invented', () async {
      signInAs(player);
      expect(await matches.playerMatches(), isEmpty);
      expect(await matches.scorecard('x'), isNull);
      expect(await matches.performance(), same(PerformanceSummary.empty));
      expect(await challenges.matchSeekers(), isEmpty);
      expect(await challenges.availabilitySlots(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Opponent directory through the club repository
  // ---------------------------------------------------------------------------
  group('SupabaseClubRepository.searchOpponents', () {
    late FakeAuth auth;
    late FakeClubDb clubDb;
    late FakeMatchDb mdb;
    late LocalClubOverlay overlay;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      overlay = LocalClubOverlay(await SharedPreferences.getInstance());
      final db = FakeDb();
      auth = FakeAuth(db);
      clubDb = FakeClubDb(db);
      mdb = FakeMatchDb(auth, clubDb);
    });

    SupabaseClubRepository repo({required bool withMatches}) =>
        SupabaseClubRepository(
          auth: auth,
          db: clubDb,
          overlay: overlay,
          local: InMemoryClubRepository(SeedData(DateTime(2026, 11, 20))),
          matches: withMatches ? mdb : null,
        );

    test(
      'with the matches gateway: other clubs, public fields, trimmed filters',
      () async {
        final a = auth.addUser('a@example.com', 'Cricket@123');
        final b = auth.addUser('b@example.com', 'Cricket@123');
        mdb.addClub(a.id, 'Lahore Lions');
        final kings = mdb.addClub(
          b.id,
          'Karachi Kings',
          city: 'Karachi',
          shortName: 'KK',
        );
        auth.current = a;
        final all = await repo(withMatches: true)
            .searchOpponents(search: '  ', city: ' ');
        expect(all.single.id, kings);
        expect(all.single.shortName, 'KK');
        expect(all.single.type, ClubType.corporate);
        expect(mdb.calls.last.params, {'p_search': null, 'p_city': null});
        await repo(withMatches: true)
            .searchOpponents(search: ' kings ', city: 'Karachi');
        expect(mdb.calls.last.params, {
          'p_search': 'kings',
          'p_city': 'Karachi',
        });
        expect(
          await repo(withMatches: true).otherClubs(),
          isEmpty,
          reason: 'no invented club profiles',
        );
      },
    );

    test('without it: nothing, and no call', () async {
      expect(
        await repo(withMatches: false).searchOpponents(search: 'kings'),
        isEmpty,
      );
      expect(mdb.calls, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Build switches and repository selection
  // ---------------------------------------------------------------------------
  group('CRICECO_MATCHES switch and providers', () {
    final supabase = BackendConfig.parse(
      backend: 'supabase',
      supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
      supabasePublishableKey: 'sb_publishable_test_0000000000000000',
    );

    test('the switch is off by default', () {
      expect(kMatchesBuild, isFalse);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(matchesEnabledProvider), isFalse);
    });

    test('BackendModules: matches, challenges and availability need Supabase + memberships + matches', () {
      const wanted = [
        BackendModule.matches,
        BackendModule.challenges,
        BackendModule.availability,
      ];
      bool all(BackendModules m) => wanted.every(m.has);
      bool none(BackendModules m) => !wanted.any(m.has);
      expect(
        all(BackendModules.of(supabase, memberships: true, matches: true)),
        isTrue,
      );
      expect(
        none(BackendModules.of(supabase, memberships: true, matches: false)),
        isTrue,
      );
      expect(
        none(BackendModules.of(supabase, memberships: false, matches: true)),
        isTrue,
      );
      expect(
        none(BackendModules.of(supabase, memberships: false, matches: false)),
        isTrue,
      );
      expect(
        all(
          BackendModules.of(
            const BackendConfig.memory(),
            memberships: false,
            matches: false,
          ),
        ),
        isTrue,
        reason: 'the demo: every module, on sample data',
      );
      // Grounds and payments stay off in Supabase whatever the switches.
      final on = BackendModules.of(supabase, memberships: true, matches: true);
      expect(
        on.has(BackendModule.grounds) || on.has(BackendModule.payments),
        isFalse,
      );
      expect(on.has(BackendModule.teams), isTrue);
    });

    ProviderContainer container({
      required BackendConfig config,
      required bool memberships,
      required bool matches,
    }) {
      SharedPreferences.setMockInitialValues({});
      final db = FakeDb();
      final auth = FakeAuth(db);
      final clubs = FakeClubDb(db);
      final c = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(config),
          membershipsEnabledProvider.overrideWithValue(memberships),
          matchesEnabledProvider.overrideWithValue(matches),
          authGatewayProvider.overrideWithValue(auth),
          clubGatewayProvider.overrideWithValue(clubs),
          // Reading the match gateway while the switch is off is a failure.
          matchGatewayProvider.overrideWith(
            (ref) => matches && memberships && config.isSupabase
                ? FakeMatchDb(auth, clubs)
                : throw StateError('match gateway used with the switch off'),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('Supabase + memberships + matches → the Supabase repositories', () {
      final c = container(config: supabase, memberships: true, matches: true);
      expect(c.read(matchesBackendLiveProvider), isTrue);
      expect(c.read(matchRepositoryProvider), isA<SupabaseMatchRepository>());
      expect(
        c.read(challengeRepositoryProvider),
        isA<SupabaseChallengeRepository>(),
      );
      expect(
        c.read(playerAvailabilityRepositoryProvider),
        isA<SupabaseAvailabilityRepository>(),
      );
    });

    for (final (memberships, matches) in [
      (true, false),
      (false, true),
      (false, false),
    ]) {
      test(
        'Supabase, memberships=$memberships, matches=$matches → empty / unavailable, the gateway never read',
        () async {
          final c = container(
            config: supabase,
            memberships: memberships,
            matches: matches,
          );
          expect(c.read(matchesBackendLiveProvider), isFalse);
          final m = c.read(matchRepositoryProvider);
          final ch = c.read(challengeRepositoryProvider);
          expect(m, isA<InMemoryMatchRepository>());
          expect(ch, isA<InMemoryChallengeRepository>());
          expect(
            c.read(playerAvailabilityRepositoryProvider),
            isA<UnavailablePlayerAvailabilityRepository>(),
          );
          expect(await m.clubMatches(), isEmpty);
          expect(await ch.challenges(), isEmpty);
          await expectLater(
            c
                .read(playerAvailabilityRepositoryProvider)
                .setMine(
                  PlayerAvailabilityRecord(
                    status: PlayerAvailability.injured,
                    since: DateTime(2026),
                  ),
                ),
            throwsA(isA<ModuleUnavailableException>()),
          );
        },
      );
    }

    test('memory mode (the demo) → the seeded in-memory repositories, whatever the switches', () async {
      final c = container(
        config: const BackendConfig.memory(),
        memberships: true,
        matches: true,
      );
      expect(c.read(matchesBackendLiveProvider), isFalse);
      expect(c.read(matchRepositoryProvider), isA<InMemoryMatchRepository>());
      expect(
        c.read(challengeRepositoryProvider),
        isA<InMemoryChallengeRepository>(),
      );
      expect(
        c.read(playerAvailabilityRepositoryProvider),
        isA<InMemoryPlayerAvailabilityRepository>(),
      );
      expect(
        await c.read(matchRepositoryProvider).clubMatches(),
        isNotEmpty,
        reason: 'the demo\'s sample matches',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // The demo: unchanged flows, plus the new operations in memory
  // ---------------------------------------------------------------------------
  group('demo repositories', () {
    final seed = SeedData(DateTime(2026, 11, 20));

    test(
      'in-memory accept creates exactly one match through the match repository',
      () async {
        final matches = InMemoryMatchRepository(seed);
        final before = (await matches.clubMatches()).length;
        final repo = InMemoryChallengeRepository(
          seed,
          createMatch: (c) => matches.createPendingMatch(
            opponentClubId: c.opponentClubId,
            format: c.format,
          ),
        );
        final received = await repo.save(
          Challenge(
            id: 'ch_test',
            opponentClubId: 'club_kk',
            direction: ChallengeDirection.received,
            status: ChallengeStatus.pending,
            createdAt: DateTime(2026, 11, 19),
            format: MatchFormat.t20,
            expiresAt: DateTime(2026, 11, 26),
          ),
        );
        final accepted = await repo.accept(
          received.id,
          at: DateTime(2026, 11, 20),
        );
        expect(accepted.status, ChallengeStatus.accepted);
        expect(accepted.matchId, isNotNull);
        final after = await matches.clubMatches();
        expect(after.length, before + 1);
        expect(after.where((m) => m.id == accepted.matchId), hasLength(1));
        await expectLater(
          repo.accept(received.id, at: DateTime(2026, 11, 20)),
          throwsA(isA<MatchRuleException>()),
        );
        expect(
          (await matches.clubMatches()).length,
          before + 1,
          reason: 'never a second match',
        );
        final declined = await repo.save(
          Challenge(
            id: 'ch_test2',
            opponentClubId: 'club_kk',
            direction: ChallengeDirection.received,
            status: ChallengeStatus.pending,
            createdAt: DateTime(2026, 11, 19),
            expiresAt: DateTime(2026, 11, 26),
          ),
        );
        expect(
          (await repo.decline(declined.id, at: DateTime(2026, 11, 20))).status,
          ChallengeStatus.declined,
        );
        expect((await matches.clubMatches()).length, before + 1);
      },
    );

    test(
      'in-memory schedule, cancel and lineup follow the same rules',
      () async {
        final matches = InMemoryMatchRepository(seed);
        final pending = (await matches.clubMatches()).firstWhere(
          (m) => m.status == MatchStatus.pending,
        );
        final start = DateTime.now().add(const Duration(days: 3));
        final proposed = await matches.proposeSchedule(
          pending.id,
          startsAt: start,
          venueName: ' Gaddafi  Stadium ',
        );
        expect(proposed.proposal!.venueName, 'Gaddafi Stadium');
        await expectLater(
          matches.respondToSchedule(
            pending.id,
            proposalVersion: 99,
            accept: true,
          ),
          throwsA(isA<MatchRuleException>()),
        );
        final confirmed = await matches.respondToSchedule(
          pending.id,
          proposalVersion: proposed.proposal!.version,
          accept: true,
        );
        expect(confirmed.status, MatchStatus.confirmed);
        expect(confirmed.startsAt, start);
        await expectLater(
          matches.saveLineup(pending.id, const Lineup(name: 'XI', members: [])),
          throwsA(isA<MatchRuleException>()),
        );
        final cancelled = await matches.cancelMatch(pending.id, reason: 'Rain');
        expect(cancelled.status, MatchStatus.cancelled);
        expect(
          MatchTab.values.any((t) => t.includes(MatchStatus.cancelled)),
          isFalse,
          reason: 'no tab for it until P5',
        );
      },
    );

    test('in-memory availability keeps the signed-in person\'s record; "available" clears reason and date', () async {
      final repo = InMemoryPlayerAvailabilityRepository();
      expect(await repo.mine(), isNull);
      final saved = await repo.setMine(
        PlayerAvailabilityRecord(
          status: PlayerAvailability.available,
          since: DateTime(2026),
          reason: AvailabilityReason.work,
          untilDate: DateTime(2026, 12),
        ),
      );
      expect(saved.reason, isNull);
      expect(saved.untilDate, isNull);
      expect(await repo.mine(), same(saved));
    });

    test('in-memory directory: the demo clubs as public entries', () async {
      final clubs = InMemoryClubRepository(seed);
      final entries = await clubs.searchOpponents();
      expect(entries, isNotEmpty);
      expect(entries.length, (await clubs.otherClubs()).length.clamp(0, 50));
      final first = entries.first;
      expect(
        await clubs.searchOpponents(search: first.name.toUpperCase()),
        contains(predicate<ClubDirectoryEntry>((e) => e.id == first.id)),
      );
    });
  });
}
