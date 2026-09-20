import 'dart:convert';

import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_health.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_state.dart';

/// Builds the blob behind `Copy diagnostics JSON`.
///
/// One JSON object rather than a concatenation of sections: a bug report has to
/// be pasteable as a single valid document, and a reviewer diffing two reports
/// needs a stable key order. The log ring buffer is embedded verbatim — it was
/// already redacted at the logger boundary, so nothing here re-filters
/// it and nothing here can leak a key the logger would have dropped.
///
/// Deliberately a pure function of the state and the clock: no widget, no cubit
/// and no I/O, so a test can assert the exact document for a hand-built state.
/// [DiagnosticsCubit] is the only production caller.
String buildDiagnosticsJsonFor({
  required DiagnosticsState state,
  required Clock clock,
}) {
  final DeliveryHealth? delivery = state.delivery;
  final HealthSnapshot? health = state.health;
  final MetricsSnapshot? metrics = state.metrics;

  final Map<String, Object?> payload = <String, Object?>{
    'generatedAt': clock.now().toUtc().toIso8601String(),
    'service': AppLogger.serviceName,
    'version': AppLogger.version,
    // The session id is the point of the export: without it a pasted blob cannot
    // be joined to any server-side record.
    'sessionId': state.sessionId,
    'shortId': state.shortId,
    'protocolVersion': state.protocolVersion,
    'internetStatus': state.internetStatus,
    'backendStatus': state.backendStatus.name,
    'engine': <String, Object?>{
      'state': state.engineState?.wire,
      'epoch': state.engineEpoch,
    },
    'delivery': <String, Object?>{
      'tier': delivery?.tier.wire,
      'override': delivery?.tierOverride.wire,
      'reason': delivery?.reason,
      'targetRatePerSec': delivery?.targetRatePerSec,
      'effectiveRatePerSec': delivery?.effectiveRatePerSec,
      'rttMs': delivery?.rttMs,
      'jitterMs': delivery?.jitterMs,
      'coalescedCount': delivery?.coalescedCount,
      'suppressedCount': delivery?.suppressedCount,
      'queuedMessages': delivery?.queuedMessages,
      'droppedMessages': delivery?.droppedMessages,
    },
    'book': <String, Object?>{
      'state': state.bookState.name,
      'epoch': state.bookEpoch,
      'appliedUpdateId': state.bookAppliedUpdateId,
      'firstUpdateId': state.lastAppliedFirstUpdateId,
      'lastUpdateId': state.lastAppliedLastUpdateId,
      'gaps': state.gapCount,
      'duplicates': state.duplicateCount,
      'stale': state.staleCount,
      'recoveries': state.recoveryCount,
    },
    'health': <String, Object?>{
      'status': health?.status,
      'version': health?.version,
      'uptimeMs': health?.uptimeMs,
      'engineState': health?.engineState,
      'metricsDriver': health?.metricsDriver,
      'metricsStatus': health?.metricsStatus,
      'metricsQueueDepth': health?.metricsQueueDepth,
      'metricsDroppedTotal': health?.metricsDroppedTotal,
    },
    'metrics': <String, Object?>{
      'generatedAt': metrics?.generatedAt.toUtc().toIso8601String(),
      'uptimeMs': metrics?.uptimeMs,
      'activeSessions': metrics?.activeSessions,
      'totalSessions': metrics?.totalSessions,
      'reconnects': metrics?.reconnects,
      'bookRecoveries': metrics?.bookRecoveries,
      'tierTransitions': metrics?.tierTransitions,
      'latencySamples': metrics?.latencySamples,
      'deliveryWindows': metrics?.deliveryWindows,
    },
    // Counts, not the arrays themselves: the raw payloads are large, already
    // live on the diagnostics screen, and would bury the counters a reviewer is
    // actually pasting this for.
    'latencyBuckets': state.latency.length,
    'tierTransitions': state.tierTransitions.length,
    'sessions': state.sessions.length,
    'deliveryWindows': state.deliveryWindows.length,
    'counters': state.counters,
    'cacheStats': state.cacheStats,
    'failure': state.failure?.code,
    'logs': AppLogger.records,
  };
  return const JsonEncoder.withIndent('  ').convert(payload);
}
