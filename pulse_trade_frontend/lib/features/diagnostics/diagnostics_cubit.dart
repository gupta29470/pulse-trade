import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_health.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_status.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/messages/delivery_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/metrics_repository.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_json.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_state.dart';

/// Drives the diagnostics screen: one polled REST refresh plus a live socket tap.
///
/// Two rules shape the design.
///
/// **Never blank a section.** The six REST calls run concurrently and are merged
/// field by field; the first failure is recorded on the state and the failure
/// message is surfaced, but every call that succeeded still updates its section.
/// A diagnostics screen that goes empty when one endpoint
/// 500s is a diagnostics screen that lies about the outage being total.
///
/// **Poll for aggregates, subscribe for state.** Rate, tier, epoch and engine
/// state change at frame cadence, so they come from `stream.messages` and
/// `stream.statusStream` with no polling at all — polling them would sample a
/// moving target and show a value that was never simultaneously true.
final class DiagnosticsCubit extends Cubit<DiagnosticsState> {
  /// Creates the cubit.
  ///
  /// [_pollInterval] is injectable so a test can drive the timer explicitly
  /// instead of waiting five real seconds per assertion.
  DiagnosticsCubit({
    required this._metrics,
    required this._stream,
    required this._counters,
    Clock? clock,
    this._pollInterval = const Duration(seconds: 5),
  }) : _clock = clock ?? SystemClock(),
       super(DiagnosticsState.initial);

  final MetricsRepository _metrics;
  final MarketStreamRepository _stream;
  final OnDeviceMetrics _counters;
  final Clock _clock;
  final Duration _pollInterval;

  Timer? _timer;
  StreamSubscription<ServerMessage>? _messages;
  StreamSubscription<ConnectionStatus>? _statuses;

  /// The latency series window (last 15 minutes).
  static const Duration latencyWindow = Duration(minutes: 15);

  /// The latency bucket size.
  static const Duration latencyBucket = Duration(seconds: 5);

  /// The latency window the summary aggregates cover.
  static const Duration summaryWindow = Duration(minutes: 15);

  /// Starts the socket tap, runs one refresh immediately, then polls.
  ///
  /// The immediate refresh matters: a screen that shows skeletons for up to
  /// [_pollInterval] after open looks broken even when everything is healthy.
  Future<void> start() async {
    _listenToStream();
    _timer ??= Timer.periodic(_pollInterval, (Timer _) {
      unawaited(refresh());
    });
    await refresh();
  }

  /// Cancels the poll timer and the socket subscriptions.
  ///
  /// Called when the screen is popped. [close] also does this, but a screen that
  /// is merely hidden must stop polling without destroying the cubit: the
  /// composition root owns its lifetime (the cubit's lifetime is about release,
  /// not visibility).
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _messages?.cancel();
    _messages = null;
    await _statuses?.cancel();
    _statuses = null;
  }

  /// Loads every REST section concurrently and merges the results.
  Future<void> refresh() async {
    emit(
      state.copyWith(
        isLoading: true,
        // The previous failure is cleared at the *start* of a refresh: leaving it
        // up while the new attempt is in flight would make a recovered endpoint
        // still look broken.
        clearFailure: true,
      ),
    );

    final List<Future<AppFailure?>> calls = <Future<AppFailure?>>[
      _loadSummary(),
      _loadLatency(),
      _loadTiers(),
      _loadSessions(),
      _loadDelivery(),
      _loadHealth(),
    ];
    final List<AppFailure?> failures = await Future.wait(calls);

    AppFailure? firstFailure;
    for (final AppFailure? failure in failures) {
      if (failure != null) {
        firstFailure = failure;
        break;
      }
    }

    emit(
      state.copyWith(
        isLoading: false,
        lastRefreshedAt: _clock.now(),
        counters: _counters.snapshot(),
        failure: firstFailure,
        clearFailure: firstFailure == null,
      ),
    );
  }

  /// Pushes the order-book bloc's synchronisation state into diagnostics.
  ///
  /// The book owns these numbers — it is the only component that sees every
  /// delta — so it reports them rather than the cubit reaching into it. The
  /// counters land in the exported JSON untouched, which is what makes them
  /// provable after the fact.
  void reportBookState({
    required OrderBookState state,
    required int epoch,
    required int appliedUpdateId,
    required int first,
    required int last,
    required int gaps,
    required int duplicates,
    required int stale,
    required int recoveries,
  }) {
    emit(
      this.state.copyWith(
        bookState: state,
        bookEpoch: epoch,
        bookAppliedUpdateId: appliedUpdateId,
        lastAppliedFirstUpdateId: first,
        lastAppliedLastUpdateId: last,
        gapCount: gaps,
        duplicateCount: duplicates,
        staleCount: stale,
        recoveryCount: recoveries,
      ),
    );
    _counters.set(MetricNames.gapsDetectedTotal, gaps);
    _counters.set(MetricNames.duplicateDeltasTotal, duplicates);
    _counters.set(MetricNames.staleDeltasTotal, stale);
    _counters.set(MetricNames.recoveriesTotal, recoveries);
  }

  /// Stores the cache layer's instrumentation for the Persistence section.
  void reportCacheStats(Map<String, Object?> stats) {
    emit(state.copyWith(cacheStats: Map<String, Object?>.unmodifiable(stats)));
  }

  /// Records the internet layer's reachability.
  ///
  /// Pushed in rather than derived: the internet layer is independent of the
  /// socket, and this cubit has no business probing for it.
  void reportInternetStatus(String status) {
    if (status == state.internetStatus) return;
    emit(state.copyWith(internetStatus: status));
  }

  /// The JSON blob behind `Copy diagnostics JSON`.
  ///
  /// Delegates to [buildDiagnosticsJsonFor] so the document's shape lives in one
  /// testable pure function instead of inside a cubit.
  String buildDiagnosticsJson() =>
      buildDiagnosticsJsonFor(state: state, clock: _clock);

  /// Copies the diagnostics document to the system clipboard.
  Future<void> copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: buildDiagnosticsJson()));
  }

  @override
  Future<void> close() async {
    // The cubit owns one timer and two subscriptions and must release all
    // three. `stop` is awaited first because a poll that fires between `close`
    // and the release would `emit` on an already-closed cubit and throw.
    await stop();
    return super.close();
  }

  void _listenToStream() {
    _messages ??= _stream.messages.listen(_onMessage);
    _statuses ??= _stream.statusStream.listen(_onStatus);
  }

  void _onMessage(ServerMessage message) {
    // A `switch` on the sealed hierarchy keeps this exhaustive: a new frame type
    // cannot be silently ignored here without a compile error.
    switch (message) {
      case WelcomeMessage():
        emit(
          state.copyWith(
            sessionId: message.sessionId,
            shortId: message.shortId,
            engineEpoch: message.epoch,
            engineState: message.engineState,
            protocolVersion: message.version,
            backendStatus: ConnectionStatus.connected,
          ),
        );
      case HealthMessage():
        final DeliveryHealth health = message.health;
        emit(
          state.copyWith(
            delivery: health,
            // The `health` frame is the backend's own statement about the epoch
            // and update id, so it refreshes both without a poll.
            engineEpoch: health.bookEpoch,
            bookEpoch: health.bookEpoch,
            bookAppliedUpdateId: health.bookUpdateId,
          ),
        );
      case MarketStatusMessage():
        emit(
          state.copyWith(
            engineState: message.status.state,
            engineEpoch: message.status.epoch,
          ),
        );
      default:
        // Every other frame is market data: diagnostics shows aggregates and
        // lifecycle, not ticks, so it is correctly ignored here.
        break;
    }
  }

  void _onStatus(ConnectionStatus status) {
    emit(
      state.copyWith(
        backendStatus: status,
        // A dropped socket invalidates the session readout: showing the old id
        // next to `RECONNECTING` would imply a session that no longer exists.
        clearSession: status == ConnectionStatus.disconnected,
      ),
    );
    AppLogger.debug(
      'diagnostics_status',
      fields: <String, Object?>{
        LogFields.component: LogComponents.metrics,
        'status': status.name,
      },
    );
  }

  Future<AppFailure?> _loadSummary() async {
    return _fetch<MetricsSnapshot>(
      () => _metrics.loadSummary(window: summaryWindow),
      onOk: (MetricsSnapshot value) {
        emit(state.copyWith(metrics: value));
      },
    );
  }

  Future<AppFailure?> _loadLatency() async {
    return _fetch<List<LatencyBucket>>(
      () => _metrics.loadLatency(
        sessionId: state.sessionId,
        window: latencyWindow,
        bucket: latencyBucket,
      ),
      onOk: (List<LatencyBucket> value) {
        emit(state.copyWith(latency: value));
      },
    );
  }

  Future<AppFailure?> _loadTiers() async {
    return _fetch<List<TierTransitionRecord>>(
      () => _metrics.loadTierTransitions(window: summaryWindow),
      onOk: (List<TierTransitionRecord> value) {
        emit(state.copyWith(tierTransitions: value));
      },
    );
  }

  Future<AppFailure?> _loadSessions() async {
    return _fetch<List<SessionRecord>>(
      _metrics.loadSessions,
      onOk: (List<SessionRecord> value) {
        emit(state.copyWith(sessions: value));
      },
    );
  }

  Future<AppFailure?> _loadDelivery() async {
    return _fetch<List<DeliveryWindow>>(
      () => _metrics.loadDeliveryWindows(
        sessionId: state.sessionId,
        window: summaryWindow,
      ),
      onOk: (List<DeliveryWindow> value) {
        emit(state.copyWith(deliveryWindows: value));
      },
    );
  }

  Future<AppFailure?> _loadHealth() async {
    return _fetch<HealthSnapshot>(
      _metrics.loadHealth,
      onOk: (HealthSnapshot value) {
        emit(
          state.copyWith(
            health: value,
            // The health endpoint is the only source of the engine state that
            // does not require a frame; it is authoritative when present.
            engineState: value.engineState == null
                ? state.engineState
                : _engineState(value.engineState!),
            engineEpoch: value.engineEpoch ?? state.engineEpoch,
          ),
        );
      },
    );
  }

  /// Runs one repository call and reports the outcome.
  ///
  /// Returns the failure (for the "first failure wins" merge) or `null` on
  /// success, having already applied [onOk]. Callers never have to wrap a
  /// repository in `try`/`catch`: a repository returns a [Result].
  Future<AppFailure?> _fetch<T>(
    Future<Result<T>> Function() operation, {
    required void Function(T value) onOk,
  }) async {
    try {
      // The result is bound to a local before it is tested: Dart promotes a
      // final local but not an arbitrary expression, so `is Ok<T>` on the local
      // is what lets `result.value` type-check without a cast.
      final Result<T> result = await operation();
      if (result is Ok<T>) {
        onOk(result.value);
        return null;
      }
      return result.failureOrNull;
    } on Object catch (error) {
      // A repository should never throw, but diagnostics is the last place that
      // is allowed to fall over because something below it misbehaved.
      return UnexpectedFailure(cause: error);
    }
  }
}

/// Maps the health endpoint's raw engine-state string onto the domain enum.
///
/// Unknown values become [MarketEngineState.unknown] rather than throwing, so a
/// newer backend cannot break an older client's diagnostics screen.
MarketEngineState _engineState(String wire) => MarketEngineState.parse(wire);
