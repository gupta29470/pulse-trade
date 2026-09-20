import 'package:equatable/equatable.dart';

/// One bucket of `GET /api/v1/metrics/latency?bucket=5s`.
///
/// The backend already aggregated the raw samples, so the app never computes a
/// percentile: it plots the numbers it was given.
final class LatencyBucket extends Equatable {
  /// Creates a latency bucket.
  const LatencyBucket({
    required this.start,
    required this.end,
    required this.count,
    required this.minMs,
    required this.avgMs,
    required this.p95Ms,
    required this.maxMs,
    required this.avgJitterMs,
  });

  /// Bucket start.
  final DateTime start;

  /// Bucket end.
  final DateTime end;

  /// Samples in the bucket.
  final int count;

  /// Minimum RTT in the bucket.
  final double minMs;

  /// Mean RTT in the bucket.
  final double avgMs;

  /// 95th percentile RTT in the bucket.
  final double p95Ms;

  /// Maximum RTT in the bucket.
  final double maxMs;

  /// Mean jitter in the bucket.
  final double avgJitterMs;

  @override
  List<Object?> get props => <Object?>[
    start,
    end,
    count,
    minMs,
    avgMs,
    p95Ms,
    maxMs,
    avgJitterMs,
  ];
}

/// One row of `GET /api/v1/metrics/tiers`.
final class TierTransitionRecord extends Equatable {
  /// Creates a transition record.
  const TierTransitionRecord({
    required this.sessionId,
    required this.at,
    required this.from,
    required this.to,
    required this.reason,
    required this.rttMs,
    required this.jitterMs,
    required this.streak,
    required this.overrideTier,
  });

  /// Session the transition applied to.
  final String sessionId;

  /// When it happened.
  final DateTime at;

  /// Previous tier.
  final String from;

  /// New tier.
  final String to;

  /// Reason slug.
  final String reason;

  /// RTT that caused it.
  final double rttMs;

  /// Jitter that caused it.
  final double jitterMs;

  /// Consecutive-report streak at the moment of transition.
  final int streak;

  /// Manual override in force, when any.
  final String overrideTier;

  @override
  List<Object?> get props => <Object?>[
    sessionId,
    at,
    from,
    to,
    reason,
    rttMs,
    jitterMs,
    streak,
    override,
  ];
}

/// One row of `GET /api/v1/metrics/sessions`.
final class SessionRecord extends Equatable {
  /// Creates a session record.
  const SessionRecord({
    required this.sessionId,
    required this.shortId,
    required this.symbol,
    required this.interval,
    required this.connectedAt,
    required this.tier,
    required this.overrideTier,
    required this.uptimeMs,
    required this.messagesSent,
    required this.messagesReceived,
    required this.protocolErrors,
  });

  /// Full session id.
  final String sessionId;

  /// Six-character display id, or the last six of the id when absent.
  final String shortId;

  /// Subscribed symbol.
  final String symbol;

  /// Subscribed interval.
  final String interval;

  /// Connection time.
  final DateTime connectedAt;

  /// Current or final tier.
  final String tier;

  /// Manual override, when any.
  final String overrideTier;

  /// Session uptime.
  final int uptimeMs;

  /// Frames the backend sent.
  final int messagesSent;

  /// Frames the client sent.
  final int messagesReceived;

  /// Protocol errors observed on this session.
  final int protocolErrors;

  @override
  List<Object?> get props => <Object?>[
    sessionId,
    shortId,
    symbol,
    interval,
    connectedAt,
    tier,
    override,
    uptimeMs,
    messagesSent,
    messagesReceived,
    protocolErrors,
  ];
}

/// One row of `GET /api/v1/metrics/delivery`.
///
/// This is what makes "target rate versus effective rate" an observation rather
/// than a claim.
final class DeliveryWindow extends Equatable {
  /// Creates a delivery window record.
  const DeliveryWindow({
    required this.sessionId,
    required this.windowStart,
    required this.windowMs,
    required this.tier,
    required this.targetRate,
    required this.effectiveRate,
    required this.candleUpdates,
    required this.tradeMessages,
    required this.bookDeltas,
    required this.healthMessages,
    required this.coalesced,
    required this.suppressed,
    required this.bytesSent,
  });

  /// Session the window belongs to.
  final String sessionId;

  /// Window start.
  final DateTime windowStart;

  /// Window length.
  final int windowMs;

  /// Tier in force during the window.
  final String tier;

  /// Messages per second targeted.
  final double targetRate;

  /// Messages per second delivered.
  final double effectiveRate;

  /// Candle updates delivered.
  final int candleUpdates;

  /// Trade messages delivered.
  final int tradeMessages;

  /// Book deltas delivered.
  final int bookDeltas;

  /// Health frames delivered.
  final int healthMessages;

  /// Messages coalesced away.
  final int coalesced;

  /// Messages suppressed by the tier.
  final int suppressed;

  /// Bytes written to the socket.
  final int bytesSent;

  @override
  List<Object?> get props => <Object?>[
    sessionId,
    windowStart,
    windowMs,
    tier,
    targetRate,
    effectiveRate,
    candleUpdates,
    tradeMessages,
    bookDeltas,
    healthMessages,
    coalesced,
    suppressed,
    bytesSent,
  ];
}
