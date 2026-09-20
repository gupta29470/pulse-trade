/// Canonical field names for the structured JSON log schema.
///
/// Constants rather than string literals at the call site: a typo in a field
/// name is invisible in a log stream, so the vocabulary lives in one file.
abstract final class LogFields {
  const LogFields._();

  /// RFC3339 with milliseconds, UTC.
  static const String time = 'time';

  /// `DEBUG` | `INFO` | `WARN` | `ERROR`.
  static const String level = 'level';

  /// Stable snake_case event slug. Never interpolated.
  static const String msg = 'msg';

  /// Always `pulsetrade-frontend`.
  static const String service = 'service';

  /// Build version.
  static const String version = 'version';

  /// Full session id (`sess_…`).
  static const String sessionId = 'sessionId';

  /// Six-character display id shown on the diagnostics screen.
  static const String shortId = 'shortId';

  /// Per-request / per-fault id.
  static const String correlationId = 'correlationId';

  /// Equals [correlationId] when a request spans layers.
  static const String traceId = 'traceId';

  /// `connectivity` | `transport` | `orderbook` | `candle` | … (see [LogComponents]).
  static const String component = 'component';

  /// Finite enum naming the specific action.
  static const String event = 'event';

  /// Market symbol, canonical id.
  static const String symbol = 'symbol';

  /// Candle interval id (`1m`, `5m`, …).
  static const String interval = 'interval';

  /// Engine book update id.
  static const String updateId = 'updateId';

  /// The first update id of an applied range.
  static const String firstUpdateId = 'firstUpdateId';

  /// The last update id of an applied range.
  static const String lastUpdateId = 'lastUpdateId';

  /// Engine trade id.
  static const String tradeId = 'tradeId';

  /// Frame sequence number from the server envelope.
  static const String seq = 'seq';

  /// Current delivery tier.
  static const String tier = 'tier';

  /// Previous delivery tier.
  static const String fromTier = 'fromTier';

  /// Manual tier override (`OFF`, `AUTO`, `FULL`, …).
  static const String override = 'override';

  /// Machine-readable reason slug (`GOOD_HEALTH`, `HIGH_RTT`, …).
  static const String reason = 'reason';

  /// Measured round-trip time in milliseconds.
  static const String rttMs = 'rttMs';

  /// Measured jitter in milliseconds.
  static const String jitterMs = 'jitterMs';

  /// Delivered messages per second actually achieved.
  static const String effectiveRate = 'effectiveRate';

  /// Delivered messages per second the tier targets.
  static const String targetRate = 'targetRate';

  /// Duration of a timed operation.
  static const String durationMs = 'durationMs';

  /// Number of items in an aggregated event.
  static const String count = 'count';

  /// Number of dropped items.
  static const String dropped = 'dropped';

  /// Number of coalesced items.
  static const String coalesced = 'coalesced';

  /// Wrapped error text.
  static const String error = 'error';

  /// Typed error code.
  static const String errorCode = 'errorCode';

  /// Whether a protocol error closed the socket.
  static const String fatal = 'fatal';

  /// Cache key, when a log record concerns one entry.
  static const String cacheKey = 'cacheKey';

  /// Category of a log record, when one is grouped by kind.
  static const String category = 'category';

  /// Keys whose values are never written to the log.
  static const Set<String> redacted = <String>{
    'token',
    'accessToken',
    'refreshToken',
    'password',
    'secret',
    'apiKey',
    'deviceFingerprint',
  };
}

/// The fixed `component` vocabulary.
abstract final class LogComponents {
  const LogComponents._();

  /// Market simulation engine (backend-owned; used for received state).
  static const String engine = 'engine';

  /// WebSocket session lifecycle.
  static const String session = 'session';

  /// Adaptive delivery / tier state.
  static const String tier = 'tier';

  /// Order-book synchronisation.
  static const String orderbook = 'orderbook';

  /// Candle history and merging.
  static const String candle = 'candle';

  /// Metrics and telemetry.
  static const String metrics = 'metrics';

  /// REST/WS transport.
  static const String transport = 'transport';

  /// Internet reachability.
  static const String connectivity = 'connectivity';

  /// Cache reads and writes.
  static const String cache = 'cache';
}

/// Stable `msg` slugs. Values are never interpolated.
abstract final class LogEvents {
  const LogEvents._();

  /// WebSocket connection established.
  static const String wsConnected = 'ws_connected';

  /// WebSocket connection closed.
  static const String wsDisconnected = 'ws_disconnected';

  /// A reconnect attempt was scheduled.
  static const String wsReconnectScheduled = 'ws_reconnect_scheduled';

  /// A client frame was rejected before it reached the transport.
  static const String offlineCallBlocked = 'offline_call_blocked';

  /// The connectivity probe changed state.
  static const String connectivityChanged = 'connectivity_changed';

  /// A book range gap was detected.
  static const String bookGapDetected = 'book_gap_detected';

  /// A duplicate delta range arrived.
  static const String bookDuplicateDelta = 'book_duplicate_delta';

  /// A stale (older) delta range arrived.
  static const String bookStaleDelta = 'book_stale_delta';

  /// Book recovery started.
  static const String bookRecoveryStarted = 'book_recovery_started';

  /// Book recovery completed.
  static const String bookRecoveryCompleted = 'book_recovery_completed';

  /// Book recovery gave up.
  static const String bookRecoveryFailed = 'book_recovery_failed';

  /// A candle update was merged into the series.
  static const String candleMerged = 'candle_merged';

  /// A stale history response was rejected.
  static const String historyResponseStale = 'history_response_stale';

  /// History loaded for an interval.
  static const String historyLoaded = 'history_loaded';

  /// A malformed frame was rejected without touching state.
  static const String malformedFrame = 'malformed_frame';

  /// A cache entry was evicted.
  static const String cacheEvicted = 'cache_evicted';

  /// A cache write failed.
  static const String cacheWriteFailed = 'cache_write_failed';

  /// An uncaught error was captured by a global safety net.
  static const String uncaughtError = 'uncaught_error';
}
