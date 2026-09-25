import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/demo_mode.dart';
import '../../app/theme/tokens.dart';
import 'ce_icons.dart';

/// Renders [child] only when Demo Mode is on. Every simulation control goes
/// through this gate (approved decision 2).
class DemoOnly extends ConsumerWidget {
  const DemoOnly({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(demoModeProvider) ? child : const SizedBox.shrink();
}

class DemoAction {
  const DemoAction(this.label, this.onPressed);
  final String label;
  final VoidCallback onPressed;
}

/// The one visual treatment for prototype controls: dashed amber frame,
/// flask icon, "Prototype controls" label, secondary-sized buttons. Never
/// styled like a production CTA. Hidden entirely when Demo Mode is off.
class DemoPanel extends StatelessWidget {
  const DemoPanel({super.key, required this.actions, this.title = 'Prototype controls', this.note, this.margin});

  final List<DemoAction> actions;
  final String title;
  final String? note;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return DemoOnly(
      child: Container(
        margin: margin ?? const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
        child: CustomPaint(
          painter: _DashedBorderPainter(),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: CeColors.demoBg, borderRadius: BorderRadius.circular(CeRadius.md)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(CeIcons.of('flask-conical'), size: 14, color: CeColors.amberInk),
                const SizedBox(width: 6),
                Text(title.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: CeColors.amberInk)),
              ]),
              if (note != null) ...[
                const SizedBox(height: 4),
                Text(note!, style: const TextStyle(fontSize: 11, color: CeColors.amberInk)),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final a in actions)
                  OutlinedButton(
                    onPressed: a.onPressed,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: CeColors.amberInk,
                      side: const BorderSide(color: CeColors.demoBorder),
                      minimumSize: const Size(0, CeSize.touchTarget),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.sm)),
                    ),
                    child: Text(a.label),
                  ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CeColors.demoBorder
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(CeRadius.md)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
