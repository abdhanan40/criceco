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
    expect((img.width, img.height, img.fit), (64.0, 64.0, BoxFit.contain));
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

  test('Android launcher: adaptive icon + legacy mipmaps; plain launch window before the animated splash', () {
    const res = 'android/app/src/main/res';
    final adaptive = File('$res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
    expect(adaptive, contains('@mipmap/ic_launcher_foreground'));
    expect(adaptive, contains('@color/ic_launcher_background'));
    expect(File('$res/mipmap-anydpi-v26/ic_launcher_round.xml').existsSync(), isTrue);
    for (final d in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      for (final f in ['ic_launcher', 'ic_launcher_round', 'ic_launcher_foreground', 'ic_launcher_monochrome']) {
        expect(File('$res/mipmap-$d/$f.png').existsSync(), isTrue, reason: '$d/$f');
      }
    }
    expect(File('$res/values/colors.xml').readAsStringSync(), contains('#0C262B'));
    // No logo screen before the Flutter splash: the native window is just the
    // splash colour the animation starts from (Android 12+: an empty icon).
    for (final f in ['drawable/launch_background.xml', 'drawable-v21/launch_background.xml']) {
      final xml = File('$res/$f').readAsStringSync();
      expect(xml, contains('@color/splash_background'), reason: f);
      expect(xml, isNot(contains('bitmap')), reason: f);
    }
    for (final f in ['values-v31/styles.xml', 'values-night-v31/styles.xml']) {
      final xml = File('$res/$f').readAsStringSync();
      expect(xml, contains('windowSplashScreenAnimatedIcon">@drawable/splash_transparent'), reason: f);
      expect(xml, contains('windowSplashScreenBackground">@color/splash_background'), reason: f);
    }
    expect(File('ios/Runner/Base.lproj/LaunchScreen.storyboard').readAsStringSync(),
        contains('red="0.047058823529411764" green="0.14901960784313725" blue="0.16862745098039217"'));
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:label="CricEco"'));
    expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher_round"'));
  });
}
