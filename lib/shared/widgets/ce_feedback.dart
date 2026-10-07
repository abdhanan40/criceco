import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import 'ce_buttons.dart';
import 'ce_icons.dart';

/// Prototype `toast(msg)`: dark floating message, 1.5 s.
void showCeToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message, textAlign: TextAlign.center),
      duration: CeMotion.toast,
      margin: const EdgeInsets.fromLTRB(40, 0, 40, 24),
    ));
}

/// Empty state (`.empty-state` / `ceEmptyState`), optional primary + secondary CTA.
class CeEmptyState extends StatelessWidget {
  const CeEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String icon;
  final String title;
  final String? body;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return CeDashedBox(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.md)),
          child: Icon(CeIcons.of(icon), size: 18, color: CeColors.primaryDark),
        ),
        const SizedBox(height: 10),
        Text(title, textAlign: TextAlign.center, style: CeType.cardTitle),
        if (body != null) ...[
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 290),
            child: Text(body!,
                textAlign: TextAlign.center,
                style: CeType.body.copyWith(fontWeight: FontWeight.w600, height: 1.5, color: CeColors.muted)),
          ),
        ],
        if (primaryLabel != null) ...[
          const SizedBox(height: 14),
          CeButton(label: primaryLabel!, onPressed: onPrimary),
        ],
        if (secondaryLabel != null) ...[
          const SizedBox(height: 6),
          TextButton(
            onPressed: onSecondary,
            child: Text(secondaryLabel!, style: CeType.chip.copyWith(color: CeColors.muted)),
          ),
        ],
      ]),
    );
  }
}

/// Load failure with a way forward: the same shape as [CeEmptyState], red
/// icon, one plain-language line and a Retry button. Never shows the raw
/// error.
class CeErrorState extends StatelessWidget {
  const CeErrorState({
    super.key,
    this.title = 'Couldn\'t load this',
    this.body = 'Check your connection and try again.',
    required this.onRetry,
  });

  final String title;
  final String body;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: CeDashedBox(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: CeColors.redSoft, borderRadius: BorderRadius.circular(CeRadius.md)),
            child: Icon(CeIcons.of('info'), size: 18, color: CeColors.red),
          ),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: CeType.cardTitle),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 290),
            child: Text(body,
                textAlign: TextAlign.center,
                style: CeType.body.copyWith(fontWeight: FontWeight.w600, height: 1.5, color: CeColors.muted)),
          ),
          const SizedBox(height: 14),
          CeButton.soft(label: 'Retry', onPressed: onRetry),
        ]),
      ),
    );
  }
}

/// Success / status panel (`.wf-success`); red variant for Reservation Expired.
class CeSuccessPanel extends StatelessWidget {
  const CeSuccessPanel({super.key, required this.title, this.body, this.icon = 'check', this.danger = false});
  final String title;
  final Widget? body;
  final String icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    // `.wf-success .icon-circle` (mint / dark green; `.red` variant).
    final bg = danger ? CeColors.redSoft : CeColors.mint;
    final fg = danger ? CeColors.red : CeColors.primaryDark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 40, 30, 24),
      child: Column(children: [
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
          child: Icon(CeIcons.of(icon), color: fg, size: 34),
        ),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        if (body != null) ...[
          const SizedBox(height: 8),
          DefaultTextStyle.merge(
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: CeColors.muted),
            child: body!,
          ),
        ],
      ]),
    );
  }
}

/// Bottom sheet shell shared by the Player Stats sheet and action sheets.
Future<T?> showCeSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    // Above the role shell's bottom navigation, so its barrier covers the
    // tabs too (no switching sections with a sheet open).
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
    // Reference sheet padding (10 / 22 / 26). Keyboard-safe, and clear of the
    // home indicator / gesture bar on phones that have one.
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          22, 10, 22, 26 + math.max(MediaQuery.viewInsetsOf(ctx).bottom, MediaQuery.paddingOf(ctx).bottom)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(color: CeColors.line2, borderRadius: BorderRadius.circular(CeRadius.pill)),
          ),
        ),
        Flexible(child: SingleChildScrollView(child: builder(ctx))),
      ]),
    ),
  );
}

/// Confirmation sheet for a destructive or money-moving action: title, one
/// line of consequence, a primary CTA (red when [destructive]) and Cancel.
/// Resolves to `true` only when confirmed.
/// "Log out?" confirmation, shared by Settings, the drawer and Role Selection.
Future<bool> confirmLogout(BuildContext context) => showCeConfirmSheet(
      context,
      title: 'Log out?',
      body: 'You will be signed out of this account and returned to Login.',
      confirmLabel: 'Log out',
      destructive: true,
      icon: 'power',
    );

Future<bool> showCeConfirmSheet(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
  String? icon,
}) async {
  final ok = await showCeSheet<bool>(
    context,
    builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        if (icon != null) ...[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: destructive ? CeColors.redSoft : CeColors.mint,
              borderRadius: BorderRadius.circular(CeRadius.sm),
            ),
            child: Icon(CeIcons.of(icon), size: 18, color: destructive ? CeColors.red : CeColors.primaryDark),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(child: Text(title, style: Theme.of(ctx).textTheme.titleLarge)),
      ]),
      const SizedBox(height: 10),
      Text(body, style: Theme.of(ctx).textTheme.bodyMedium!.copyWith(color: CeColors.muted, height: 1.45)),
      const SizedBox(height: 20),
      destructive
          ? CeButton.danger(label: confirmLabel, onPressed: () => Navigator.of(ctx).pop(true))
          : CeButton(label: confirmLabel, onPressed: () => Navigator.of(ctx).pop(true)),
      const SizedBox(height: 10),
      CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(ctx).pop(false)),
    ]),
  );
  return ok ?? false;
}

class CeSheetAction {
  const CeSheetAction({required this.icon, required this.label, required this.id});
  final String icon;
  final String label;
  final String id;
}

/// Action sheet (`ceActionSheet`). Returns the chosen action id; the caller
/// navigates after the sheet has closed.
Future<String?> showCeActionSheet(BuildContext context, {required String title, required List<CeSheetAction> actions}) {
  return showCeSheet<String>(
    context,
    builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: Theme.of(ctx).textTheme.titleLarge),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.row),
          border: Border.all(color: CeColors.line),
        ),
        child: Column(children: [
          for (var i = 0; i < actions.length; i++)
            InkWell(
              onTap: () => Navigator.of(ctx).pop(actions[i].id),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                decoration: i == actions.length - 1
                    ? null
                    : const BoxDecoration(border: Border(bottom: BorderSide(color: CeColors.line))),
                child: Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
                    child: Icon(CeIcons.of(actions[i].icon), size: 16, color: CeColors.primaryDark),
                  ),
                  const SizedBox(width: 11),
                  Expanded(child: Text(actions[i].label, style: Theme.of(ctx).textTheme.titleSmall)),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 18),
      CeButton.soft(label: 'Cancel', onPressed: () => Navigator.of(ctx).pop()),
    ]),
  );
}

/// The reference's quiet empty box: 1.5px dashed #C9D8CE, radius 18, padding
/// 22 / 16, centred content, inside the screen gutters.
class CeDashedBox extends StatelessWidget {
  const CeDashedBox({super.key, required this.child, this.margin});
  final Widget child;
  final EdgeInsetsGeometry? margin;

  @override
  // Hugs its content even as a whole screen body (no full-height box).
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: Padding(
          padding: margin ?? const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 12),
          child: CustomPaint(
            painter: const _DashedRRectPainter(),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
              child: child,
            ),
          ),
        ),
      );
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const w = 1.5, dash = 6.0, gap = 4.0;
    final rrect = RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(w / 2), const Radius.circular(CeRadius.card));
    final paint = Paint()
      ..color = CeColors.dashedBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, (d + dash).clamp(0, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) => false;
}
