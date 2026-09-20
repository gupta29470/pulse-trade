import 'package:equatable/equatable.dart';

/// The backend's process/engine/metrics-store health, from `GET /health` and
/// `GET /api/v1/health`.
///
/// Three independent layers rather than one boolean, mirroring the backend
/// response: process `status`, engine state, and metrics-store status. The
/// diagnostics screen shows them separately, because "the server is up but the
/// metrics store is down" is a different situation from "the server is down".
final class HealthSnapshot extends Equatable {
  /// Creates a health snapshot. Detailed fields are null for the liveness probe.
  const HealthSnapshot({
    required this.status,
    required this.version,
    required this.uptimeMs,
    required this.serverTime,
    this.engineState,
    this.engineSymbol,
    this.engineEpoch,
    this.engineEventIndex,
    this.engineUpdateId,
    this.warmupComplete,
    this.metricsDriver,
    this.metricsStatus,
    this.metricsQueueDepth,
    this.metricsDroppedTotal,
    this.metricsLastFlushMs,
    this.sessionsActive,
    this.sessionsTotal,
    this.reasons = const <String>[],
  });

  /// `ok` or `degraded`.
  final String status;

  /// Backend build version.
  final String version;

  /// Process uptime.
  final int uptimeMs;

  /// Server time, UTC.
  final DateTime serverTime;

  /// Engine state string, `null` for the liveness probe.
  final String? engineState;

  /// The engine's symbol.
  final String? engineSymbol;

  /// Engine epoch.
  final int? engineEpoch;

  /// Monotonic engine event index.
  final int? engineEventIndex;

  /// Current book update id.
  final int? engineUpdateId;

  /// Whether warmup finished.
  final bool? warmupComplete;

  /// Metrics store driver (`sqlite`, `memory`).
  final String? metricsDriver;

  /// Metrics store status (`ok`, `degraded`).
  final String? metricsStatus;

  /// Pending rows in the metrics writer queue.
  final int? metricsQueueDepth;

  /// Rows dropped because the queue was full.
  final int? metricsDroppedTotal;

  /// Duration of the last metrics flush.
  final int? metricsLastFlushMs;

  /// Currently connected sessions.
  final int? sessionsActive;

  /// Sessions seen since start.
  final int? sessionsTotal;

  /// Why the status is `degraded`, when it is.
  final List<String> reasons;

  /// True when the backend reports itself fully healthy.
  bool get isOk => status == 'ok';

  @override
  List<Object?> get props => <Object?>[
    status,
    version,
    uptimeMs,
    serverTime,
    engineState,
    engineSymbol,
    engineEpoch,
    engineEventIndex,
    engineUpdateId,
    warmupComplete,
    metricsDriver,
    metricsStatus,
    metricsQueueDepth,
    metricsDroppedTotal,
    metricsLastFlushMs,
    sessionsActive,
    sessionsTotal,
    reasons,
  ];

  @override
  String toString() => 'HealthSnapshot($status, v$version, up=${uptimeMs}ms)';
}
