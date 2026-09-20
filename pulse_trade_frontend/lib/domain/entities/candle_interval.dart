/// A candle aggregation interval.
///
/// The `wire` values are the exact ids the backend registry accepts;
/// anything else is a `400 UNSUPPORTED_INTERVAL`. Modelled as an enum so an
/// unknown interval cannot be sent by accident and so the chart can size its
/// buckets without a lookup table.
enum CandleInterval {
  /// One minute, the default chart interval.
  m1('1m', Duration(minutes: 1)),

  /// Five minutes.
  m5('5m', Duration(minutes: 5)),

  /// Fifteen minutes.
  m15('15m', Duration(minutes: 15)),

  /// One hour.
  h1('1h', Duration(hours: 1)),

  /// Four hours.
  h4('4h', Duration(hours: 4)),

  /// One day. The backend id keeps the capital `D`, so this is not decorative.
  d1('1D', Duration(days: 1));

  const CandleInterval(this.wire, this.duration);

  /// The exact id used on the wire and in REST query strings.
  final String wire;

  /// Bucket length; the active candle is the one whose bucket contains now.
  final Duration duration;

  /// Parses a wire interval id, returning `null` for anything unknown.
  static CandleInterval? tryParse(String value) {
    for (final CandleInterval interval in CandleInterval.values) {
      if (interval.wire == value) return interval;
    }
    return null;
  }

  /// The default interval for a cold start.
  static const CandleInterval defaultInterval = CandleInterval.m1;
}
