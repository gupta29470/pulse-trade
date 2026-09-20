import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_health.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_status.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';

/// Everything the diagnostics screen renders.
///
/// The state is deliberately a *sink*, not a projection: several independent
/// producers write into it — the REST metrics API, the socket, and the
/// order-book bloc pushing its own sync state — and no producer is allowed to
/// blank another's section. That is why every remote payload is nullable,
/// merged field by field rather than replaced wholesale: a failing
/// `/metrics/latency` call must leave the last latency series on screen so the
/// page degrades to "stale" instead of "empty".
///
/// Every value shown by the screen comes from here. Nothing is invented, and a
/// value that no producer has reported is rendered as `—` rather than filled in
/// with a plausible-looking constant.
final class DiagnosticsState extends Equatable {
  /// Creates a state. All remote payloads default to empty so
  /// [DiagnosticsState.initial] can be `const`.
  const DiagnosticsState({
    this.isLoading = false,
    this.lastRefreshedAt,
    this.failure,
    this.health,
    this.metrics,
    this.latency = const <LatencyBucket>[],
    this.tierTransitions = const <TierTransitionRecord>[],
    this.sessions = const <SessionRecord>[],
    this.deliveryWindows = const <DeliveryWindow>[],
    this.internetStatus = 'UNKNOWN',
    this.backendStatus = ConnectionStatus.disconnected,
    this.engineState,
    this.engineEpoch,
    this.bookState = OrderBookState.initialLoading,
    this.bookEpoch = 0,
    this.bookAppliedUpdateId = 0,
    this.lastAppliedFirstUpdateId = 0,
    this.lastAppliedLastUpdateId = 0,
    this.gapCount = 0,
    this.duplicateCount = 0,
    this.staleCount = 0,
    this.recoveryCount = 0,
    this.delivery,
    this.counters = const <String, int>{},
    this.cacheStats = const <String, Object?>{},
    this.sessionId,
    this.shortId,
    this.protocolVersion,
  });

  /// The state before the first refresh has completed.
  static const DiagnosticsState initial = DiagnosticsState();

  /// True while any refresh is in flight.
  final bool isLoading;

  /// When the last refresh finished, from the injected [Clock].
  final DateTime? lastRefreshedAt;

  /// The first failure of the last refresh, if any.
  ///
  /// One failure is enough to surface a warning line; the successful sections
  /// still render. The page shows this as a notice, never as a replacement for
  /// the whole screen.
  final AppFailure? failure;

  /// `GET /api/v1/health`.
  final HealthSnapshot? health;

  /// `GET /api/v1/metrics/summary`.
  final MetricsSnapshot? metrics;

  /// `GET /api/v1/metrics/latency` buckets (15 min window, 5 s buckets).
  final List<LatencyBucket> latency;

  /// `GET /api/v1/metrics/tiers`.
  final List<TierTransitionRecord> tierTransitions;

  /// `GET /api/v1/metrics/sessions`.
  final List<SessionRecord> sessions;

  /// `GET /api/v1/metrics/delivery`.
  final List<DeliveryWindow> deliveryWindows;

  /// Internet reachability, `ONLINE` | `OFFLINE` | `UNKNOWN`.
  ///
  /// A plain string rather than an enum because this layer has three values and
  /// its own vocabulary; the connectivity module owns the parsed type and the
  /// composition root pushes the value in. It is never derived from the socket:
  /// the internet layer and the backend layer are independent by design.
  final String internetStatus;

  /// The socket's own lifecycle.
  final ConnectionStatus backendStatus;

  /// The engine's state as last reported by the backend.
  ///
  /// Comes from the `health` snapshot rather than from a local guess: the app
  /// never derives engine liveness from the socket.
  final MarketEngineState? engineState;

  /// The engine epoch in force.
  final int? engineEpoch;

  /// Where the local order book is in its synchronisation lifecycle.
  final OrderBookState bookState;

  /// Engine epoch the local book is synchronised to.
  final int bookEpoch;

  /// The newest fully applied update id.
  final int bookAppliedUpdateId;

  /// First update id of the last applied delta range.
  final int lastAppliedFirstUpdateId;

  /// Last update id of the last applied delta range.
  final int lastAppliedLastUpdateId;

  /// Delta ranges rejected because they were not contiguous.
  final int gapCount;

  /// Delta ranges rejected because they were already applied.
  final int duplicateCount;

  /// Delta ranges rejected because they were older than the applied range.
  final int staleCount;

  /// Resynchronisations that completed.
  final int recoveryCount;

  /// The backend's `health` frame, including target and effective rate.
  final DeliveryHealth? delivery;

  /// The on-device counter registry, verbatim.
  final Map<String, int> counters;

  /// Cache store instrumentation, pushed in by the cache layer.
  final Map<String, Object?> cacheStats;

  /// The session id in force, from the last `welcome`.
  final String? sessionId;

  /// The six-character display id paired with [sessionId].
  final String? shortId;

  /// The protocol version negotiated on the envelope.
  final int? protocolVersion;

  /// The most recent latency bucket, when a series has arrived.
  ///
  /// Used for the gauge's headline value; the aggregates themselves are computed
  /// by the page from the whole series.
  LatencyBucket? get latestBucket => latency.isEmpty ? null : latency.last;

  /// True when everything the screen needs has arrived at least once.
  bool get hasData =>
      health != null ||
      metrics != null ||
      latency.isNotEmpty ||
      delivery != null;

  /// Copy with individual fields changed.
  ///
  /// Nullable fields are cleared through explicit `clear*` flags because a
  /// nullable parameter cannot express "set this back to null" — without them,
  /// a failed health call could never clear a stale version string.
  DiagnosticsState copyWith({
    bool? isLoading,
    DateTime? lastRefreshedAt,
    AppFailure? failure,
    HealthSnapshot? health,
    MetricsSnapshot? metrics,
    List<LatencyBucket>? latency,
    List<TierTransitionRecord>? tierTransitions,
    List<SessionRecord>? sessions,
    List<DeliveryWindow>? deliveryWindows,
    String? internetStatus,
    ConnectionStatus? backendStatus,
    MarketEngineState? engineState,
    int? engineEpoch,
    OrderBookState? bookState,
    int? bookEpoch,
    int? bookAppliedUpdateId,
    int? lastAppliedFirstUpdateId,
    int? lastAppliedLastUpdateId,
    int? gapCount,
    int? duplicateCount,
    int? staleCount,
    int? recoveryCount,
    DeliveryHealth? delivery,
    Map<String, int>? counters,
    Map<String, Object?>? cacheStats,
    String? sessionId,
    String? shortId,
    int? protocolVersion,
    bool clearFailure = false,
    bool clearHealth = false,
    bool clearMetrics = false,
    bool clearSession = false,
  }) {
    return DiagnosticsState(
      isLoading: isLoading ?? this.isLoading,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
      failure: clearFailure ? null : (failure ?? this.failure),
      health: clearHealth ? null : (health ?? this.health),
      metrics: clearMetrics ? null : (metrics ?? this.metrics),
      latency: latency ?? this.latency,
      tierTransitions: tierTransitions ?? this.tierTransitions,
      sessions: sessions ?? this.sessions,
      deliveryWindows: deliveryWindows ?? this.deliveryWindows,
      internetStatus: internetStatus ?? this.internetStatus,
      backendStatus: backendStatus ?? this.backendStatus,
      engineState: engineState ?? this.engineState,
      engineEpoch: engineEpoch ?? this.engineEpoch,
      bookState: bookState ?? this.bookState,
      bookEpoch: bookEpoch ?? this.bookEpoch,
      bookAppliedUpdateId: bookAppliedUpdateId ?? this.bookAppliedUpdateId,
      lastAppliedFirstUpdateId:
          lastAppliedFirstUpdateId ?? this.lastAppliedFirstUpdateId,
      lastAppliedLastUpdateId:
          lastAppliedLastUpdateId ?? this.lastAppliedLastUpdateId,
      gapCount: gapCount ?? this.gapCount,
      duplicateCount: duplicateCount ?? this.duplicateCount,
      staleCount: staleCount ?? this.staleCount,
      recoveryCount: recoveryCount ?? this.recoveryCount,
      delivery: delivery ?? this.delivery,
      counters: counters ?? this.counters,
      cacheStats: cacheStats ?? this.cacheStats,
      sessionId: clearSession ? null : (sessionId ?? this.sessionId),
      shortId: clearSession ? null : (shortId ?? this.shortId),
      protocolVersion: clearSession
          ? null
          : (protocolVersion ?? this.protocolVersion),
    );
  }

  @override
  List<Object?> get props => <Object?>[
    isLoading,
    lastRefreshedAt,
    failure,
    health,
    metrics,
    latency,
    tierTransitions,
    sessions,
    deliveryWindows,
    internetStatus,
    backendStatus,
    engineState,
    engineEpoch,
    bookState,
    bookEpoch,
    bookAppliedUpdateId,
    lastAppliedFirstUpdateId,
    lastAppliedLastUpdateId,
    gapCount,
    duplicateCount,
    staleCount,
    recoveryCount,
    delivery,
    counters,
    cacheStats,
    sessionId,
    shortId,
    protocolVersion,
  ];

  @override
  String toString() =>
      'DiagnosticsState(loading: $isLoading, '
      'health: ${health?.status ?? 'none'}, latency: ${latency.length}, '
      'session: ${shortId ?? 'none'})';
}
