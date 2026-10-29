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
    expect(
      SupabaseErrorMapper.map(
        const GatewayConstraintException(sqlState: '42501', message: 'rls'),
      ),
      isA<NotSignedInException>(),
    );
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
