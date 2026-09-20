import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';

/// Rejects late history responses for an interval the user has already left.
///
/// Every history request carries a monotonically increasing id. A response is
/// committed only when its id is still the current one **and** its interval still
/// matches the selected interval. Without this, a slow `1m` response
/// can overwrite the `5m` chart the user is looking at — the classic interval
/// race.
final class IntervalRequestGuard {
  /// Creates a guard. [metrics] defaults to a private registry so the guard can
  /// be used in isolation; production passes the shared instance.
  IntervalRequestGuard({OnDeviceMetrics? metrics})
    : _metrics = metrics ?? OnDeviceMetrics();

  final OnDeviceMetrics _metrics;

  int _counter = 0;
  int _currentRequestId = 0;
  CandleInterval? _currentInterval;
  int _rejectedCount = 0;

  /// The id of the newest request, or zero when none has been issued.
  int get currentRequestId => _currentRequestId;

  /// The interval of the newest request, or `null` when none has been issued.
  CandleInterval? get currentInterval => _currentInterval;

  /// True while a history request is in flight.
  bool get hasPendingRequest => _currentRequestId != 0;

  /// How many responses this guard rejected as stale.
  int get rejectedCount => _rejectedCount;

  /// Starts a new request for [interval] and returns its id.
  ///
  /// Any response carrying an earlier id is now stale by construction.
  int begin(CandleInterval interval) {
    _counter++;
    _currentRequestId = _counter;
    _currentInterval = interval;
    _metrics.increment(MetricNames.historyRequestsTotal);
    return _currentRequestId;
  }

  /// True when [requestId] is still the newest request.
  bool isCurrent(int requestId) =>
      requestId != 0 && requestId == _currentRequestId;

  /// True when a response for [requestId] and [interval] may be committed.
  ///
  /// Counts a rejection so `stale_history_responses_total` is observable,
  /// records the reason as a DEBUG log line at the call site rather than here.
  bool accept(int requestId, CandleInterval interval) {
    if (isCurrent(requestId) && interval == _currentInterval) return true;
    recordRejection();
    return false;
  }

  /// Records a rejection without committing anything.
  void recordRejection() {
    _rejectedCount++;
    _metrics.increment(MetricNames.staleHistoryResponsesTotal);
  }

  /// Clears the in-flight request, e.g. because the load failed.
  void complete(int requestId) {
    if (isCurrent(requestId)) {
      _currentRequestId = 0;
      _currentInterval = null;
    }
  }

  /// Forgets the current request and its counters. Used when the screen is
  /// disposed, so a later screen does not inherit a stale generation.
  void reset() {
    _currentRequestId = 0;
    _currentInterval = null;
    _rejectedCount = 0;
  }
}
