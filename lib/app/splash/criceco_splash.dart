import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/widgets/ce_brand_logo.dart';
import '../theme/tokens.dart';

/// Launch animation (≈4.2 s, portrait): a hard cricket ball drops in from the
/// top and hits the stumps *in the stadium photo*; the photo's own bails and
/// stumps scatter (they are cut out of the image — nothing is drawn on top),
/// then a frosted-glass card brings in the CricEco logo, name and
/// "Play · Connect · Grow". Tap anywhere to skip. Respects reduced motion.
class CricEcoSplash extends StatefulWidget {
  const CricEcoSplash({super.key, required this.onDone});

  /// Called once, when the splash has faded out.
  final VoidCallback onDone;

  static const asset = 'assets/branding/splash_stadium.png';
  static const duration = Duration(milliseconds: 4200);

  @override
  State<CricEcoSplash> createState() => _CricEcoSplashState();
}

/// Timeline, as fractions of [CricEcoSplash.duration].
abstract final class _T {
  static const bgIn = 0.10;
  static const ballStart = 0.10;
  static const hit = 0.38; // ≈1.6 s
  static const debrisEnd = 0.84;
  static const dimStart = 0.46;
  static const dimEnd = 0.62;
  static const cardStart = 0.52;
  static const cardEnd = 0.66;
  static const exitStart = 0.93;
}

class _CricEcoSplashState extends State<CricEcoSplash> with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: CricEcoSplash.duration);
  late final AnimationController _skip =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  ui.Image? _image;
  ui.Image? _clean;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Timer? _startFallback;
  bool _started = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    _skip.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    _listener = ImageStreamListener(
      (info, _) {
        // May fire synchronously (cached): act after the first frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _image = info.image);
          _start();
          _StadiumPainter.cleanPlate(info.image).then((plate) {
            if (mounted) {
              setState(() => _clean = plate);
            } else {
              plate.dispose();
            }
          });
        });
      },
      onError: (_, _) => _finish(), // no photo → no splash; go straight in
    );
    _stream = const AssetImage(CricEcoSplash.asset).resolve(ImageConfiguration.empty)..addListener(_listener!);
    // Never hold the app back on a slow decode.
    _startFallback = Timer(const Duration(milliseconds: 900), _start);
  }

  void _start() {
    if (_started || !mounted) return;
    _started = true;
    _startFallback?.cancel();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      // Reduced motion: no ball or debris — just the card, then fade.
      _c.value = 0.80;
      _c.animateTo(1, duration: const Duration(milliseconds: 1400), curve: Curves.linear);
    } else {
      _c.forward();
    }
  }

  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onDone();
  }

  @override
  void dispose() {
    _startFallback?.cancel();
    if (_listener != null) _stream?.removeListener(_listener!);
    _clean?.dispose();
    _c.dispose();
    _skip.dispose();
    super.dispose();
  }

  static double _seg(double t, double a, double b, [Curve curve = Curves.linear]) =>
      curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Semantics(
        container: true,
        label: 'CricEco. Play, Connect, Grow.',
        onTapHint: 'Skip',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (!_finished && !_skip.isAnimating) _skip.forward();
          },
          child: ExcludeSemantics(
            child: AnimatedBuilder(
              animation: Listenable.merge([_c, _skip]),
              builder: (context, _) {
                final t = _c.value;
                final exit = 1 - _seg(t, _T.exitStart, 1, Curves.easeIn);
                return Opacity(
                  opacity: (exit * (1 - _skip.value)).clamp(0.0, 1.0),
                  child: LayoutBuilder(builder: (context, box) {
                    final size = box.biggest;
                    // Above the Navigator, so it brings its own Material (text style).
                    return Material(
                      type: MaterialType.transparency,
                      child: Stack(fit: StackFit.expand, children: [
                        const ColoredBox(color: Color(0xFF0C262B)), // = native launch colour
                        CustomPaint(painter: _StadiumPainter(image: _image, clean: _clean, t: t), size: size),
                        _GlassCard(t: t, size: size),
                      ]),
                    );
                  }),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The photo, the ball, the impact and the scattering pieces.
class _StadiumPainter extends CustomPainter {
  _StadiumPainter({required this.image, required this.clean, required this.t});
  final ui.Image? image;

  /// [image] without its stumps and bails ([cleanPlate]); `null` until built.
  final ui.Image? clean;
  final double t;

  // ---- Source photo geometry (assets/branding/splash_stadium.png, 781 × 441) ----
  static const _img = Size(781, 441);
  static const _bails = [Rect.fromLTRB(374.5, 265.5, 388, 276.5), Rect.fromLTRB(387, 265.5, 401.5, 276.5)];
  static const _stumps = [
    Rect.fromLTRB(372.8, 276.5, 379.2, 368.5),
    Rect.fromLTRB(383.8, 276.5, 390.2, 368.5),
    Rect.fromLTRB(395.6, 276.5, 402.2, 368.5),
  ];

  /// The "clean plate" shown after the hit: where each stump and the bails
  /// stood is painted over with the photo's own background right beside it —
  /// (destination, source) in whole photo pixels, so the strips butt up with
  /// no filtering seams. Neighbouring strips keep the crowd tiers, boards,
  /// pitch and crease lines continuous.
  static const _erase = [
    (Rect.fromLTRB(372, 262, 380, 371), Rect.fromLTRB(364, 262, 372, 371)), // left stump: from its left
    (Rect.fromLTRB(383, 262, 391, 371), Rect.fromLTRB(380, 262, 383, 371)), // middle: the clean gap, widened
    (Rect.fromLTRB(395, 262, 403, 371), Rect.fromLTRB(403, 262, 411, 371)), // right stump: from its right
    (Rect.fromLTRB(372, 262, 403, 279), Rect.fromLTRB(341, 262, 372, 279)), // bails: same rows, from the left
  ];

  /// Builds the clean plate once, at the photo's native size.
  static Future<ui.Image> cleanPlate(ui.Image photo) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..filterQuality = FilterQuality.none;
    canvas.drawImage(photo, Offset.zero, paint);
    for (final (dst, src) in _erase) {
      canvas.drawImageRect(photo, src, dst, paint);
    }
    return recorder.endRecording().toImage(photo.width, photo.height);
  }
  static const _impact = Offset(388, 273); // bails / top of the middle stump

  static double _seg(double t, double a, double b, [Curve curve = Curves.linear]) =>
      curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.max(size.width / _img.width, size.height / _img.height);
    final origin = Offset((size.width - _img.width * scale) / 2, (size.height - _img.height * scale) / 2);
    Offset p(Offset o) => origin + o * scale;
    Rect r(Rect o) => Rect.fromPoints(p(o.topLeft), p(o.bottomRight));
    final impact = p(_impact);
    final stumpH = (_stumps[1].height) * scale;
    final secs = (t - _T.hit) * CricEcoSplash.duration.inMilliseconds / 1000; // time since the hit
    final hit = t >= _T.hit;

    // ---- Camera: slow push-in, then a short shake on impact ----
    final zoom = 1.07 - 0.07 * _seg(t, 0, _T.hit, Curves.easeOutCubic);
    var shake = Offset.zero;
    if (hit && secs < 0.45) {
      final decay = math.exp(-secs * 9);
      shake = Offset(math.sin(secs * 95) * 7 * decay, math.cos(secs * 80) * 5 * decay);
    }
    canvas.save();
    canvas.translate(impact.dx + shake.dx, impact.dy + shake.dy);
    canvas.scale(zoom);
    canvas.translate(-impact.dx, -impact.dy);

    final bgOpacity = _seg(t, 0, _T.bgIn, Curves.easeOut);
    final imagePaint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(255, 255, 255, bgOpacity);
    final img = image;
    if (img != null) {
      // Before the hit: the untouched photo. After: the clean plate, with the
      // photo's own stumps and bails flying over it.
      final plate = hit ? (clean ?? img) : img;
      canvas.drawImageRect(plate, Offset.zero & _img, r(Offset.zero & _img), imagePaint);
      if (hit) {
        if (clean == null) {
          for (final (dst, src) in _erase) {
            canvas.drawImageRect(img, src, r(dst), imagePaint);
          }
        }
        _drawDebris(canvas, img, p, r, secs, stumpH, imagePaint);
      }
    } else {
      // Photo still decoding: the brand gradient keeps the frame alive.
      canvas.drawRect(Offset.zero & size, Paint()..shader = CeColors.brandGradient.createShader(Offset.zero & size));
    }

    if (hit) _drawImpact(canvas, impact, secs, stumpH);
    _drawBall(canvas, size, impact, stumpH, secs);
    canvas.restore();

    // ---- Dim + vignette so the glass card reads ----
    final dim = _seg(t, _T.dimStart, _T.dimEnd, Curves.easeInOut);
    if (dim > 0) {
      final rect = Offset.zero & size;
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, -0.25),
            radius: 1.1,
            colors: [Colors.black.withValues(alpha: 0.18 * dim), Colors.black.withValues(alpha: 0.62 * dim)],
          ).createShader(rect),
      );
    }
  }

  /// One cut-out piece of the photo, moved / rotated / scaled about [pivot].
  void _piece(
    Canvas canvas,
    ui.Image img,
    Rect src,
    Rect dst,
    Offset pivot, {
    Offset shift = Offset.zero,
    double angle = 0,
    double scale = 1,
    double opacity = 1,
    required Paint imagePaint,
  }) {
    if (opacity <= 0) return;
    canvas.save();
    canvas.translate(pivot.dx + shift.dx, pivot.dy + shift.dy);
    canvas.rotate(angle);
    canvas.scale(scale);
    canvas.translate(-pivot.dx, -pivot.dy);
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = imagePaint.color.withValues(alpha: imagePaint.color.a * opacity);
    canvas.drawImageRect(img, src, dst, paint);
    canvas.restore();
  }

  void _drawDebris(
    Canvas canvas,
    ui.Image img,
    Offset Function(Offset) p,
    Rect Function(Rect) r,
    double s,
    double h,
    Paint imagePaint,
  ) {
    final fade = 1 - _seg(t, _T.debrisEnd - 0.12, _T.debrisEnd, Curves.easeIn);
    Offset ballistic(Offset v, double g) => Offset(v.dx * s, v.dy * s + 0.5 * g * s * s);

    // Bails: flicked up and out, spinning.
    for (final (i, bail) in _bails.indexed) {
      final dir = i == 0 ? -1.0 : 1.0;
      _piece(canvas, img, bail, r(bail), r(bail).center,
          shift: ballistic(Offset(dir * (1.0 + 0.3 * i) * h, -(2.5 + 0.35 * i) * h), 7 * h),
          angle: dir * s * (9 + 3 * i),
          opacity: fade,
          imagePaint: imagePaint);
    }

    // Stumps pivot on their base: the middle one is ripped out and cartwheels
    // back, the outer two splay.
    final splay = Curves.easeOutBack.transform((s / 0.42).clamp(0.0, 1.0));
    for (final (i, stump) in _stumps.indexed) {
      final dst = r(stump);
      final base = Offset(dst.center.dx, dst.bottom);
      switch (i) {
        case 1:
          _piece(canvas, img, stump, dst, base,
              shift: ballistic(Offset(0.5 * h, -2.3 * h), 3.0 * h),
              angle: s * 4.2,
              scale: 1 - 0.5 * Curves.easeOut.transform((s / 1.1).clamp(0.0, 1.0)),
              opacity: 1 - ((s - 0.7) / 0.45).clamp(0.0, 1.0),
              imagePaint: imagePaint);
        case 0:
          _piece(canvas, img, stump, dst, base,
              shift: Offset(-0.06 * h * splay, 0), angle: -0.5 * splay, imagePaint: imagePaint);
        default:
          _piece(canvas, img, stump, dst, base,
              shift: Offset(0.08 * h * splay, 0), angle: 0.72 * splay, imagePaint: imagePaint);
      }
    }
  }

  void _drawImpact(Canvas canvas, Offset at, double s, double h) {
    // Flash.
    final flash = (1 - s / 0.38).clamp(0.0, 1.0);
    if (flash > 0) {
      final radius = h * (0.25 + 1.1 * (1 - flash));
      canvas.drawCircle(
        at,
        radius,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.95 * flash),
            const Color(0xFFFFD27A).withValues(alpha: 0.55 * flash),
            Colors.transparent,
          ], stops: const [0, 0.35, 1])
              .createShader(Rect.fromCircle(center: at, radius: radius)),
      );
    }
    // Shockwave.
    final ring = (s / 0.45).clamp(0.0, 1.0);
    if (ring < 1) {
      canvas.drawCircle(
        at,
        h * (0.15 + 1.05 * Curves.easeOutCubic.transform(ring)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6 * (1 - ring) + 0.3
          ..color = Colors.white.withValues(alpha: 0.42 * (1 - ring)),
      );
    }
    // Splinters and pitch dust.
    final rnd = math.Random(7);
    for (var i = 0; i < 28; i++) {
      final dust = i >= 16;
      final angle = dust ? -math.pi * (0.1 + 0.8 * rnd.nextDouble()) : -math.pi * rnd.nextDouble() * 1.05;
      final speed = h * (dust ? 0.5 + rnd.nextDouble() * 0.7 : 0.9 + rnd.nextDouble() * 1.6);
      final life = 0.55 + rnd.nextDouble() * 0.5;
      final size = dust ? 1.6 + rnd.nextDouble() * 2.4 : 1.2 + rnd.nextDouble() * 1.8;
      final k = (s / life).clamp(0.0, 1.0);
      if (k >= 1) continue;
      final origin = dust ? at + Offset((rnd.nextDouble() - 0.5) * 0.3 * h, 0.95 * h) : at;
      final pos = origin +
          Offset(math.cos(angle) * speed * s, math.sin(angle) * speed * s + 0.5 * 3.2 * h * s * s);
      canvas.drawCircle(
        pos,
        size * (1 - 0.4 * k),
        Paint()
          ..color = (dust ? const Color(0xFFE6CF9E) : const Color(0xFFFFE6A8)).withValues(alpha: (1 - k) * 0.95),
      );
    }
  }

  void _drawBall(Canvas canvas, Size size, Offset impact, double h, double s) {
    final rEnd = math.max(5.0, 0.105 * h); // a ball is ~1/10 of a stump
    if (t < _T.ballStart) return;
    if (t < _T.hit) {
      // Incoming: drops from the top on a gentle curve, accelerating and
      // shrinking into the frame (depth), leaving a short motion trail.
      final start = Offset(impact.dx + size.width * 0.38, -size.height * 0.04);
      final control = Offset(impact.dx + size.width * 0.30, impact.dy - size.height * 0.48);
      Offset at(double u) {
        final a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u;
        return Offset(a * start.dx + b * control.dx + c * impact.dx, a * start.dy + b * control.dy + c * impact.dy);
      }

      double radius(double u) => ui.lerpDouble(size.width * 0.085, rEnd, u)!;
      final u = _seg(t, _T.ballStart, _T.hit, Curves.easeIn);
      for (var i = 5; i >= 1; i--) {
        final ut = (u - i * 0.035).clamp(0.0, 1.0);
        canvas.drawCircle(
          at(ut),
          radius(ut) * (1 - i * 0.07),
          Paint()..color = const Color(0xFFB3191C).withValues(alpha: 0.10 * (6 - i) / 5 * u),
        );
      }
      _ball(canvas, at(u), radius(u), u * 9 * math.pi, 1);
    } else {
      // Deflects off the stumps and drops away.
      final k = (s / 0.5).clamp(0.0, 1.0);
      if (k >= 1) return;
      final pos = impact + Offset(-0.55 * h * s * 2, -0.6 * h * s * 2 + 4.0 * h * s * s);
      _ball(canvas, pos, rEnd * (1 - 0.3 * k), 9 * math.pi + s * 30, 1 - k);
    }
  }

  /// A red leather ball with a stitched seam and a specular highlight.
  void _ball(Canvas canvas, Offset c, double radius, double spin, double opacity) {
    final rect = Rect.fromCircle(center: c, radius: radius);
    canvas.drawCircle(
      c + Offset(radius * 0.12, radius * 0.18),
      radius * 1.04,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35 * opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.35),
    );
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.05,
          colors: [
            const Color(0xFFE5483B).withValues(alpha: opacity),
            const Color(0xFFA9181B).withValues(alpha: opacity),
            const Color(0xFF4E080A).withValues(alpha: opacity),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
    // Seam (rotates with the spin), clipped to the ball.
    canvas.save();
    canvas.clipPath(Path()..addOval(rect));
    canvas.translate(c.dx, c.dy);
    canvas.rotate(spin);
    final seamRect = Rect.fromCenter(center: Offset.zero, width: radius * 2.1, height: radius * 0.55);
    final seam = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, radius * 0.09)
      ..color = const Color(0xFFF4E3CC).withValues(alpha: 0.85 * opacity);
    canvas.drawArc(seamRect, math.pi * 0.05, math.pi * 0.9, false, seam);
    final stitch = Paint()
      ..strokeWidth = math.max(0.6, radius * 0.05)
      ..color = const Color(0xFFF4E3CC).withValues(alpha: 0.7 * opacity);
    for (var i = 1; i < 8; i++) {
      final a = math.pi * (0.05 + 0.9 * i / 8);
      final pt = Offset(math.cos(a) * seamRect.width / 2, math.sin(a) * seamRect.height / 2);
      canvas.drawLine(pt + Offset(0, -radius * 0.1), pt + Offset(0, radius * 0.1), stitch);
    }
    canvas.restore();
    // Specular highlight.
    canvas.drawCircle(
      c + Offset(-radius * 0.38, -radius * 0.42),
      radius * 0.32,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.75 * opacity),
          Colors.white.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: c + Offset(-radius * 0.38, -radius * 0.42), radius: radius * 0.32)),
    );
  }

  @override
  bool shouldRepaint(_StadiumPainter old) => old.t != t || old.image != image || old.clean != clean;
}

/// Frosted-glass card: logo, "CricEco", "Play · Connect · Grow".
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.t, required this.size});
  final double t;
  final Size size;

  static double _seg(double t, double a, double b, [Curve curve = Curves.easeOutCubic]) =>
      curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  Widget _reveal(double a, double b, Widget child, {double dy = 10}) {
    final v = _seg(t, a, b);
    return Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, dy * (1 - v)), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final card = _seg(t, _T.cardStart, _T.cardEnd);
    if (card <= 0) return const SizedBox.shrink();
    final width = math.min(size.width - 48, 340.0);
    final words = ['PLAY', 'CONNECT', 'GROW'];
    return Align(
      alignment: const Alignment(0, -0.34),
      child: Opacity(
        opacity: card,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - card)),
          child: Transform.scale(
            scale: 0.92 + 0.08 * card,
            child: Container(
              key: const Key('splash.card'),
              width: width,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 34, offset: const Offset(0, 14))],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 16 * card, sigmaY: 16 * card),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.2),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Colors.white.withValues(alpha: 0.20), Colors.white.withValues(alpha: 0.06)],
                      ),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      _reveal(0.55, 0.68, const CeBrandLogo(size: 68, onDark: true), dy: 14),
                      const SizedBox(height: 14),
                      _reveal(
                        0.60,
                        0.72,
                        const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('CricEco',
                              style: TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.8,
                                  height: 1.05,
                                  color: Colors.white,
                                  shadows: [Shadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 3))])),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _reveal(
                        0.63,
                        0.74,
                        Container(
                          width: 46,
                          height: 3,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            gradient: const LinearGradient(colors: [Color(0xFFFFD27A), CeColors.primary]),
                          ),
                        ),
                        dy: 0,
                      ),
                      const SizedBox(height: 12),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          for (final (i, w) in words.indexed) ...[
                            if (i > 0)
                              _reveal(
                                0.66 + i * 0.04,
                                0.74 + i * 0.04,
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 9),
                                  child: Text('•', style: TextStyle(fontSize: 12, color: Color(0xFFFFD27A))),
                                ),
                                dy: 0,
                              ),
                            _reveal(
                              0.66 + i * 0.04,
                              0.76 + i * 0.04,
                              Text(w,
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 3,
                                      color: Colors.white.withValues(alpha: 0.9))),
                              dy: 6,
                            ),
                          ],
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [CricEcoSplash] over the app on launch, then gets out of the way.
/// Wraps the router's content (no route of its own).
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child});
  final Widget child;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        ExcludeSemantics(excluding: !_done, child: widget.child),
        if (!_done) Positioned.fill(child: CricEcoSplash(onDone: () => setState(() => _done = true))),
      ]);
}
