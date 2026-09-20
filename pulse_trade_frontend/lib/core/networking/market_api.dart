import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';

/// The REST surface of the backend, expressed in domain types only.
///
/// Every method either completes with the domain value or throws the
/// [AppFailure] produced by `FailureMapper` — never a raw `DioException`, and
/// never a `Result`. Folding a failure into a `Result` is the repository's job,
/// so this layer stays a thin, replaceable transport and a bloc
/// can be driven by a fake implementation with no socket at all.
///
/// The interface deliberately returns domain entities rather than wire DTOs so
/// the same object can be produced by REST, by a WebSocket frame, or by cache,
/// and the order-book synchronizer cannot tell which one it got.
abstract interface class MarketApi {
  /// Every market row in the roster, each with its latest price.
  Future<List<MarketInfo>> getMarkets();

  /// The rolling 24h summary for [symbol].
  Future<MarketSummary> getSummary(String symbol);

  /// A full order-book image for [symbol] at the engine's current update id.
  Future<OrderBookSnapshot> getOrderBook(String symbol);

  /// Up to [limit] ascending candles for [symbol] at [interval].
  ///
  /// Ascending order is part of the REST contract, so callers may
  /// append without sorting.
  Future<List<Candle>> getCandles(
    String symbol,
    CandleInterval interval, {
    int limit = 500,
  });

  /// The most recent trades for [symbol], newest first.
  Future<List<Trade>> getRecentTrades(String symbol, {int limit = 50});

  /// The liveness/readiness probe (`GET /health`).
  ///
  /// The detailed engine/metrics fields are absent from this response.
  Future<HealthSnapshot> getHealth();

  /// The detailed health report (`GET /api/v1/health`).
  Future<HealthSnapshot> getDetailedHealth();

  /// Aggregate counters and current health for the diagnostics screen.
  Future<MetricsSnapshot> getMetricsSummary();

  /// The bucketed RTT/jitter series for the diagnostic chart.
  ///
  /// [window] is the look-back range and [bucket] the aggregation width.
  Future<List<LatencyBucket>> getLatencyBuckets({
    String? sessionId,
    required Duration window,
    required Duration bucket,
  });

  /// Tier transition history with the reasons the backend recorded.
  Future<List<TierTransitionRecord>> getTierTransitions({Duration? window});

  /// Session lifecycle records, newest first, capped at [limit].
  Future<List<SessionRecord>> getSessions({int limit = 50});

  /// Delivered-versus-target rate windows.
  Future<List<DeliveryWindow>> getDeliveryWindows({
    String? sessionId,
    Duration? window,
  });
}

/// Decides whether a network attempt may be made at all.
///
/// `true` means the call may be attempted. `false` means the caller must not
/// touch the transport: it must fail immediately with [OfflineFailure] and let
/// the cache answer, so a device in airplane mode never waits for a connect
/// timeout it cannot win.
///
/// The `UNKNOWN` state — the first reachability probe has not finished yet —
/// must return `true`, allowing exactly one probe attempt. Blocking on an
/// unresolved probe would stall the user's very first load, and a single failed
/// probe is cheap compared with a cold start that renders nothing.
abstract interface class OfflineGate {
  /// Whether one network call may be attempted right now.
  Future<bool> canCall();
}

/// An [OfflineGate] that always allows the call.
///
/// Used in tests that care about transport behaviour rather than connectivity,
/// and as the default wiring when no connectivity service is available. It
/// performs no probe, so an offline device is only discovered by the attempt
/// itself. It is never used in production.
final class AlwaysOnlineGate implements OfflineGate {
  /// Creates the gate. Const because it holds no state.
  const AlwaysOnlineGate();

  @override
  Future<bool> canCall() async => true;
}

/// A [MarketApi] decorator that refuses every call while offline.
///
/// The gate is applied here, once, rather than as an `if (offline)` branch in
/// each repository or bloc, so a newly added API method is gated automatically
/// and cannot forget the check. When the gate says no, the inner transport is
/// not touched at all (the test asserts the fake recorded zero calls), the
/// `offline_calls_blocked_total` counter is incremented, and exactly one
/// structured WARN is emitted so a log reader can see the refusal without
/// reading a line per retry.
final class OfflineGatedMarketApi implements MarketApi {
  /// Wraps [_inner] and consults [_gate] before every call.
  const OfflineGatedMarketApi({
    required this._inner,
    required this._gate,
    required this._metrics,
  });

  final MarketApi _inner;
  final OfflineGate _gate;
  final OnDeviceMetrics _metrics;

  @override
  Future<List<MarketInfo>> getMarkets() async {
    await _assertOnline();
    return _inner.getMarkets();
  }

  @override
  Future<MarketSummary> getSummary(String symbol) async {
    await _assertOnline();
    return _inner.getSummary(symbol);
  }

  @override
  Future<OrderBookSnapshot> getOrderBook(String symbol) async {
    await _assertOnline();
    return _inner.getOrderBook(symbol);
  }

  @override
  Future<List<Candle>> getCandles(
    String symbol,
    CandleInterval interval, {
    int limit = 500,
  }) async {
    await _assertOnline();
    return _inner.getCandles(symbol, interval, limit: limit);
  }

  @override
  Future<List<Trade>> getRecentTrades(String symbol, {int limit = 50}) async {
    await _assertOnline();
    return _inner.getRecentTrades(symbol, limit: limit);
  }

  @override
  Future<HealthSnapshot> getHealth() async {
    await _assertOnline();
    return _inner.getHealth();
  }

  @override
  Future<HealthSnapshot> getDetailedHealth() async {
    await _assertOnline();
    return _inner.getDetailedHealth();
  }

  @override
  Future<MetricsSnapshot> getMetricsSummary() async {
    await _assertOnline();
    return _inner.getMetricsSummary();
  }

  @override
  Future<List<LatencyBucket>> getLatencyBuckets({
    String? sessionId,
    required Duration window,
    required Duration bucket,
  }) async {
    await _assertOnline();
    return _inner.getLatencyBuckets(
      sessionId: sessionId,
      window: window,
      bucket: bucket,
    );
  }

  @override
  Future<List<TierTransitionRecord>> getTierTransitions({
    Duration? window,
  }) async {
    await _assertOnline();
    return _inner.getTierTransitions(window: window);
  }

  @override
  Future<List<SessionRecord>> getSessions({int limit = 50}) async {
    await _assertOnline();
    return _inner.getSessions(limit: limit);
  }

  @override
  Future<List<DeliveryWindow>> getDeliveryWindows({
    String? sessionId,
    Duration? window,
  }) async {
    await _assertOnline();
    return _inner.getDeliveryWindows(sessionId: sessionId, window: window);
  }

  /// Throws [OfflineFailure] when the gate refuses, after counting and logging.
  Future<void> _assertOnline() async {
    final bool allowed = await _gate.canCall();
    if (allowed) return;

    _metrics.increment(MetricNames.offlineCallsBlockedTotal);
    AppLogger.warn(
      LogEvents.offlineCallBlocked,
      fields: const <String, Object?>{
        LogFields.component: LogComponents.transport,
      },
    );
    // The contract of this layer is to throw the typed failure rather than a
    // transport exception; `only_throw_errors` prefers Exception/Error, but
    // AppFailure is the app-wide failure currency.
    // ignore: only_throw_errors
    throw const OfflineFailure();
  }
}
