import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/orderbook/candle_merger.dart';

DateTime _start(int minute) => DateTime.utc(2026, 9, 17, 12, minute);

Candle _candle({
  int minute = 0,
  CandleInterval interval = CandleInterval.m1,
  String close = '67421.35',
  int sequence = 1,
  bool closed = false,
  int tradeCount = 1,
}) {
  return Candle(
    interval: interval,
    startTime: _start(minute),
    open: Money.parse('67400.00'),
    high: Money.parse('67450.00'),
    low: Money.parse('67390.00'),
    close: Money.parse(close),
    volume: Quantity.parse('1.00000000'),
    tradeCount: tradeCount,
    sourceSequence: sequence,
    closed: closed,
  );
}

void main() {
  group('CandleMerger merge table', () {
    test(
      'M-07 a newer timestamp appends and finalises the previous bucket',
      () {
        final CandleMerger merger = CandleMerger();
        final List<Candle> first = merger.merge(
          <Candle>[],
          _candle(minute: 0, sequence: 10, tradeCount: 4),
        );
        expect(first.length, 1);
        expect(first.single.closed, isFalse);

        final List<Candle> second = merger.merge(
          first,
          _candle(minute: 1, sequence: 11, tradeCount: 1),
        );
        expect(second.length, 2);
        expect(
          second[0].closed,
          isTrue,
          reason: 'the previous bucket finalises',
        );
        expect(second[1].startTime, _start(1));
        expect(second[1].closed, isFalse);
        // The input list is never mutated.
        expect(first.length, 1);
        expect(first.single.closed, isFalse);
      },
    );

    test('M-07 a duplicate identity does not grow the list', () {
      final CandleMerger merger = CandleMerger();
      final List<Candle> series = merger.merge(
        <Candle>[],
        _candle(minute: 0, sequence: 10, tradeCount: 3),
      );
      final List<Candle> again = merger.merge(
        series,
        _candle(minute: 0, sequence: 10, tradeCount: 3),
      );
      expect(again.length, 1);
      expect(identical(again, series), isTrue);
      expect(merger.ignoredCount, 1);
      expect(merger.appendedCount, 1);
    });

    test('M-07 a higher sourceSequence replaces the bucket', () {
      final CandleMerger merger = CandleMerger();
      final List<Candle> series = merger.merge(
        <Candle>[],
        _candle(minute: 0, sequence: 10, close: '67400.00'),
      );
      final List<Candle> updated = merger.merge(
        series,
        _candle(minute: 0, sequence: 11, close: '67499.99', tradeCount: 2),
      );
      expect(updated.length, 1);
      expect(updated.single.close.format(), '67499.99');
      expect(updated.single.sourceSequence, 11);
      expect(updated.single.tradeCount, 2);
      expect(merger.replacedCount, 1);
      expect(merger.ignoredCount, 0);
    });

    test('M-07 a lower or equal sourceSequence is ignored and counted', () {
      final CandleMerger merger = CandleMerger();
      final List<Candle> series = merger.merge(
        <Candle>[],
        _candle(minute: 0, sequence: 10, close: '67400.00'),
      );
      final List<Candle> stale = merger.merge(
        series,
        _candle(minute: 0, sequence: 9, close: '1.00'),
      );
      expect(stale.single.close.format(), '67400.00');
      expect(merger.ignoredCount, 1);
    });

    test('M-07 a closed bucket is immutable', () {
      final CandleMerger merger = CandleMerger();
      final List<Candle> series = merger.merge(
        <Candle>[],
        _candle(minute: 0, sequence: 10, closed: true, close: '67400.00'),
      );
      final List<Candle> late = merger.merge(
        series,
        _candle(minute: 0, sequence: 99, close: '1.00'),
      );
      expect(late.single.close.format(), '67400.00');
      expect(late.single.sourceSequence, 10);
      expect(merger.ignoredCount, 1);
    });

    test('M-07 a candle_closed frame always finalises the active bucket', () {
      final CandleMerger merger = CandleMerger();
      final List<Candle> series = merger.merge(
        <Candle>[],
        _candle(minute: 0, sequence: 10, close: '67400.00'),
      );
      final List<Candle> closed = merger.merge(
        series,
        _candle(minute: 0, sequence: 10, closed: true, close: '67421.35'),
      );
      expect(closed.single.closed, isTrue);
      expect(closed.single.close.format(), '67421.35');
      expect(merger.replacedCount, 1);
    });

    test('M-07 an older bucket than the window is ignored', () {
      final CandleMerger merger = CandleMerger();
      final List<Candle> series = merger.merge(
        <Candle>[],
        _candle(minute: 10, sequence: 10),
      );
      final List<Candle> older = merger.merge(
        series,
        _candle(minute: 5, sequence: 5),
      );
      expect(older.length, 1);
      expect(older.single.startTime, _start(10));
      expect(merger.ignoredCount, 1);
    });

    test(
      'M-07 a history response overlapping live candles dedupes by identity',
      () {
        final CandleMerger merger = CandleMerger();
        List<Candle> series = merger.merge(
          <Candle>[],
          _candle(minute: 2, sequence: 20, close: '100.00'),
        );
        series = merger.mergeHistory(series, <Candle>[
          _candle(minute: 0, sequence: 10, close: '10.00'),
          _candle(minute: 1, sequence: 15, close: '15.00'),
          // Same identity as the live bucket but an older sequence: ignored.
          _candle(minute: 2, sequence: 12, close: '12.00'),
        ]);
        expect(series.length, 3);
        expect(series[0].startTime, _start(0));
        expect(series[1].startTime, _start(1));
        expect(series[2].close.format(), '100.00');
        expect(series[2].sourceSequence, 20);
      },
    );

    test('M-07 identity includes the interval', () {
      final CandleMerger merger = CandleMerger();
      List<Candle> series = merger.merge(
        <Candle>[],
        _candle(minute: 0, interval: CandleInterval.m1, sequence: 10),
      );
      series = merger.merge(
        series,
        _candle(minute: 0, interval: CandleInterval.m5, sequence: 3),
      );
      expect(series.length, 2);
    });

    test(
      'M-07 the retained window is bounded and keeps the newest candles',
      () {
        final CandleMerger merger = CandleMerger(retention: 3);
        var series = <Candle>[];
        for (var minute = 0; minute < 6; minute++) {
          series = merger.merge(
            series,
            _candle(minute: minute, sequence: minute),
          );
        }
        expect(series.length, 3);
        expect(series.first.startTime, _start(3));
        expect(series.last.startTime, _start(5));
      },
    );
  });
}
