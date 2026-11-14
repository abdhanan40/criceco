import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/supabase/club_row_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stage 3A: `public.clubs` rows ↔ [Club] (no Supabase involved).
void main() {
  Map<String, dynamic> fullRow() => {
    'id': 'c1a1b2c3-0000-4000-8000-000000000001',
    'owner_id': '00000000-0000-4000-8000-000000000001',
    'name': 'Lahore Lions CC',
    'short_name': 'Lions',
    'city': 'Lahore',
    'club_type': 'college_university',
    'code': 'K7MQ2X',
    'owner_name': 'Hamza Sheikh',
    'address': 'Mian Mir Road',
    'email': 'club@example.com',
    'home_ground_id': 'g_pindi',
    'established_year': 2026,
    'created_at': '2026-11-09T10:00:00+00:00',
    'last_updated_at': '2026-11-09T10:00:00+00:00',
  };

  Club club() => ClubRowMapper.clubFromRow(fullRow());

  group('club type codes', () {
    test('every type round-trips (same codes as clubs_club_type_check)', () {
      expect(
        {for (final t in ClubType.values) t: ClubRowMapper.clubTypeCode(t)},
        {
          ClubType.professional: 'professional',
          ClubType.collegeUniversity: 'college_university',
          ClubType.corporate: 'corporate',
        },
      );
      for (final t in ClubType.values) {
        expect(
          ClubRowMapper.clubTypeFromCode(ClubRowMapper.clubTypeCode(t)),
          t,
        );
      }
    });

    test('an unknown code fails loudly', () {
      expect(
        () => ClubRowMapper.clubTypeFromCode('amateur'),
        throwsFormatException,
      );
    });
  });

  group('row → Club', () {
    test('every column is mapped', () {
      final c = club();
      expect(c.id, 'c1a1b2c3-0000-4000-8000-000000000001');
      expect(
        (c.name, c.shortName, c.city, c.type, c.code),
        (
          'Lahore Lions CC',
          'Lions',
          'Lahore',
          ClubType.collegeUniversity,
          'K7MQ2X',
        ),
      );
      expect(
        (c.ownerName, c.address, c.email, c.homeGroundId, c.establishedYear),
        ('Hamza Sheikh', 'Mian Mir Road', 'club@example.com', 'g_pindi', 2026),
      );
      expect(
        (c.hasLogo, c.logoPath),
        (false, null),
        reason: 'never from the database',
      );
    });

    test('optional columns may be NULL', () {
      final c = ClubRowMapper.clubFromRow({
        ...fullRow(),
        'short_name': null,
        'owner_name': null,
        'address': null,
        'email': null,
        'home_ground_id': null,
        'established_year': null,
      });
      expect(
        (
          c.shortName,
          c.ownerName,
          c.address,
          c.email,
          c.homeGroundId,
          c.establishedYear,
        ),
        (null, null, null, null, null, null),
      );
      expect(c.displayShortName, 'Lahore Lions CC');
    });

    test('a numeric year from JSON (num) and this device\'s picture', () {
      final c = ClubRowMapper.clubFromRow({
        ...fullRow(),
        'established_year': 1999.0,
      }, logoPath: '/photos/club.jpg');
      expect(c.establishedYear, 1999);
      expect((c.hasLogo, c.logoPath), (true, '/photos/club.jpg'));
    });
  });

  group('create_club parameters', () {
    test(
      'exact p_* names; type as its code; optional values passed as given',
      () {
        expect(
          ClubRowMapper.createParams(
            name: 'Lahore Lions CC',
            city: 'Lahore',
            type: ClubType.corporate,
            ownerName: 'Hamza Sheikh',
            homeGroundId: 'g_pindi',
          ),
          {
            'p_name': 'Lahore Lions CC',
            'p_city': 'Lahore',
            'p_club_type': 'corporate',
            'p_owner_name': 'Hamza Sheikh',
            'p_address': null,
            'p_email': null,
            'p_home_ground_id': 'g_pindi',
          },
        );
      },
    );
  });

  group('update columns', () {
    test('nothing changed → nothing to write', () {
      expect(ClubRowMapper.updateColumns(club(), club()), isEmpty);
    });

    test('only the changed editable columns', () {
      final before = club();
      final after = before.copyWith(city: 'Karachi', establishedYear: 2001);
      expect(ClubRowMapper.updateColumns(before, after), {
        'city': 'Karachi',
        'established_year': 2001,
      });
      expect(
        ClubRowMapper.updateColumns(
          before,
          before.copyWith(type: ClubType.professional),
        ),
        {'club_type': 'professional'},
      );
    });

    test('a cleared optional value is written as NULL', () {
      final before = club();
      final after = before.copyWith(
        clearAddress: true,
        clearEmail: true,
        clearEstablished: true,
      );
      expect(ClubRowMapper.updateColumns(before, after), {
        'address': null,
        'email': null,
        'established_year': null,
      });
    });

    test('a rename also clears short_name (as Club.copyWith does)', () {
      final before = club();
      expect(
        ClubRowMapper.updateColumns(
          before,
          before.copyWith(name: 'Lahore Lions'),
        ),
        {'name': 'Lahore Lions', 'short_name': null},
      );
    });

    test('never the picture, code, owner or id', () {
      final before = club();
      final columns = ClubRowMapper.updateColumns(
        before,
        before.withLogo('/photos/new.jpg'),
      );
      expect(columns, isEmpty, reason: 'the picture stays on the device');
      for (final key in [
        'id',
        'owner_id',
        'code',
        'created_at',
        'last_updated_at',
        'logo_path',
        'has_logo',
      ]) {
        expect(
          ClubRowMapper.updateColumns(
            before,
            before.copyWith(name: 'X Club'),
          ).containsKey(key),
          isFalse,
          reason: key,
        );
      }
    });
  });
}
