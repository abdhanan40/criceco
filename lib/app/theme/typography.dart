import 'package:flutter/material.dart';

import 'tokens.dart';

/// CricEco type scale (the CricEco Phone reference): Sora for display text —
/// titles, section headings, numbers, the primary CTA — and Manrope for the
/// interface. Compact on purpose: body text stays 12.5–14px.
abstract final class CeType {
  static const display = 'Sora';
  static const ui = 'Manrope';

  static TextStyle _sora(double size, {FontWeight w = FontWeight.w700, double? height, double? spacing}) =>
      TextStyle(fontFamily: display, fontSize: size, fontWeight: w, height: height, letterSpacing: spacing, color: CeColors.ink);

  static TextStyle _manrope(double size, FontWeight w, {double? height, double? spacing, Color color = CeColors.ink}) =>
      TextStyle(fontFamily: ui, fontSize: size, fontWeight: w, height: height, letterSpacing: spacing, color: color);

  /// Large brand / hero heading — 30 Sora Bold.
  static final displayLarge = _sora(30, height: 1.1, spacing: -0.6);

  /// Onboarding / profile screen heading — 24 Sora Bold.
  static final pageTitleLarge = _sora(24, height: 1.2, spacing: -0.24);

  /// Page / sheet title — 20 Sora Bold, -0.01em.
  static final pageTitle = _sora(20, height: 1.2, spacing: -0.2);

  /// Dashboard user name — 19 Sora Bold.
  static final heroName = _sora(19, height: 1.15, spacing: -0.19);

  /// Section heading ("Quick actions", "Upcoming matches") — 16 Sora Bold.
  static final sectionTitle = _sora(16, height: 1.25);

  /// Card / profile-card title — 15 Sora Bold.
  static final cardTitle = _sora(15, height: 1.25);

  /// List-row title — 14 Manrope Bold.
  static final listTitle = _manrope(14, FontWeight.w700, height: 1.3);

  /// Body — 13 Manrope Medium.
  static final body = _manrope(13, FontWeight.w500, height: 1.45);

  /// Small body / supporting text — 12.5 Manrope Medium.
  static final bodySmall = _manrope(12.5, FontWeight.w500, height: 1.4, color: CeColors.muted);

  /// Text inputs — 15 Manrope Medium.
  static final input = _manrope(15, FontWeight.w500);

  /// Field labels — 12 Manrope Bold, +0.02em.
  static final label = _manrope(12, FontWeight.w700, spacing: 0.24, color: CeColors.ink2);

  /// Secondary metadata — 11 Manrope SemiBold.
  static final caption = _manrope(11, FontWeight.w600, height: 1.3, color: CeColors.muted);

  /// Chips / badges — 10.5 Manrope Bold.
  static final micro = _manrope(10.5, FontWeight.w700);

  /// Primary CTA — 15 Sora Bold.
  static final button = _sora(15);

  /// Secondary / compact buttons, tabs — 13 Manrope Bold.
  static final buttonSmall = _manrope(13, FontWeight.w700);

  /// Chips / filters — 12.5 Manrope Bold.
  static final chip = _manrope(12.5, FontWeight.w700);

  /// KPI / stat value — Sora Bold (16–24 by importance; 19 by default).
  static TextStyle statValue([double size = 19]) => _sora(size, height: 1.1);

  /// Stat label — 10.5 Manrope SemiBold.
  static final statLabel = _manrope(10.5, FontWeight.w600, height: 1.2, color: CeColors.muted);
}
