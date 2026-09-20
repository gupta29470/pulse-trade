import 'package:flutter/material.dart';

/// The type scale of the terminal.
///
/// **Tabular numerics mandate.** Every price, quantity, percentage, timestamp
/// and metric is rendered with a `label*` token, and every `label*` token
/// declares `FontFeature.tabularFigures()`. Digits therefore occupy a fixed
/// advance width, so a value ticking from `9` to `10` cannot reflow the row it
/// lives in. On a tick only the colour changes; the geometry does not.
///
/// **No token carries a colour.** Colour is a *state* (`bull`/`bear`/disabled)
/// while the scale is *structure*, so callers apply it at the call site:
///
/// ```dart
/// Text(price, style: AppTypography.labelLg.copyWith(color: AppColors.bull));
/// ```
///
/// **Families degrade gracefully.** No font files are bundled, so every token
/// names its preferred family and a platform fallback chain: `Inter` falls back
/// to Roboto and the generic `sans-serif`, `JetBrains Mono` to `Roboto Mono`
/// and the generic `monospace`. On a device without either family the layout
/// still works; only the letterforms change.
///
/// Line heights are written as `lineHeight / fontSize` because `TextStyle.height`
/// is a multiple of the font size, and the division keeps the token's absolute
/// dp values visible and exact.
abstract final class AppTypography {
  /// Sans fallback chain for the Inter-based UI scale.
  static const List<String> _sansFallback = <String>['Roboto', 'sans-serif'];

  /// Monospace fallback chain for the numeric scale. A fallback that is not
  /// monospaced would still be legible, and the tabular-figure feature keeps
  /// the digit advance uniform where the platform honours it.
  static const List<String> _monoFallback = <String>[
    'Roboto Mono',
    'monospace',
  ];

  /// Hero price on tablet and expanded layouts: 32/40, w700, −0.02em.
  static const TextStyle headlineLg = TextStyle(
    fontFamily: 'Inter',
    fontFamilyFallback: _sansFallback,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    height: 40 / 32,
    letterSpacing: -0.64, // −0.02em × 32px
  );

  /// Hero price on phones: 26/32, w700, −0.01em. A separate token because the
  /// hero has less horizontal room here and must not clip.
  static const TextStyle headlineLgMobile = TextStyle(
    fontFamily: 'Inter',
    fontFamilyFallback: _sansFallback,
    fontSize: 26,
    fontWeight: FontWeight.w700,
    height: 32 / 26,
    letterSpacing: -0.26, // −0.01em × 26px
  );

  /// Screen and dialog titles: 20/26, w600, −0.01em.
  static const TextStyle headlineMd = TextStyle(
    fontFamily: 'Inter',
    fontFamilyFallback: _sansFallback,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 26 / 20,
    letterSpacing: -0.2, // −0.01em × 20px
  );

  /// Card headers and the symbol: 16/22, w600, no tracking.
  static const TextStyle headlineSm = TextStyle(
    fontFamily: 'Inter',
    fontFamilyFallback: _sansFallback,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 22 / 16,
    letterSpacing: 0,
  );

  /// Body copy: 15/22, w400, no tracking.
  static const TextStyle bodyLg = TextStyle(
    fontFamily: 'Inter',
    fontFamilyFallback: _sansFallback,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 22 / 15,
    letterSpacing: 0,
  );

  /// Secondary copy: 13/18, w400, no tracking.
  static const TextStyle bodyMd = TextStyle(
    fontFamily: 'Inter',
    fontFamilyFallback: _sansFallback,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 18 / 13,
    letterSpacing: 0,
  );

  /// Labels and hints: 11/16, w400, no tracking.
  static const TextStyle bodySm = TextStyle(
    fontFamily: 'Inter',
    fontFamilyFallback: _sansFallback,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 16 / 11,
    letterSpacing: 0,
  );

  /// Numeric inputs and large values: 14/18, w600, +0.01em. Tabular figures are
  /// what let a live price update without shifting its neighbours.
  static const TextStyle labelLg = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: _monoFallback,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 18 / 14,
    letterSpacing: 0.14, // +0.01em × 14px
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// Interval chips and tabs: 12/16, w500, no tracking. Tabular for the same
  /// reason as [labelLg] — the selected chip must not resize when its value
  /// changes.
  static const TextStyle labelMd = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: _monoFallback,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 16 / 12,
    letterSpacing: 0,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// Table cells, timestamps and badges: 10/14, w500, +0.02em. The densest
  /// token in the app and the one most exposed to ticking values, so its
  /// tabular figures matter most.
  static const TextStyle labelSm = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: _monoFallback,
    fontSize: 10,
    fontWeight: FontWeight.w500,
    height: 14 / 10,
    letterSpacing: 0.2, // +0.02em × 10px
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}
