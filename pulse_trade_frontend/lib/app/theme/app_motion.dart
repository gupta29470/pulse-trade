/// Every duration the UI is allowed to animate over.
///
/// A widget that writes its own `Duration` is how an app ends up with four
/// different "quick" fades. All of these are short by design: this is a
/// low-latency terminal, so motion acknowledges a change and then gets out of
/// the way. Nothing here translates or scales a value, because moving a number
/// is indistinguishable from the number changing.
abstract final class AppMotion {
  /// Price tick: the colour cross-fade when a value moves. The value itself
  /// never scales or translates, so a tick cannot reflow the row.
  static const Duration priceTickFade = Duration(milliseconds: 120);

  /// Depth bar: the implicit width animation of a book row's depth bar.
  static const Duration depthBar = Duration(milliseconds: 90);

  /// New trade row: the background flash that fades back to transparent.
  static const Duration tradeFlash = Duration(milliseconds: 400);

  /// Tier change and stale-to-live recovery: the single pulse of the
  /// `ConnectionChip` or `TierChip`. Nothing moves position.
  static const Duration chipPulse = Duration(milliseconds: 200);

  /// Stale-to-live transition: how long the `CachedTag`s take to fade out.
  static const Duration cachedTagFade = Duration(milliseconds: 150);

  /// One half-cycle of the skeleton placeholder's pulse. Long enough to read as
  /// *loading* rather than *flickering*.
  static const Duration skeletonPulse = Duration(milliseconds: 900);

  /// How long a transient notice stays before it dismisses itself.
  static const Duration noticeAutoDismiss = Duration(seconds: 4);
}
