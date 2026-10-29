import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/supabase/local_account_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// D9: photo and settings stored on the device, per user id.
void main() {
  late SharedPreferences prefs;
  late LocalAccountOverlay overlay;

  const a = UserAccount(
    id: 'user-a',
    fullName: 'A User',
    contactMethod: ContactMethod.email,
  );
  const b = UserAccount(
    id: 'user-b',
    fullName: 'B User',
    contactMethod: ContactMethod.email,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    overlay = LocalAccountOverlay(prefs);
  });

  test('nothing stored → the account is unchanged', () {
    final out = overlay.applyTo(a);
    expect(out.hasPhoto, isFalse);
    expect(out.settings.publicProfile, isTrue);
  });

  test('photo and every setting round-trip', () async {
    final changedAt = DateTime(2026, 10, 1, 9, 30);
    await overlay.save(
      a.copyWith(
        hasPhoto: true,
        photoPath: '/photos/a.jpg',
        settings: const AccountSettings(
          publicProfile: false,
          showStats: false,
          showPhone: true,
          twoStep: true,
          loginAlerts: false,
        ).copyWith(passwordChangedAt: changedAt),
      ),
    );
    final out = LocalAccountOverlay(prefs)
        .applyTo(a); // a fresh instance ("restart")
    expect(out.hasPhoto, isTrue);
    expect(out.photoPath, '/photos/a.jpg');
    expect(
      [
        out.settings.publicProfile,
        out.settings.showStats,
        out.settings.showPhone,
        out.settings.twoStep,
        out.settings.loginAlerts,
      ],
      [false, false, true, true, false],
    );
    expect(out.settings.passwordChangedAt, changedAt);
  });

  test('stored per user: B never sees A\'s data', () async {
    await overlay.save(a.copyWith(hasPhoto: true, photoPath: '/photos/a.jpg'));
    expect(overlay.applyTo(b).photoPath, isNull);
  });

  test('unreadable stored data never blocks sign-in', () async {
    await prefs.setString(LocalAccountOverlay.keyFor(a.id), '{not json');
    expect(overlay.applyTo(a).id, 'user-a');
  });
}
