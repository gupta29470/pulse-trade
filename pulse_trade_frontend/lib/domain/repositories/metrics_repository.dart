import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';

/// The backend metrics API, read by the diagnostics screen only.
///
/// Nothing here feeds market state: diagnostics must be able to fail entirely
/// without the market screen noticing.
abstract interface class MetricsRepository {
  /// Aggregate counters and current health.
  Future<Result<MetricsSnapshot>> loadSummary({Duration? window});

  /// Latency/jitter time series.
  Future<Result<List<LatencyBucket>>> loadLatency({
    String? sessionId,
    required Duration window,
    required Duration bucket,
  });

  /// Tier transition history with reasons.
  Future<Result<List<TierTransitionRecord>>> loadTierTransitions({
    Duration? window,
  });

  /// Session lifecycle records.
  Future<Result<List<SessionRecord>>> loadSessions({int limit = 50});

  /// Delivered versus target rate windows.
  Future<Result<List<DeliveryWindow>>> loadDeliveryWindows({
    String? sessionId,
    Duration? window,
  });

  /// Process/engine/metrics-store health from `/api/v1/health`.
  Future<Result<HealthSnapshot>> loadHealth();
}
