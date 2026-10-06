import 'package:flutter/material.dart';

/// CricEco design tokens — the CricEco Phone reference design system
/// (`CricECo Phone.dc.html`, 380 × 812): palette #092328 / #12544F /
/// #3A9A72 / #8BBB92 on #F3F7F5, borders #D5E3DA / #E0EAE3, compact
/// spacing, Sora for display text and Manrope for the interface. Status
/// colours (red / amber / blue) keep their meaning and are unchanged.
abstract final class CeColors {
  // Reference palette (exact values)
  static const paletteDeep = Color(0xFF092328); // deep teal-black: text, dark surfaces
  static const paletteTeal = Color(0xFF12544F); // primary dark green: buttons, active UI
  static const paletteGreen = Color(0xFF3A9A72); // accent: links, positive, progress
  static const paletteSage = Color(0xFF8BBB92); // soft green: secondary accent

  // Brand
  static const primary = paletteTeal; // primary CTA / active state
  static const primaryPressed = Color(0xFF0E4642); // CTA pressed
  static const primaryDark = paletteTeal; // headers, icon ink, text on tints
  static const primary600 = Color(0xFF1B6B58); // between teal and green
  static const primaryDeep = paletteDeep;
  static const accent = paletteGreen; // links, positive indicators, progress, toggles on
  static const fresh = paletteGreen; // positive / "won"
  static const sage = paletteSage; // soft accent: rings, highlights
  static const mint = Color(0xFFE3ECE6); // surface muted: tab tracks, icon wells, tints
  static const mint2 = Color(0xFFD2E0D6); // stronger tint: count pills, selected fills

  // Surfaces
  static const bg = Color(0xFFF3F7F5); // page background
  static const surface = Color(0xFFFFFFFF); // cards, inputs, sheets
  static const surfaceAlt = Color(0xFFF7FAF8); // quiet inner panels
  static const hairline = Color(0xFFEEF3EF); // inner dividers on white cards

  // Ink
  static const ink = paletteDeep;
  static const ink2 = Color(0xFF24403D); // secondary dark text, labels
  static const inkSoft = Color(0xFF41605B); // secondary body text on tints
  static const muted = Color(0xFF5B716D); // secondary text
  static const muted2 = Color(0xFF8A9C98); // tertiary text, placeholders

  // Lines
  static const line = Color(0xFFE0EAE3); // card border (1px)
  static const line2 = Color(0xFFD5E3DA); // input / button border (1.5px)
  static const dashedBorder = Color(0xFFC9D8CE); // empty states, add-slots

  // Status (semantic colours, unchanged)
  static const red = Color(0xFFC43B2F);
  static const redSoft = Color(0xFFFBEAE7);
  static const redBorder = Color(0xFFEFCFCB);
  static const amber = Color(0xFFB7791F);
  static const amberSoft = Color(0xFFFDF3E2);
  static const amberInk = Color(0xFF8A5F12);
  static const blue = Color(0xFF2563A8);
  static const blueSoft = Color(0xFFE9F1FB);
  static const violet = Color(0xFF7C4DBA); // tournament "registered" stat
  static const historySoft = Color(0xFFEEF4F1);
  static const toggleOff = Color(0xFFC9D8CE);

  // Countdown box
  static const countdownTop = Color(0xFFFDF3E2);
  static const countdownBottom = Color(0xFFF7E3BB);
  static const countdownBorder = Color(0xFFF0D9A8);
  static const countdownInk = Color(0xFF6E4A0F);

  // Scrims
  static const drawerScrim = Color(0x66092328); // deep teal, 40%
  static const sheetScrim = Color(0x6B092328); // deep teal, 42%

  // Demo panel (prototype controls) — deliberately not a brand colour.
  static const demoBorder = Color(0xFFD9962A);
  static const demoBg = Color(0xFFFFFBF2);

  // Design-system names (the CricEco reference spec) for new code.
  static const textPrimary = ink;
  static const textSecondary = muted;
  static const textTertiary = muted2;
  static const surfaceMuted = mint;
  static const border = line2;
  static const cardBorder = line;
  static const softGreen = sage;
  static const danger = red;
  static const warning = amber;

  /// Hero / header surface: deep teal-black → deep teal → accent green.
  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [paletteDeep, paletteTeal, paletteGreen],
    stops: [0, 0.62, 1],
  );
}

/// Radius levels used deliberately by component hierarchy (no single
/// universal radius).
abstract final class CeRadius {
  static const xs = 8.0; // small elements
  static const sm = 10.0;
  static const tab = 11.0; // segmented tabs, compact buttons
  static const md = 12.0; // small info boxes, back button
  static const row = 14.0; // list rows
  static const input = 14.0; // inputs, search, tab tracks
  static const lg = 16.0; // quick-action tiles, inner cards
  static const button = 16.0; // primary / secondary CTA
  static const card = 18.0; // standard card
  static const feature = 20.0; // feature card
  static const xl = 20.0;
  static const hero = 22.0; // hero / glass card
  static const sheet = 28.0; // bottom-sheet top corners
  static const pill = 999.0;
}

/// Spacing — compact and systematic (4 … 24).
abstract final class CeSpace {
  static const gutter = 20.0; // screen side padding
  static const form = 24.0; // onboarding / auth body padding
  static const card = 14.0; // card inner padding
  static const section = 20.0; // gap above a section header
  static const rowGap = 8.0; // gap between list-card rows
  static const g4 = 4.0;
  static const g6 = 6.0;
  static const g8 = 8.0;
  static const g10 = 10.0;
  static const g12 = 12.0;
  static const g14 = 14.0;
  static const g16 = 16.0;
  static const g20 = 20.0;
  static const g24 = 24.0;
}

abstract final class CeSize {
  static const buttonMinHeight = 54.0; // primary CTA
  static const buttonSecondaryHeight = 50.0;
  static const buttonCompactHeight = 40.0;
  static const inputMinHeight = 52.0;
  static const searchMinHeight = 48.0;
  static const chipMinHeight = 34.0;
  static const statusChipMinHeight = 22.0;
  static const touchTarget = 40.0;
  static const navItemMinHeight = 48.0;
  static const drawerItemMinHeight = 44.0;
  static const topBarMinHeight = 66.0; // 12 + 40 (back button) + 14
  static const backButton = 40.0;
  static const listRowMinHeight = 60.0; // dense list-card row
}

/// Subtle depth only where the reference uses it — cards and rows rely on
/// borders and background contrast instead.
abstract final class CeShadows {
  static const card = <BoxShadow>[];
  /// Selected segmented control / toggle surface.
  static const control = [BoxShadow(color: Color(0x1F092328), blurRadius: 3, offset: Offset(0, 1))];
  static const raised = [
    BoxShadow(
        color: Color(0x38092328),
        blurRadius: 18,
        spreadRadius: -8,
        offset: Offset(0, 6)),
  ];
  static const hero = [
    BoxShadow(
        color: Color(0x80092328),
        blurRadius: 34,
        spreadRadius: -16,
        offset: Offset(0, 16)),
  ];
  /// Floating action control (raised nav buttons): 0 8px 18px -6px rgba(9,35,40,.5).
  static const floating = [
    BoxShadow(color: Color(0x80092328), blurRadius: 18, spreadRadius: -6, offset: Offset(0, 8)),
  ];
  static const primaryButton = <BoxShadow>[];
  /// Bottom sheet: 0 -10px 30px -12px rgba(9,35,40,.3).
  static const sheet = [
    BoxShadow(color: Color(0x4D092328), blurRadius: 30, spreadRadius: -12, offset: Offset(0, -10)),
  ];
  static const bottomNav = <BoxShadow>[];
}

abstract final class CeMotion {
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 160);
  static const slow = Duration(milliseconds: 220);
  static const toast = Duration(milliseconds: 1500);
  static const roleSwitchFade = Duration(milliseconds: 160);
}
