import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_account_overlay.dart';
import 'package:criceco/data/supabase/profile_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_account_repository.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:criceco/features/auth/onboarding_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'supabase_fakes.dart';

/// Stage 4.3.4: city ids through the account, save_profile_setup_v2 and the
/// v1 fallback (no SQL: the gateway / repository layers with fakes).
void main() {
  UserAccount setup({bool same = true, int? currentId = 2, int? permanentId}) =>
      UserAccount(
        id: 'u1',
        fullName: 'Hamza Sheikh',
        contactMethod: ContactMethod.email,
        phone: '+923001234567',
        dateOfBirth: DateTime(2000, 5, 1),
        currentCity: 'Lahore',
        currentCityId: currentId,
        currentArea: 'Gulberg',
        currentAddress: 'House 1',
        isPermanentSameAsCurrent: same,
        permanentCity: same ? 'Lahore' : 'Multan',
        permanentCityId: same ? currentId : permanentId,
        permanentArea: same ? 'Gulberg' : 'Cantt',
        permanentAddress: same ? 'House 1' : 'Street 9',
      );

  group('ProfileRowMapper', () {
    test('v2 params: "same as current" leaves the permanent arguments out', () {
      expect(ProfileRowMapper.saveProfileSetupV2Params(setup()), {
        'p_full_name': 'Hamza Sheikh',
        'p_phone': '+923001234567',
        'p_date_of_birth': '2000-05-01',
        'p_current_city_id': 2,
        'p_current_area': 'Gulberg',
        'p_current_address': 'House 1',
        'p_permanent_same_as_current': true,
        'p_permanent_city_id': null,
        'p_permanent_area': null,
        'p_permanent_address': null,
      });
    });

    test('v2 params: a different permanent city sends both ids', () {
      final p = ProfileRowMapper.saveProfileSetupV2Params(
        setup(same: false, permanentId: 6),
      );
      expect(p['p_current_city_id'], 2);
      expect(p['p_permanent_same_as_current'], isFalse);
      expect(p['p_permanent_city_id'], 6);
      expect(p['p_permanent_area'], 'Cantt');
      expect(p.containsKey('p_current_city'), isFalse); // ids, not text
    });

    test('v2 params need the ids; hasCityIds says when v2 can be used', () {
      expect(ProfileRowMapper.hasCityIds(setup()), isTrue);
      expect(ProfileRowMapper.hasCityIds(setup(currentId: null)), isFalse);
      expect(
        ProfileRowMapper.hasCityIds(setup(same: false, permanentId: null)),
        isFalse,
      );
      expect(
        ProfileRowMapper.hasCityIds(setup(same: false, permanentId: 6)),
        isTrue,
      );
      expect(
        () => ProfileRowMapper.saveProfileSetupV2Params(setup(currentId: null)),
        throwsStateError,
      );
      expect(
        () => ProfileRowMapper.saveProfileSetupV2Params(
          setup(same: false, permanentId: null),
        ),
        throwsStateError,
      );
    });

    test('the account read maps city_id (int or number); absent → null', () {
      final a = ProfileRowMapper.accountFromRows(
        profile: {'id': 'u1', 'full_name': 'A'},
        currentAddress: {
          'city': 'Kamra',
          'city_id': 101,
          'area': 'Cantt',
          'address': 'H',
        },
        permanentAddress: {
          'city': 'Multan',
          'city_id': 6.0,
          'area': 'C',
          'address': 'H',
        },
      );
      expect((a.currentCityId, a.currentCity), (101, 'Kamra'));
      expect((a.permanentCityId, a.permanentCity), (6, 'Multan'));
      final older = ProfileRowMapper.accountFromRows(
        profile: {'id': 'u1', 'full_name': 'A'},
        currentAddress: {'city': 'Lahore', 'area': 'G', 'address': 'H'},
      );
      expect(older.currentCityId, isNull); // database before migration 8
      expect(older.permanentCityId, isNull);
    });
  });

  group('SupabaseProfileGateway.saveProfileSetupV2', () {
    test('POST rpc/save_profile_setup_v2 with the params', () async {
      final requests = <http.Request>[];
      final client = sb.SupabaseClient(
        'https://abcdefghijklmnop.supabase.co',
        'sb_publishable_test_0000000000000000',
        httpClient: MockClient((r) async {
          requests.add(r);
          return http.Response.bytes(utf8.encode(''), 204, request: r);
        }),
        authOptions: const sb.AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: sb.AuthFlowType.implicit,
        ),
      );
      addTearDown(client.dispose);
      final params = ProfileRowMapper.saveProfileSetupV2Params(setup());
      await SupabaseProfileGateway(client).saveProfileSetupV2(params);
      final r = requests.single;
      expect(
        (r.method, r.url.path),
        ('POST', '/rest/v1/rpc/save_profile_setup_v2'),
      );
      expect(jsonDecode(r.body), params);
    });
  });

  group('SupabaseErrorMapper', () {
    test('v2 city refusals → friendly messages', () {
      Object mapped(String message) => SupabaseErrorMapper.map(
        GatewayConstraintException(sqlState: '23514', message: message),
      );
      expect(
        mapped('current_city_id must be an active city'),
        isA<ProfileValidationException>().having(
          (e) => e.message,
          'message',
          'Please choose your city again',
        ),
      );
      expect(
        mapped('permanent_city_id must be an active city'),
        isA<ProfileValidationException>().having(
          (e) => e.message,
          'message',
          'Please choose your permanent city again',
        ),
      );
    });
  });

  group('SupabaseAccountRepository.saveProfileSetup: v2 or v1', () {
    late FakeDb db;
    late FakeAuth auth;
    late SupabaseAccountRepository repo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      db = FakeDb();
      auth = FakeAuth(db);
      repo = SupabaseAccountRepository(
        auth: auth,
        db: db,
        overlay: LocalAccountOverlay(prefs),
        clock: Clock(() => DateTime(2026, 11, 11)),
      );
    });

    Future<UserAccount> signedUp() => repo.signUp(
      fullName: 'Hamza Sheikh',
      method: ContactMethod.email,
      identifier: 'hamza@example.com',
      password: 'Cricket@2026',
    );

    UserAccount filled(
      UserAccount a, {
      int? currentId,
      bool same = true,
      int? permanentId,
    }) => a.copyWith(
      phone: '0300 1234567',
      dateOfBirth: DateTime(2000, 5, 1),
      currentCity: 'Lahore',
      currentCityId: currentId,
      clearCurrentCityId: currentId == null,
      currentArea: 'Gulberg',
      currentAddress: 'House 1',
      isPermanentSameAsCurrent: same,
      permanentCity: same ? 'Lahore' : 'Multan',
      permanentCityId: same ? currentId : permanentId,
      clearPermanentCityId: (same ? currentId : permanentId) == null,
      permanentArea: same ? 'Gulberg' : 'Cantt',
      permanentAddress: same ? 'House 1' : 'Street 9',
    );

    test(
      'ids present → v2 (stored phone, ids); the read-back has the ids',
      () async {
        final a = await signedUp();
        final saved = await repo.saveProfileSetup(
          filled(a, currentId: 2, same: false, permanentId: 6),
          at: DateTime(2026, 11, 11),
        );
        expect(db.calls, contains('saveProfileSetupV2'));
        expect(db.calls, isNot(contains('saveProfileSetup')));
        expect(db.lastSetupV2Params!['p_phone'], '+923001234567');
        expect(db.lastSetupV2Params!['p_current_city_id'], 2);
        expect(db.lastSetupV2Params!['p_permanent_city_id'], 6);
        expect((saved.currentCityId, saved.permanentCityId), (2, 6));
        expect((saved.currentCity, saved.permanentCity), ('Lahore', 'Multan'));
        expect(saved.profileComplete, isTrue);
      },
    );

    test('no ids → v1 with the city text, exactly as before', () async {
      final a = await signedUp();
      await repo.saveProfileSetup(filled(a), at: DateTime(2026, 11, 11));
      expect(db.calls, contains('saveProfileSetup'));
      expect(db.calls, isNot(contains('saveProfileSetupV2')));
      expect(db.lastSetupParams!['p_current_city'], 'Lahore');
    });

    test('a permanent city without an id → v1 (v2 needs both)', () async {
      final a = await signedUp();
      await repo.saveProfileSetup(
        filled(a, currentId: 2, same: false),
        at: DateTime(2026, 11, 11),
      );
      expect(db.calls, contains('saveProfileSetup'));
      expect(db.calls, isNot(contains('saveProfileSetupV2')));
    });

    test('the v2 refusal messages match migration 8: the error mapper and the '
        'fake raise exactly what save_profile_setup_v2 raises', () async {
      // The messages save_profile_setup_v2 raises (migration 8), read from
      // the migration itself so a change there fails here.
      final sql = File(
        'supabase/migrations/20261110090200_add_address_city_id.sql',
      ).readAsStringSync();
      final raised = {
        for (final m in RegExp(
          r"raise exception '(\w+_city_id must be an active city)' "
          r"using errcode = '(\w+)'",
        ).allMatches(sql))
          m.group(1)!: m.group(2)!,
      };
      expect(raised, {
        'current_city_id must be an active city': '23514',
        'permanent_city_id must be an active city': '23514',
      });

      // The error mapper turns each one into its friendly message.
      const friendly = {
        'current_city_id must be an active city':
            'Please choose your city again',
        'permanent_city_id must be an active city':
            'Please choose your permanent city again',
      };
      for (final MapEntry(key: message, value: sqlState) in raised.entries) {
        expect(
          SupabaseErrorMapper.map(
            GatewayConstraintException(sqlState: sqlState, message: message),
          ),
          isA<ProfileValidationException>().having(
            (e) => e.message,
            'message',
            friendly[message],
          ),
        );
      }

      // The fake refuses with the same SQLSTATE and text.
      await signedUp();
      Future<GatewayConstraintException> refusal(UserAccount a) async {
        try {
          await db.saveProfileSetupV2(
            ProfileRowMapper.saveProfileSetupV2Params(a),
          );
        } on GatewayConstraintException catch (e) {
          return e;
        }
        fail('the fake accepted an unknown city id');
      }

      final current = await refusal(setup(currentId: 999));
      final permanent = await refusal(setup(same: false, permanentId: 999));
      expect(
        (current.sqlState, current.message),
        ('23514', 'current_city_id must be an active city'),
      );
      expect(
        (permanent.sqlState, permanent.message),
        ('23514', 'permanent_city_id must be an active city'),
      );
      expect(raised.keys, containsAll([current.message, permanent.message]));
    });

    test(
      'a refused city id → the friendly ProfileValidationException',
      () async {
        final a = await signedUp();
        await expectLater(
          repo.saveProfileSetup(
            filled(a, currentId: 999),
            at: DateTime(2026, 11, 11),
          ),
          throwsA(
            isA<ProfileValidationException>().having(
              (e) => e.message,
              'message',
              'Please choose your city again',
            ),
          ),
        );
      },
    );
  });

  group('OnboardingController', () {
    test(
      'a city picked with an id keeps it; a city set without one clears it',
      () {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final n = c.read(onboardingProvider.notifier);
        n.setCurrentCity('Kamra', id: 101, qualifier: 'Attock');
        n.setPermanentCity('Multan', id: 6);
        var d = c.read(onboardingProvider);
        expect(
          (d.currentCityId, d.currentCityQualifier, d.permanentCityId),
          (101, 'Attock', 6),
        );
        n.setCurrentCity('Lahore');
        n.setPermanentCity('Karachi');
        d = c.read(onboardingProvider);
        expect(
          (d.currentCity, d.currentCityId, d.currentCityQualifier),
          ('Lahore', null, null),
        );
        expect((d.permanentCity, d.permanentCityId), ('Karachi', null));
      },
    );
  });

  group('SessionController', () {
    test(
      'syncProfileCity: a City changed on Edit Profile drops the old id',
      () {
        const before = UserAccount(
          id: 'u1',
          fullName: 'A',
          contactMethod: ContactMethod.email,
          city: 'Lahore',
          currentCity: 'Lahore',
          currentCityId: 2,
        );
        final after = SessionController.syncProfileCity(
          before,
          before.copyWith(city: 'Karachi'),
        );
        expect((after.currentCity, after.currentCityId), ('Karachi', null));
        // Profile Setup's own current city (with its id) is left as it is.
        final setupChange = SessionController.syncProfileCity(
          before,
          before.copyWith(currentCity: 'Multan', currentCityId: 6),
        );
        expect((setupChange.city, setupChange.currentCityId), ('Multan', 6));
      },
    );
  });
}
