import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';
import 'typography.dart';

/// Builds the CricEco [ThemeData] from the CricEco Phone reference design
/// system. Manrope (bundled) is the interface face; Sora (bundled) is used
/// for titles, section headings, numbers and the primary CTA through the
/// text theme below. No runtime font download.
abstract final class AppTheme {
  static const defaultFontFamily = CeType.ui;
  static const displayFontFamily = CeType.display;

  /// Material roles mapped onto the reference type scale ([CeType]).
  static TextTheme textTheme(String? fontFamily) {
    // Interface styles follow [fontFamily] (Manrope); display styles are Sora.
    TextStyle ui(TextStyle s) => s.copyWith(fontFamily: fontFamily);
    return TextTheme(
      // hero / brand heading
      displayLarge: CeType.displayLarge,
      displayMedium: CeType.pageTitleLarge,
      // hero name / banner h1
      displaySmall: CeType.pageTitleLarge,
      headlineMedium: CeType.pageTitleLarge,
      // success title / empty title
      headlineSmall: CeType.pageTitle,
      // page and sheet titles
      titleLarge: CeType.pageTitle,
      // section title
      titleMedium: CeType.sectionTitle,
      // row title
      titleSmall: ui(CeType.listTitle),
      bodyLarge: ui(CeType.input),
      bodyMedium: ui(CeType.body),
      bodySmall: ui(CeType.bodySmall),
      labelLarge: CeType.button, // primary buttons
      labelMedium: ui(CeType.chip), // chips, links
      labelSmall: ui(CeType.statLabel), // stat labels
    );
  }

  static ThemeData light({String? fontFamily = defaultFontFamily}) {
    final text = textTheme(fontFamily);
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: CeColors.primary,
      onPrimary: Colors.white,
      primaryContainer: CeColors.mint,
      onPrimaryContainer: CeColors.primaryDark,
      secondary: CeColors.accent,
      onSecondary: Colors.white,
      secondaryContainer: CeColors.mint2,
      onSecondaryContainer: CeColors.primaryDark,
      tertiary: CeColors.primaryDark,
      onTertiary: Colors.white,
      error: CeColors.red,
      onError: Colors.white,
      errorContainer: CeColors.redSoft,
      onErrorContainer: CeColors.red,
      surface: CeColors.surface,
      onSurface: CeColors.ink,
      onSurfaceVariant: CeColors.muted,
      outline: CeColors.line2,
      outlineVariant: CeColors.line,
      shadow: CeColors.primaryDark,
      scrim: CeColors.drawerScrim,
      inverseSurface: CeColors.ink,
      onInverseSurface: Colors.white,
      inversePrimary: CeColors.mint,
      surfaceContainerLowest: CeColors.surface,
      surfaceContainerLow: CeColors.bg,
      surfaceContainer: CeColors.bg,
      surfaceContainerHigh: CeColors.mint,
      surfaceContainerHighest: CeColors.mint2,
    );

    OutlineInputBorder border(Color c, [double w = 1.5]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(CeRadius.input),
          borderSide: BorderSide(color: c, width: w),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      textTheme: text,
      scaffoldBackgroundColor: CeColors.bg,
      splashFactory: InkRipple.splashFactory,
      dividerTheme: const DividerThemeData(color: CeColors.line, thickness: 1, space: 1),
      // Compact sticky page header: page-coloured, left-aligned Sora title.
      appBarTheme: AppBarTheme(
        backgroundColor: CeColors.bg,
        foregroundColor: CeColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: false,
        constraints: const BoxConstraints(minHeight: CeSize.inputMinHeight),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        hintStyle: text.bodyLarge?.copyWith(color: CeColors.muted2),
        prefixIconColor: CeColors.muted,
        suffixIconColor: CeColors.muted,
        border: border(CeColors.line2),
        enabledBorder: border(CeColors.line2),
        focusedBorder: border(CeColors.accent),
        errorBorder: border(CeColors.red),
        focusedErrorBorder: border(CeColors.red),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: CeColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(CeSize.buttonMinHeight),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.button)),
          elevation: 0,
        ).copyWith(
          overlayColor: const WidgetStatePropertyAll(Color(0x1F0E4642)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: CeColors.accent,
          textStyle: text.labelMedium,
          minimumSize: const Size(CeSize.touchTarget, CeSize.touchTarget),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: CeColors.ink,
        contentTextStyle: text.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.md)),
        elevation: 0,
      ),
      // Reference bottom sheets: white, 28px top corners.
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: CeColors.sheetScrim,
        showDragHandle: false,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(CeRadius.sheet)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CeRadius.hero)),
        titleTextStyle: text.titleLarge,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        scrimColor: CeColors.drawerScrim,
        shape: RoundedRectangleBorder(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? CeColors.accent : CeColors.toggleOff),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? CeColors.accent : null),
        side: const BorderSide(color: CeColors.line2, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? CeColors.accent : CeColors.muted2),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: CeColors.accent,
        linearTrackColor: CeColors.mint,
      ),
    );
  }
}
