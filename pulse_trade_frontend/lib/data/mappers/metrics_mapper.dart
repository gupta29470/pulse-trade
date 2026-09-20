import 'package:pulse_trade_frontend/data/dto/metrics_dto.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';

/// Maps RTT aggregates onto the domain value.
extension RttStatsDtoMapper on RttStatsDto {
  /// The domain aggregate.
  RttStats toEntity() => RttStats(
    samples: samples,
    minMs: minMs,
    avgMs: avgMs,
    p95Ms: p95Ms,
    maxMs: maxMs,
  );
}

/// Maps the metrics summary response onto the domain snapshot.
extension MetricsSummaryDtoMapper on MetricsSummaryDto {
  /// The domain snapshot.
  MetricsSnapshot toEntity() => MetricsSnapshot(
    generatedAt: DateTime.parse(generatedAt).toUtc(),
    uptimeMs: uptimeMs,
    activeSessions: activeSessions,
    totalSessions: totalSessions,
    tierDistribution: tierDistribution,
    rtt: rtt.toEntity(),
    jitterMsMean: jitterMsMean,
    reconnects: reconnects,
    bookRecoveries: bookRecoveries,
    bookGapsDetected: bookGapsDetected,
    malformedMessages: malformedMessages,
    duplicateDeltas: duplicateDeltas,
    staleDeltas: staleDeltas,
    outOfOrderTrades: outOfOrderTrades,
    tierTransitions: tierTransitions,
    candlesClosed: candlesClosed,
    candleInvariantViolations: candleInvariantViolations,
    latencySamples: latencySamples,
    deliveryWindows: deliveryWindows,
    counters: counters,
  );
}

/// Maps the backend's latency series onto domain buckets.
extension LatencyBucketDtoMapper on LatencyBucketDto {
  /// The domain bucket. The backend already aggregated it; the app plots it.
  LatencyBucket toEntity() => LatencyBucket(
    start: DateTime.parse(start).toUtc(),
    end: DateTime.parse(end).toUtc(),
    count: count,
    minMs: minMs,
    avgMs: avgMs,
    p95Ms: p95Ms,
    maxMs: maxMs,
    avgJitterMs: avgJitterMs,
  );
}

/// Maps one recorded tier transition onto the domain record.
extension TierTransitionDtoMapper on TierTransitionDto {
  /// The domain transition record.
  TierTransitionRecord toEntity() => TierTransitionRecord(
    sessionId: sessionId,
    at: DateTime.parse(at).toUtc(),
    from: from,
    to: to,
    reason: reason,
    rttMs: rttMs,
    jitterMs: jitterMs,
    streak: streak,
    overrideTier: tierOverride,
  );
}

/// Maps one session row onto the domain record.
extension SessionDtoMapper on SessionDto {
  /// The domain session record.
  ///
  /// `shortId` is not on the wire: the session row predates the display id, so
  /// it is derived as the last six characters of the full id (the whole id when
  /// it is shorter than six) to match what the backend logs.
  SessionRecord toEntity() {
    final String effectiveTier = finalTier.isEmpty ? initialTier : finalTier;
    return SessionRecord(
      sessionId: sessionId,
      shortId: _shortId(sessionId),
      symbol: symbol,
      interval: interval,
      connectedAt: DateTime.parse(connectedAt).toUtc(),
      tier: effectiveTier,
      overrideTier: overrideTier,
      uptimeMs: uptimeMs,
      messagesSent: messagesSent,
      messagesReceived: messagesReceived,
      protocolErrors: protocolErrors,
    );
  }
}

/// Maps one delivery window onto the domain record.
extension DeliveryWindowDtoMapper on DeliveryWindowDto {
  /// The domain delivery window. This is what makes "target rate versus
  /// effective rate" an observation rather than a claim.
  DeliveryWindow toEntity() => DeliveryWindow(
    sessionId: sessionId,
    windowStart: DateTime.parse(windowStart).toUtc(),
    windowMs: windowMs,
    tier: tier,
    targetRate: targetRate,
    effectiveRate: effectiveRate,
    candleUpdates: candleUpdates,
    tradeMessages: tradeMessages,
    bookDeltas: bookDeltas,
    healthMessages: healthMessages,
    coalesced: coalesced,
    suppressed: suppressed,
    bytesSent: bytesSent,
  );
}

/// The six-character display id derived from a full session id.
String _shortId(String sessionId) => sessionId.length <= 6
    ? sessionId
    : sessionId.substring(sessionId.length - 6);
