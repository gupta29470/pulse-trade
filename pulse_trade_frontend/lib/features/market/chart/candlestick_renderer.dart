// The chart adapter.
//
// **Deliberate split of the chart into two renderers.** The adapter consumes
// `fl_chart` where it can, and the pinned `fl_chart` in this build is `0.70.2`,
// which predates `CandlestickChart` (added in 0.71.0). Rather than pin an
// unreleased API or hand-draw the volume strip as well, the adapter is split by
// capability:
//
// * the candle canvas is a `CustomPainter` (`CandleSeriesPainter`), because
// `fl_chart` 0.70.2 has no candlestick series to delegate to;
// * the volume histogram underneath uses `fl_chart`'s `BarChart`, which does
// exist and is the reason the dependency is still pulled in here.
//
// The adapter's contract is unchanged either way: it is the single place a
// `Money`/`Quantity` becomes a `double`, and it performs no I/O.
import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';

/// Which candle the user is inspecting, if any.
///
/// Owned by the widget, not by the bloc: a drag must repaint the canvas without
/// rebuilding the surrounding market screen. [index] is the position
/// inside the visible window, and [candle] is carried alongside so the readout
/// strip does not have to index back into the series.
final class CrosshairState extends Equatable {
  /// Creates a crosshair.
  const CrosshairState({this.index = -1, this.candle, this.isActive = false});

  /// The resting crosshair: nothing selected.
  static const CrosshairState none = CrosshairState();

  /// Position inside the visible window, or `-1` when the crosshair is off.
  final int index;

  /// The candle under the crosshair, or `null` when it is off.
  final Candle? candle;

  /// True while a pointer is down or a gesture is in progress.
  final bool isActive;

  @override
  List<Object?> get props => <Object?>[index, candle, isActive];

  @override
  String toString() => 'CrosshairState(index: $index, active: $isActive)';
}

/// The one way the market screen draws candles.
///
/// A renderer returns a widget and takes domain values; it never fetches, never
/// reads a repository and never decides what state the chart is in. Loading,
/// empty and error presentation belong to the market page, which is
/// what keeps the renderer a pure function of the series.
abstract interface class CandlestickRenderer {
  /// Builds the chart for [candles].
  ///
  /// [active] is the bucket still forming, if any; [crosshair] selects the
  /// candle being inspected; [livePrice] draws the dashed pointer; the colour
  /// overrides exist so a caller can theme the canvas without the adapter
  /// importing a second palette.
  Widget build({
    required List<Candle> candles,
    required Candle? active,
    required CrosshairState crosshair,
    double? livePrice,
    Color? bullColor,
    Color? bearColor,
  });
}

/// The production renderer: a `CustomPainter` for candles, `BarChart` for volume.
///
/// Stateless and field-free, so it can be a `const` value the market page
/// constructs once and reuses across rebuilds.
final class FlChartCandlestickRenderer implements CandlestickRenderer {
  /// Creates the renderer.
  const FlChartCandlestickRenderer();

  @override
  Widget build({
    required List<Candle> candles,
    required Candle? active,
    required CrosshairState crosshair,
    double? livePrice,
    Color? bullColor,
    Color? bearColor,
  }) {
    return _CandlestickChart(
      candles: candles,
      active: active,
      crosshair: crosshair,
      livePrice: livePrice,
      bullColor: bullColor ?? AppColors.bull,
      bearColor: bearColor ?? AppColors.bear,
    );
  }
}

/// The rendering boundary between exact fixed-point decimals and `double`.
///
/// Every conversion in this file goes through these two methods, and every call
/// site below is annotated with the reason. Nothing else in the feature may
/// convert a price or a quantity to a floating-point value.
abstract final class CandleSeriesAdapter {
  const CandleSeriesAdapter._();

  /// Rendering boundary: a price becomes a canvas coordinate.
  static double priceToDouble(Money value) => value.toDouble();

  /// Rendering boundary: a quantity becomes a bar height.
  static double quantityToDouble(Quantity value) => value.toDouble();

  /// The newest [max] candles, which is all the canvas can resolve legibly.
  ///
  /// Returning a stable sublist rather than asking the painter to skip leading
  /// elements keeps the painter's x-mapping a single division.
  static List<Candle> visibleWindow(List<Candle> candles, {int max = 120}) {
    if (max <= 0) return const <Candle>[];
    if (candles.length <= max) return candles;
    return candles.sublist(candles.length - max);
  }
}

/// The candle canvas.
final class CandleSeriesPainter extends CustomPainter {
  /// Creates the painter for one immutable series.
  const CandleSeriesPainter({
    required this.candles,
    required this.bullColor,
    required this.bearColor,
    this.crosshairIndex = -1,
    this.activeCandle,
    this.livePrice,
  });

  /// Wick stroke width, in logical pixels.
  static const double wickWidth = 1;

  /// Body width, in logical pixels.
  static const double bodyWidth = 6;

  /// Minimum body height, so a doji is still visible as a line.
  static const double bodyMinHeight = 1;

  /// The visible series, ascending by `startTime`.
  final List<Candle> candles;

  /// Colour for `close >= open`.
  final Color bullColor;

  /// Colour for `close < open`.
  final Color bearColor;

  /// Slot under the crosshair, or `-1`.
  final int crosshairIndex;

  /// The bucket still forming, marked so the eye can find it.
  final Candle? activeCandle;

  /// Dashed pointer price, or `null` for no pointer.
  final double? livePrice;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;

    final double low = _lowest();
    final double high = _highest();
    final double range = high - low;
    // A single flat bucket has no range; a nominal pad keeps the division finite
    // and centres the line rather than pinning it to an edge.
    final double pad = range <= 0 ? 1 : range * 0.04;
    final double floor = low - pad;
    final double span = (high + pad) - floor;
    final double slot = size.width / candles.length;
    final double width = math.min(bodyWidth, slot * 0.7);

    double yFor(double price) =>
        size.height - ((price - floor) / span) * size.height;

    final Paint wick = Paint()
      ..strokeWidth = wickWidth
      // Half-pixel alignment matters at 1px: antialiasing here produces a wick
      // that looks 2px on one side and absent on the other.
      ..isAntiAlias = false;
    final Paint body = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < candles.length; i++) {
      final Candle candle = candles[i];
      final bool isBull = candle.close >= candle.open;
      final Color colour = isBull ? bullColor : bearColor;
      final double centre = (i + 0.5) * slot;

      wick.color = colour;
      canvas.drawLine(
        Offset(centre, yFor(CandleSeriesAdapter.priceToDouble(candle.high))),
        Offset(centre, yFor(CandleSeriesAdapter.priceToDouble(candle.low))),
        wick,
      );

      // Rendering boundary: the body's four prices become geometry.
      final double openY = yFor(CandleSeriesAdapter.priceToDouble(candle.open));
      final double closeY = yFor(
        CandleSeriesAdapter.priceToDouble(candle.close),
      );
      final double bodyTop = math.min(openY, closeY);
      final double bodyHeight = math.max((closeY - openY).abs(), bodyMinHeight);
      body.color = colour;
      canvas.drawRect(
        Rect.fromLTWH(centre - width / 2, bodyTop, width, bodyHeight),
        body,
      );
    }

    _paintActiveMarker(canvas, size, slot);
    _paintCrosshair(canvas, size, slot);
    _paintLivePointer(canvas, size, yFor);
  }

  /// The active bucket gets a quiet band behind it plus a marker under its low.
  void _paintActiveMarker(Canvas canvas, Size size, double slot) {
    final Candle? active = activeCandle;
    if (active == null) return;
    final int index = _indexOfIdentity(active);
    if (index < 0) return;
    final double centre = (index + 0.5) * slot;
    final Paint band = Paint()..color = bullColor.withValues(alpha: 0.08);
    canvas.drawRect(
      Rect.fromLTWH(centre - slot / 2, 0, slot, size.height),
      band,
    );
    final Paint marker = Paint()..color = bullColor;
    canvas.drawPath(
      Path()
        ..moveTo(centre, size.height - 2)
        ..lineTo(centre - 3, size.height - 8)
        ..lineTo(centre + 3, size.height - 8)
        ..close(),
      marker,
    );
  }

  void _paintCrosshair(Canvas canvas, Size size, double slot) {
    if (crosshairIndex < 0 || crosshairIndex >= candles.length) return;
    final double centre = (crosshairIndex + 0.5) * slot;
    final Paint line = Paint()
      ..color = AppColors.outlineFocus
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(Offset(centre, 0), Offset(centre, size.height), line);
  }

  void _paintLivePointer(
    Canvas canvas,
    Size size,
    double Function(double) yFor,
  ) {
    final double? live = livePrice;
    if (live == null) return;
    final double y = yFor(live);
    if (y < 0 || y > size.height) return;
    // The pointer borrows the direction of the newest bucket: it is the same
    // fact the hero price is coloured by, so the two never disagree.
    final Candle last = candles.last;
    final Paint dash = Paint()
      ..color = last.close >= last.open ? bullColor : bearColor
      ..strokeWidth = 1
      ..isAntiAlias = false;
    const double dashLength = 4;
    const double gap = 3;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dashLength, size.width), y),
        dash,
      );
      x += dashLength + gap;
    }
  }

  double _lowest() {
    var low = CandleSeriesAdapter.priceToDouble(candles.first.low);
    for (final Candle candle in candles) {
      final double value = CandleSeriesAdapter.priceToDouble(candle.low);
      if (value < low) low = value;
    }
    return low;
  }

  double _highest() {
    var high = CandleSeriesAdapter.priceToDouble(candles.first.high);
    for (final Candle candle in candles) {
      final double value = CandleSeriesAdapter.priceToDouble(candle.high);
      if (value > high) high = value;
    }
    return high;
  }

  int _indexOfIdentity(Candle candle) {
    for (var i = 0; i < candles.length; i++) {
      if (identical(candles[i], candle)) return i;
    }
    return -1;
  }

  @override
  bool shouldRepaint(covariant CandleSeriesPainter oldDelegate) =>
      // Identity, not equality: the bloc replaces the list immutably, so a new
      // list object is exactly the signal that a candle changed.
      !identical(oldDelegate.candles, candles) ||
      oldDelegate.crosshairIndex != crosshairIndex ||
      // The pointer moves without the series changing, so it must be compared
      // too or a live price would freeze on screen.
      oldDelegate.livePrice != livePrice ||
      !identical(oldDelegate.activeCandle, activeCandle);
}

/// The composed chart: candle canvas on top, volume histogram underneath.
class _CandlestickChart extends StatelessWidget {
  const _CandlestickChart({
    required this.candles,
    required this.active,
    required this.crosshair,
    required this.livePrice,
    required this.bullColor,
    required this.bearColor,
  });

  final List<Candle> candles;
  final Candle? active;
  final CrosshairState crosshair;
  final double? livePrice;
  final Color bullColor;
  final Color bearColor;

  @override
  Widget build(BuildContext context) {
    final List<Candle> window = CandleSeriesAdapter.visibleWindow(candles);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: RepaintBoundary(
            child: SizedBox.expand(
              child: CustomPaint(
                painter: CandleSeriesPainter(
                  candles: window,
                  activeCandle: active,
                  crosshairIndex: crosshair.index,
                  livePrice: livePrice,
                  bullColor: bullColor,
                  bearColor: bearColor,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        // The volume strip is a histogram, not a positional axis: it is drawn by
        // fl_chart over the same window so a tall bucket still lines up roughly
        // with its candle without the two packages sharing a coordinate system.
        SizedBox(
          height: 34,
          child: BarChart(
            _volumeData(window),
            // Not an ad-hoc motion token: this switches fl_chart's implicit
            // swap animation *off*. At 10 Hz an animated bar swap would leave
            // the strip permanently mid-transition and redraw the whole scene
            // every frame; the volume strip is a histogram, not a tween.
            duration: Duration.zero,
          ),
        ),
      ],
    );
  }

  BarChartData _volumeData(List<Candle> window) {
    var ceiling = 0.0;
    for (final Candle candle in window) {
      final double volume = CandleSeriesAdapter.quantityToDouble(candle.volume);
      if (volume > ceiling) ceiling = volume;
    }
    if (ceiling <= 0) ceiling = 1;

    return BarChartData(
      alignment: BarChartAlignment.spaceBetween,
      groupsSpace: 1,
      minY: 0,
      maxY: ceiling * 1.15,
      barGroups: <BarChartGroupData>[
        for (var i = 0; i < window.length; i++)
          BarChartGroupData(
            x: i,
            barRods: <BarChartRodData>[
              BarChartRodData(
                toY: CandleSeriesAdapter.quantityToDouble(window[i].volume),
                color:
                    (window[i].close >= window[i].open ? bullColor : bearColor)
                        .withValues(alpha: 0.55),
                width: 3,
              ),
            ],
          ),
      ],
      titlesData: const FlTitlesData(show: false),
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(enabled: false),
    );
  }
}
