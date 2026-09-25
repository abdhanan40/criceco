import 'package:flutter/material.dart';

/// CricEco design tokens. Theme update (2026-09-25): the brand palette comes
/// from the approved reference swatch — deep teal-black, deep teal, green and
/// sage — on light surfaces. Every other colour below is derived from those
/// four (tints for surfaces, teal-greys for ink and lines). Status colours
/// (red / amber / blue) keep their meaning and are unchanged.
abstract final class CeColors {
  // Reference palette (exact swatch values)
  static const paletteDeep = Color(0xFF092328); // deep teal-black
  static const paletteTeal = Color(0xFF12544F); // deep teal
  static const paletteGreen = Color(0xFF2A835F); // green
  static const paletteSage = Color(0xFF8BBB92); // sage

  // Brand
  static const primary = paletteGreen; // signature / action green
  static const primaryDark = paletteTeal; // headers, icon ink, text on tints
  static const primary600 = Color(0xFF1B6B58); // between teal and green
  static const primaryDeep = paletteDeep;
  static const fresh = Color(0xFF3E9D72); // positive / "won" (a lighter green)
  static const sage = paletteSage; // soft accent: rings, selected tracks, hero highlights
  static const mint = Color(0xFFE8F2EB); // sage tint: chips, icon wells
  static const mint2 = Color(0xFFD3E6D7); // stronger sage tint: borders, selected fills

  // Surfaces
  static const bg = Color(0xFFF3F7F5); // faint sage-teal page background
  static const surface = Color(0xFFFFFFFF);
  static const hairline = Color(0xFFEDF3F0); // inner dividers on white cards

  // Ink (teal-greys from the deep palette colour)
  static const ink = paletteDeep;
  static const ink2 = Color(0xFF24403D);
  static const inkSoft = Color(0xFF41605B); // secondary body text on tints
  static const muted = Color(0xFF5B716D);
  static const muted2 = Color(0xFF92A6A1);

  // Lines
  static const line = Color(0xFFDCE7E2);
  static const line2 = Color(0xFFCFDED8);

  // Status
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
  static const toggleOff = Color(0xFFC2D3CC);

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

  /// Hero / header surface: deep teal-black → deep teal → green.
  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [paletteDeep, paletteTeal, paletteGreen],
    stops: [0, 0.62, 1],
  );
}

abstract final class CeRadius {
  static const xs = 8.0;
  static const sm = 10.0;
  static const md = 12.0; // buttons, inputs, icon wells
  static const row = 14.0; // list rows, stat cards
  static const lg = 16.0; // cards
  static const xl = 20.0; // empty-state icon
  static const sheet = 22.0;
  static const pill = 999.0;
}

abstract final class CeSpace {
  static const gutter = 18.0; // screen side padding for lists / sections
  static const form = 22.0; // form body padding
  static const card = 14.0; // card inner padding
  static const g6 = 6.0;
  static const g8 = 8.0;
  static const g10 = 10.0;
  static const g12 = 12.0;
  static const g14 = 14.0;
}

abstract final class CeSize {
  static const buttonMinHeight = 50.0;
  static const inputMinHeight = 52.0;
  static const searchMinHeight = 48.0;
  static const chipMinHeight = 31.0;
  static const statusChipMinHeight = 22.0;
  static const touchTarget = 40.0;
  static const navItemMinHeight = 52.0;
  static const drawerItemMinHeight = 44.0;
  static const topBarMinHeight = 58.0;
}

abstract final class CeShadows {
  static const card = [
    BoxShadow(color: Color(0x0F092328), blurRadius: 12, offset: Offset(0, 3)),
  ];
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
  static const primaryButton = [
    BoxShadow(
        color: Color(0x992A835F),
        blurRadius: 14,
        spreadRadius: -8,
        offset: Offset(0, 6)),
  ];
  static const bottomNav = [
    BoxShadow(
        color: Color(0x40092328),
        blurRadius: 16,
        spreadRadius: -10,
        offset: Offset(0, -4)),
  ];
}

abstract final class CeMotion {
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 160);
  static const slow = Duration(milliseconds: 220);
  static const toast = Duration(milliseconds: 1500);
  static const roleSwitchFade = Duration(milliseconds: 160);
}
