import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/app/theme/tokens.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Manrope weights 400–800 are bundled as local assets (no runtime download)', () async {
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      final data = await rootBundle.load('assets/fonts/manrope/Manrope-$w.ttf');
      expect(data.lengthInBytes, greaterThan(90000), reason: w);
    }
    final manifest = await rootBundle.loadString('FontManifest.json');
    expect(manifest, contains('"family":"Manrope"'));
  });

  test('theme uses Manrope and the approved brand green', () {
    final theme = AppTheme.light();
    expect(theme.textTheme.titleLarge!.fontFamily, 'Manrope');
    expect(theme.colorScheme.primary, CeColors.primary);
    expect(CeColors.primary, const Color(0xFF158447));
    expect(CeColors.primaryDark, const Color(0xFF0B3324));
  });
}
