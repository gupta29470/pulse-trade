import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/data/dto/candle_dto.dart';
import 'package:pulse_trade_frontend/data/dto/rest_market_dto.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';

/// Maps the `candle_update` / `candle_closed` / REST candle payloads onto
/// [Candle] entities.
extension CandleDtoMapper on CandleDto {
  /// The domain candle.
  ///
  /// [interval] comes from the enclosing frame: the payload itself does not
  /// repeat it. [closed] is true only for a finalised bucket.
  Candle toEntity({required CandleInterval interval, required bool closed}) =>
      Candle(
        interval: interval,
        startTime: DateTime.parse(startTime).toUtc(),
        open: Money.parse(open),
        high: Money.parse(high),
        low: Money.parse(low),
        close: Money.parse(close),
        volume: Quantity.parse(volume),
        tradeCount: tradeCount,
        sourceSequence: sourceSequence,
        closed: closed,
      );
}

/// Maps a candles history response onto domain candles.
extension CandlesResponseDtoMapper on CandlesResponseDto {
  /// The history, oldest first. The last bucket is finalised only when the
  /// response says it is.
  ///
  /// History includes the in-progress bucket, and `active` is how the backend
  /// names which element that is. The mapper derives `closed` from it, so the
  /// newest bucket stays mutable and the merger accepts every live update for
  /// it: the chart tracks the price trade by trade while the bucket is open.
  ///
  /// An interval id this build does not know is a parse failure rather than an
  /// invented interval, so the chart can never be labelled with the wrong
  /// bucket length.
  List<Candle> toEntities() {
    final CandleInterval? parsedInterval = CandleInterval.tryParse(interval);
    if (parsedInterval == null) {
      throw FormatException('unknown candle interval', interval);
    }
    return <Candle>[
      for (final CandleDto candle in candles)
        candle.toEntity(interval: parsedInterval, closed: !candle.active),
    ];
  }
}
