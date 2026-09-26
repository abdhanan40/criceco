import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';

enum CeButtonVariant { primary, soft, dangerOutline, google }

/// Prototype `.btn-primary` / `.btn-green-soft` / `.btn-outline-red` /
/// `.btn-google`. Full width, min height 50, labels may wrap to 2 lines.
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
    final (bg, fg, border) = switch (variant) {
      CeButtonVariant.primary => (CeColors.primary, Colors.white, null),
      CeButtonVariant.soft => (CeColors.mint, CeColors.primaryDark, CeColors.mint2),
      CeButtonVariant.dangerOutline => (Colors.white, CeColors.red, CeColors.redBorder),
      CeButtonVariant.google => (Colors.white, CeColors.ink, CeColors.line2),
    };
    final enabled = onPressed != null && !loading;
    final text = Theme.of(context).textTheme.labelLarge!.copyWith(color: fg, fontSize: dense ? 13 : null);
    final iconSize = dense ? 15.0 : 18.0;

    final content = loading
        ? SizedBox(
            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: fg))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: iconSize, color: fg), const SizedBox(width: 6)],
              Flexible(child: Text(label, textAlign: TextAlign.center, maxLines: 2, style: text)),
              if (trailingIcon != null) ...[const SizedBox(width: 6), Icon(trailingIcon, size: iconSize, color: fg)],
            ],
          );

    final button = AnimatedOpacity(
      duration: CeMotion.fast,
      opacity: enabled || loading ? 1 : 0.45,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(CeRadius.md),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(CeRadius.md),
          child: Container(
            constraints: BoxConstraints(minHeight: dense ? CeSize.touchTarget : CeSize.buttonMinHeight),
            padding: dense
                ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8)
                : const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(CeRadius.md),
              border: border == null ? null : Border.all(color: border),
              boxShadow: variant == CeButtonVariant.primary && enabled ? CeShadows.primaryButton : null,
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
