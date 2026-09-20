import 'package:equatable/equatable.dart';

/// RTT aggregates as reported by `GET /api/v1/metrics/summary`.
final class RttStats extends Equatable {
  /// Creates an RTT aggregate.
  const RttStats({
    required this.samples,
    required this.minMs,
    required this.avgMs,
    required this.p95Ms,
    required this.maxMs,
  });

  /// Number of samples in the window.
  final int samples;

  /// Minimum observed RTT.
  final double minMs;

  /// Mean observed RTT.
  final double avgMs;

  /// 95th percentile RTT.
  final double p95Ms;

  /// Maximum observed RTT.
  final double maxMs;

  /// An empty aggregate, used when the metrics store is disabled.
  static const RttStats empty = RttStats(
    samples: 0,
    minMs: 0,
    avgMs: 0,
    p95Ms: 0,
    maxMs: 0,
  );

  @override
  List<Object?> get props => <Object?>[samples, minMs, avgMs, p95Ms, maxMs];
}

/// The aggregate counters behind the diagnostics screen.
///
/// The backend computes every value; the app only formats them.
final class MetricsSnapshot extends Equatable {
  /// Creates a metrics snapshot.
  const MetricsSnapshot({
    required this.generatedAt,
    required this.uptimeMs,
    required this.activeSessions,
    required this.totalSessions,
    required this.tierDistribution,
    required this.rtt,
    required this.jitterMsMean,
    required this.reconnects,
    required this.bookRecoveries,
    required this.bookGapsDetected,
    required this.malformedMessages,
    required this.duplicateDeltas,
    required this.staleDeltas,
    required this.outOfOrderTrades,
    required this.tierTransitions,
    required this.candlesClosed,
    required this.candleInvariantViolations,
    required this.latencySamples,
    required this.deliveryWindows,
    required this.counters,
  });

  /// When the summary was produced.
  final DateTime generatedAt;

  /// Backend uptime.
  final int uptimeMs;

  /// Sessions connected right now.
  final int activeSessions;

  /// Sessions seen since start.
  final int totalSessions;

  /// Session count per tier.
  final Map<String, int> tierDistribution;

  /// RTT aggregates.
  final RttStats rtt;

  /// Mean jitter over the window.
  final double jitterMsMean;

  /// Reconnects observed by the backend.
  final int reconnects;

  /// Book recoveries.
  final int bookRecoveries;

  /// Book gaps detected.
  final int bookGapsDetected;

  /// Malformed frames received.
  final int malformedMessages;

  /// Duplicate delta ranges observed.
  final int duplicateDeltas;

  /// Stale delta ranges observed.
  final int staleDeltas;

  /// Out-of-order trades observed.
  final int outOfOrderTrades;

  /// Tier transitions recorded.
  final int tierTransitions;

  /// Candles closed and persisted.
  final int candlesClosed;

  /// Candle invariant violations (always zero is the goal).
  final int candleInvariantViolations;

  /// Latency samples persisted in the window.
  final int latencySamples;

  /// Delivery windows persisted in the window.
  final int deliveryWindows;

  /// The raw counter map, exported verbatim by `Copy diagnostics JSON`.
  final Map<String, int> counters;

  @override
  List<Object?> get props => <Object?>[
    generatedAt,
    uptimeMs,
    activeSessions,
    totalSessions,
    tierDistribution,
    rtt,
    jitterMsMean,
    reconnects,
    bookRecoveries,
    bookGapsDetected,
    malformedMessages,
    duplicateDeltas,
    staleDeltas,
    outOfOrderTrades,
    tierTransitions,
    candlesClosed,
    candleInvariantViolations,
    latencySamples,
    deliveryWindows,
    counters,
  ];
}
