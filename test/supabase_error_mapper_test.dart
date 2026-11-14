import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gateway errors → user-facing app errors, and the stored phone format.
void main() {
  String messageOf(GatewayException e) =>
      (SupabaseErrorMapper.map(e) as ProfileValidationException).message;

  test('transport errors become typed account errors', () {
    expect(
      SupabaseErrorMapper.map(const GatewayNetworkException()),
      isA<BackendUnavailableException>(),
    );
    expect(
      SupabaseErrorMapper.map(const GatewayPermissionException()),
      isA<NotSignedInException>(),
    );
    expect(
      SupabaseErrorMapper.map(const GatewayUnexpectedException('x')),
      isA<BackendOperationException>(),
    );
  });

  group('42501 is a refusal, not a lost session (M1)', () {
    test('an RLS / privilege refusal → PermissionDeniedException', () {
      for (final message in [
        'new row violates row-level security policy for table "profiles"',
        'permission denied for table profiles',
        'rls',
      ]) {
        final e = SupabaseErrorMapper.map(
          GatewayConstraintException(sqlState: '42501', message: message),
        );
        expect(e, isA<PermissionDeniedException>(), reason: message);
        expect(
          (e as AccountException).message,
          "You don't have permission to do that",
        );
      }
    });

    test('the functions\' own "not authenticated" still means sign in', () {
      expect(
        SupabaseErrorMapper.map(
          const GatewayConstraintException(
            sqlState: '42501',
            message: 'not authenticated',
          ),
        ),
        isA<NotSignedInException>(),
      );
    });
  });

  test(
    'every migration CHECK constraint has a message (by name or in the text)',
    () {
      for (final name in [
        'profiles_date_of_birth_check',
        'current_addresses_city_check',
        'permanent_addresses_city_check',
        'current_addresses_area_check',
        'permanent_addresses_area_check',
        'current_addresses_address_check',
        'permanent_addresses_address_check',
        'player_profiles_player_role_check',
        'player_profiles_batting_style_check',
        'player_profiles_bowling_style_check',
        'player_profiles_batting_follows_role',
        'player_profiles_bowling_follows_role',
        'player_profiles_wicketkeeper_batsman_only',
      ]) {
        final byName = messageOf(
          GatewayConstraintException(
            sqlState: '23514',
            message: '',
            constraint: name,
          ),
        );
        final inText = messageOf(
          GatewayConstraintException(
            sqlState: '23514',
            message:
                'new row for relation "x" violates check constraint "$name"',
          ),
        );
        expect(byName, isNot(SupabaseErrorMapper.generic), reason: name);
        expect(inText, byName, reason: name);
      }
    },
  );

  test('Supabase Auth refusals (from the SDK gateway) get app messages', () {
    expect(
      SupabaseErrorMapper.map(const GatewayEmailNotConfirmedException()),
      isA<EmailConfirmationRequiredException>(),
    );
    expect(
      messageOf(
        const GatewayConstraintException(
          sqlState: '23505',
          message: 'user already exists',
        ),
      ),
      'An account with this email already exists — please log in',
    );
    expect(
      messageOf(
        const GatewayConstraintException(
          sqlState: '23514',
          message: 'weak password',
        ),
      ),
      'Choose a stronger password',
    );
  });

  test('raw database text is never passed on', () {
    const raw = 'internal detail: relation secret_table';
    final m = messageOf(
      const GatewayConstraintException(sqlState: '23514', message: raw),
    );
    expect(m, SupabaseErrorMapper.generic);
    expect(
      SupabaseErrorMapper.map(
        const GatewayConstraintException(sqlState: 'XX000', message: raw),
      ),
      isA<BackendOperationException>().having(
        (e) => e.message,
        'message',
        isNot(contains('secret')),
      ),
    );
  });

  group('clubs (migration 5, Stage 3A)', () {
    test('every clubs rule has its message, by constraint name', () {
      const expected = {
        'clubs_name_check': 'Enter a club name (up to 100 characters)',
        'clubs_short_name_check': 'Short name must be up to 40 characters',
        'clubs_city_check': 'City is required (up to 100 characters)',
        'clubs_club_type_check': 'Choose a valid club type',
        'clubs_owner_name_check': 'Owner name must be 2–100 characters',
        'clubs_address_check': 'Address must be up to 500 characters',
        'clubs_email_check': 'Enter a valid email address',
        'clubs_home_ground_id_check': 'Choose a valid home ground',
        'clubs_established_year_check':
            'Established year must be between 1800 and 2100',
      };
      for (final MapEntry(key: name, value: text) in expected.entries) {
        // As PostgREST reports it: the name only inside the message.
        expect(
          messageOf(
            GatewayConstraintException(
              sqlState: '23514',
              message:
                  'new row for relation "clubs" violates check constraint "$name"',
            ),
          ),
          text,
          reason: name,
        );
      }
    });

    test('create_club()\'s own refusals', () {
      for (final (raw, text) in [
        ('club name is required', 'Club name is required'),
        ('club city is required', 'Please select a city'),
        ('club type is required', 'Please select a club type'),
        (
          'profile_completed requires a completed User Profile Setup before creating a club',
          'Please complete all profile details',
        ),
      ]) {
        expect(
          messageOf(
            GatewayConstraintException(sqlState: '23514', message: raw),
          ),
          text,
          reason: raw,
        );
      }
      expect(
        SupabaseErrorMapper.map(
          const GatewayConstraintException(
            sqlState: '42501',
            message: 'not authenticated',
          ),
        ),
        isA<NotSignedInException>(),
      );
    });

    test(
      'a join-code collision asks for a retry; a second club is refused',
      () {
        expect(
          messageOf(
            const GatewayConstraintException(
              sqlState: '23505',
              message: 'duplicate key value violates unique constraint "clubs_code_key"',
            ),
          ),
          "Couldn't create the club — please try again",
        );
        expect(
          messageOf(
            const GatewayConstraintException(
              sqlState: '23505',
              message: 'duplicate key value violates unique constraint "clubs_owner_id_key"',
            ),
          ),
          'You already have a club',
        );
      },
    );

    test('no raw clubs text reaches the user', () {
      for (final e in const [
        GatewayConstraintException(
          sqlState: '23514',
          message: 'new row for relation "clubs" violates check constraint "clubs_secret_check"',
        ),
        GatewayConstraintException(
          sqlState: '23505',
          message:
              'duplicate key value violates unique constraint "clubs_pkey"',
        ),
      ]) {
        final text = messageOf(e);
        expect(text, SupabaseErrorMapper.generic);
        expect(text, isNot(contains('clubs')));
      }
    });
  });

  group('storedPhone', () {
    test('every accepted spelling becomes +923XXXXXXXXX', () {
      for (final p in [
        '03001234567',
        '0300 1234567',
        '0300-1234567',
        '923001234567',
        '+92 300 1234567',
        '(0300) 1234567',
      ]) {
        expect(SupabaseErrorMapper.storedPhone(p), '+923001234567', reason: p);
      }
    });

    test('anything else is refused with the form message', () {
      expect(
        () => SupabaseErrorMapper.storedPhone('12345'),
        throwsA(
          isA<ProfileValidationException>().having(
            (e) => e.message,
            'message',
            'Enter a valid mobile number (03XX-XXXXXXX)',
          ),
        ),
      );
    });
  });
}
