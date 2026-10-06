import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';

enum CeButtonVariant { primary, soft, dangerOutline, google }

/// The reference buttons. Primary CTA: 54px, radius 16, #12544F (#0E4642
/// pressed), Sora 15 Bold. Secondary ([CeButton.soft]) / Google: 50px, white
/// with a 1.5px #D5E3DA border, Manrope 14 Bold. Danger keeps its semantic
/// red. [dense]: compact in-card action (40px, radius 11, Manrope 13 Bold).
/// Full width by default; labels may wrap to 2 lines.
class CeButton extends StatelessWidget {
  const CeButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = CeButtonVariant.primary,
    this.icon,
    this.trailingIcon,
    this.loading = false,
    this.expand = true,
    this.dense = false,
  });

  const CeButton.soft(
      {super.key, required this.label, this.onPressed, this.icon, this.trailingIcon, this.expand = true, this.dense = false})
      : variant = CeButtonVariant.soft,
        loading = false;

  const CeButton.danger({super.key, required this.label, this.onPressed, this.icon, this.expand = true, this.dense = false})
      : variant = CeButtonVariant.dangerOutline,
        trailingIcon = null,
        loading = false;

  final String label;
  final VoidCallback? onPressed;
  final CeButtonVariant variant;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool loading;
  final bool expand;

  /// Compact in-card action (list rows / cards): 40 dp tall, smaller label.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final primary = variant == CeButtonVariant.primary;
    final (bg, fg, border) = switch (variant) {
      CeButtonVariant.primary => (CeColors.primary, Colors.white, null),
      CeButtonVariant.soft => (Colors.white, CeColors.ink, CeColors.line2),
      CeButtonVariant.dangerOutline => (Colors.white, CeColors.red, CeColors.redBorder),
      CeButtonVariant.google => (Colors.white, CeColors.ink, CeColors.line2),
    };
    final enabled = onPressed != null && !loading;
    final base = dense
        ? CeType.buttonSmall
        : primary
            ? CeType.button
            : CeType.listTitle; // Manrope 14 Bold
    final text = base.copyWith(color: fg, height: 1.2);
    final iconSize = dense ? 15.0 : 18.0;
    final radius = BorderRadius.circular(dense ? CeRadius.tab : CeRadius.button);
    final minHeight = dense
        ? CeSize.buttonCompactHeight
        : primary
            ? CeSize.buttonMinHeight
            : CeSize.buttonSecondaryHeight;

    final content = loading
        ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: fg))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: iconSize, color: fg), const SizedBox(width: 6)],
              // One line: in a button row the label scales down a touch
              // rather than wrapping (e.g. "Send Join Request" at 320 px).
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label, textAlign: TextAlign.center, maxLines: 1, style: text),
                ),
              ),
              if (trailingIcon != null) ...[const SizedBox(width: 6), Icon(trailingIcon, size: iconSize, color: fg)],
            ],
          );

    final button = AnimatedOpacity(
      duration: CeMotion.fast,
      opacity: enabled || loading ? 1 : 0.45,
      child: Material(
        color: bg,
        borderRadius: radius,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: radius,
          // Primary pressed state: #0E4642.
          highlightColor: primary ? CeColors.primaryPressed : null,
          splashColor: primary ? CeColors.primaryPressed : null,
          child: Container(
            constraints: BoxConstraints(minHeight: minHeight),
            padding: dense
                ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8)
                : const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: border == null ? null : Border.all(color: border, width: 1.5),
            ),
            alignment: Alignment.center,
            child: content,
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: expand ? SizedBox(width: double.infinity, child: button) : button,
    );
  }
}

/// Sticky bottom CTA bar (reference): page-coloured, a #E0EAE3 top line,
/// padding 12 / 20 / 14 and clear of the home indicator. Holds the screen's
/// primary action (usually a [CeButton]).
class CeStickyCta extends StatelessWidget {
  const CeStickyCta({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          color: CeColors.bg,
          border: Border(top: BorderSide(color: CeColors.line)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 14), child: child),
        ),
      );
}

/// The reference toggle (48 × 28 track, same-size white thumb): the Material
/// switch, themed (on #3A9A72 / off #C9D8CE) and fitted to the reference size.
class CeSwitch extends StatelessWidget {
  const CeSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 48,
        height: 28,
        child: FittedBox(
          fit: BoxFit.contain,
          child: Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            // A thumb icon keeps the thumb full-size when off (reference).
            thumbIcon: const WidgetStatePropertyAll(Icon(null)),
          ),
        ),
      );
}
