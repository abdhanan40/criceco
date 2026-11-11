import 'package:clock/clock.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_account_overlay.dart';
import 'package:criceco/data/supabase/supabase_account_repository.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/features/location/area_field.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

/// Stage 4.3.5: Edit Profile's city change — the Area rule, the session
/// sync of city ids and the repository's address update with `city_id`.
void main() {
  group('CityAreas.keepsArea (Profile Setup and Edit Profile)', () {
    const areas = CityAreas({
      'Karachi': ['Clifton', 'DHA'],
      'Lahore': ['Gulberg', 'DHA'],
    });

    test('keep: same city, no area, or listed under the new city', () {
      expect(areas.keepsArea('Karachi', 'Karachi', 'Clifton'), isTrue);
      expect(areas.keepsArea('Karachi', 'Lahore', null), isTrue);
      expect(areas.keepsArea('Karachi', 'Lahore', '  '), isTrue);
      expect(areas.keepsArea('Karachi', 'Lahore', 'DHA'), isTrue);
    });

    test('clear: the new city lists areas and this is not one', () {
      expect(areas.keepsArea('Karachi', 'Lahore', 'Clifton'), isFalse);
      expect(areas.keepsArea('Multan', 'Lahore', 'Cantt'), isFalse);
    });

    test('a new city without listed areas keeps a typed area only', () {
      expect(areas.keepsArea('Multan', 'Kamra', 'Cantt'), isTrue); // typed
      expect(areas.keepsArea('Karachi', 'Kamra', 'Clifton'), isFalse); // listed
      expect(CityAreas.empty.keepsArea('Karachi', 'Lahore', 'Clifton'), isTrue);
    });
  });

  test(
    'AreaField.textFor: a listed area as it is; Other keeps a typed one',
    () {
      const listed = ['Gulberg', 'DHA'];
      expect(AreaField.textFor('DHA', listed: listed, typed: 'x'), 'DHA');
      expect(
        AreaField.textFor(kOtherArea, listed: listed, typed: 'Cantt'),
        'Cantt',
      );
      expect(AreaField.textFor(kOtherArea, listed: listed, typed: 'DHA'), '');
    },
  );

  group('SessionController.syncProfileCity (Edit Profile)', () {
    const before = UserAccount(
      id: 'u1',
      fullName: 'A',
      contactMethod: ContactMethod.email,
      city: 'Karachi',
      currentCity: 'Karachi',
      currentCityId: 1,
      currentArea: 'Clifton',
      currentAddress: 'Street 1',
      permanentCity: 'Karachi',
      permanentCityId: 1,
      permanentArea: 'Clifton',
      permanentAddress: 'Street 1',
    );
    UserAccount edit(UserAccount from, {String? city, int? id, String? area}) =>
        SessionController.syncProfileCity(
          from,
          from.copyWith(
            city: city,
            currentCityId: id,
            clearCurrentCityId: id == null,
            currentArea: area,
          ),
        );

    test('a City picked with an id keeps it; same as current follows', () {
      final a = edit(before, city: 'Kamra', id: 101, area: 'Cantt');
      expect(
        (a.city, a.currentCity, a.currentCityId, a.currentArea),
        ('Kamra', 'Kamra', 101, 'Cantt'),
      );
      expect(
        (
          a.permanentCity,
          a.permanentCityId,
          a.permanentArea,
          a.permanentAddress,
        ),
        ('Kamra', 101, 'Cantt', 'Street 1'),
      );
    });

    test('a City set without a new id clears the old one (text only)', () {
      final a = SessionController.syncProfileCity(
        before,
        before.copyWith(city: 'Lahore'),
      );
      expect((a.currentCity, a.currentCityId), ('Lahore', null));
      expect((a.permanentCity, a.permanentCityId), ('Lahore', null));
    });

    test('a town with the same name: the new id is kept', () {
      final kamra = before.copyWith(
        city: 'Kamra',
        currentCity: 'Kamra',
        currentCityId: 101,
        permanentCity: 'Kamra',
        permanentCityId: 101,
      );
      final a = edit(kamra, city: 'Kamra', id: 102, area: 'Clifton');
      expect((a.city, a.currentCity, a.currentCityId), ('Kamra', 'Kamra', 102));
      expect(a.permanentCityId, 102);
    });

    test('a separate permanent address never follows', () {
      final separate = before.copyWith(
        isPermanentSameAsCurrent: false,
        permanentCity: 'Multan',
        permanentCityId: 6,
        permanentArea: 'Cantt',
      );
      final a = edit(separate, city: 'Lahore', id: 2, area: 'Gulberg');
      expect((a.currentCity, a.currentCityId), ('Lahore', 2));
      expect(
        (a.permanentCity, a.permanentCityId, a.permanentArea),
        ('Multan', 6, 'Cantt'),
      );
    });

    test(
      'no permanent copy yet: none is invented; Profile Setup unchanged',
      () {
        const legacy = UserAccount(
          id: 'u1',
          fullName: 'A',
          contactMethod: ContactMethod.phone,
          city: 'Islamabad',
        );
        final a = edit(legacy, city: 'Lahore', id: 2, area: 'Gulberg');
        expect((a.currentCity, a.currentCityId), ('Lahore', 2));
        expect((a.permanentCity, a.permanentCityId), (null, null));
        // Profile Setup (a new Current City) keeps its own permanent answers.
        final setup = SessionController.syncProfileCity(
          before,
          before.copyWith(currentCity: 'Multan', currentCityId: 6),
        );
        expect((setup.city, setup.permanentCity), ('Multan', 'Karachi'));
      },
    );

    test('unchanged City and Area: nothing moves', () {
      final a = SessionController.syncProfileCity(
        before,
        before.copyWith(fullName: 'B'),
      );
      expect(
        (a.currentCityId, a.permanentCityId, a.permanentArea),
        (1, 1, 'Clifton'),
      );
    });
  });

  group('SupabaseAccountRepository.update: city_id with the address', () {
    late FakeDb db;
    late SupabaseAccountRepository repo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      db = FakeDb();
      repo = SupabaseAccountRepository(
        auth: FakeAuth(db),
        db: db,
        overlay: LocalAccountOverlay(prefs),
        clock: Clock(() => DateTime(2026, 11, 11)),
      );
    });

    /// A signed-up user whose Profile Setup saved Karachi (1) / Clifton —
    /// with v2 (ids) unless [ids] is false (v1, text only); [same]: the
    /// permanent address is the current copy, else Multan (6).
    Future<UserAccount> profiled({bool ids = true, bool same = true}) async {
      final a = await repo.signUp(
        fullName: 'Hamza Sheikh',
        method: ContactMethod.email,
        identifier: 'hamza@example.com',
        password: 'Cricket@2026',
      );
      final saved = await repo.saveProfileSetup(
        a.copyWith(
          phone: '0300 1234567',
          dateOfBirth: DateTime(2000, 5, 1),
          currentCity: 'Karachi',
          currentCityId: ids ? 1 : null,
          currentArea: 'Clifton',
          currentAddress: 'Street 1',
          isPermanentSameAsCurrent: same,
          permanentCity: same ? 'Karachi' : 'Multan',
          permanentCityId: ids ? (same ? 1 : 6) : null,
          permanentArea: same ? 'Clifton' : 'Cantt',
          permanentAddress: same ? 'Street 1' : 'Street 9',
        ),
        at: DateTime(2026, 11, 11),
      );
      db.calls.clear();
      db.lastAddressUpdate.clear();
      return saved;
    }

    /// Edit Profile's change, through the session's sync as the app does.
    UserAccount edit(UserAccount a, String city, int? id, String area) =>
        SessionController.syncProfileCity(
          a,
          a.copyWith(
            city: city,
            currentCityId: id,
            clearCurrentCityId: id == null,
            currentArea: area,
          ),
        );

    test(
      'a picked id is written with the text; the read-back has it',
      () async {
        final a = await profiled();
        final saved = await repo.update(edit(a, 'Kamra', 101, 'Cantt'));
        const columns = {
          'city': 'Kamra',
          'area': 'Cantt',
          'address': 'Street 1',
          'city_id': 101,
        };
        expect(db.lastAddressUpdate['current_addresses'], columns);
        expect(db.lastAddressUpdate['permanent_addresses'], columns);
        expect(
          (saved.city, saved.currentCityId, saved.currentArea),
          ('Kamra', 101, 'Cantt'),
        );
        expect((saved.permanentCity, saved.permanentCityId), ('Kamra', 101));
      },
    );

    test(
      'same text, another id (two towns named Kamra) is still a change',
      () async {
        final a = await repo.update(
          edit(await profiled(), 'Kamra', 101, 'Cantt'),
        );
        db.lastAddressUpdate.clear();
        final saved = await repo.update(edit(a, 'Kamra', 102, 'Cantt'));
        expect(db.lastAddressUpdate['current_addresses']!['city_id'], 102);
        expect((saved.currentCityId, saved.permanentCityId), (102, 102));
      },
    );

    test('unchanged city, Area and address: no address write', () async {
      final a = await profiled();
      await repo.update(a.copyWith(fullName: 'Hamza S.'));
      expect(db.calls.where((c) => c.startsWith('updateAddress')), isEmpty);
    });

    test('an unchanged id is not sent again; text only, as before', () async {
      final a = await profiled();
      // e.g. an Area change by another caller: the id stays the stored one.
      await repo.update(a.copyWith(currentArea: 'DHA', permanentArea: 'DHA'));
      expect(db.lastAddressUpdate['current_addresses'], {
        'city': 'Karachi',
        'area': 'DHA',
        'address': 'Street 1',
      });
      expect(db.currentAddresses.values.single['city_id'], 1); // kept
    });

    test('a City without an id (v1 / text-only) writes no city_id; the '
        'database resolves the text', () async {
      final a = await profiled(ids: false);
      final saved = await repo.update(edit(a, 'Lahore', null, 'Gulberg'));
      expect(
        db.lastAddressUpdate['current_addresses']!.containsKey('city_id'),
        isFalse,
      );
      expect(saved.currentCityId, 2); // the fake's unique-name resolution
      final ambiguous = await repo.update(edit(saved, 'Kamra', null, 'Cantt'));
      expect(ambiguous.currentCityId, isNull); // two cities named Kamra
    });

    test('a separate permanent address is not written', () async {
      final a = await profiled(same: false);
      final saved = await repo.update(edit(a, 'Lahore', 2, 'Gulberg'));
      expect(db.lastAddressUpdate.keys, ['current_addresses']);
      expect((saved.permanentCity, saved.permanentCityId), ('Multan', 6));
    });

    test('an unknown id (23503, foreign key) → "Please choose your city '
        'again"; nothing changes', () async {
      final a = await profiled();
      await expectLater(
        repo.update(edit(a, 'Atlantis', 999, 'Cantt')),
        throwsA(
          isA<ProfileValidationException>().having(
            (e) => e.message,
            'message',
            'Please choose your city again',
          ),
        ),
      );
      expect(db.currentAddresses.values.single['city_id'], 1);
      expect(db.currentAddresses.values.single['city'], 'Karachi');
    });
  });

  group('SupabaseErrorMapper: the address city_id foreign keys (E2)', () {
    Object mapped(String table, {bool named = false}) =>
        SupabaseErrorMapper.map(
          GatewayConstraintException(
            sqlState: '23503',
            message:
                'insert or update on table "$table" violates foreign key '
                'constraint "${table}_city_id_fkey"',
            constraint: named ? '${table}_city_id_fkey' : null,
          ),
        );
    Matcher message(String text) => isA<ProfileValidationException>().having(
      (e) => e.message,
      'message',
      text,
    );

    test('by the constraint in the message, or its name', () {
      for (final named in [false, true]) {
        expect(
          mapped('current_addresses', named: named),
          message('Please choose your city again'),
        );
        expect(
          mapped('permanent_addresses', named: named),
          message('Please choose your permanent city again'),
        );
      }
    });

    test('other foreign keys keep the generic message', () {
      expect(
        SupabaseErrorMapper.map(
          const GatewayConstraintException(
            sqlState: '23503',
            message: 'violates foreign key constraint "clubs_owner_id_fkey"',
          ),
        ),
        message(SupabaseErrorMapper.generic),
      );
    });
  });
}
