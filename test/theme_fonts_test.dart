import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/app/theme/tokens.dart';
import 'package:flutter/material.dart';
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

  test('theme uses Manrope and the reference palette (deep, teal, green, sage)', () {
    final theme = AppTheme.light();
    expect(theme.textTheme.titleLarge!.fontFamily, 'Manrope');
    expect(theme.colorScheme.primary, CeColors.primary);
    expect(theme.brightness, Brightness.light, reason: 'light app on the new palette');
    // Exact swatch values from the approved reference image.
    expect(
      [CeColors.paletteDeep, CeColors.paletteTeal, CeColors.paletteGreen, CeColors.paletteSage],
      const [Color(0xFF092328), Color(0xFF12544F), Color(0xFF2A835F), Color(0xFF8BBB92)],
    );
    expect(CeColors.primary, CeColors.paletteGreen);
    expect(CeColors.primaryDark, CeColors.paletteTeal);
    expect(CeColors.ink, CeColors.paletteDeep);
    expect(CeColors.brandGradient.colors, [CeColors.paletteDeep, CeColors.paletteTeal, CeColors.paletteGreen]);
  });

  test('palette contrast: body text and white-on-brand stay readable (WCAG AA)', () {
    double lum(Color c) => c.computeLuminance();
    double ratio(Color a, Color b) {
      final (x, y) = (lum(a), lum(b));
      return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
    }

    expect(ratio(CeColors.ink, CeColors.bg), greaterThanOrEqualTo(4.5));
    expect(ratio(CeColors.muted, Colors.white), greaterThanOrEqualTo(4.5));
    expect(ratio(Colors.white, CeColors.primary), greaterThanOrEqualTo(4.5), reason: 'button labels');
    expect(ratio(CeColors.primaryDark, CeColors.mint), greaterThanOrEqualTo(4.5), reason: 'chip text on tints');
    expect(ratio(Colors.white, CeColors.paletteTeal), greaterThanOrEqualTo(4.5), reason: 'hero text');
  });
}
