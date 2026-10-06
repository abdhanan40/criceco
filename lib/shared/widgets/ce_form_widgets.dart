import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../media/photo_picker.dart';
import 'ce_icons.dart';
import 'ce_indicators.dart';

/// Step progress (reference setup header): [steps] 4 px segments — done in
/// the accent green, the rest #D5E3DA — and the step label underneath.
class CeStepProgress extends StatelessWidget {
  const CeStepProgress({super.key, required this.value, required this.label, this.steps = 3, this.padding});
  final double value;
  final String label;
  final int steps;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final done = (value * steps).round().clamp(0, steps);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          label: label,
          value: '${(value * 100).round()}%',
          child: Row(children: [
            for (var i = 0; i < steps; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: AnimatedContainer(
                  duration: CeMotion.base,
                  height: 4,
                  decoration: BoxDecoration(
                    color: i < done ? CeColors.accent : CeColors.line2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 8),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CeType.label.copyWith(color: CeColors.muted, letterSpacing: 0.48)),
      ]),
    );
  }
}

/// Photo / crest picker (reference profile photo & club crest): an 84 px
/// mint well with a dashed sage outline until a picture is chosen, and a
/// 28 px green badge (+ to add, pencil to change). With [title] the hint
/// sits beside it (reference layout); without, [caption] sits underneath.
class CePhotoPicker extends StatelessWidget {
  const CePhotoPicker({
    super.key,
    required this.placeholderIcon,
    required this.caption,
    required this.onTap,
    this.hasPhoto = false,
    this.initial,
    this.imagePath,
    this.semanticLabel = 'Choose photo',
    this.title,
    this.square = false,
  });

  final String placeholderIcon;
  final String caption;
  final VoidCallback onTap;
  final bool hasPhoto;
  final String? initial;

  /// Local file of the chosen picture (device photo picker).
  final String? imagePath;
  final String semanticLabel;

  /// Side title ("Profile photo", "Club crest"): reference row layout.
  final String? title;

  /// Rounded square (club crest, radius 24) instead of a circle.
  final bool square;

  static const double _size = 84;

  @override
  Widget build(BuildContext context) {
    final filled = hasPhoto || imagePath != null;
    final radius = square ? 24.0 : _size / 2;
    final well = Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: square ? BorderRadius.circular(radius) : null,
        color: hasPhoto && imagePath == null ? CeColors.primary : CeColors.mint,
      ),
      child: hasPhoto && initial != null
          ? Text(initial!, style: CeType.displayLarge.copyWith(color: Colors.white))
          : Icon(CeIcons.of(placeholderIcon), size: 28, color: hasPhoto ? Colors.white : CeColors.primary),
    );
    final picker = Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: _size,
          height: _size,
          child: Stack(clipBehavior: Clip.none, children: [
            CustomPaint(
              foregroundPainter: filled ? null : _DashedOutlinePainter(radius: radius),
              child: CePhotoImage(path: imagePath, size: _size, square: square, radius: radius, fallback: well),
            ),
            Positioned(
              right: square ? -4 : -2,
              bottom: square ? -4 : -2,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: CeColors.accent,
                  border: Border.all(color: CeColors.bg, width: 3),
                ),
                child: Icon(CeIcons.of(filled ? 'edit-3' : 'plus'), size: 12, color: Colors.white),
              ),
            ),
          ]),
        ),
      ),
    );
    if (title == null) {
      return Column(children: [
        picker,
        const SizedBox(height: 8),
        Text(caption, style: CeType.bodySmall.copyWith(fontSize: 12)),
      ]);
    }
    return Row(children: [
      picker,
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title!, style: CeType.listTitle.copyWith(fontSize: 15)),
          const SizedBox(height: 6),
          Text(caption, style: CeType.body.copyWith(color: CeColors.muted, height: 1.4)),
        ]),
      ),
    ]);
  }
}

class _DashedOutlinePainter extends CustomPainter {
  _DashedOutlinePainter({required this.radius});
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CeColors.sage
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rrect = RRect.fromRectAndRadius((Offset.zero & size).deflate(1), Radius.circular(radius - 1));
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      for (double d = 0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedOutlinePainter oldDelegate) => oldDelegate.radius != radius;
}

/// Group of selectable options. Wrapping pills by default; with [columns]
/// an equal-width grid of 42 px option buttons (reference role / club-type
/// pickers: radius 12, 1.5 px border, selected filled #12544F).
class CeChoiceGroup<T> extends StatelessWidget {
  const CeChoiceGroup({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.iconOf,
    this.columns,
  });

  final List<T> values;
  final T? selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;
  final String? Function(T)? iconOf;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    if (columns == null) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in values)
            CeChip(label: labelOf(v), icon: iconOf?.call(v), selected: v == selected, onTap: () => onSelected(v)),
        ],
      );
    }
    final n = columns!;
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 8 * (n - 1)) / n;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final v in values)
          SizedBox(width: w, child: CeChoiceButton(label: labelOf(v), selected: v == selected, onTap: () => onSelected(v))),
      ]);
    });
  }
}

/// One option button of a grid choice (reference: 42 px, radius 12).
class CeChoiceButton extends StatelessWidget {
  const CeChoiceButton({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? CeColors.primary : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.md),
            side: BorderSide(color: selected ? CeColors.primary : CeColors.line2, width: 1.5),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.md),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 42),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: CeType.buttonSmall.copyWith(color: selected ? Colors.white : CeColors.ink)),
                ),
              ),
            ),
          ),
        ),
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
          Flexible(child: Text('$prompt ', style: CeType.body.copyWith(color: CeColors.muted))),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
            child: Text(action, style: CeType.buttonSmall.copyWith(color: CeColors.primary)),
          ),
        ]),
      );
}
