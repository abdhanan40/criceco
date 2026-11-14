import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_club_overlay.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// Stage 3A: [SupabaseClubRepository] against fake gateways that mimic
/// migration 5 — no network, no supabase_flutter.
void main() {
  late SharedPreferences prefs;
  late FakeDb db;
  late FakeAuth auth;
  late FakeClubDb clubs;
  late InMemoryClubRepository local;
  late SupabaseClubRepository repo;

  SupabaseClubRepository newRepo() => SupabaseClubRepository(
    auth: auth,
    db: clubs,
    overlay: LocalClubOverlay(prefs),
    local: local,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    clubs = FakeClubDb(db);
    local = InMemoryClubRepository(SeedData(DateTime(2026, 11, 9)));
    repo = newRepo();
  });

  /// A signed-in user — by default with User Profile Setup done.
  AuthUser signedIn(String email, {bool profileDone = true}) {
    final u = auth.addUser(email, 'Cricket@123');
    auth.current = u;
    if (profileDone) db.completeProfile(u.id);
    return u;
  }

  Future<Club> createFor(AuthUser u, {String name = 'Lahore Lions CC'}) =>
      repo.createClub(
        accountId: u.id,
        name: name,
        city: 'Lahore',
        type: ClubType.corporate,
        ownerName: 'Hamza Sheikh',
        homeGroundId: 'g_pindi',
      );

  String? roleOf(AuthUser u) => db.profiles[u.id]!['role'] as String?;

  group('ownClub', () {
    test('no club yet → null', () async {
      final u = signedIn('owner@example.com');
      expect(await repo.ownClub(u.id), isNull);
      expect(clubs.calls, ['fetchOwnClub']);
    });

    test('the own club, mapped, with this device\'s picture', () async {
      final u = signedIn('owner@example.com');
      final created = await createFor(u);
      await repo.updateClub(u.id, created.withLogo('/photos/club.jpg'));

      final c = (await newRepo().ownClub(u.id))!; // a fresh run
      expect(
        (c.id, c.name, c.code, c.type),
        (created.id, 'Lahore Lions CC', created.code, ClubType.corporate),
      );
      expect((c.ownerName, c.homeGroundId), ('Hamza Sheikh', 'g_pindi'));
      expect((c.hasLogo, c.logoPath), (true, '/photos/club.jpg'));
    });

    test(
      'another account or signed out → null, with no database call',
      () async {
        final u = signedIn('owner@example.com');
        await createFor(u);
        clubs.calls.clear();
        expect(await repo.ownClub('someone-else'), isNull);
        auth.current = null;
        expect(await repo.ownClub(u.id), isNull);
        expect(clubs.calls, isEmpty);
      },
    );

    test('offline → BackendUnavailableException', () async {
      final u = signedIn('owner@example.com');
      clubs.failNext = const GatewayNetworkException();
      await expectLater(
        repo.ownClub(u.id),
        throwsA(isA<BackendUnavailableException>()),
      );
    });
  });

  group('createClub', () {
    test(
      'one create_club call: the club, its code, role NULL → club_owner',
      () async {
        final u = signedIn('owner@example.com');
        expect(roleOf(u), isNull);
        final c = await createFor(u);
        expect(clubs.calls, ['createClub']);
        expect(clubs.lastCreateParams, {
          'p_name': 'Lahore Lions CC',
          'p_city': 'Lahore',
          'p_club_type': 'corporate',
          'p_owner_name': 'Hamza Sheikh',
          'p_address': null,
          'p_email': null,
          'p_home_ground_id': 'g_pindi',
        });
        expect(c.code, hasLength(6));
        expect(
          (c.name, c.type, c.ownerName, c.establishedYear),
          (
            'Lahore Lions CC',
            ClubType.corporate,
            'Hamza Sheikh',
            DateTime.now().year,
          ),
        );
        expect(c.hasLogo, isFalse);
        expect(roleOf(u), 'club_owner');
      },
    );

    test('player → club_owner; an existing club_owner stays', () async {
      final p = signedIn('player@example.com');
      db.profiles[p.id] = {...db.profiles[p.id]!, 'role': 'player'};
      await createFor(p);
      expect(roleOf(p), 'club_owner');

      final o = signedIn('owner@example.com');
      db.profiles[o.id] = {...db.profiles[o.id]!, 'role': 'club_owner'};
      await createFor(o);
      expect(roleOf(o), 'club_owner');
    });

    test('a retry returns the existing club: never a second one', () async {
      final u = signedIn('owner@example.com');
      final first = await createFor(u);
      final again = await createFor(u, name: 'Another Name');
      expect(
        (again.id, again.code, again.name),
        (first.id, first.code, 'Lahore Lions CC'),
      );
      expect(clubs.clubs, hasLength(1));
    });

    test('Profile Setup not done → its message; nothing stored', () async {
      final u = signedIn('new@example.com', profileDone: false);
      await expectLater(
        createFor(u),
        throwsA(
          isA<ProfileValidationException>().having(
            (e) => e.message,
            'message',
            'Please complete all profile details',
          ),
        ),
      );
      expect(clubs.clubs, isEmpty);
      expect(roleOf(u), isNull);
    });

    test('a missing club name → "Club name is required"', () async {
      final u = signedIn('owner@example.com');
      await expectLater(
        createFor(u, name: '   '),
        throwsA(
          isA<ProfileValidationException>().having(
            (e) => e.message,
            'message',
            'Club name is required',
          ),
        ),
      );
    });

    test('offline, an RLS refusal, a lost session: typed errors', () async {
      final u = signedIn('owner@example.com');
      for (final (failure, matcher) in [
        (
          const GatewayNetworkException() as GatewayException,
          isA<BackendUnavailableException>(),
        ),
        (
          const GatewayConstraintException(
            sqlState: '42501',
            message:
                'new row violates row-level security policy for table "clubs"',
          ),
          isA<PermissionDeniedException>(),
        ),
        (const GatewayPermissionException(), isA<NotSignedInException>()),
      ]) {
        clubs.failNext = failure;
        await expectLater(createFor(u), throwsA(matcher), reason: '$failure');
      }
      expect(clubs.clubs, isEmpty);
      await createFor(u); // and then it works
      expect(clubs.clubs, hasLength(1));
    });

    test('a join-code collision: the retry message (no automatic retry); then it works', () async {
      final first = signedIn('first@example.com');
      final taken = (await createFor(first)).code;
      final second = signedIn('second@example.com');
      clubs.nextCode = taken;
      await expectLater(
        createFor(second),
        throwsA(
          isA<ProfileValidationException>().having(
            (e) => e.message,
            'message',
            "Couldn't create the club — please try again",
          ),
        ),
      );
      expect(
        clubs.calls.where((c) => c == 'createClub'),
        hasLength(2),
        reason: 'not retried by itself',
      );
      final c = await createFor(second); // the user tries again
      expect(c.code, isNot(taken));
    });

    test('another account or signed out → refused before any call', () async {
      signedIn('owner@example.com');
      await expectLater(
        repo.createClub(
          accountId: 'someone-else',
          name: 'X Club',
          city: 'Lahore',
          type: ClubType.corporate,
        ),
        throwsA(isA<AccountMismatchException>()),
      );
      auth.current = null;
      await expectLater(
        repo.createClub(
          accountId: 'someone-else',
          name: 'X Club',
          city: 'Lahore',
          type: ClubType.corporate,
        ),
        throwsA(isA<NotSignedInException>()),
      );
      expect(clubs.calls, isEmpty);
    });
  });

  group('updateClub', () {
    test('writes only the changed columns', () async {
      final u = signedIn('owner@example.com');
      final c = await createFor(u);
      clubs.calls.clear();
      final saved = await repo.updateClub(
        u.id,
        c.copyWith(city: 'Karachi', establishedYear: 2001),
      );
      expect(clubs.calls, ['updateClub']);
      expect(clubs.lastUpdateColumns, {
        'city': 'Karachi',
        'established_year': 2001,
      });
      expect((saved.city, saved.establishedYear), ('Karachi', 2001));
      expect(clubs.clubs[u.id]!['city'], 'Karachi');
    });

    test(
      'a picture-only change makes no database call and survives a restart',
      () async {
        final u = signedIn('owner@example.com');
        final c = await createFor(u);
        clubs.calls.clear();
        final saved = await repo.updateClub(
          u.id,
          c.withLogo('/photos/new.jpg'),
        );
        expect(clubs.calls, isEmpty);
        expect((saved.hasLogo, saved.logoPath), (true, '/photos/new.jpg'));
        expect((await newRepo().ownClub(u.id))!.logoPath, '/photos/new.jpg');

        final removed = await repo.updateClub(u.id, saved.withLogo(null));
        expect(removed.logoPath, isNull);
        expect((await newRepo().ownClub(u.id))!.logoPath, isNull);
      },
    );

    test('a value rule refusal: its message; the club unchanged', () async {
      final u = signedIn('owner@example.com');
      final c = await createFor(u);
      await expectLater(
        repo.updateClub(u.id, c.copyWith(email: 'not-an-email')),
        throwsA(
          isA<ProfileValidationException>().having(
            (e) => e.message,
            'message',
            'Enter a valid email address',
          ),
        ),
      );
      expect(clubs.clubs[u.id]!['email'], isNull);
      // The next save compares with the unchanged club.
      await repo.updateClub(u.id, c.copyWith(city: 'Multan'));
      expect(clubs.lastUpdateColumns, {'city': 'Multan'});
    });

    test('no row updated (no longer this user\'s club) → PermissionDeniedException', () async {
      final u = signedIn('owner@example.com');
      final c = await createFor(u);
      clubs.clubs.remove(u.id); // e.g. removed on the server meanwhile
      await expectLater(
        repo.updateClub(u.id, c.copyWith(city: 'Karachi')),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test(
      'another club id → PermissionDeniedException, no update sent',
      () async {
        final u = signedIn('owner@example.com');
        final c = await createFor(u);
        clubs.calls.clear();
        const other = Club(
          id: 'club-x',
          name: 'X Club',
          city: 'Lahore',
          type: ClubType.corporate,
          code: 'XXXXXX',
        );
        await expectLater(
          repo.updateClub(u.id, other),
          throwsA(isA<PermissionDeniedException>()),
        );
        expect(clubs.calls, isEmpty);
        expect(clubs.clubs[u.id]!['name'], c.name);
      },
    );

    test('a fresh run reads the club first, then writes the change', () async {
      final u = signedIn('owner@example.com');
      final c = await createFor(u);
      clubs.calls.clear();
      await newRepo().updateClub(u.id, c.copyWith(city: 'Karachi'));
      expect(clubs.calls, ['fetchOwnClub', 'updateClub']);
      expect(clubs.lastUpdateColumns, {'city': 'Karachi'});
    });

    test('another account or signed out → refused before any call', () async {
      final u = signedIn('owner@example.com');
      final c = await createFor(u);
      clubs.calls.clear();
      await expectLater(
        repo.updateClub('someone-else', c),
        throwsA(isA<AccountMismatchException>()),
      );
      auth.current = null;
      await expectLater(
        repo.updateClub(u.id, c),
        throwsA(isA<NotSignedInException>()),
      );
      expect(clubs.calls, isEmpty);
    });
  });

  group('not in Supabase yet', () {
    test(
      'a new club starts with no members, requests, pool or activity',
      () async {
        final u = signedIn('owner@example.com');
        final c = await createFor(u);
        expect(await repo.members(c.id), isEmpty);
        expect(await repo.joinRequests(c.id), isEmpty);
        expect(await repo.playerPool(c.id), isEmpty);
        expect(await repo.memberActivity(c.id), isEmpty);
        // The demo club's seeded data is under another id and never shows.
        expect(await local.members(SeedData.ownClubId), isNotEmpty);
      },
    );

    test('members added stay under the real club id', () async {
      final u = signedIn('owner@example.com');
      final c = await createFor(u);
      await repo.addMember(
        c.id,
        name: 'Ali Raza',
        phone: '0300 1234567',
        role: MemberRole.player,
      );
      expect((await repo.members(c.id)).map((m) => m.name), ['Ali Raza']);
    });

    test('opponent clubs stay the demo data (D-3A-4)', () async {
      final others = await repo.otherClubs();
      expect(
        others.map((c) => c.id),
        (await local.otherClubs()).map((c) => c.id),
      );
      expect(await repo.clubSummary(others.first.id), isNotNull);
    });
  });

  group('join-by-code (Phase 3E)', () {
    test('no simulated lookup or request: "coming soon", no calls', () async {
      signedIn('player@example.com');
      await expectLater(
        repo.findClubByCode(SeedData.demoJoinCode),
        throwsA(isA<ClubJoinUnavailableException>()),
        reason: 'the demo code must not resolve in Supabase mode',
      );
      await expectLater(
        repo.requestToJoin(SeedData.demoJoinCode),
        throwsA(
          isA<ClubJoinUnavailableException>().having(
            (e) => e.message,
            'message',
            'Joining a club by code is coming soon',
          ),
        ),
      );
      expect(clubs.calls, isEmpty);
    });
  });
}
