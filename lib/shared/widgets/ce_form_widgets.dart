import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import 'ce_icons.dart';
import 'ce_indicators.dart';

/// Step progress (`.progress-wrap`): 6 px track + "Step 2 of 3 — …" label.
class CeStepProgress extends StatelessWidget {
  const CeStepProgress({super.key, required this.value, required this.label});
  final double value;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(
            label: label,
            value: '${(value * 100).round()}%',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CeRadius.pill),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: value),
                duration: const Duration(milliseconds: 350),
                curve: const Cubic(.3, .8, .4, 1),
                builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 6),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: CeColors.muted)),
        ]),
      );
}

/// Circular photo / logo picker with camera badge (`Complete Profile`,
/// `Create Club`). Shows [initial] on a filled circle once a photo is set.
class CePhotoPicker extends StatelessWidget {
  const CePhotoPicker({
    super.key,
    required this.placeholderIcon,
    required this.caption,
    required this.onTap,
    this.hasPhoto = false,
    this.initial,
    this.semanticLabel = 'Choose photo',
  });

  final String placeholderIcon;
  final String caption;
  final VoidCallback onTap;
  final bool hasPhoto;
  final String? initial;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Semantics(
        button: true,
        label: semanticLabel,
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 84,
            height: 84,
            child: Stack(clipBehavior: Clip.none, children: [
              CustomPaint(
                foregroundPainter: hasPhoto ? null : _DashedCirclePainter(),
                child: Container(
                  width: 84,
                  height: 84,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hasPhoto ? CeColors.primary : CeColors.mint,
                  ),
                  child: hasPhoto && initial != null
                      ? Text(initial!,
                          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white))
                      : Icon(CeIcons.of(placeholderIcon), size: 30, color: hasPhoto ? Colors.white : CeColors.primaryDark),
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: CeColors.primaryDark,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Icon(CeIcons.of('camera'), size: 12, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(caption, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
    ]);
  }
}

class _DashedCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CeColors.muted2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rect = Offset.zero & size;
    const dashes = 36;
    const sweep = 2 * 3.1415926535 / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect.deflate(1), i * sweep, sweep * 0.55, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Wrapping group of selectable pills (`.role-pill-row`) with optional error.
class CeChoiceGroup<T> extends StatelessWidget {
  const CeChoiceGroup({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.iconOf,
  });

  final List<T> values;
  final T? selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;
  final String? Function(T)? iconOf;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final v in values)
            CeChip(label: labelOf(v), icon: iconOf?.call(v), selected: v == selected, onTap: () => onSelected(v)),
        ],
      );
}

/// "Already have an account? **Login**" (`.switch-line`).
class CeSwitchLine extends StatelessWidget {
  const CeSwitchLine({super.key, required this.prompt, required this.action, required this.onTap});
  final String prompt;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Flexible(child: Text('$prompt ', style: const TextStyle(fontSize: 13, color: CeColors.muted))),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
            child: Text(action,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.primaryDark)),
          ),
        ]),
      );
}
