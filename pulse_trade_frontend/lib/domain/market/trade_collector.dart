import 'dart:collection';

import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';

/// The bounded, deduplicated, newest-first recent-trades list.
///
/// Three rules:
/// * duplicate ids collapse (the id set is bounded so it cannot grow forever),
/// * ids older than the newest seen are ignored and counted, because the
/// canonical trade ids are strictly increasing and a regression means the
/// frame was reordered,
/// * the list never exceeds [capacity], and its identity is stable per row so
/// the list can use `ValueKey(tradeId)`.
final class TradeCollector {
  /// Creates a collector holding at most [capacity] trades.
  TradeCollector({
    this.capacity = 50,
    this.dedupeWindow = 500,
    OnDeviceMetrics? metrics,
  }) : assert(capacity > 0, 'capacity must be positive'),
       _metrics = metrics ?? OnDeviceMetrics();

  /// Maximum retained trades.
  final int capacity;

  /// How many trade ids are remembered for duplicate detection.
  final int dedupeWindow;

  final OnDeviceMetrics _metrics;
  final List<Trade> _trades = <Trade>[];
  final LinkedHashSet<int> _seenIds = LinkedHashSet<int>();

  int _newestTradeId = 0;
  int _duplicateCount = 0;
  int _outOfOrderCount = 0;
  int _droppedCount = 0;
  int _omittedCount = 0;

  /// The collected trades, newest first. Immutable view.
  List<Trade> get trades => List<Trade>.unmodifiable(_trades);

  /// How many trades are currently held.
  int get length => _trades.length;

  /// The newest trade id seen, or zero before the first trade.
  int get newestTradeId => _newestTradeId;

  /// Duplicate ids rejected.
  int get duplicateCount => _duplicateCount;

  /// Older ids rejected as out of order.
  int get outOfOrderCount => _outOfOrderCount;

  /// Trades evicted by the [capacity] bound.
  int get droppedCount => _droppedCount;

  /// How many intermediate trades the backend told us it omitted.
  int get omittedCount => _omittedCount;

  /// True when no trade has been collected.
  bool get isEmpty => _trades.isEmpty;

  /// Adds one trade. Returns true when it became part of the list.
  bool add(Trade trade) {
    if (_seenIds.contains(trade.tradeId)) {
      _duplicateCount++;
      _metrics.increment(MetricNames.duplicateTradesTotal);
      return false;
    }
    if (_newestTradeId != 0 && trade.tradeId < _newestTradeId) {
      // A strictly increasing id stream is the contract; a regression is a
      // reordered frame, not a new execution.
      _outOfOrderCount++;
      _metrics.increment(MetricNames.outOfOrderTradesTotal);
      return false;
    }

    _remember(trade.tradeId);
    _trades.insert(0, trade);
    _newestTradeId = trade.tradeId;
    _omittedCount += trade.omittedCount;

    while (_trades.length > capacity) {
      _trades.removeLast();
      _droppedCount++;
    }
    return true;
  }

  /// Adds a batch, oldest first, and returns how many were accepted.
  int addBatch(Iterable<Trade> batch) {
    var accepted = 0;
    for (final Trade trade in batch) {
      if (add(trade)) accepted++;
    }
    return accepted;
  }

  /// Empties the list. The dedupe set is kept so a duplicate cannot slip back in
  /// immediately after a UI clear.
  void clear() {
    _trades.clear();
  }

  /// Forgets everything, including the id watermark. Used on an epoch reset.
  void reset() {
    _trades.clear();
    _seenIds.clear();
    _newestTradeId = 0;
  }

  void _remember(int tradeId) {
    _seenIds.add(tradeId);
    while (_seenIds.length > dedupeWindow) {
      _seenIds.remove(_seenIds.first);
    }
  }
}
