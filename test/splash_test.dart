import 'dart:io';

import 'package:criceco/app/app.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/splash/criceco_splash.dart';
import 'package:criceco/app/theme/app_theme.dart';
import 'package:criceco/shared/widgets/ce_brand_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The photo is decoded asynchronously; under the test clock the splash starts
/// on its fallback timer (900 ms) and paints the brand gradient instead.
const _fallbackStart = Duration(milliseconds: 900);

Future<void> _pumpSplash(
  WidgetTester tester, {
  double width = 390,
  double height = 844,
  bool reduceMotion = false,
  VoidCallback? onDone,
}) async {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, height), disableAnimations: reduceMotion),
      child: CricEcoSplash(onDone: onDone ?? () {}),
    ),
  ));
  await tester.pump(_fallbackStart);
}

/// Advances the splash timeline to [ms] after it started.
Future<void> _at(WidgetTester tester, int ms, {int from = 0}) => tester.pump(Duration(milliseconds: ms - from));

void main() {
  test('the stadium photo is bundled and declared', () {
    expect(File(CricEcoSplash.asset).existsSync(), isTrue);
    expect(File('pubspec.yaml').readAsStringSync(), contains(CricEcoSplash.asset));
  });

  testWidgets('timeline: hit first, then the glass card with logo, name and tagline; done in ~4.2 s', (tester) async {
    var done = 0;
    await _pumpSplash(tester, onDone: () => done++);
    expect(CricEcoSplash.duration, const Duration(milliseconds: 4200), reason: 'within 3–5 s');

    // Before / around the hit: no card yet.
    await _at(tester, 1500);
    expect(find.byKey(const Key('splash.card')), findsNothing);

    // After the hit the card arrives, then its contents.
    await _at(tester, 3400, from: 1500);
    expect(find.byKey(const Key('splash.card')), findsOneWidget);
    expect(find.text('CricEco'), findsOneWidget);
    for (final w in ['PLAY', 'CONNECT', 'GROW']) {
      expect(find.text(w), findsOneWidget, reason: w);
    }
    expect(find.byType(CeBrandLogo), findsOneWidget, reason: 'the approved logo');
    expect(done, 0);

    await _at(tester, 4300, from: 3400);
    expect(done, 1, reason: 'faded out and handed over once');
    await tester.pump(const Duration(seconds: 1));
    expect(done, 1);
  });

  testWidgets('tap anywhere skips', (tester) async {
    var done = 0;
    await _pumpSplash(tester, onDone: () => done++);
    await _at(tester, 600);
    await tester.tap(find.byType(CricEcoSplash));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(done, 1);
  });

  testWidgets('reduced motion: no ball or debris — the card, then out', (tester) async {
    var done = 0;
    await _pumpSplash(tester, reduceMotion: true, onDone: () => done++);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('CricEco'), findsOneWidget, reason: 'straight to the card');
    await tester.pump(const Duration(milliseconds: 1500));
    expect(done, 1);
  });

  testWidgets('the app shows the splash over the first screen only when asked (real launch)', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp(showSplash: true)));
    await tester.pump();
    expect(find.byType(CricEcoSplash), findsOneWidget);
    await tester.pump(_fallbackStart);
    await tester.pump(const Duration(milliseconds: 4400));
    await tester.pumpAndSettle();
    expect(find.byType(CricEcoSplash), findsNothing, reason: 'gone after the animation');
    expect(find.text('Login'), findsWidgets, reason: 'the first screen underneath');

    // Default (tests, previews): no splash.
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const CricEcoApp()));
    await tester.pumpAndSettle();
    expect(find.byType(CricEcoSplash), findsNothing);
  });

  for (final width in [320.0, 360.0, 375.0, 390.0, 414.0]) {
    testWidgets('fits at ${width.toInt()} px (portrait) through the whole timeline', (tester) async {
      await _pumpSplash(tester, width: width, height: width < 360 ? 568 : 800);
      var at = 0;
      for (final ms in [400, 1200, 1700, 2200, 2800, 3400, 4000]) {
        await _at(tester, ms, from: at);
        at = ms;
        expect(tester.takeException(), isNull, reason: '$ms ms @ $width');
      }
    });
  }
}
