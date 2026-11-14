import 'package:clock/clock.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/supabase/local_account_overlay.dart';
import 'package:criceco/data/supabase/profile_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_account_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// Stage 4.2 (migration 7): the account reads the server-granted roles
/// (`user_roles`) — informational only; routing still follows the player
/// profile and the club row.
void main() {
  group('ProfileRowMapper.grantedRolesFromRows', () {
    test('known roles; unknown ones (ground_owner, admin) are skipped', () {
      expect(
        ProfileRowMapper.grantedRolesFromRows([
          {'role': 'player'},
          {'role': 'club_owner'},
          {'role': 'admin'},
          {'role': 'ground_owner'},
          {'role': 'player'},
          {'role': null},
          {},
        ]),
        {UserRole.player, UserRole.clubOwner},
      );
      expect(ProfileRowMapper.grantedRolesFromRows(const []), isEmpty);
    });

    test('accountFromRows maps them; none → empty set', () {
      final profile = {'id': 'u1', 'full_name': 'Hamza Sheikh'};
      expect(
        ProfileRowMapper.accountFromRows(profile: profile).grantedRoles,
        isEmpty,
      );
      expect(
        ProfileRowMapper.accountFromRows(
          profile: profile,
          roles: const [
            {'role': 'club_owner'},
          ],
        ).grantedRoles,
        {UserRole.clubOwner},
      );
    });

    test(
      'a granted role alone does not create a Club Owner / Player profile',
      () {
        final a = ProfileRowMapper.accountFromRows(
          profile: {'id': 'u1', 'full_name': 'Hamza Sheikh'},
          roles: const [
            {'role': 'club_owner'},
            {'role': 'player'},
          ],
        );
        expect(a.hasClubOwnerProfile, isFalse); // the clubs row decides
        expect(a.ownedClubId, isNull);
        expect(a.playerProfile.isComplete, isFalse); // the player row decides
      },
    );

    test('copyWith keeps and replaces grantedRoles', () {
      const a = UserAccount(
        id: 'u1',
        fullName: 'A',
        contactMethod: ContactMethod.email,
        grantedRoles: {UserRole.player},
      );
      expect(a.copyWith(fullName: 'B').grantedRoles, {UserRole.player});
      expect(a.copyWith(grantedRoles: {UserRole.clubOwner}).grantedRoles, {
        UserRole.clubOwner,
      });
    });
  });

  group('SupabaseAccountRepository carries the roles', () {
    late FakeDb db;
    late FakeAuth auth;
    late FakeClubDb clubs;
    late SupabaseAccountRepository repo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      db = FakeDb();
      auth = FakeAuth(db);
      clubs = FakeClubDb(db);
      repo = SupabaseAccountRepository(
        auth: auth,
        db: db,
        overlay: LocalAccountOverlay(prefs),
        clock: Clock(() => DateTime(2026, 11, 10)),
      );
    });

    test('none → player → player + club_owner', () async {
      final a = await repo.signUp(
        fullName: 'Hamza Sheikh',
        method: ContactMethod.email,
        identifier: 'player@example.com',
        password: 'Cricket@2026',
      );
      expect(a.grantedRoles, isEmpty);

      final p = await repo.savePlayerProfile(
        a.id,
        const PlayerProfile(
          role: PlayerRole.batsman,
          battingStyle: BattingStyle.rightHanded,
        ),
      );
      expect(p.grantedRoles, {UserRole.player});

      db.completeProfile(a.id);
      await clubs.createClub({
        'p_name': 'Lahore Lions CC',
        'p_city': 'Lahore',
        'p_club_type': 'corporate',
      });
      final read = await repo.byId(a.id);
      expect(read!.grantedRoles, {UserRole.player, UserRole.clubOwner});
      expect(read.hasClubOwnerProfile, isTrue);
      // profiles.role behaves as before (player → club_owner on the club).
      expect(db.profiles[a.id]!['role'], 'club_owner');
    });
  });

  group('routing is unchanged by grantedRoles', () {
    SessionState signedIn(UserAccount a) =>
        SessionState(status: SessionStatus.signedIn, account: a);

    test('server roles without the rows infer no entry role', () {
      const a = UserAccount(
        id: 'u1',
        fullName: 'A',
        contactMethod: ContactMethod.email,
        profileComplete: true,
        grantedRoles: {UserRole.player, UserRole.clubOwner},
      );
      expect(inferEntryRole(signedIn(a)), isNull);
      expect(effectiveRole(UserRole.clubOwner, signedIn(a)), isNull);
    });
  });
}
