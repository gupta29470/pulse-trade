import 'dart:math' as math;

/// Rolling jitter over the last [window] RTT samples.
///
/// `jitter_n = mean(|RTT_i - RTT_(i-1)|)` across the window, with three rules:
/// * the first sample reports `0` (there is nothing to compare it with),
/// * fewer than two samples report `0` and are described as insufficient,
/// * a sample larger than `3 × the window median` is capped at that bound before
/// it enters the window, and the cap is counted so it is visible in diagnostics
/// rather than silently smoothing the trace.
final class JitterCalculator {
  /// Creates a calculator with the documented window of 10 and cap factor of 3.
  JitterCalculator({this.window = 10, this.outlierCapFactor = 3.0})
    : assert(window > 0, 'window must be positive');

  /// Number of RTT samples in the rolling window.
  final int window;

  /// Multiple of the window median above which a sample is capped.
  final double outlierCapFactor;

  final List<double> _samples = <double>[];

  int _cappedCount = 0;
  double _jitterMs = 0;
  double _windowMedianMs = 0;

  /// The current jitter estimate.
  double get jitterMs => _jitterMs;

  /// How many samples in the retained window were capped as outliers.
  int get cappedCount => _cappedCount;

  /// Samples currently in the window.
  int get sampleCount => _samples.length;

  /// The median of the retained window, used for the outlier cap.
  double get windowMedianMs => _windowMedianMs;

  /// True while there are fewer than two samples, so jitter is not yet meaningful.
  bool get hasInsufficientSamples => _samples.length < 2;

  /// Whether current jitter is inside the FULL-tier safe band.
  ///
  /// Purely informational for the diagnostics readout: the *backend* decides the
  /// tier, and this must never feed a client-side tier decision.
  bool isWithinSafeBand(double safeMaxMs) => _jitterMs < safeMaxMs;

  /// Adds one RTT sample and returns the updated jitter.
  double add(double rttMs) {
    var value = rttMs;
    if (_samples.isNotEmpty) {
      final double median = _median();
      final double cap = median * outlierCapFactor;
      if (median > 0 && value > cap) {
        value = cap;
        _cappedCount++;
      }
    }

    _samples.add(value);
    while (_samples.length > window) {
      _samples.removeAt(0);
    }

    _windowMedianMs = _median();
    _jitterMs = _computeJitter();
    return _jitterMs;
  }

  /// Clears the window. Called on reconnect together with the RTT reset.
  void reset() {
    _samples.clear();
    _jitterMs = 0;
    _windowMedianMs = 0;
    _cappedCount = 0;
  }

  double _computeJitter() {
    if (_samples.length < 2) return 0;
    var total = 0.0;
    for (var i = 1; i < _samples.length; i++) {
      total += (_samples[i] - _samples[i - 1]).abs();
    }
    return total / (_samples.length - 1);
  }

  double _median() {
    if (_samples.isEmpty) return 0;
    final List<double> sorted = List<double>.of(_samples)..sort();
    final int middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

/// The population standard deviation of the retained samples.
///
/// Used only by the diagnostics "Dev ±" readout. It lives here rather than in a
/// widget so the widget performs no statistics.
double standardDeviationOf(List<double> values) {
  if (values.length < 2) return 0;
  final double mean =
      values.reduce((double a, double b) => a + b) / values.length;
  var sumSquares = 0.0;
  for (final double value in values) {
    sumSquares += math.pow(value - mean, 2).toDouble();
  }
  return math.sqrt(sumSquares / values.length);
}
