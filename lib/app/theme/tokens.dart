import 'package:flutter/material.dart';

/// CricEco design tokens, extracted from the approved prototype's v20 design
/// system layer (criceco-app.js :1875). The host-wrapper override `#0D3F2A`
/// is intentionally NOT used (approved decision: primary = #158447).
abstract final class CeColors {
  // Brand
  static const primary = Color(0xFF158447); // signature / action green
  static const primaryDark = Color(0xFF0B3324); // deep green: heroes, headers
  static const primary600 = Color(0xFF105C38); // dark / secondary green
  static const primaryDeep = Color(0xFF07261B);
  static const fresh = Color(0xFF28A85F);
  static const mint = Color(0xFFEAF6EF);
  static const mint2 = Color(0xFFD6EDE0);

  // Surfaces
  static const bg = Color(0xFFF6F8F6);
  static const surface = Color(0xFFFFFFFF);

  // Ink
  static const ink = Color(0xFF152019);
  static const ink2 = Color(0xFF2F3B34);
  static const muted = Color(0xFF69746D);
  static const muted2 = Color(0xFF98A29B);

  // Lines
  static const line = Color(0xFFE4EAE6);
  static const line2 = Color(0xFFDBE3DD);

  // Status
  static const red = Color(0xFFC43B2F);
  static const redSoft = Color(0xFFFBEAE7);
  static const redBorder = Color(0xFFEFCFCB);
  static const amber = Color(0xFFB7791F);
  static const amberSoft = Color(0xFFFDF3E2);
  static const amberInk = Color(0xFF8A5F12);
  static const blue = Color(0xFF2563A8);
  static const blueSoft = Color(0xFFE9F1FB);
  static const historySoft = Color(0xFFF2F6F3);
  static const toggleOff = Color(0xFFC8D2CB);

  // Countdown box
  static const countdownTop = Color(0xFFFDF3E2);
  static const countdownBottom = Color(0xFFF7E3BB);
  static const countdownBorder = Color(0xFFF0D9A8);
  static const countdownInk = Color(0xFF6E4A0F);

  // Scrims
  static const drawerScrim = Color(0x59000000); // rgba(0,0,0,.35)
  static const sheetScrim = Color(0x6B0B3324); // rgba(11,51,36,.42)

  // Demo panel (prototype controls) — deliberately not a brand colour.
  static const demoBorder = Color(0xFFD9962A);
  static const demoBg = Color(0xFFFFFBF2);

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryDark, primary600, primary],
    stops: [0, 0.6, 1],
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
    BoxShadow(color: Color(0x0D0B3324), blurRadius: 12, offset: Offset(0, 3)),
  ];
  static const raised = [
    BoxShadow(
        color: Color(0x380B3324),
        blurRadius: 18,
        spreadRadius: -8,
        offset: Offset(0, 6)),
  ];
  static const hero = [
    BoxShadow(
        color: Color(0x800B3324),
        blurRadius: 34,
        spreadRadius: -16,
        offset: Offset(0, 16)),
  ];
  static const primaryButton = [
    BoxShadow(
        color: Color(0xD916803D),
        blurRadius: 14,
        spreadRadius: -8,
        offset: Offset(0, 6)),
  ];
  static const bottomNav = [
    BoxShadow(
        color: Color(0x400D3F2A),
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
