import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';

/// One OHLCV bucket.
///
/// Identity for merging is the pair `(interval, startTime)` — never
/// `sourceSequence`, which only decides which of two values for the same
/// identity wins.
final class Candle extends Equatable {
  /// Creates a candle. [closed] is false while the bucket is still forming.
  const Candle({
    required this.interval,
    required this.startTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.tradeCount,
    required this.sourceSequence,
    this.closed = false,
  });

  /// Bucket length.
  final CandleInterval interval;

  /// Bucket start, aligned to a UTC boundary.
  final DateTime startTime;

  /// First trade price in the bucket.
  final Money open;

  /// Highest trade price in the bucket.
  final Money high;

  /// Lowest trade price in the bucket.
  final Money low;

  /// Most recent trade price in the bucket.
  final Money close;

  /// Exact sum of the bucket's trade quantities.
  final Quantity volume;

  /// Number of trades folded into the bucket.
  final int tradeCount;

  /// Trade id of the last trade folded in.
  final int sourceSequence;

  /// Whether the bucket has been finalised by a `candle_closed` frame.
  final bool closed;

  /// The exclusive end of the bucket, derived from [interval].
  DateTime get endTime => startTime.add(interval.duration);

  /// True when [time] falls inside this bucket.
  bool contains(DateTime time) =>
      !time.isBefore(startTime) && time.isBefore(endTime);

  /// Copy with the fields a merge can change.
  Candle copyWith({
    Money? open,
    Money? high,
    Money? low,
    Money? close,
    Quantity? volume,
    int? tradeCount,
    int? sourceSequence,
    bool? closed,
  }) {
    return Candle(
      interval: interval,
      startTime: startTime,
      open: open ?? this.open,
      high: high ?? this.high,
      low: low ?? this.low,
      close: close ?? this.close,
      volume: volume ?? this.volume,
      tradeCount: tradeCount ?? this.tradeCount,
      sourceSequence: sourceSequence ?? this.sourceSequence,
      closed: closed ?? this.closed,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    interval,
    startTime,
    open,
    high,
    low,
    close,
    volume,
    tradeCount,
    sourceSequence,
    closed,
  ];

  @override
  String toString() =>
      'Candle(${interval.wire}, ${startTime.toIso8601String()}, '
      'O=${open.format()} H=${high.format()} L=${low.format()} '
      'C=${close.format()} V=${volume.format()}, n=$tradeCount, '
      'seq=$sourceSequence, closed=$closed)';
}
