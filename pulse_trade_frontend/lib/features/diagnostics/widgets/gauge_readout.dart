import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/app/theme/app_spacing.dart';
import 'package:pulse_trade_frontend/app/theme/app_typography.dart';

/// Round-trip or jitter: one number, its spread, and a drawn gauge.
///
/// The diagnostics page gives these two sections the same shape — a headline
/// value, a `min/avg/max` row, and (for jitter) a deviation — so one widget
/// renders both and the two readouts cannot drift apart visually.
///
/// The gauge is a hand-drawn range strip rather than a chart: a `fl_chart` line
/// here would imply a third axis and a time series the widget was not given.
/// The strip shows where [value] sits between [min] and [max], with the
/// [average] marked and an optional 1σ band drawn from [deviation].
class GaugeReadout extends StatelessWidget {
  /// Creates a gauge readout.
  ///
  /// [title] is rendered small and monospace; [value], [min], [max], [average]
  /// and [p95] all use the same token so the four numbers align as a row.
  const GaugeReadout({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.average,
    this.p95,
    this.deviation,
    this.sampleCount = 0,
    this.unit = 'ms',
  });

  /// Section label (`Round Trip`, `Jitter`).
  final String title;

  /// The headline value: the latest sample for round trip, the current jitter.
  final double value;

  /// Lowest sample in the window.
  final double min;

  /// Highest sample in the window.
  final double max;

  /// Mean sample in the window.
  final double average;

  /// 95th percentile, when the backend reported one.
  final double? p95;

  /// Standard deviation, when it is known. Only the jitter readout supplies it.
  final double? deviation;

  /// Samples behind the aggregate, from the bucket counts.
  final int sampleCount;

  /// Unit suffix for every number, `ms` by default.
  final String unit;

  @override
  Widget build(BuildContext context) {
    final double? p95Value = p95;
    final double? devValue = deviation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: AppTypography.labelMd.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Text(
              _format(value),
              style: AppTypography.labelLg.copyWith(color: AppColors.bull),
            ),
            const SizedBox(width: AppSpacing.space2xs),
            Text(
              unit,
              style: AppTypography.labelSm.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.spaceXs),
        SizedBox(
          height: 22,
          child: CustomPaint(
            // The painter is given primitives rather than the state object, so a
            // test can drive it directly and so it has no reachable state to
            // mutate during paint.
            painter: _GaugePainter(
              value: value,
              min: min,
              max: max,
              average: average,
              p95: p95Value ?? max,
              deviation: devValue ?? 0,
              hasP95: p95Value != null,
              hasDeviation: devValue != null,
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: AppSpacing.spaceXs),
        Row(
          children: <Widget>[
            _Stat(label: 'Min', value: '${_format(min)} $unit'),
            _Stat(label: 'Avg', value: '${_format(average)} $unit'),
            _Stat(label: 'Max', value: '${_format(max)} $unit'),
            if (p95Value != null)
              _Stat(label: 'p95', value: '${_format(p95Value)} $unit'),
            if (devValue != null)
              _Stat(label: 'Dev', value: '±${_format(devValue)} $unit'),
            if (sampleCount > 0) _Stat(label: 'n', value: '$sampleCount'),
          ],
        ),
      ],
    );
  }

  /// One decimal place, except for whole numbers, which stay whole.
  ///
  /// Diagnostics is read by someone comparing a number with a threshold.
  /// `74 ms` is easier to compare than `74.0 ms`.
  static String _format(double raw) {
    if (raw.isNaN || raw.isInfinite) return '—';
    if (raw == raw.roundToDouble()) return raw.toStringAsFixed(0);
    return raw.toStringAsFixed(1);
  }
}

/// One `Label value` cell of the readout row.
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: AppTypography.labelSm.copyWith(
              color: AppColors.textDisabled,
            ),
          ),
          const SizedBox(height: AppSpacing.space2xs),
          Text(
            value,
            style: AppTypography.labelSm.copyWith(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// Draws the range strip: track, σ band, p95 marker and the value marker.
class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.value,
    required this.min,
    required this.max,
    required this.average,
    required this.p95,
    required this.deviation,
    required this.hasP95,
    required this.hasDeviation,
  });

  final double value;
  final double min;
  final double max;
  final double average;
  final double p95;
  final double deviation;
  final bool hasP95;
  final bool hasDeviation;

  /// Vertical inset of the 2dp track inside the 22dp strip.
  static const double _trackHeight = 2;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final double span = max - min;
    // A flat window (one sample, or a constant latency) has no useful scale; the
    // track is drawn plain rather than dividing by zero and painting NaN.
    final bool hasSpan = span > 0 && span.isFinite;
    final double midY = size.height / 2;

    final Paint track = Paint()
      ..color = AppColors.outline
      ..strokeWidth = _trackHeight;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), track);

    if (!hasSpan) {
      _drawMarker(canvas, size.width / 2, midY, size.height, AppColors.bull);
      return;
    }

    // Clamped via `math.min`/`math.max` rather than `num.clamp`, whose declared
    // return type is `num`: under `strict-casts` that would need a cast, and a
    // cast is exactly the kind of unchecked narrowing this project bans.
    double ratio(double v) {
      final double raw = (v - min) / span;
      return math.max(0, math.min(1, raw));
    }

    // The σ band, when it is known: where the sample actually lives, as opposed
    // to where the extremes are.
    if (hasDeviation && deviation > 0) {
      final double bandLeft = ratio(
        math.max(min, math.min(max, average - deviation)),
      );
      final double bandRight = ratio(
        math.max(min, math.min(max, average + deviation)),
      );
      final Paint band = Paint()..color = AppColors.bidDepth;
      canvas.drawRect(
        Rect.fromLTRB(
          bandLeft * size.width,
          midY - 5,
          bandRight * size.width,
          midY + 5,
        ),
        band,
      );
    }

    // p95: a hairline, drawn under the value marker so the current reading is
    // always the topmost thing on the strip.
    if (hasP95) {
      final Paint p95Paint = Paint()
        ..color = AppColors.warn
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.square;
      final double x = ratio(p95) * size.width;
      canvas.drawLine(Offset(x, midY - 7), Offset(x, midY + 7), p95Paint);
    }

    // The average, as a hollow tick: it is a summary, not a measurement.
    final Paint averagePaint = Paint()
      ..color = AppColors.textDisabled
      ..strokeWidth = 1;
    final double averageX = ratio(average) * size.width;
    canvas.drawLine(
      Offset(averageX, midY + 6),
      Offset(averageX, midY + 10),
      averagePaint,
    );

    _drawMarker(
      canvas,
      ratio(value) * size.width,
      midY,
      size.height,
      AppColors.bull,
    );
  }

  /// The current value: a filled diamond, the only solid shape on the strip.
  void _drawMarker(
    Canvas canvas,
    double x,
    double midY,
    double height,
    Color color,
  ) {
    final double half = math.min(height / 2, 7);
    final Path diamond = Path()
      ..moveTo(x, midY - half)
      ..lineTo(x + half * 0.55, midY)
      ..lineTo(x, midY + half)
      ..lineTo(x - half * 0.55, midY)
      ..close();
    canvas.drawPath(
      diamond,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    // Repaint only when a drawn number moved, so a 5 s poll that returns an
    // identical aggregate does not cost a raster pass.
    return oldDelegate.value != value ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.average != average ||
        oldDelegate.p95 != p95 ||
        oldDelegate.deviation != deviation ||
        oldDelegate.hasP95 != hasP95 ||
        oldDelegate.hasDeviation != hasDeviation;
  }
}
