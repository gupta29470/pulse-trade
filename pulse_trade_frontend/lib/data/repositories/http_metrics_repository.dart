import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/repositories/metrics_repository.dart';

/// The backend metrics API behind [Result].
///
/// Diagnostics is allowed to fail completely: nothing here feeds market state,
/// and every method degrades to an [Err] that the diagnostics cubit renders as a
/// "metrics unavailable" row rather than an error screen.
final class HttpMetricsRepository implements MetricsRepository {
  /// Creates the repository.
  const HttpMetricsRepository({
    required this._api,
    required FailureMapper failureMapper,
  }) : _mapper = failureMapper;

  final MarketApi _api;
  final FailureMapper _mapper;

  @override
  Future<Result<MetricsSnapshot>> loadSummary({Duration? window}) =>
      _guard<MetricsSnapshot>(_api.getMetricsSummary);

  @override
  Future<Result<List<LatencyBucket>>> loadLatency({
    String? sessionId,
    required Duration window,
    required Duration bucket,
  }) => _guard<List<LatencyBucket>>(
    () => _api.getLatencyBuckets(
      sessionId: sessionId,
      window: window,
      bucket: bucket,
    ),
  );

  @override
  Future<Result<List<TierTransitionRecord>>> loadTierTransitions({
    Duration? window,
  }) => _guard<List<TierTransitionRecord>>(
    () => _api.getTierTransitions(window: window),
  );

  @override
  Future<Result<List<SessionRecord>>> loadSessions({int limit = 50}) =>
      _guard<List<SessionRecord>>(() => _api.getSessions(limit: limit));

  @override
  Future<Result<List<DeliveryWindow>>> loadDeliveryWindows({
    String? sessionId,
    Duration? window,
  }) => _guard<List<DeliveryWindow>>(
    () => _api.getDeliveryWindows(sessionId: sessionId, window: window),
  );

  @override
  Future<Result<HealthSnapshot>> loadHealth() =>
      _guard<HealthSnapshot>(_api.getDetailedHealth);

  /// Runs a transport call and converts every failure into an [Err].
  ///
  /// This is the only `try`/`catch` in the diagnostics path, so the cubit never
  /// sees a thrown object and no widget ever sees an exception.
  Future<Result<T>> _guard<T>(Future<T> Function() call) async {
    try {
      return Ok<T>(await call());
    } on AppFailure catch (failure) {
      return Err<T>(failure);
    } on Object catch (error) {
      return Err<T>(_mapper.map(error));
    }
  }
}
