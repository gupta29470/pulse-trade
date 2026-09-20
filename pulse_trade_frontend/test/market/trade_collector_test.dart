import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/entities/trade_side.dart';
import 'package:pulse_trade_frontend/domain/market/trade_collector.dart';

final DateTime _timestamp = DateTime.utc(2026, 9, 17, 12, 41, 3);

Trade _trade(int id, {int omitted = 0}) => Trade(
  tradeId: id,
  symbol: 'BTCUSDT',
  timestamp: _timestamp,
  price: Money.parse('67421.35'),
  quantity: Quantity.parse('0.10000000'),
  side: id.isEven ? TradeSide.buy : TradeSide.sell,
  omittedCount: omitted,
);

void main() {
  group('TradeCollector (M-12)', () {
    test('the list is capped at 50 with the newest first', () {
      final TradeCollector collector = TradeCollector();

      for (var id = 1; id <= 60; id++) {
        expect(collector.add(_trade(id)), isTrue);
      }

      expect(collector.length, 50);
      expect(collector.trades.first.tradeId, 60);
      expect(collector.trades.last.tradeId, 11);
      expect(collector.droppedCount, 10);
      expect(collector.newestTradeId, 60);

      // Stable identity: every row is unique, which is what makes
      // ValueKey(tradeId) safe in the list.
      final Set<int> ids = collector.trades
          .map((Trade trade) => trade.tradeId)
          .toSet();
      expect(ids.length, 50);
    });

    test('duplicate ids collapse and are counted', () {
      final OnDeviceMetrics metrics = OnDeviceMetrics();
      final TradeCollector collector = TradeCollector(metrics: metrics);

      expect(collector.add(_trade(1)), isTrue);
      expect(collector.add(_trade(2)), isTrue);
      expect(collector.add(_trade(1)), isFalse);

      expect(collector.length, 2);
      expect(collector.duplicateCount, 1);
      expect(metrics.value(MetricNames.duplicateTradesTotal), 1);
      expect(collector.trades.first.tradeId, 2);
    });

    test('out-of-order ids are ignored and counted', () {
      final OnDeviceMetrics metrics = OnDeviceMetrics();
      final TradeCollector collector = TradeCollector(metrics: metrics);

      collector.add(_trade(10));
      expect(collector.add(_trade(5)), isFalse);

      expect(collector.length, 1);
      expect(collector.outOfOrderCount, 1);
      expect(collector.newestTradeId, 10);
      expect(metrics.value(MetricNames.outOfOrderTradesTotal), 1);
    });

    test('a reordered id is not double-counted as a duplicate', () {
      final TradeCollector collector = TradeCollector();
      collector.add(_trade(10));
      collector.add(_trade(5));
      expect(collector.duplicateCount, 0);
      expect(collector.outOfOrderCount, 1);
    });

    test('a batch is accepted oldest first', () {
      final TradeCollector collector = TradeCollector();
      final int accepted = collector.addBatch(<Trade>[
        _trade(1),
        _trade(2),
        _trade(3),
      ]);
      expect(accepted, 3);
      expect(collector.length, 3);
      expect(collector.trades.first.tradeId, 3);
      expect(collector.trades.last.tradeId, 1);
    });

    test('a batch with a reordered tail keeps only the increasing prefix', () {
      final TradeCollector collector = TradeCollector();
      final int accepted = collector.addBatch(<Trade>[
        _trade(1),
        _trade(2),
        _trade(5),
        _trade(4),
        _trade(6),
      ]);
      expect(accepted, 4);
      expect(collector.outOfOrderCount, 1);
      expect(collector.trades.first.tradeId, 6);
    });

    test('omitted counts are accumulated so the UI can show them', () {
      final TradeCollector collector = TradeCollector();
      collector.add(_trade(1, omitted: 3));
      collector.add(_trade(2, omitted: 4));
      expect(collector.omittedCount, 7);
      expect(collector.trades.first.isCompacted, isTrue);
    });

    test(
      'the duplicate set is bounded but still catches recent duplicates',
      () {
        final TradeCollector collector = TradeCollector(dedupeWindow: 5);
        for (var id = 1; id <= 20; id++) {
          collector.add(_trade(id));
        }
        // The most recent ids are still remembered.
        expect(collector.add(_trade(20)), isFalse);
        expect(collector.duplicateCount, 1);
      },
    );

    test('the exposed list cannot be mutated by a caller', () {
      final TradeCollector collector = TradeCollector();
      collector.add(_trade(1));
      expect(
        () => collector.trades.add(_trade(2)),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('reset forgets the id watermark, clear does not', () {
      final TradeCollector collector = TradeCollector();
      collector.add(_trade(10));
      collector.clear();
      expect(collector.length, 0);
      // The watermark survives a clear, so a stale id is still rejected.
      expect(collector.add(_trade(5)), isFalse);

      collector.reset();
      expect(collector.newestTradeId, 0);
      expect(collector.add(_trade(5)), isTrue);
    });
  });
}
