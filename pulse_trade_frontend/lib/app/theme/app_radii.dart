import 'package:flutter/painting.dart';

/// Corner radii.
///
/// Roundness communicates what a surface *is*: 4dp for a chip-like fragment,
/// 8dp for a component the user interacts with, 12dp for a container that
/// holds other components, and a hard 0dp for anything that represents data.
/// Data boundaries stay square so a grid reads as a grid and a chart's axes
/// line up with the panel edge.
abstract final class AppRadii {
  /// 4dp: depth bars, badges and interval pills — fragments, not surfaces.
  static const double micro = 4.0;

  /// 8dp: cards, buttons and inputs — components the user interacts with.
  static const double component = 8.0;

  /// 12dp: sheets and other containers that hold components.
  static const double container = 12.0;

  /// 0dp: data grids and chart boundaries. Square on purpose.
  static const double data = 0.0;

  /// [micro] as a `BorderRadius`, for widgets that take one instead of a double.
  static const BorderRadius microAll = BorderRadius.all(Radius.circular(micro));

  /// [component] as a `BorderRadius`.
  static const BorderRadius componentAll = BorderRadius.all(
    Radius.circular(component),
  );

  /// [container] as a `BorderRadius`.
  static const BorderRadius containerAll = BorderRadius.all(
    Radius.circular(container),
  );

  /// [data] as a `BorderRadius`; identical to [BorderRadius.zero] and named so
  /// data surfaces state their intent instead of their coordinates.
  static const BorderRadius dataAll = BorderRadius.zero;
}
