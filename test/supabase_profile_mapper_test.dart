import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/supabase/profile_row_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Supabase row mapping (Phase 1): pure conversions only, no backend.
void main() {
  const id = '00000000-0000-4000-8000-000000000001';

  Map<String, dynamic> profileRow({
    String? fullName,
    String? phone,
    String? role,
    bool? completed = false,
    String? dateOfBirth,
    bool sameAsCurrent = true,
  }) => {
    'id': id,
    'created_at': '2026-10-28T10:00:00+00:00',
    'full_name': fullName,
    'phone': phone,
    'role': role,
    'profile_completed': completed,
    'date_of_birth': dateOfBirth,
    'permanent_same_as_current': sameAsCurrent,
    'last_updated_at': '2026-10-28T10:00:00+00:00',
  };

  Map<String, dynamic> address(String city, String area, String address) => {
    'id': 'x',
    'user_id': id,
    'city': city,
    'area': area,
    'address': address,
  };

  group('database codes', () {
    test('match the CHECK constraints exactly', () {
      expect(PlayerRole.values.map(ProfileRowMapper.playerRoleCode).toSet(), {
        'batsman',
        'bowler',
        'all_rounder',
      });
      expect(
        BattingStyle.values.map(ProfileRowMapper.battingStyleCode).toSet(),
        {'right_handed', 'left_handed'},
      );
      expect(
        BowlingStyle.values.map(ProfileRowMapper.bowlingStyleCode).toSet(),
        {
          'right_arm_fast',
          'right_arm_medium',
          'right_arm_off_spin',
          'right_arm_leg_spin',
          'left_arm_fast',
          'left_arm_medium',
          'left_arm_orthodox',
          'left_arm_chinaman',
        },
      );
      expect(UserRole.values.map(ProfileRowMapper.userRoleCode).toSet(), {
        'player',
        'club_owner',
      });
    });

    test('round-trip for every value', () {
      for (final r in PlayerRole.values) {
        expect(
          ProfileRowMapper.playerRoleFromCode(
            ProfileRowMapper.playerRoleCode(r),
          ),
          r,
        );
      }
      for (final s in BattingStyle.values) {
        expect(
          ProfileRowMapper.battingStyleFromCode(
            ProfileRowMapper.battingStyleCode(s),
          ),
          s,
        );
      }
      for (final s in BowlingStyle.values) {
        expect(
          ProfileRowMapper.bowlingStyleFromCode(
            ProfileRowMapper.bowlingStyleCode(s),
          ),
          s,
        );
      }
      for (final r in UserRole.values) {
        expect(
          ProfileRowMapper.userRoleFromCode(ProfileRowMapper.userRoleCode(r)),
          r,
        );
      }
      expect(ProfileRowMapper.userRoleFromCode(null), isNull);
    });

    test('unknown codes fail loudly', () {
      expect(
        () => ProfileRowMapper.playerRoleFromCode('wicketkeeper'),
        throwsFormatException,
      );
      expect(
        () => ProfileRowMapper.battingStyleFromCode('Right-hand'),
        throwsFormatException,
      );
      expect(
        () => ProfileRowMapper.bowlingStyleFromCode('spin'),
        throwsFormatException,
      );
      expect(
        () => ProfileRowMapper.userRoleFromCode('admin'),
        throwsFormatException,
      );
    });
  });

  group('rows → account', () {
    test(
      'a fresh sign-up row (only defaults) is an empty, incomplete account',
      () {
        final a = ProfileRowMapper.accountFromRows(
          profile: profileRow(),
          email: 'new@example.com',
        );
        expect(a.id, id);
        expect(a.fullName, '');
        expect(a.contactMethod, ContactMethod.email);
        expect(a.email, 'new@example.com');
        expect(a.phone, isNull);
        expect(a.dateOfBirth, isNull);
        expect(a.city, isNull);
        expect(a.isPermanentSameAsCurrent, isTrue);
        expect(a.playerProfile.role, isNull);
        expect(a.profileComplete, isFalse);
        expect(a.hasPhoto, isFalse); // D3: photo is device-only
      },
    );

    test('a completed row maps every field; City is the current city (D4)', () {
      final a = ProfileRowMapper.accountFromRows(
        profile: profileRow(
          fullName: 'Test User A',
          phone: '+923001234567',
          role: 'player',
          completed: true,
          dateOfBirth: '2000-05-01',
          sameAsCurrent: false,
        ),
        currentAddress: address('Lahore', 'Gulberg', 'House 1'),
        permanentAddress: address('Multan', 'Cantt', 'Street 9'),
        playerProfile: {
          'user_id': id,
          'player_role': 'all_rounder',
          'batting_style': 'left_handed',
          'bowling_style': 'left_arm_chinaman',
          'is_wicketkeeper': false,
        },
        email: 'a@example.com',
      );
      expect(a.fullName, 'Test User A');
      expect(a.phone, '03001234567');
      expect(a.dateOfBirth, DateTime(2000, 5, 1));
      expect(a.city, 'Lahore');
      expect(
        [a.currentCity, a.currentArea, a.currentAddress],
        ['Lahore', 'Gulberg', 'House 1'],
      );
      expect(
        [a.permanentCity, a.permanentArea, a.permanentAddress],
        ['Multan', 'Cantt', 'Street 9'],
      );
      expect(a.isPermanentSameAsCurrent, isFalse);
      expect(a.playerProfile.role, PlayerRole.allRounder);
      expect(a.playerProfile.battingStyle, BattingStyle.leftHanded);
      expect(a.playerProfile.bowlingStyle, BowlingStyle.leftArmChinaman);
      expect(a.playerProfile.isComplete, isTrue);
      expect(a.profileComplete, isTrue);
    });

    test('D7: completed legacy rows without date of birth or addresses are incomplete', () {
      final noDob = ProfileRowMapper.accountFromRows(
        profile: profileRow(
          fullName: 'Owner One',
          phone: '03001234567',
          role: 'club_owner',
          completed: true,
        ),
      );
      expect(noDob.profileComplete, isFalse);

      final noAddresses = ProfileRowMapper.accountFromRows(
        profile: profileRow(
          fullName: 'Owner Two',
          completed: true,
          dateOfBirth: '1990-01-01',
        ),
      );
      expect(noAddresses.profileComplete, isFalse);

      final onlyCurrent = ProfileRowMapper.accountFromRows(
        profile: profileRow(
          fullName: 'Owner Three',
          completed: true,
          dateOfBirth: '1990-01-01',
        ),
        currentAddress: address('Karachi', 'Clifton', 'Flat 4'),
      );
      expect(onlyCurrent.profileComplete, isFalse);
    });

    test('legacy shapes: no name and NULL profile_completed', () {
      final a = ProfileRowMapper.accountFromRows(
        profile: profileRow(phone: '03451234567', completed: null),
      );
      expect(a.fullName, '');
      expect(a.profileComplete, isFalse);
    });

    test('profiles.role is not mapped onto the account yet (pending D6)', () {
      for (final role in [null, 'player', 'club_owner']) {
        final a = ProfileRowMapper.accountFromRows(
          profile: profileRow(fullName: 'Legacy', role: role),
        );
        expect(a.hasClubOwnerProfile, isFalse, reason: 'role $role');
        expect(a.ownedClubId, isNull, reason: 'role $role');
        expect(a.playerProfile.role, isNull, reason: 'role $role');
      }
    });

    test('a completed profile without a player profile is still complete', () {
      final a = ProfileRowMapper.accountFromRows(
        profile: profileRow(
          fullName: 'Owner',
          phone: '+923001234567',
          completed: true,
          dateOfBirth: '1990-01-01',
        ),
        currentAddress: address('Karachi', 'Clifton', 'Flat 4'),
        permanentAddress: address('Karachi', 'Clifton', 'Flat 4'),
      );
      expect(a.profileComplete, isTrue);
      expect(a.playerProfile.role, isNull);
      expect(a.playerProfile.isComplete, isFalse);
    });

    test('a missing permanent_same_as_current defaults to true', () {
      final row = profileRow()..remove('permanent_same_as_current');
      expect(
        ProfileRowMapper.accountFromRows(profile: row).isPermanentSameAsCurrent,
        isTrue,
      );
    });

    test('same as current read back: the permanent row is the stored copy', () {
      final a = ProfileRowMapper.accountFromRows(
        profile: profileRow(
          fullName: 'Test User B',
          phone: '+923331112223',
          completed: true,
          dateOfBirth: '1999-01-01',
          sameAsCurrent: true,
        ),
        currentAddress: address('Karachi', 'Clifton', 'Flat 4, Block 5'),
        permanentAddress: address('Karachi', 'Clifton', 'Flat 4, Block 5'),
      );
      expect(a.isPermanentSameAsCurrent, isTrue);
      expect(
        [a.permanentCity, a.permanentArea, a.permanentAddress],
        [a.currentCity, a.currentArea, a.currentAddress],
      );
      // Saving it again sends "same as current", not a second address.
      final p = ProfileRowMapper.saveProfileSetupParams(a);
      expect(p['p_permanent_same_as_current'], isTrue);
      expect(p['p_permanent_city'], isNull);
      expect(p['p_phone'], '03331112223');
    });

    test('phones: legacy spellings and +92 become 03XXXXXXXXX; anything else is kept', () {
      String? phoneOf(String p) =>
          ProfileRowMapper.accountFromRows(profile: profileRow(phone: p)).phone;
      expect(phoneOf('0312 9020000'), '03129020000');
      expect(phoneOf('0333-1112223'), '03331112223');
      expect(phoneOf('+923331112223'), '03331112223');
      expect(phoneOf('923001234567'), '03001234567');
      expect(phoneOf('+92 300 1234567'), '03001234567');
      expect(phoneOf('not a phone'), 'not a phone');
    });

    test('no email means a phone account', () {
      final a = ProfileRowMapper.accountFromRows(
        profile: profileRow(phone: '03001234567'),
      );
      expect(a.contactMethod, ContactMethod.phone);
      expect(a.email, isNull);
    });

    test('a blank email also means a phone account', () {
      final a = ProfileRowMapper.accountFromRows(
        profile: profileRow(phone: '03001234567'),
        email: '   ',
      );
      expect(a.contactMethod, ContactMethod.phone);
      expect(a.email, isNull);
    });
  });

  group('account → save_profile_setup arguments', () {
    const base = UserAccount(
      id: id,
      fullName: 'Test User B',
      contactMethod: ContactMethod.email,
    );

    test('same as current: permanent arguments are left to the function', () {
      final p = ProfileRowMapper.saveProfileSetupParams(
        base.copyWith(
          phone: '0333 1112223',
          dateOfBirth: DateTime(1999, 1, 9),
          currentCity: 'Karachi',
          currentArea: 'Clifton',
          currentAddress: 'Flat 4, Block 5',
          isPermanentSameAsCurrent: true,
        ),
      );
      expect(p, {
        'p_full_name': 'Test User B',
        'p_phone': '0333 1112223',
        'p_date_of_birth': '1999-01-09',
        'p_current_city': 'Karachi',
        'p_current_area': 'Clifton',
        'p_current_address': 'Flat 4, Block 5',
        'p_permanent_same_as_current': true,
        'p_permanent_city': null,
        'p_permanent_area': null,
        'p_permanent_address': null,
      });
    });

    test('a separate permanent address is sent as entered', () {
      final p = ProfileRowMapper.saveProfileSetupParams(
        base.copyWith(
          phone: '03001234567',
          dateOfBirth: DateTime(2000, 5, 1),
          currentCity: 'Lahore',
          currentArea: 'Gulberg',
          currentAddress: 'House 1',
          permanentCity: 'Multan',
          permanentArea: 'Cantt',
          permanentAddress: 'Street 9',
          isPermanentSameAsCurrent: false,
        ),
      );
      expect(p['p_permanent_same_as_current'], isFalse);
      expect(
        [
          p['p_permanent_city'],
          p['p_permanent_area'],
          p['p_permanent_address'],
        ],
        ['Multan', 'Cantt', 'Street 9'],
      );
    });

    test('missing required fields are reported, not sent', () {
      expect(
        () => ProfileRowMapper.saveProfileSetupParams(base),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('phone'),
              contains('dateOfBirth'),
              contains('currentCity'),
            ),
          ),
        ),
      );
      expect(
        () => ProfileRowMapper.saveProfileSetupParams(
          base.copyWith(
            phone: '03001234567',
            dateOfBirth: DateTime(2000, 5, 1),
            currentCity: 'Lahore',
            currentArea: 'Gulberg',
            currentAddress: 'House 1',
            isPermanentSameAsCurrent: false,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('permanentCity'),
          ),
        ),
      );
    });

    test('a whitespace-only full name is reported as missing', () {
      expect(
        () => ProfileRowMapper.saveProfileSetupParams(
          base.copyWith(
            fullName: '   ',
            phone: '03001234567',
            dateOfBirth: DateTime(2000, 5, 1),
            currentCity: 'Lahore',
            currentArea: 'Gulberg',
            currentAddress: 'House 1',
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fullName'),
          ),
        ),
      );
    });
  });

  group('player profile rows', () {
    test('a Batsman wicket keeper', () {
      expect(
        ProfileRowMapper.playerProfileRow(
          id,
          const PlayerProfile(
            role: PlayerRole.batsman,
            battingStyle: BattingStyle.rightHanded,
            isWicketkeeper: true,
          ),
        ),
        {
          'user_id': id,
          'player_role': 'batsman',
          'batting_style': 'right_handed',
          'bowling_style': null,
          'is_wicketkeeper': true,
        },
      );
    });

    test('round-trips through a row', () {
      const p = PlayerProfile(
        role: PlayerRole.bowler,
        bowlingStyle: BowlingStyle.rightArmOffSpin,
      );
      final back = ProfileRowMapper.playerProfileFromRow(
        ProfileRowMapper.playerProfileRow(id, p),
      );
      expect(
        [back.role, back.battingStyle, back.bowlingStyle, back.isWicketkeeper],
        [PlayerRole.bowler, null, BowlingStyle.rightArmOffSpin, false],
      );
    });

    test('no playing role yet: nothing to save', () {
      expect(
        () => ProfileRowMapper.playerProfileRow(id, const PlayerProfile()),
        throwsStateError,
      );
    });
  });

  test('dates travel as YYYY-MM-DD without shifting', () {
    expect(ProfileRowMapper.formatDate(DateTime(2001, 7, 7)), '2001-07-07');
    expect(ProfileRowMapper.parseDate('2001-07-07'), DateTime(2001, 7, 7));
    expect(ProfileRowMapper.parseDate(null), isNull);
  });
}
