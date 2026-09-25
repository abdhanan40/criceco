import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Builds the CricEco [ThemeData]. [fontFamily] defaults to the bundled
/// Manrope (assets/fonts/manrope); no runtime font download.
abstract final class AppTheme {
  static const defaultFontFamily = 'Manrope';

  static TextTheme textTheme(String? fontFamily) {
    TextStyle s(double size, FontWeight w,
            {double? spacing, Color color = CeColors.ink, double? height}) =>
        TextStyle(
          fontFamily: fontFamily,
          fontSize: size,
          fontWeight: w,
          letterSpacing: spacing,
          color: color,
          height: height,
        );
    return TextTheme(
      // hero name / banner h1
      displaySmall: s(22, FontWeight.w800, spacing: -0.66),
      // success title / empty title
      headlineSmall: s(19, FontWeight.w800, spacing: -0.5, height: 1.2),
      // top bar title
      titleLarge: s(16, FontWeight.w700, spacing: -0.3),
      // section title
      titleMedium: s(15, FontWeight.w700, spacing: -0.15),
      // row title
      titleSmall: s(13.5, FontWeight.w700, spacing: -0.2),
      bodyLarge: s(14.5, FontWeight.w500),
      bodyMedium: s(13, FontWeight.w500, height: 1.5),
      bodySmall: s(12, FontWeight.w500, color: CeColors.muted, height: 1.35),
      labelLarge: s(15, FontWeight.w700, spacing: -0.15), // buttons
      labelMedium: s(12.5, FontWeight.w600), // chips
      labelSmall: s(10.5, FontWeight.w600,
          spacing: 0.5, color: CeColors.muted), // stat labels
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
      secondary: CeColors.primary600,
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

    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(CeRadius.md),
          borderSide: BorderSide(color: c, width: w),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      textTheme: text,
      scaffoldBackgroundColor: CeColors.bg,
      splashFactory: InkRipple.splashFactory,
      dividerTheme:
          const DividerThemeData(color: CeColors.line, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: CeColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: false,
        constraints: const BoxConstraints(minHeight: CeSize.inputMinHeight),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        hintStyle: text.bodyLarge?.copyWith(color: CeColors.muted2),
        prefixIconColor: CeColors.muted,
        suffixIconColor: CeColors.muted,
        border: border(CeColors.line2),
        enabledBorder: border(CeColors.line2),
        focusedBorder: border(CeColors.primary, 1.4),
        errorBorder: border(CeColors.red),
        focusedErrorBorder: border(CeColors.red, 1.4),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: CeColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(CeSize.buttonMinHeight),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CeRadius.md)),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: CeColors.primary,
          textStyle: text.labelMedium,
          minimumSize: const Size(CeSize.touchTarget, CeSize.touchTarget),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: CeColors.ink,
        contentTextStyle:
            text.labelMedium?.copyWith(color: Colors.white, fontSize: 12.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.md)),
        elevation: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: CeColors.bg,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: CeColors.sheetScrim,
        showDragHandle: false,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(CeRadius.sheet)),
        ),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        scrimColor: CeColors.drawerScrim,
        shape: RoundedRectangleBorder(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? CeColors.primary
                : CeColors.toggleOff),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: CeColors.primary,
        linearTrackColor: CeColors.mint2,
      ),
    );
  }
}
