import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/data/dto/candle_dto.dart';
import 'package:pulse_trade_frontend/data/dto/rest_market_dto.dart';
import 'package:pulse_trade_frontend/data/mappers/candle_mapper.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/orderbook/candle_merger.dart';

/// The contract between REST history and live candle updates.
///
/// History includes the in-progress bucket and names it, so the bucket the
/// backend marks active is seeded open and still accepts live updates, while a
/// series the backend marks closed stays immutable.
void main() {
  Map<String, dynamic> candleJson({
    required String startTime,
    required String close,
    required bool active,
    required int sourceSequence,
  }) => <String, dynamic>{
    'startTime': startTime,
    'open': '67400.00',
    'high': close,
    'low': '67390.00',
    'close': close,
    'volume': '1.50000000',
    'tradeCount': 3,
    'sourceSequence': sourceSequence,
    'active': active,
  };

  CandlesResponseDto history({required bool lastActive}) => CandlesResponseDto(
    symbol: 'BTCUSDT',
    interval: '1m',
    limit: 500,
    serverTime: '2026-09-17T12:43:00.000Z',
    candles: <CandleDto>[
      CandleDto.fromJson(
        candleJson(
          startTime: '2026-09-17T12:41:00.000Z',
          close: '67410.00',
          active: false,
          sourceSequence: 10,
        ),
      ),
      CandleDto.fromJson(
        candleJson(
          startTime: '2026-09-17T12:42:00.000Z',
          close: '67421.35',
          active: lastActive,
          sourceSequence: 11,
        ),
      ),
    ],
  );

  /// A live update for the bucket history labelled last.
  Candle liveUpdate() => Candle(
    interval: CandleInterval.m1,
    startTime: DateTime.utc(2026, 9, 17, 12, 42),
    open: Money.parse('67419.00'),
    high: Money.parse('67430.00'),
    low: Money.parse('67418.00'),
    close: Money.parse('67429.99'),
    volume: Quantity.parse('2.75000000'),
    tradeCount: 9,
    sourceSequence: 12,
  );

  test('a history bucket the backend marks active is seeded open', () {
    final List<Candle> series = history(lastActive: true).toEntities();

    expect(series.last.closed, isFalse);
    expect(
      series.first.closed,
      isTrue,
      reason: 'only the last bucket is still forming',
    );
  });

  test('the active bucket from history still accepts live updates', () {
    final CandleMerger merger = CandleMerger();

    // Exactly what the app does on cold start, then what the socket delivers.
    final List<Candle> seeded = merger.mergeHistory(
      const <Candle>[],
      history(lastActive: true).toEntities(),
    );
    final List<Candle> merged = merger.merge(seeded, liveUpdate());

    expect(
      identical(merged, seeded),
      isFalse,
      reason: 'the newest bucket must not be sealed by its own history entry',
    );
    expect(merged.last.close, Money.parse('67429.99'));
    expect(merged.last.high, Money.parse('67430.00'));
    expect(merged.last.sourceSequence, 12);
  });

  test('a series the backend marks fully closed stays immutable', () {
    final CandleMerger merger = CandleMerger();

    // `lastActive: false` is the "every bucket finalised" reading, which must
    // keep the guarantee: a closed candle is never rewritten.
    final List<Candle> seeded = merger.mergeHistory(
      const <Candle>[],
      history(lastActive: false).toEntities(),
    );
    final List<Candle> merged = merger.merge(seeded, liveUpdate());

    expect(
      identical(merged, seeded),
      isTrue,
      reason: 'nothing may rewrite a finalised bucket',
    );
  });
}
