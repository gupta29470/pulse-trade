import 'package:dio/dio.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/networking/market_dto_decoder.dart';
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

/// The dio-backed [MarketApi].
///
/// This class is the only REST call site in the app, which is what makes the
/// retry policy, the timeout policy and the error mapping reviewable in one
/// place. It never inspects a transport exception type itself: every
/// thrown object passes through [FailureMapper] first, and the retry decision is
/// taken from the mapped `AppFailure.retryable` flag. That is what keeps
/// `FailureMapper` the single file in `lib/` that names `DioException`.
final class DioMarketApi implements MarketApi {
  /// Creates the client around an already-built [_dio].
  ///
  /// [baseUrl] is applied to every request as an absolute URL, so an injected
  /// `Dio` may carry any (or no) `baseUrl` of its own. [_decoder] is the seam to
  /// the generated DTOs (see [MarketDtoDecoder]). [_metrics] is optional so a
  /// unit test that only cares about decoding need not build a registry.
  DioMarketApi({
    required this._dio,
    required this._failureMapper,
    required this._clock,
    required String baseUrl,
    required this._decoder,
    this._metrics,
  }) : _baseUrl = _stripTrailingSlash(baseUrl) {
    final BaseOptions options = _dio.options;
    options.connectTimeout = _connectTimeout;
    options.receiveTimeout = _receiveTimeout;
    options.sendTimeout = _sendTimeout;
  }

  /// Connect budget: long enough for a slow mobile handshake, short enough that
  /// an unreachable host fails before the user gives up.
  static const Duration _connectTimeout = Duration(seconds: 3);

  /// Receive budget: a history response for 500 candles is not instantaneous.
  static const Duration _receiveTimeout = Duration(seconds: 5);

  /// Send budget; the API is read-only, so this only covers the request head.
  static const Duration _sendTimeout = Duration(seconds: 3);

  /// Retries allowed for one idempotent GET. Two retries cover a single blip
  /// without turning a dead backend into a six-second wait.
  static const int _maxRetries = 2;

  /// Backoff before retry 1 and retry 2.
  static const List<Duration> _retryBackoffs = <Duration>[
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
  ];

  final Dio _dio;
  final FailureMapper _failureMapper;
  final Clock _clock;
  final String _baseUrl;
  final MarketDtoDecoder _decoder;
  final OnDeviceMetrics? _metrics;

  @override
  Future<List<MarketInfo>> getMarkets() => _getWithRetry<List<MarketInfo>>(
    path: '/api/v1/markets',
    query: null,
    decode: _decoder.decodeMarkets,
  );

  @override
  Future<MarketSummary> getSummary(String symbol) =>
      _getWithRetry<MarketSummary>(
        path: '/api/v1/markets/${Uri.encodeComponent(symbol)}/summary',
        query: null,
        decode: _decoder.decodeSummary,
      );

  @override
  Future<OrderBookSnapshot> getOrderBook(String symbol) =>
      _getWithRetry<OrderBookSnapshot>(
        path: '/api/v1/markets/${Uri.encodeComponent(symbol)}/orderbook',
        query: null,
        decode: _decoder.decodeOrderBook,
      );

  @override
  Future<List<Candle>> getCandles(
    String symbol,
    CandleInterval interval, {
    int limit = 500,
  }) {
    _metrics?.increment(MetricNames.historyRequestsTotal);
    return _getWithRetry<List<Candle>>(
      path: '/api/v1/markets/${Uri.encodeComponent(symbol)}/candles',
      query: <String, Object?>{'interval': interval.wire, 'limit': limit},
      decode: _decoder.decodeCandles,
    );
  }

  @override
  Future<List<Trade>> getRecentTrades(String symbol, {int limit = 50}) =>
      _getWithRetry<List<Trade>>(
        path: '/api/v1/markets/${Uri.encodeComponent(symbol)}/trades',
        query: <String, Object?>{'limit': limit},
        decode: _decoder.decodeTrades,
      );

  @override
  Future<HealthSnapshot> getHealth() => _getWithRetry<HealthSnapshot>(
    path: '/health',
    query: null,
    decode: _decoder.decodeHealth,
  );

  @override
  Future<HealthSnapshot> getDetailedHealth() => _getWithRetry<HealthSnapshot>(
    path: '/api/v1/health',
    query: null,
    decode: _decoder.decodeHealth,
  );

  @override
  Future<MetricsSnapshot> getMetricsSummary() => _getWithRetry<MetricsSnapshot>(
    path: '/api/v1/metrics/summary',
    query: null,
    decode: _decoder.decodeMetricsSummary,
  );

  @override
  Future<List<LatencyBucket>> getLatencyBuckets({
    String? sessionId,
    required Duration window,
    required Duration bucket,
  }) => _getWithRetry<List<LatencyBucket>>(
    path: '/api/v1/metrics/latency',
    query: <String, Object?>{
      'sessionId': ?sessionId,
      'bucket': _formatDuration(bucket),
      ..._rangeQuery(window),
    },
    decode: _decoder.decodeLatencyBuckets,
  );

  @override
  Future<List<TierTransitionRecord>> getTierTransitions({Duration? window}) =>
      _getWithRetry<List<TierTransitionRecord>>(
        path: '/api/v1/metrics/tiers',
        query: _rangeQuery(window),
        decode: _decoder.decodeTierTransitions,
      );

  @override
  Future<List<SessionRecord>> getSessions({int limit = 50}) =>
      _getWithRetry<List<SessionRecord>>(
        path: '/api/v1/metrics/sessions',
        query: <String, Object?>{'limit': limit},
        decode: _decoder.decodeSessions,
      );

  @override
  Future<List<DeliveryWindow>> getDeliveryWindows({
    String? sessionId,
    Duration? window,
  }) => _getWithRetry<List<DeliveryWindow>>(
    path: '/api/v1/metrics/delivery',
    query: <String, Object?>{'sessionId': ?sessionId, ..._rangeQuery(window)},
    decode: _decoder.decodeDeliveryWindows,
  );

  /// Runs one idempotent GET, retrying only when the mapped failure allows it.
  ///
  /// Retry rules, all decided from the mapped [AppFailure] rather than from any
  /// transport type:
  ///
  /// * at most [_maxRetries] additional attempts, after [Duration]s of 250 ms
  ///   then 750 ms;
  /// * only when `failure.retryable` is true — a 5xx, a timeout or a reset
  ///   socket may succeed on a second try;
  /// * never for [OfflineFailure] (recovery is driven by the connectivity
  ///   stream, not by burning retries) and never for [ValidationFailure] (a
  ///   400/404 with a typed code is deterministic).
  ///
  /// [attempt] is only the recursion counter; callers omit it. Recursion rather
  /// than a loop keeps the always-returns-or-throws analysis simple.
  Future<T> _getWithRetry<T>({
    required String path,
    required Map<String, Object?>? query,
    required T Function(Map<String, Object?> json) decode,
    int attempt = 0,
  }) async {
    try {
      final Response<Object?> response = await _dio.get<Object?>(
        '$_baseUrl$path',
        queryParameters: query,
      );
      return decode(_asMap(response.data));
    } on Object catch (error) {
      final AppFailure failure = _failureMapper.map(error);
      if (attempt >= _maxRetries || !_isRetryable(failure)) {
        // The layer's contract is to surface the typed failure, not the raw
        // transport exception.
        // ignore: only_throw_errors
        throw failure;
      }
      await Future<void>.delayed(_retryBackoffs[attempt]);
      return _getWithRetry<T>(
        path: path,
        query: query,
        decode: decode,
        attempt: attempt + 1,
      );
    }
  }

  /// Whether [failure] may be retried. Offline and validation never are.
  static bool _isRetryable(AppFailure failure) {
    if (failure is OfflineFailure || failure is ValidationFailure) return false;
    return failure.retryable;
  }

  /// Narrows a decoded body to a JSON object.
  ///
  /// The API is JSON-object-only, so anything else means the response was not
  /// what the backend promises; that is a protocol error, not a transport one.
  static Map<String, Object?> _asMap(Object? data) {
    if (data is Map<String, Object?>) return data;
    // ignore: only_throw_errors
    throw const ProtocolFailure(message: 'Unexpected response shape');
  }

  /// Builds the `from`/`to` query pair the metrics endpoints accept.
  ///
  /// The backend reads a time range rather than a duration for latency, tiers
  /// and delivery (`parseTimeRange`), so the caller's [window] is converted with
  /// the injected [Clock] — which also keeps the URL deterministic in a test
  /// that injects a `FakeClock`.
  Map<String, Object?> _rangeQuery(Duration? window) {
    if (window == null) return const <String, Object?>{};
    final DateTime to = _clock.now().toUtc();
    final DateTime from = to.subtract(window);
    return <String, Object?>{
      'from': from.toIso8601String(),
      'to': to.toIso8601String(),
    };
  }

  /// Formats a duration in the Go `time.ParseDuration` vocabulary the backend
  /// metrics endpoints parse, e.g. `5s`, `30s`, `1m`, `2h`.
  static String _formatDuration(Duration value) {
    final int ms = value.inMilliseconds;
    if (ms <= 0) return '0s';
    if (ms % Duration.millisecondsPerHour == 0) {
      return '${ms ~/ Duration.millisecondsPerHour}h';
    }
    if (ms % Duration.millisecondsPerMinute == 0) {
      return '${ms ~/ Duration.millisecondsPerMinute}m';
    }
    if (ms % Duration.millisecondsPerSecond == 0) {
      return '${ms ~/ Duration.millisecondsPerSecond}s';
    }
    return '${ms}ms';
  }

  /// Removes a trailing slash so `baseUrl + path` never produces `//`.
  static String _stripTrailingSlash(String value) {
    if (value.isEmpty) return value;
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }
}
