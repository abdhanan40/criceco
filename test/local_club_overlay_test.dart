import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/supabase/local_club_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stage 3A: the club picture stays on this device, per club id (D-S2-2).
void main() {
  const a = Club(
    id: 'club-a',
    name: 'A Club',
    city: 'Lahore',
    type: ClubType.corporate,
    code: 'AAAAAA',
  );
  const b = Club(
    id: 'club-b',
    name: 'B Club',
    city: 'Karachi',
    type: ClubType.professional,
    code: 'BBBBBB',
  );

  late SharedPreferences prefs;
  late LocalClubOverlay overlay;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    overlay = LocalClubOverlay(prefs);
  });

  test('nothing stored → no picture', () {
    final c = overlay.applyTo(a.withLogo('/stale/path.jpg'));
    expect((c.hasLogo, c.logoPath), (false, null));
    expect(
      (c.id, c.name, c.code),
      (a.id, a.name, a.code),
      reason: 'everything else unchanged',
    );
  });

  test(
    'saved per club id; other clubs unaffected; survives a new overlay',
    () async {
      await overlay.save(a.withLogo('/photos/a.jpg'));
      final restarted = LocalClubOverlay(prefs);
      expect(restarted.applyTo(a).logoPath, '/photos/a.jpg');
      expect(restarted.applyTo(a).hasLogo, isTrue);
      expect(restarted.applyTo(b).logoPath, isNull);
      expect(prefs.getString(LocalClubOverlay.keyFor('club-a')), isNotNull);
    },
  );

  test('removing the picture clears it', () async {
    await overlay.save(a.withLogo('/photos/a.jpg'));
    await overlay.save(a.withLogo(null));
    expect(overlay.applyTo(a).logoPath, isNull);
    expect(prefs.getString(LocalClubOverlay.keyFor('club-a')), isNull);
  });

  test('unreadable local data never blocks loading', () async {
    for (final raw in ['not json', '[1, 2]', '{"logoPath": 42}', 'null']) {
      await prefs.setString(LocalClubOverlay.keyFor('club-a'), raw);
      final c = overlay.applyTo(a);
      expect(
        (c.hasLogo, c.logoPath, c.name),
        (false, null, 'A Club'),
        reason: raw,
      );
    }
  });
}
