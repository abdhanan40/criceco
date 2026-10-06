import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../shared/widgets/ce_brand_logo.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';

enum AuthTab { login, signUp }

/// Auth header (reference `isAuth` header): the floodlit stadium photo under
/// a deep-teal wash, the CricEco logo tile, a Sora title and subtitle,
/// left-aligned. Extends under the status bar. The page body follows in an
/// [AuthPanel] that overlaps the header's bottom edge.
///
/// Setup screens (Create Account, Profile Setup, Role Selection) hide the
/// logo ([showLogo]) and carry a Back button ([onBack]) and/or a [trailing]
/// action on a 40 px glass row above the title.
class AuthBanner extends StatelessWidget {
  const AuthBanner({
    super.key,
    required this.title,
    required this.subtitle,
    this.bottomPadding = AuthPanel.overlap + 30,
    this.stadiumPhoto = false,
    this.onBack,
    this.trailing,
    this.showLogo = true,
  });

  /// The floodlit stadium photo (same asset as the splash) behind the banner.
  static const photo = 'assets/branding/splash_stadium.png';

  final String title;
  final String subtitle;
  final double bottomPadding;
  final bool stadiumPhoto;
  final bool showLogo;

  /// Shows a Back button on the banner (screens without a top bar).
  final VoidCallback? onBack;

  /// A header action on the right of the Back row (e.g. Log out).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final hasRow = onBack != null || trailing != null;
    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (hasRow) ...[
        Row(children: [
          if (onBack != null) AuthGlassButton(tooltip: 'Back', icon: 'arrow-left', onPressed: onBack!),
          const Spacer(),
          ?trailing,
        ]),
        const SizedBox(height: 18),
      ],
      if (showLogo) ...[
        // Approved CricEco logo tile.
        const CeBrandLogo(size: 64, onDark: true),
        const SizedBox(height: 22),
      ],
      Text(title,
          style: (hasRow ? CeType.pageTitleLarge : CeType.displayLarge).copyWith(color: Colors.white, letterSpacing: -0.5)),
      const SizedBox(height: 6),
      Text(subtitle, style: CeType.body.copyWith(fontSize: 13.5, color: Colors.white.withValues(alpha: 0.85))),
    ]);
    final padding = EdgeInsets.fromLTRB(CeSpace.form, (hasRow ? 12 : 28) + top, CeSpace.form, bottomPadding);
    final banner = AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: stadiumPhoto
          ? Stack(key: const Key('auth.stadiumBanner'), clipBehavior: Clip.hardEdge, children: [
              const Positioned.fill(child: ColoredBox(color: CeColors.paletteDeep)),
              Positioned.fill(
                child: Image.asset(
                  photo,
                  fit: BoxFit.cover,
                  // Keep the floodlights and the stumps in frame.
                  alignment: const Alignment(0, -0.3),
                  filterQuality: FilterQuality.medium,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
              // Reference wash: 50% → 18% → 70% deep teal.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        CeColors.paletteDeep.withValues(alpha: 0.55),
                        CeColors.paletteDeep.withValues(alpha: 0.25),
                        CeColors.paletteDeep.withValues(alpha: 0.85),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
              const Positioned(right: -70, top: -40, child: _Ring(size: 220, alpha: 0.18)),
              const Positioned(right: -30, top: 0, child: _Ring(size: 140, alpha: 0.14)),
              Padding(
                padding: padding,
                child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: content),
              ),
            ])
          : CeBrandHero(padding: padding, child: content),
    );
    return banner;
  }
}

/// Decorative sage ring on the auth header.
class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.alpha});
  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: CeColors.sage.withValues(alpha: alpha), width: 1.5),
          ),
        ),
      );
}

/// 40 px glass button on the dark header (Back, Log out).
class AuthGlassButton extends StatelessWidget {
  const AuthGlassButton({super.key, required this.tooltip, required this.icon, required this.onPressed});
  final String tooltip;
  final String icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: CeSize.backButton, height: CeSize.backButton),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: CeColors.sage.withValues(alpha: 0.16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.md)),
        ),
        icon: Icon(CeIcons.of(icon), size: 18, color: Colors.white),
      );
}

/// The light page body that overlaps the auth header (reference: `-32px`
/// top margin, 28 px top corners, #F3F7F5). Children are stacked with the
/// reference 18 px rhythm left to each screen.
class AuthPanel extends StatelessWidget {
  const AuthPanel({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(CeSpace.form, 24, CeSpace.form, 28)});

  /// How far the panel rides up over the header.
  static const double overlap = 32;

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Transform.translate(
        offset: const Offset(0, -overlap),
        child: Container(
          decoration: const BoxDecoration(
            color: CeColors.bg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(CeRadius.sheet)),
          ),
          padding: padding,
          child: child,
        ),
      );
}

/// Log in / Sign up segmented control (reference: mint track, radius 14,
/// 40 px tabs, the active one white with a soft shadow).
class AuthTabs extends StatelessWidget {
  const AuthTabs({super.key, required this.active, required this.onSelected});
  final AuthTab active;
  final ValueChanged<AuthTab> onSelected;

  @override
  Widget build(BuildContext context) {
    Widget tab(AuthTab t, String label) {
      final isActive = t == active;
      return Expanded(
        child: Semantics(
          selected: isActive,
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: isActive ? null : () => onSelected(t),
            child: AnimatedContainer(
              duration: CeMotion.base,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(CeRadius.tab),
                boxShadow: isActive ? CeShadows.control : null,
              ),
              child: Text(label,
                  style: CeType.listTitle.copyWith(color: isActive ? CeColors.ink : CeColors.muted)),
            ),
          ),
        ),
      );
    }

    return Container(
      key: const Key('auth.tabs'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.input)),
      child: Row(children: [tab(AuthTab.login, 'Login'), tab(AuthTab.signUp, 'Sign Up')]),
    );
  }
}

/// Auth body heading (reference: Sora 22 title + Manrope 14 muted line).
class AuthHeading extends StatelessWidget {
  const AuthHeading({super.key, required this.title, required this.subtitle, this.center = false, this.large = false});
  final String title;
  final String subtitle;
  final bool center;

  /// Setup screens: Sora 24 (auth tabs use 22).
  final bool large;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Text(title,
              textAlign: center ? TextAlign.center : TextAlign.start,
              style: large ? CeType.pageTitleLarge : CeType.pageTitleLarge.copyWith(fontSize: 22)),
          const SizedBox(height: 6),
          Text(subtitle,
              textAlign: center ? TextAlign.center : TextAlign.start,
              style: CeType.body.copyWith(fontSize: 14, color: CeColors.muted)),
        ],
      );
}

/// Centered icon circle + heading (`.center-block`).
class CenterBlock extends StatelessWidget {
  const CenterBlock({super.key, required this.icon, required this.title, required this.subtitle})
      : brand = false;

  /// Brand intro (e.g. "Join Criceco"): the approved logo instead of an icon.
  const CenterBlock.brand({super.key, required this.title, required this.subtitle})
      : icon = '',
        brand = true;

  final String icon;
  final String title;
  final String subtitle;
  final bool brand;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(children: [
          if (brand) const CeBrandLogo(size: 72) else CeIconWell(icon, size: 72, iconSize: 30, circle: true),
          const SizedBox(height: 12),
          AuthHeading(title: title, subtitle: subtitle, center: true),
        ]),
      );
}

/// "— or —" divider (reference: 1 px #D5E3DA rules, Manrope 12/600 muted).
class AuthDivider extends StatelessWidget {
  const AuthDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(children: [
          const Expanded(child: Divider(height: 1, thickness: 1, color: CeColors.line2)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('or', style: CeType.caption.copyWith(fontSize: 12)),
          ),
          const Expanded(child: Divider(height: 1, thickness: 1, color: CeColors.line2)),
        ]),
      );
}

/// "Continue with Google" (reference: 52 px, radius 16, 1.5 px #D5E3DA
/// border, Manrope 14 Bold) with the four-colour G mark.
class GoogleButton extends StatelessWidget {
  const GoogleButton({super.key, required this.onPressed, this.loading = false});
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Continue with Google',
        excludeSemantics: true,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.button),
            side: const BorderSide(color: CeColors.line2, width: 1.5),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.button),
            onTap: loading ? null : onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: CeSize.inputMinHeight),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: CeColors.ink))
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const SizedBox(width: 18, height: 18, child: CustomPaint(painter: _GoogleGPainter())),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text('Continue with Google',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: CeType.listTitle),
                          ),
                        ]),
                      ),
              ),
            ),
          ),
        ),
      );
}

class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.2;
    final rect = Rect.fromCircle(center: Offset(s / 2, s / 2), radius: (s - stroke) / 2);
    Paint p(int color) => Paint()
      ..color = Color(color)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const deg = math.pi / 180;
    canvas.drawArc(rect, -40 * deg, -100 * deg, false, p(0xFFEA4335)); // red (top)
    canvas.drawArc(rect, -140 * deg, -80 * deg, false, p(0xFFFBBC05)); // yellow (left)
    canvas.drawArc(rect, -220 * deg, -95 * deg, false, p(0xFF34A853)); // green (bottom)
    canvas.drawArc(rect, 45 * deg, -45 * deg, false, p(0xFF4285F4)); // blue (right)
    canvas.drawRect(Rect.fromLTWH(s / 2, s / 2 - stroke / 2, s / 2 - stroke / 4, stroke), Paint()..color = const Color(0xFF4285F4));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
