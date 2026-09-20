import 'package:json_annotation/json_annotation.dart';

part 'candle_dto.g.dart';

/// One OHLCV bucket as exact decimal strings.
///
/// Identity for merging is `(interval, startTime)`; [sourceSequence] only
/// decides which of two values for that identity wins.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class CandleDto {
  /// Creates a candle payload.
  const CandleDto({
    required this.startTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.tradeCount,
    required this.sourceSequence,
    this.active = false,
  });

  /// Decodes a candle payload.
  factory CandleDto.fromJson(Map<String, dynamic> json) =>
      _$CandleDtoFromJson(json);

  /// Bucket start, RFC3339 with milliseconds, UTC, aligned to the interval.
  final String startTime;

  /// First trade price in the bucket, exact.
  final String open;

  /// Highest trade price in the bucket, exact.
  final String high;

  /// Lowest trade price in the bucket, exact.
  final String low;

  /// Most recent trade price in the bucket, exact.
  final String close;

  /// Exact sum of the bucket's trade quantities.
  final String volume;

  /// Number of trades folded into the bucket.
  final int tradeCount;

  /// Trade id of the last trade folded into the bucket.
  final int sourceSequence;

  /// Whether this bucket is still forming.
  ///
  /// REST history *includes* the in-progress bucket, so the response names it
  /// rather than leaving a client to assume the whole list is finalised. A
  /// client that made that assumption would treat the newest bucket as
  /// immutable and reject every later update for it.
  @JsonKey(defaultValue: false)
  final bool active;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$CandleDtoToJson(this);
}

/// `candle_update` — the complete active candle, never a diff.
///
/// Because the whole bucket is sent, a coalesced or missed intermediate update
/// cannot leave the client with a partial candle.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class CandleUpdateDto {
  /// Creates a candle update payload.
  const CandleUpdateDto({
    required this.symbol,
    required this.interval,
    required this.candle,
    required this.sourceSequence,
    required this.active,
  });

  /// Decodes a candle update payload.
  factory CandleUpdateDto.fromJson(Map<String, dynamic> json) =>
      _$CandleUpdateDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// Bucket length id (`1m`, `5m`, …).
  final String interval;

  /// The complete bucket state.
  final CandleDto candle;

  /// Last trade id folded into the bucket.
  final int sourceSequence;

  /// False when the bucket has already closed.
  final bool active;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$CandleUpdateDtoToJson(this);
}

/// `candle_closed` — the immutable final bucket.
///
/// It is never coalesced away, because a client that misses it cannot finalise
/// the bucket.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class CandleClosedDto {
  /// Creates a candle closed payload.
  const CandleClosedDto({
    required this.symbol,
    required this.interval,
    required this.candle,
    required this.epoch,
  });

  /// Decodes a candle closed payload.
  factory CandleClosedDto.fromJson(Map<String, dynamic> json) =>
      _$CandleClosedDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// Bucket length id (`1m`, `5m`, …).
  final String interval;

  /// The final bucket.
  final CandleDto candle;

  /// Engine epoch the bucket belongs to.
  final int epoch;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$CandleClosedDtoToJson(this);
}
