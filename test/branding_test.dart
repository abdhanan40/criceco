import 'dart:io';
import 'dart:ui' as ui;

import 'package:criceco/features/auth/widgets/auth_widgets.dart';
import 'package:criceco/shared/widgets/ce_brand_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the approved logo asset is bundled, square and full resolution', () async {
    final data = await rootBundle.load(CeBrandLogo.asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    expect((image.width, image.height), (512, 512), reason: 'square, proportions locked');
  });

  testWidgets('auth banner shows the CricEco logo (not the old placeholder mark)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: AuthBanner(title: 'Criceco', subtitle: 'Your cricket club, organized.')),
    ));
    expect(find.byType(CeBrandLogo), findsOneWidget);
    expect(find.bySemanticsLabel('CricEco'), findsOneWidget);
    final img = tester.widget<Image>(find.byType(Image));
    expect((img.width, img.height, img.fit), (74.0, 74.0, BoxFit.contain));
  });

  testWidgets('sign-up intro uses the logo; feature intros keep their icons', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          CenterBlock.brand(title: 'Join Criceco', subtitle: 'x'),
          CenterBlock(icon: 'key', title: 'Enter Club Code', subtitle: 'y'),
        ]),
      ),
    ));
    expect(find.byType(CeBrandLogo), findsOneWidget);
  });

  test('Android launcher: adaptive icon + legacy mipmaps + CricEco splash are wired', () {
    const res = 'android/app/src/main/res';
    final adaptive = File('$res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
    expect(adaptive, contains('@mipmap/ic_launcher_foreground'));
    expect(adaptive, contains('@color/ic_launcher_background'));
    expect(File('$res/mipmap-anydpi-v26/ic_launcher_round.xml').existsSync(), isTrue);
    for (final d in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      for (final f in ['ic_launcher', 'ic_launcher_round', 'ic_launcher_foreground', 'ic_launcher_monochrome']) {
        expect(File('$res/mipmap-$d/$f.png').existsSync(), isTrue, reason: '$d/$f');
      }
      expect(File('$res/drawable-$d/splash_logo.png').existsSync(), isTrue, reason: 'splash $d');
    }
    expect(File('$res/values/colors.xml').readAsStringSync(), contains('#0C262B'));
    expect(File('$res/drawable/launch_background.xml').readAsStringSync(), contains('@drawable/splash_logo'));
    expect(File('$res/values-v31/styles.xml').readAsStringSync(), contains('windowSplashScreenAnimatedIcon'));
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:label="CricEco"'));
    expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher_round"'));
  });
}
