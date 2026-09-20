/// Canonical metric names for the on-device counter registry.
///
/// These counters are never persisted to the backend; they exist so the
/// Diagnostics screen and `Copy diagnostics JSON` can prove what this device
/// did (sync decisions, cache behaviour, offline blocks).
abstract final class MetricNames {
  const MetricNames._();

  /// Successful WebSocket dials.
  static const String wsConnectsTotal = 'ws_connects_total';

  /// Reconnect attempts started after a drop.
  static const String wsReconnectsTotal = 'ws_reconnects_total';

  /// History (candle) REST requests issued.
  static const String historyRequestsTotal = 'history_requests_total';

  /// History responses rejected because a newer request superseded them.
  static const String staleHistoryResponsesTotal =
      'stale_history_responses_total';

  /// Cache reads that produced a usable entry.
  static const String cacheHitsTotal = 'cache_hits_total';

  /// Cache reads that produced nothing (absent, expired-version or corrupt).
  static const String cacheMissesTotal = 'cache_misses_total';

  /// Successful cache writes.
  static const String cacheWritesTotal = 'cache_writes_total';

  /// Failed cache writes.
  static const String cacheWriteFailuresTotal = 'cache_write_failures_total';

  /// Network calls refused by the offline gate.
  static const String offlineCallsBlockedTotal = 'offline_calls_blocked_total';

  /// Delta ranges ignored because `lastUpdateId <= appliedUpdateId`.
  static const String duplicateDeltasTotal = 'duplicate_deltas_total';

  /// Delta ranges ignored because they were older than the applied range.
  static const String staleDeltasTotal = 'stale_deltas_total';

  /// Range gaps detected in the delta stream.
  static const String gapsDetectedTotal = 'gaps_detected_total';

  /// Book resynchronisations that completed.
  static const String recoveriesTotal = 'recoveries_total';

  /// Frames rejected as malformed or unknown without mutating state.
  static const String malformedMessagesTotal = 'malformed_messages_total';

  /// Trades ignored because their id was older than the newest seen.
  static const String outOfOrderTradesTotal = 'out_of_order_trades_total';

  /// Trades ignored because the id was already present.
  static const String duplicateTradesTotal = 'duplicate_trades_total';

  /// Pings that received no pong within the 4 s timeout.
  static const String missedPongsTotal = 'missed_pongs_total';

  /// Frames dropped because the socket was not ready to accept them.
  static const String wsFramesDroppedTotal = 'ws_frames_dropped_total';

  /// Builds that exceeded the 16 ms frame budget (debug builds only).
  static const String droppedFramesTotal = 'dropped_frames_total';
}

/// An in-memory, per-process counter registry.
///
/// Deliberately not a singleton: tests construct one per case so a counter can
/// never leak between assertions. The production instance lives in the
/// composition root and is handed to the components that increment it.
final class OnDeviceMetrics {
  /// Creates an empty registry.
  OnDeviceMetrics();

  final Map<String, int> _counters = <String, int>{};

  /// Every counter, including ones that have never been touched.
  static const List<String> knownNames = <String>[
    MetricNames.wsConnectsTotal,
    MetricNames.wsReconnectsTotal,
    MetricNames.historyRequestsTotal,
    MetricNames.staleHistoryResponsesTotal,
    MetricNames.cacheHitsTotal,
    MetricNames.cacheMissesTotal,
    MetricNames.cacheWritesTotal,
    MetricNames.cacheWriteFailuresTotal,
    MetricNames.offlineCallsBlockedTotal,
    MetricNames.duplicateDeltasTotal,
    MetricNames.staleDeltasTotal,
    MetricNames.gapsDetectedTotal,
    MetricNames.recoveriesTotal,
    MetricNames.malformedMessagesTotal,
    MetricNames.outOfOrderTradesTotal,
    MetricNames.duplicateTradesTotal,
    MetricNames.missedPongsTotal,
    MetricNames.wsFramesDroppedTotal,
    MetricNames.droppedFramesTotal,
  ];

  /// Adds [by] to [name] and returns the new value.
  int increment(String name, {int by = 1}) {
    final next = (_counters[name] ?? 0) + by;
    _counters[name] = next;
    return next;
  }

  /// Sets [name] to an absolute value (used for gauges such as cache size).
  void set(String name, int value) {
    _counters[name] = value;
  }

  /// The current value of [name], zero when it has never been incremented.
  int value(String name) => _counters[name] ?? 0;

  /// Syntactic sugar for [value], so call sites read like a dashboard.
  int operator [](String name) => value(name);

  /// A snapshot of the registry, with every known counter present so the
  /// diagnostics JSON has a stable shape.
  Map<String, int> snapshot() {
    final out = <String, int>{for (final name in knownNames) name: value(name)};
    for (final MapEntry<String, int> entry in _counters.entries) {
      out[entry.key] = entry.value;
    }
    return out;
  }

  /// Zeroes every counter.
  void reset() {
    _counters.clear();
  }
}
