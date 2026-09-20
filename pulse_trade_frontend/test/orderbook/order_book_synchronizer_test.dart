import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/local_order_book.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';

const String _symbol = 'BTCUSDT';
final DateTime _serverTime = DateTime.utc(2026, 9, 17, 12, 41, 3, 240);

List<OrderBookLevel> _levels(List<List<String>> raw) => <OrderBookLevel>[
  for (final List<String> pair in raw)
    OrderBookLevel(
      price: Money.parse(pair[0]),
      quantity: Quantity.parse(pair[1]),
    ),
];

OrderBookDeltaMessage _delta({
  required int first,
  required int last,
  List<List<String>> bids = const <List<String>>[],
  List<List<String>> asks = const <List<String>>[],
  int epoch = 1,
}) {
  return OrderBookDeltaMessage(
    version: 1,
    serverTime: _serverTime,
    seq: last,
    symbol: _symbol,
    epoch: epoch,
    firstUpdateId: first,
    lastUpdateId: last,
    bids: _levels(bids),
    asks: _levels(asks),
  );
}

OrderBookSnapshot _snapshot({
  required int updateId,
  List<List<String>> bids = const <List<String>>[],
  List<List<String>> asks = const <List<String>>[],
  int epoch = 1,
}) {
  return OrderBookSnapshot(
    symbol: _symbol,
    epoch: epoch,
    updateId: updateId,
    bids: _levels(bids),
    asks: _levels(asks),
    serverTime: _serverTime,
  );
}

/// Applies every [ApplyLevels] effect to a real book so a test can assert on the
/// projection the UI would render.
LocalOrderBook _applyAll(List<OrderBookEffect> effects) {
  final LocalOrderBook book = LocalOrderBook(
    symbol: _symbol,
    epoch: 1,
    appliedUpdateId: 0,
  );
  for (final OrderBookEffect effect in effects) {
    if (effect is ApplyLevels) {
      book.applyLevels(effect.bids, isBid: true);
      book.applyLevels(effect.asks, isBid: false);
    }
  }
  return book;
}

void main() {
  group('OrderBookSynchronizer', () {
    test(
      'M-03 buffered deltas 10429 and 10430-10431 are applied after snapshot 10428',
      () {
        final OrderBookSynchronizer sync = OrderBookSynchronizer(
          clock: FakeClock(),
        );

        final List<OrderBookEffect> started = sync.start(epoch: 1);
        expect(started.whereType<RequestSnapshot>().length, 1);
        expect(sync.state, OrderBookState.syncing);

        // Deltas arrive while the snapshot is still in flight: they are buffered,
        // never applied, because continuity cannot be proven yet.
        final List<OrderBookEffect> firstBuffer = sync.handle(
          DeltaArrived(
            _delta(
              first: 10429,
              last: 10429,
              bids: <List<String>>[
                <String>['67420.90', '0.40000000'],
              ],
            ),
          ),
        );
        expect(firstBuffer.whereType<ApplyLevels>(), isEmpty);
        expect(sync.bufferedRangeCount, 1);

        sync.handle(
          DeltaArrived(
            _delta(
              first: 10430,
              last: 10431,
              bids: <List<String>>[
                <String>['67420.80', '0.50000000'],
              ],
              asks: <List<String>>[
                <String>['67421.10', '0.25000000'],
              ],
            ),
          ),
        );
        expect(sync.bufferedRangeCount, 2);

        final List<OrderBookEffect> applied = sync.handle(
          SnapshotArrived(
            _snapshot(
              updateId: 10428,
              bids: <List<String>>[
                <String>['67420.90', '0.38000000'],
                <String>['67420.55', '0.71000000'],
              ],
              asks: <List<String>>[
                <String>['67421.10', '0.22000000'],
                <String>['67421.30', '0.61000000'],
              ],
            ),
          ),
        );

        final List<ApplyLevels> applyEffects = applied
            .whereType<ApplyLevels>()
            .toList();
        expect(applyEffects.length, 3);
        expect(applyEffects[0].isSnapshot, isTrue);
        expect(applyEffects[0].appliedUpdateId, 10428);
        expect(applyEffects[1].appliedUpdateId, 10429);
        expect(applyEffects[2].appliedUpdateId, 10431);

        expect(sync.appliedUpdateId, 10431);
        expect(sync.bufferedRangeCount, 0);
        expect(sync.state, OrderBookState.live);
        expect(
          sync.recoveryCount,
          0,
          reason:
              'buffering during the snapshot is normal synchronisation, not recovery',
        );

        final LocalOrderBook book = _applyAll(applied);
        book.appliedUpdateId = sync.appliedUpdateId;
        expect(book.appliedUpdateId, 10431);

        final top = book.top(10);
        // 0.40 is absolute, so it replaces the snapshot's 0.38 at the same price.
        expect(top.bids[0].price.format(), '67420.90');
        expect(top.bids[0].quantity.format(), '0.40000000');
        expect(top.bids[1].price.format(), '67420.80');
        expect(top.bids[2].price.format(), '67420.55');
        expect(top.asks[0].price.format(), '67421.10');
        expect(top.asks[0].quantity.format(), '0.25000000');
        expect(top.bestBid!.format(), '67420.90');
        expect(top.bestAsk!.format(), '67421.10');
        expect(top.spread!.format(), '0.20');
      },
    );

    test(
      'M-04 a live gap enters RECOVERING and never applies the gap range',
      () {
        final OrderBookSynchronizer sync = OrderBookSynchronizer(
          clock: FakeClock(),
        );

        sync.start(epoch: 1);
        sync.handle(
          SnapshotArrived(
            _snapshot(
              updateId: 10430,
              bids: <List<String>>[
                <String>['67420.90', '0.38000000'],
              ],
              asks: <List<String>>[
                <String>['67421.10', '0.22000000'],
              ],
            ),
          ),
        );
        expect(sync.state, OrderBookState.live);
        expect(sync.appliedUpdateId, 10430);

        final List<OrderBookEffect> gap = sync.handle(
          DeltaArrived(
            _delta(
              first: 10432,
              last: 10432,
              bids: <List<String>>[
                <String>['67420.70', '0.10000000'],
              ],
            ),
          ),
        );

        expect(sync.state, OrderBookState.recovering);
        expect(
          sync.appliedUpdateId,
          10430,
          reason: 'a gap range is never applied',
        );
        expect(gap.whereType<ApplyLevels>(), isEmpty);
        final List<RequestSnapshot> requests = gap
            .whereType<RequestSnapshot>()
            .toList();
        expect(requests.length, 1);
        expect(requests.first.reason, 'gap');
        expect(sync.bufferedRangeCount, 1);

        // The recovery snapshot is one update behind the gap range, so the range
        // buffered during recovery completes the sequence.
        final List<OrderBookEffect> recovered = sync.handle(
          SnapshotArrived(
            _snapshot(
              updateId: 10431,
              bids: <List<String>>[
                <String>['67420.90', '0.38000000'],
              ],
              asks: <List<String>>[
                <String>['67421.10', '0.22000000'],
              ],
            ),
          ),
        );

        final List<ApplyLevels> applyEffects = recovered
            .whereType<ApplyLevels>()
            .toList();
        expect(applyEffects.length, 2);
        expect(applyEffects[0].isSnapshot, isTrue);
        expect(applyEffects[0].appliedUpdateId, 10431);
        expect(applyEffects[1].appliedUpdateId, 10432);
        expect(sync.appliedUpdateId, 10432);
        expect(sync.state, OrderBookState.live);
      },
    );

    test('M-04 a second gap during recovery discards the obsolete buffer', () {
      final OrderBookSynchronizer sync = OrderBookSynchronizer(
        clock: FakeClock(),
      );
      sync.start(epoch: 1);
      sync.handle(SnapshotArrived(_snapshot(updateId: 10430)));

      sync.handle(DeltaArrived(_delta(first: 10432, last: 10432)));
      expect(sync.state, OrderBookState.recovering);
      expect(
        sync.bufferedRangeCount,
        1,
        reason:
            'the offending range is buffered so it can be applied once the '
            'snapshot reconciles with it',
      );

      final List<OrderBookEffect> secondGap = sync.handle(
        DeltaArrived(_delta(first: 10450, last: 10450)),
      );
      expect(sync.state, OrderBookState.recovering);
      final List<RequestSnapshot> requests = secondGap
          .whereType<RequestSnapshot>()
          .toList();
      expect(requests.length, 1);
      expect(requests.first.reason, 'gap_in_buffer');
      expect(requests.first.attempt, 2);
      // The 10432 range is gone: only the newest range is kept.
      expect(sync.bufferedRangeCount, 1);

      // The second snapshot is one update behind 10450, so only that range applies.
      final List<OrderBookEffect> recovered = sync.handle(
        SnapshotArrived(_snapshot(updateId: 10449)),
      );
      final List<ApplyLevels> applyEffects = recovered
          .whereType<ApplyLevels>()
          .toList();
      expect(applyEffects.length, 2);
      expect(applyEffects[1].appliedUpdateId, 10450);
      expect(sync.appliedUpdateId, 10450);
      expect(sync.state, OrderBookState.live);
    });

    test('M-04 the fourth recovery failure is terminal', () {
      final OrderBookSynchronizer sync = OrderBookSynchronizer(
        clock: FakeClock(),
      );
      sync.start(epoch: 1);
      sync.handle(SnapshotArrived(_snapshot(updateId: 10430)));

      sync.handle(DeltaArrived(_delta(first: 10432, last: 10432)));
      expect(sync.state, OrderBookState.recovering);
      sync.handle(DeltaArrived(_delta(first: 10450, last: 10450)));
      expect(sync.state, OrderBookState.recovering);
      sync.handle(DeltaArrived(_delta(first: 10460, last: 10460)));
      expect(sync.state, OrderBookState.recovering);
      expect(sync.recoveryAttempts, 3);

      final List<OrderBookEffect> fourth = sync.handle(
        DeltaArrived(_delta(first: 10470, last: 10470)),
      );
      expect(sync.state, OrderBookState.error);
      expect(sync.isFrozen, isTrue);
      expect(fourth.whereType<RequestSnapshot>(), isEmpty);
      expect(
        fourth.whereType<OrderBookStateChanged>().last.to,
        OrderBookState.error,
      );
    });

    test('M-05 duplicate and stale ranges are inert', () {
      final OrderBookSynchronizer sync = OrderBookSynchronizer(
        clock: FakeClock(),
      );
      sync.start(epoch: 1);
      sync.handle(
        SnapshotArrived(
          _snapshot(
            updateId: 10430,
            bids: <List<String>>[
              <String>['67420.90', '0.38000000'],
            ],
          ),
        ),
      );

      final List<OrderBookEffect> applied = sync.handle(
        DeltaArrived(
          _delta(
            first: 10431,
            last: 10431,
            bids: <List<String>>[
              <String>['67420.90', '0.50000000'],
            ],
          ),
        ),
      );
      expect(applied.whereType<ApplyLevels>().length, 1);
      expect(sync.appliedUpdateId, 10431);

      // Same range twice: nothing is applied and the watermark does not move.
      final List<OrderBookEffect> duplicate = sync.handle(
        DeltaArrived(
          _delta(
            first: 10431,
            last: 10431,
            bids: <List<String>>[
              <String>['67420.90', '9.99000000'],
            ],
          ),
        ),
      );
      expect(duplicate.whereType<ApplyLevels>(), isEmpty);
      expect(duplicate, isEmpty);
      expect(sync.appliedUpdateId, 10431);
      expect(sync.duplicateCount, 1);

      // An older range is ignored and counted as stale, not as duplicate.
      final List<OrderBookEffect> stale = sync.handle(
        DeltaArrived(_delta(first: 10420, last: 10425)),
      );
      expect(stale, isEmpty);
      expect(sync.appliedUpdateId, 10431);
      expect(sync.staleCount, 1);
      expect(sync.duplicateCount, 1);
    });

    test('a deltas buffer overflow forces a recovery instead of growing', () {
      final OrderBookSynchronizer sync = OrderBookSynchronizer(
        clock: FakeClock(),
        bufferCap: 1000,
      );
      sync.start(epoch: 1);

      for (var id = 1; id <= 999; id++) {
        sync.handle(DeltaArrived(_delta(first: id, last: id)));
      }
      expect(sync.bufferedRangeCount, 999);

      sync.handle(DeltaArrived(_delta(first: 1000, last: 1000)));
      expect(sync.bufferedRangeCount, 1000);
      expect(sync.state, OrderBookState.syncing);

      sync.handle(DeltaArrived(_delta(first: 1001, last: 1001)));
      expect(sync.state, OrderBookState.recovering);
      expect(
        sync.bufferedRangeCount,
        0,
        reason:
            'entering recovery discards buffered ranges: they are rebuilt '
            'against the snapshot that recovery requests',
      );
    });

    test('an epoch mismatch resets the book and resynchronises', () {
      final OrderBookSynchronizer sync = OrderBookSynchronizer(
        clock: FakeClock(),
      );
      sync.start(epoch: 1);
      sync.handle(SnapshotArrived(_snapshot(updateId: 10430)));
      expect(sync.state, OrderBookState.live);

      final List<OrderBookEffect> effects = sync.handle(
        DeltaArrived(_delta(first: 5, last: 5, epoch: 2)),
      );

      expect(sync.epoch, 2);
      expect(sync.state, OrderBookState.syncing);
      expect(sync.appliedUpdateId, 0);
      final List<RequestSnapshot> requests = effects
          .whereType<RequestSnapshot>()
          .toList();
      expect(requests.length, 1);
      expect(requests.first.reason, 'epoch_mismatch');
    });

    test('a connection loss freezes the book without clearing it', () {
      final OrderBookSynchronizer sync = OrderBookSynchronizer(
        clock: FakeClock(),
      );
      sync.start(epoch: 1);
      sync.handle(SnapshotArrived(_snapshot(updateId: 10430)));

      final List<OrderBookEffect> effects = sync.handle(const ConnectionLost());
      expect(sync.state, OrderBookState.stale);
      expect(sync.appliedUpdateId, 10430);
      expect(effects.whereType<ApplyLevels>(), isEmpty);
      expect(sync.isFrozen, isTrue);

      // While stale, a delta must not mutate the book.
      final List<OrderBookEffect> whileStale = sync.handle(
        DeltaArrived(_delta(first: 10431, last: 10431)),
      );
      expect(whileStale.whereType<ApplyLevels>(), isEmpty);
      expect(sync.appliedUpdateId, 10430);
    });

    test('a snapshot after a failure is authoritative and returns to live', () {
      final OrderBookSynchronizer sync = OrderBookSynchronizer(
        clock: FakeClock(),
      );
      sync.start(epoch: 1);
      sync.handle(SnapshotArrived(_snapshot(updateId: 10430)));
      for (var i = 0; i < 4; i++) {
        sync.handle(
          DeltaArrived(_delta(first: 20000 + i * 10, last: 20000 + i * 10)),
        );
      }
      expect(sync.state, OrderBookState.error);

      sync.handle(SnapshotArrived(_snapshot(updateId: 20029)));
      expect(sync.state, OrderBookState.live);
      expect(sync.appliedUpdateId, 20030);
    });
  });
}
