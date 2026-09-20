import 'dart:ui';

/// Every colour the app is allowed to use.
///
/// The list is deliberately short, and three rules keep it honest:
///
/// * [bull] and [bear] encode **direction** — up/down, bid/ask, buy/sell — and
/// never "good" versus "bad".
/// * [warn] encodes **data-quality degradation** — stale, reconnecting, a lower
/// delivery tier, a paused generator — and never a failure the user caused.
/// * Status is never conveyed by colour alone. Every use of these
/// tokens is paired with a text label or a glyph, so a reader in greyscale
/// loses no information.
///
/// Elevation is tonal rather than shadowed: level 0 is [canvas],
/// level 1 is [surface1] plus a 1dp [outline], level 2 is [surface2] plus a 1dp
/// [outlineFocus]. Widgets reference these tokens; a raw `Color(0x…)` literal
/// anywhere else is a review failure.
abstract final class AppColors {
  // ---------------------------------------------------------------------------
  // Surfaces
  // ---------------------------------------------------------------------------

  /// Level 0: the scaffold behind everything. Content without a card of its own
  /// is drawn directly on it.
  static const Color canvas = Color(0xFF0B0E14);

  /// Level 1: cards, panels and the app bar's resting surface.
  static const Color surface1 = Color(0xFF121824);

  /// Level 2: overlays, sheets, snackbars and anything that must read as
  /// floating above [surface1].
  static const Color surface2 = Color(0xFF172030);

  /// The 1dp border and divider colour. Quiet by design: chrome recedes so the
  /// numbers carry the screen.
  static const Color outline = Color(0xFF1B2234);

  /// A border that is focused or selected, and the level-2 outline. Nothing is
  /// "selected" by colour alone; it is always paired with a label or a glyph.
  static const Color outlineFocus = Color(0xFF2C3852);

  // ---------------------------------------------------------------------------
  // Semantic
  // ---------------------------------------------------------------------------

  /// Up, bids, buy aggressors, connected and recovery. Direction, not virtue.
  static const Color bull = Color(0xFF05D596);

  /// The deeper bull shade, for the rare case where [bull] would sit on a
  /// surface it cannot contrast with.
  static const Color bullDeep = Color(0xFF00C087);

  /// Down, asks, sell aggressors, critical states, and the `MINIMAL` delivery
  /// tier, which is a genuine loss of fidelity rather than a warning.
  static const Color bear = Color(0xFFF6465D);

  /// Degradation of the data itself: stale values, reconnecting, a lowered
  /// tier, a paused generator. It warns about what is on screen, never about
  /// what the user did.
  static const Color warn = Color(0xFFF3A43B);

  // ---------------------------------------------------------------------------
  // Text
  // ---------------------------------------------------------------------------

  /// Primary copy and every numeric value at rest.
  static const Color textPrimary = Color(0xFFFFFFFF);

  /// Secondary copy, hints and inactive labels. Meets 4.5:1 on [surface1];
  /// do not use it for values that must be read at a glance.
  static const Color textSecondary = Color(0xFF78869E);

  /// Disabled copy and the skeleton placeholder. Not for content that must be
  /// read.
  static const Color textDisabled = Color(0xFF3D4759);

  // ---------------------------------------------------------------------------
  // Alpha blends used for depth bars, row flashes and notice strips
  // ---------------------------------------------------------------------------

  /// Bid depth-bar fill: [bull] at 12 %.
  static const Color bidDepth = Color(0x1F05D596);

  /// Ask depth-bar fill: [bear] at 12 %.
  static const Color askDepth = Color(0x1FF6465D);

  /// The strip background behind an engine-condition notice: [warn] at 10 %.
  static const Color warnBannerBg = Color(0x1AF3A43B);

  /// No paint at all. Used where a decoration must be explicitly absent, and
  /// for `surfaceTint`, because elevation here is tonal and never tinted.
  static const Color transparent = Color(0x00000000);

  /// Bull-tinted overlay for recovery and positive status surfaces.
  ///
  /// The same blend as [bidDepth] because both mean "bull at 12 %", but kept as
  /// its own token: a surface that later needs a different tint must not
  /// silently change the depth bars.
  static const Color bullTint = bidDepth;

  /// Bear-tinted overlay for failure and negative status surfaces. Kept
  /// separate from [askDepth] for the same reason as [bullTint].
  static const Color bearTint = askDepth;
}
