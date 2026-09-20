import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_radii.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// The one theme the app runs under: a dark, dense, shadowless terminal.
///
/// This file is the only place where a colour token is turned into a Material
/// theme value. Everything else — every widget in `lib/app/widgets/` and every
/// screen — reads either `Theme.of(context)` or `AppColors` directly, so there
/// is exactly one place to change how the app looks.
///
/// Elevation is tonal: cards are [AppColors.surface1] with a 1dp
/// [AppColors.outline] border and zero elevation, overlays are
/// [AppColors.surface2] with a 1dp [AppColors.outlineFocus] border. No shadow
/// is used anywhere except the transient snackbar.
abstract final class AppTheme {
  /// The dark terminal theme.
  ///
  /// Built once and reused: `ThemeData` construction walks and merges a large
  /// number of style objects, so rebuilding it per call would be pure waste for
  /// a value that never varies at runtime. A light variant is not provided:
  /// the dark palette is the default and the only one that is pixel-reviewed.
  static ThemeData get dark => _dark;

  /// The cached result of [_buildDark].
  static final ThemeData _dark = _buildDark();

  /// The Material type scale, mapped from [AppTypography].
  ///
  /// Material widgets resolve through these slots (`titleLarge` for an app bar
  /// title, `bodyMedium` for snackbar copy), so the mapping exists to keep
  /// generated Material chrome on the same scale as hand-built widgets. The
  /// `display*` and `headline*` slots are aliases rather than a second scale:
  /// the table is the only scale.
  static const TextTheme _textTheme = TextTheme(
    displayLarge: AppTypography.headlineLg,
    displayMedium: AppTypography.headlineLgMobile,
    displaySmall: AppTypography.headlineMd,
    headlineLarge: AppTypography.headlineLg,
    headlineMedium: AppTypography.headlineLgMobile,
    headlineSmall: AppTypography.headlineMd,
    titleLarge: AppTypography.headlineMd,
    titleMedium: AppTypography.headlineSm,
    titleSmall: AppTypography.headlineSm,
    bodyLarge: AppTypography.bodyLg,
    bodyMedium: AppTypography.bodyMd,
    bodySmall: AppTypography.bodySm,
    labelLarge: AppTypography.labelLg,
    labelMedium: AppTypography.labelMd,
    labelSmall: AppTypography.labelSm,
  );

  /// Assembles the dark theme from the tokens.
  ///
  /// `pageTransitionsTheme` is deliberately left unset so each platform keeps
  /// its native push/pop transition: the app has no custom navigation motion,
  /// and overriding it would only make a deep link feel foreign.
  static ThemeData _buildDark() {
    // `background`, `onBackground` and `surfaceVariant` are intentionally not
    // passed: they are deprecated in favour of `surface`,
    // `surfaceContainer*` and `onSurfaceVariant`, and passing both would give
    // Material two disagreeing answers for the same surface.
    const ColorScheme scheme = ColorScheme.dark(
      primary: AppColors.bull,
      onPrimary: AppColors.canvas,
      primaryContainer: AppColors.bullDeep,
      onPrimaryContainer: AppColors.canvas,
      secondary: AppColors.outlineFocus,
      onSecondary: AppColors.textPrimary,
      error: AppColors.bear,
      onError: AppColors.textPrimary,
      surface: AppColors.surface1,
      onSurface: AppColors.textPrimary,
      surfaceDim: AppColors.canvas,
      surfaceBright: AppColors.surface2,
      surfaceContainerLowest: AppColors.canvas,
      surfaceContainerLow: AppColors.surface1,
      surfaceContainer: AppColors.surface1,
      surfaceContainerHigh: AppColors.surface2,
      surfaceContainerHighest: AppColors.surface2,
      onSurfaceVariant: AppColors.textSecondary,
      outline: AppColors.outline,
      outlineVariant: AppColors.outline,
      shadow: AppColors.transparent,
      surfaceTint: AppColors.transparent,
      inverseSurface: AppColors.surface2,
      onInverseSurface: AppColors.textPrimary,
      inversePrimary: AppColors.bullDeep,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      textTheme: _textTheme,

      // Level 1: flat, hairline-bordered cards. The 8dp radius and the 1dp
      // outline repeat what AppCard draws, so a plain `Card` and an `AppCard`
      // are visually identical.
      cardTheme: const CardThemeData(
        color: AppColors.surface1,
        surfaceTintColor: AppColors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.componentAll,
          side: BorderSide(color: AppColors.outline),
        ),
      ),

      // The app bar sits at level 0 with the canvas, so the telemetry strip
      // below it reads as the first surface rather than a second toolbar.
      appBarTheme: AppBarThemeData(
        backgroundColor: AppColors.canvas,
        foregroundColor: AppColors.textPrimary,
        surfaceTintColor: AppColors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Centred: every screen with an app bar is a full-screen route reached from
        // a back arrow, so a centred title reads as that screen's name rather than as
        // something hanging off the arrow.
        centerTitle: true,
        // Colour is applied here, not in AppTypography: the token is the scale
        // and the theme is where a scale becomes a rendered colour. An explicit
        // colour is required because the app bar does not tint a caller-supplied
        // title style.
        titleTextStyle: AppTypography.headlineMd.copyWith(
          color: AppColors.textPrimary,
        ),
        iconTheme: const IconThemeData(
          color: AppColors.textSecondary,
          size: 20,
        ),
        actionsIconTheme: const IconThemeData(
          color: AppColors.textSecondary,
          size: 20,
        ),
      ),

      // Hairlines with no built-in breathing room: a divider is a boundary, and
      // the caller chooses the spacing around it with AppSpacing.
      dividerTheme: const DividerThemeData(
        color: AppColors.outline,
        thickness: 1,
        space: 1,
      ),

      // The bottom bar is chrome: canvas, no elevation, and the selected item
      // marked by colour *and* its label, never by colour alone.
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.canvas,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.bull,
        unselectedItemColor: AppColors.textSecondary,
        selectedLabelStyle: AppTypography.labelMd,
        unselectedLabelStyle: AppTypography.labelMd,
        showUnselectedLabels: true,
      ),

      // Level 3 notice surface: floating so it never reads as a full-width
      // banner, over surface2 with the focus outline. It is reserved for
      // discrete events; connectivity is never a snackbar.
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surface2,
        contentTextStyle: AppTypography.bodyMd.copyWith(
          color: AppColors.textPrimary,
        ),
        actionTextColor: AppColors.bull,
        behavior: SnackBarBehavior.floating,
        elevation: 4,
        insetPadding: const EdgeInsets.all(AppSpacing.spaceSm),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadii.componentAll,
          side: BorderSide(color: AppColors.outlineFocus),
        ),
      ),

      // Inputs are level 0 wells inside a level 1 card: filled with the canvas
      // so a field reads as a hole rather than another card, and outlined with
      // the focus token only while focused.
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: AppColors.canvas,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.spaceSm,
          vertical: AppSpacing.spaceXs,
        ),
        hintStyle: AppTypography.bodyMd.copyWith(color: AppColors.textDisabled),
        labelStyle: AppTypography.bodySm.copyWith(
          color: AppColors.textSecondary,
        ),
        floatingLabelStyle: AppTypography.bodySm.copyWith(
          color: AppColors.bull,
        ),
        errorStyle: AppTypography.bodySm.copyWith(color: AppColors.bear),
        counterStyle: AppTypography.labelSm.copyWith(
          color: AppColors.textSecondary,
        ),
        prefixIconColor: AppColors.textSecondary,
        suffixIconColor: AppColors.textSecondary,
        border: const OutlineInputBorder(
          borderRadius: AppRadii.componentAll,
          borderSide: BorderSide(color: AppColors.outline),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadii.componentAll,
          borderSide: BorderSide(color: AppColors.outline),
        ),
        disabledBorder: const OutlineInputBorder(
          borderRadius: AppRadii.componentAll,
          borderSide: BorderSide(color: AppColors.outline),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadii.componentAll,
          borderSide: BorderSide(color: AppColors.outlineFocus),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: AppRadii.componentAll,
          borderSide: BorderSide(color: AppColors.bear),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: AppRadii.componentAll,
          borderSide: BorderSide(color: AppColors.bear),
        ),
      ),

      // Icons are chrome: secondary by default, so an icon never competes with
      // the number next to it.
      iconTheme: const IconThemeData(color: AppColors.textSecondary, size: 20),

      // Loading is always a bull-tinted indicator on an outline track: it is
      // the only motion on an otherwise frozen screen.
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.bull,
        linearTrackColor: AppColors.outline,
        linearMinHeight: 2,
        circularTrackColor: AppColors.outline,
      ),
    );
  }
}
