/// The 4dp baseline grid.
///
/// Every gap, inset and margin in the app is one of these tokens. A raw number
/// in a `padding:` is how a dense layout drifts out of alignment one widget at
/// a time, so the scale is intentionally small and complete.
abstract final class AppSpacing {
  /// 4dp: between a status dot and its label, or between a label and its value
  /// inside a single tile.
  static const double space2xs = 4.0;

  /// 8dp: between sibling controls that belong together, and the phone gutter.
  static const double spaceXs = 8.0;

  /// 12dp: the default internal padding of a card, and the phone screen margin.
  static const double spaceSm = 12.0;

  /// 16dp: between groups inside a card, and the tablet screen margin.
  static const double spaceMd = 16.0;

  /// 20dp: between cards stacked in a scrolling column.
  static const double spaceLg = 20.0;

  /// 24dp: between major sections of a screen.
  static const double spaceXl = 24.0;

  /// 32dp: the margin around an empty state, where the screen has nothing to
  /// show and whitespace is the layout.
  static const double space2xl = 32.0;

  /// Horizontal screen margin on phones.
  static const double screenMarginPhone = 12.0;

  /// Horizontal screen margin on tablets and larger windows.
  static const double screenMarginTablet = 16.0;

  /// Gap between columns of a grid on phones.
  static const double gutterPhone = 8.0;

  /// Gap between columns of a grid on tablets and larger windows.
  static const double gutterTablet = 12.0;

  /// The minimum hit area of any interactive element. Rows and badges may
  /// *look* compact, but their touch target is never smaller than this:
  /// a 6dp dot still needs a finger-sized target.
  static const double minTouchTarget = 48.0;
}
