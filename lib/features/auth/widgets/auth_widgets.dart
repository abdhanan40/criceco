import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/tokens.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';

enum AuthTab { login, signUp }

/// Green auth banner (`.banner`): logo circle, title, subtitle and the
/// optional Login / Sign Up toggle pill. Extends under the status bar.
class AuthBanner extends StatelessWidget {
  const AuthBanner({
    super.key,
    required this.title,
    required this.subtitle,
    this.activeTab,
    this.onTabSelected,
    this.bottomPadding = 22,
  });

  final String title;
  final String subtitle;
  final AuthTab? activeTab;
  final ValueChanged<AuthTab>? onTabSelected;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      // Always full-bleed, whether or not the toggle row stretches it.
      child: CeBrandHero(
        padding: EdgeInsets.fromLTRB(24, 34 + top, 24, bottomPadding),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 74,
              height: 74,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: Icon(CeIcons.of('circle-dot'), size: 30, color: CeColors.primaryDark),
            ),
          ),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.7, color: Colors.white)),
          const SizedBox(height: 4),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.78))),
          if (activeTab != null) ...[
            const SizedBox(height: 20),
            _TogglePill(active: activeTab!, onSelected: onTabSelected ?? (_) {}),
          ],
        ]),
      ),
    );
  }
}

class _TogglePill extends StatelessWidget {
  const _TogglePill({required this.active, required this.onSelected});
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
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(CeRadius.pill),
                boxShadow: isActive ? CeShadows.card : null,
              ),
              child: Text(label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: isActive ? CeColors.primaryDark : CeColors.muted,
                  )),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.pill)),
      child: Row(children: [tab(AuthTab.login, 'Login'), const SizedBox(width: 4), tab(AuthTab.signUp, 'Sign Up')]),
    );
  }
}

/// Auth body heading (`.auth-body h3` + `p.sub`, `.center-block`).
class AuthHeading extends StatelessWidget {
  const AuthHeading({super.key, required this.title, required this.subtitle, this.center = false});
  final String title;
  final String subtitle;
  final bool center;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Text(title,
              textAlign: center ? TextAlign.center : TextAlign.start,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.57, height: 1.2)),
          const SizedBox(height: 4),
          Text(subtitle,
              textAlign: center ? TextAlign.center : TextAlign.start,
              style: const TextStyle(fontSize: 13, color: CeColors.muted, height: 1.55)),
        ],
      );
}

/// Centered icon circle + heading (`.center-block`).
class CenterBlock extends StatelessWidget {
  const CenterBlock({super.key, required this.icon, required this.title, required this.subtitle});
  final String icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(children: [
          CeIconWell(icon, size: 72, iconSize: 30, circle: true),
          const SizedBox(height: 12),
          AuthHeading(title: title, subtitle: subtitle, center: true),
        ]),
      );
}

/// "— OR —" divider (`.auth-divider`).
class AuthDivider extends StatelessWidget {
  const AuthDivider({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Row(children: [
          Expanded(child: Divider(color: CeColors.line)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text('OR', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.muted2)),
          ),
          Expanded(child: Divider(color: CeColors.line)),
        ]),
      );
}

/// "Continue with Google" (`.btn-google`) with the four-colour G mark.
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
            borderRadius: BorderRadius.circular(CeRadius.md),
            side: const BorderSide(color: CeColors.line2),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.md),
            onTap: loading ? null : onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: CeSize.buttonMinHeight),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: CeColors.ink))
                    : const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(width: 18, height: 18, child: CustomPaint(painter: _GoogleGPainter())),
                          SizedBox(width: 10),
                          Flexible(
                            child: Text('Continue with Google',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: CeColors.ink)),
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
