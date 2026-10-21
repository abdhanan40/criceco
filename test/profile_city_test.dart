import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/features/club/hunt/player_hunt_controller.dart';
import 'package:criceco/features/player/player_providers.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

/// Profile Setup → Continue with a current city (and optionally a separate
/// permanent city).
Future<void> _profileSetup(ProviderContainer c, {required String current, String? permanent}) =>
    c.read(sessionProvider.notifier).completeProfile(
          fullName: 'Hamza Sheikh',
          phone: '0333 9876543',
          dateOfBirth: DateTime(2000, 5, 1),
          currentCity: current,
          currentArea: 'Clifton',
          currentAddress: 'House 12, Street 4',
          permanentCity: permanent ?? current,
          permanentArea: 'Cantt',
          permanentAddress: 'Street 9',
          isPermanentSameAsCurrent: permanent == null,
        );

UserAccount _account(ProviderContainer c) => c.read(currentAccountProvider)!;

void main() {
  group('syncProfileCity', () {
    const base = UserAccount(id: 'a', fullName: 'A', contactMethod: ContactMethod.phone, city: 'Islamabad');
    UserAccount sync(UserAccount after, [UserAccount before = base]) => SessionController.syncProfileCity(before, after);

    test('a new Current City becomes the profile City; the Permanent City never does', () {
      final a = sync(base.copyWith(currentCity: 'Karachi', permanentCity: 'Multan'));
      expect((a.city, a.currentCity, a.permanentCity), ('Karachi', 'Karachi', 'Multan'));
      expect(sync(base.copyWith(permanentCity: 'Multan')).city, 'Islamabad');
    });

    test('a changed profile City (Edit Profile) becomes the Current City', () {
      final before = base.copyWith(city: 'Karachi', currentCity: 'Karachi');
      final a = sync(before.copyWith(city: 'Lahore'), before);
      expect((a.city, a.currentCity), ('Lahore', 'Lahore'));
    });

    test('unchanged or empty values leave existing accounts alone', () {
      expect(sync(base.copyWith(fullName: 'B')).currentCity, isNull, reason: 'no Current City is invented');
      expect(sync(base.copyWith(fullName: 'B')).city, 'Islamabad');
      expect(sync(base.copyWith(currentCity: '  ')).city, 'Islamabad', reason: 'empty is not a city');
    });
  });

  group('Session', () {
    test('Profile Setup saves the current city as the profile City (not the permanent one)', () async {
      final c = await makeContainer();
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      expect(_account(c).city, 'Islamabad', reason: 'demo account before');
      await _profileSetup(c, current: 'Karachi', permanent: 'Multan');
      final a = _account(c);
      expect((a.city, a.currentCity, a.permanentCity), ('Karachi', 'Karachi', 'Multan'));
    });

    test('a later City change keeps Current City in step', () async {
      final c = await makeContainer();
      final s = c.read(sessionProvider.notifier);
      await s.signIn(identifier: 'x', password: 'y');
      await _profileSetup(c, current: 'Karachi');
      await s.updateAccount((a) => a.copyWith(city: 'Lahore'));
      expect((_account(c).city, _account(c).currentCity), ('Lahore', 'Lahore'));
      await s.updateAccount((a) => a.copyWith(fullName: 'Hamza S.'));
      expect((_account(c).city, _account(c).currentCity), ('Lahore', 'Lahore'), reason: 'other edits keep both');
    });

    test('"available to clubs" lists the player under the synced city, so city filtering finds them', () async {
      final c = await makeContainer();
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      await _profileSetup(c, current: 'Karachi', permanent: 'Multan');
      await c.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
      final open = await c.read(openPlayersProvider.future);
      final me = open.where((p) => p.isMe).single;
      expect(me.city, 'Karachi');
      expect(c.read(openPlayerCitiesProvider), contains('Karachi'), reason: 'the club-side City filter offers it');
      // Same rule as Available Players: city + role.
      expect([for (final p in open) if (p.city == 'Karachi' && p.role == me.role) p.id], contains(me.id));
      expect([for (final p in open) if (p.city == 'Multan') p.id], isNot(contains(me.id)));
    });

    test('existing account without a Current City keeps its City for the listing', () async {
      final c = await makeContainer();
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      expect(_account(c).currentCity, isNull);
      await c.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
      final me = (await c.read(openPlayersProvider.future)).where((p) => p.isMe).single;
      expect(me.city, 'Islamabad');
    });
  });

  group('My Profile', () {
    testWidgets('shows the Profile Setup city; Edit Profile City updates Current City', (tester) async {
      tester.view.physicalSize = const Size(375 * 3, 812 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
      await tester.pumpAndSettle();
      await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
      await _profileSetup(c, current: 'Karachi', permanent: 'Multan');
      c.read(routerProvider).go(Routes.playerProfile);
      await tester.pumpAndSettle();
      expect(find.text('Karachi'), findsOneWidget);
      expect(find.text('Multan'), findsNothing, reason: 'the permanent city is not the profile City');

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('edit.city')));
      await tester.tap(find.byKey(const Key('edit.city')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lahore').last);
      await tester.pumpAndSettle();
      final save = find.widgetWithText(CeButton, 'Save Changes');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final a = _account(c);
      expect((a.city, a.currentCity, a.permanentCity), ('Lahore', 'Lahore', 'Multan'));
      expect(find.text('Lahore'), findsOneWidget);
    });
  });
}
