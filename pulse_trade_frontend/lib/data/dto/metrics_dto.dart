import 'package:json_annotation/json_annotation.dart';

part 'metrics_dto.g.dart';

/// `GET /api/v1/metrics/summary` — the aggregate counters behind diagnostics.
///
/// The backend computes every value; the app only formats them.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class MetricsSummaryDto {
  /// Creates a metrics summary.
  const MetricsSummaryDto({
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

  /// Decodes a metrics summary.
  factory MetricsSummaryDto.fromJson(Map<String, dynamic> json) =>
      _$MetricsSummaryDtoFromJson(json);

  /// When the summary was produced, RFC3339 UTC.
  final String generatedAt;

  /// Backend uptime in milliseconds.
  final int uptimeMs;

  /// Sessions connected right now.
  final int activeSessions;

  /// Sessions seen since the backend started.
  final int totalSessions;

  /// Session count per tier wire name.
  final Map<String, int> tierDistribution;

  /// RTT aggregates over the queried window.
  final RttStatsDto rtt;

  /// Mean jitter in milliseconds over the window.
  final double jitterMsMean;

  /// Reconnects observed by the backend.
  final int reconnects;

  /// Order-book recoveries recorded.
  final int bookRecoveries;

  /// Order-book range gaps detected.
  final int bookGapsDetected;

  /// Malformed frames received by the backend.
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

  /// Candle invariant violations; zero is the goal.
  final int candleInvariantViolations;

  /// Latency samples persisted in the window.
  final int latencySamples;

  /// Delivery windows persisted in the window.
  final int deliveryWindows;

  /// The raw counter map, exported verbatim by `Copy diagnostics JSON`.
  final Map<String, int> counters;

  /// Encodes this summary.
  Map<String, dynamic> toJson() => _$MetricsSummaryDtoToJson(this);
}

/// RTT aggregates over one window.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class RttStatsDto {
  /// Creates an RTT aggregate.
  const RttStatsDto({
    required this.samples,
    required this.minMs,
    required this.avgMs,
    required this.p95Ms,
    required this.maxMs,
  });

  /// Decodes an RTT aggregate.
  factory RttStatsDto.fromJson(Map<String, dynamic> json) =>
      _$RttStatsDtoFromJson(json);

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

  /// Encodes this aggregate.
  Map<String, dynamic> toJson() => _$RttStatsDtoToJson(this);
}

/// `GET /api/v1/metrics/latency` — the bucketed latency series.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class LatencyBucketsResponseDto {
  /// Creates a latency response.
  const LatencyBucketsResponseDto({
    required this.sessionId,
    required this.from,
    required this.to,
    required this.bucketMs,
    required this.buckets,
  });

  /// Decodes a latency response.
  factory LatencyBucketsResponseDto.fromJson(Map<String, dynamic> json) =>
      _$LatencyBucketsResponseDtoFromJson(json);

  /// The session that was queried, or the empty string for all sessions.
  final String sessionId;

  /// Start of the queried range, RFC3339 UTC.
  final String from;

  /// End of the queried range, RFC3339 UTC.
  final String to;

  /// Bucket width that was applied, in milliseconds.
  final int bucketMs;

  /// The aggregated buckets, oldest first.
  final List<LatencyBucketDto> buckets;

  /// Encodes this response.
  Map<String, dynamic> toJson() => _$LatencyBucketsResponseDtoToJson(this);
}

/// One aggregated point of the latency time series.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class LatencyBucketDto {
  /// Creates a latency bucket.
  const LatencyBucketDto({
    required this.start,
    required this.end,
    required this.count,
    required this.minMs,
    required this.avgMs,
    required this.p95Ms,
    required this.maxMs,
    required this.avgJitterMs,
  });

  /// Decodes a latency bucket.
  factory LatencyBucketDto.fromJson(Map<String, dynamic> json) =>
      _$LatencyBucketDtoFromJson(json);

  /// Bucket start, RFC3339 UTC.
  final String start;

  /// Bucket end, RFC3339 UTC.
  final String end;

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

  /// Encodes this bucket.
  Map<String, dynamic> toJson() => _$LatencyBucketDtoToJson(this);
}

/// `GET /api/v1/metrics/tiers` — tier transitions with their reasons.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class TierTransitionsResponseDto {
  /// Creates a tier transitions response.
  const TierTransitionsResponseDto({
    required this.from,
    required this.to,
    required this.transitions,
  });

  /// Decodes a tier transitions response.
  factory TierTransitionsResponseDto.fromJson(Map<String, dynamic> json) =>
      _$TierTransitionsResponseDtoFromJson(json);

  /// Start of the queried range, RFC3339 UTC.
  final String from;

  /// End of the queried range, RFC3339 UTC.
  final String to;

  /// The transitions, oldest first.
  final List<TierTransitionDto> transitions;

  /// Encodes this response.
  Map<String, dynamic> toJson() => _$TierTransitionsResponseDtoToJson(this);
}

/// One tier change with enough context to explain it.
///
/// The backend row has no JSON tags, so the wire keys are the Go field names
/// and each is pinned with an exact `@JsonKey`.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class TierTransitionDto {
  /// Creates a transition row.
  const TierTransitionDto({
    required this.sessionId,
    required this.at,
    required this.from,
    required this.to,
    required this.reason,
    required this.rttMs,
    required this.jitterMs,
    required this.streak,
    required this.tierOverride,
  });

  /// Decodes a transition row.
  factory TierTransitionDto.fromJson(Map<String, dynamic> json) =>
      _$TierTransitionDtoFromJson(json);

  /// Session the transition applied to.
  @JsonKey(name: 'SessionID')
  final String sessionId;

  /// When it happened, RFC3339 UTC.
  @JsonKey(name: 'At')
  final String at;

  /// Previous tier.
  @JsonKey(name: 'From')
  final String from;

  /// New tier.
  @JsonKey(name: 'To')
  final String to;

  /// Reason slug (`HIGH_RTT`, `RECOVERED`, …).
  @JsonKey(name: 'Reason')
  final String reason;

  /// RTT that caused the transition.
  @JsonKey(name: 'RTTMs')
  final double rttMs;

  /// Jitter that caused the transition.
  @JsonKey(name: 'JitterMs')
  final double jitterMs;

  /// Consecutive-report streak at the moment of transition.
  @JsonKey(name: 'Streak')
  final int streak;

  /// Manual override in force, when any. The wire key is the Go `Override`;
  /// the Dart field avoids the `dart:core` `override` annotation constant.
  @JsonKey(name: 'Override')
  final String tierOverride;

  /// Encodes this row.
  Map<String, dynamic> toJson() => _$TierTransitionDtoToJson(this);
}

/// `GET /api/v1/metrics/sessions` — session lifecycle records.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class SessionsResponseDto {
  /// Creates a sessions response.
  const SessionsResponseDto({required this.sessions});

  /// Decodes a sessions response.
  factory SessionsResponseDto.fromJson(Map<String, dynamic> json) =>
      _$SessionsResponseDtoFromJson(json);

  /// The session records, newest first.
  final List<SessionDto> sessions;

  /// Encodes this response.
  Map<String, dynamic> toJson() => _$SessionsResponseDtoToJson(this);
}

/// The lifecycle record of one connection. Wire keys are Go field names.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class SessionDto {
  /// Creates a session record.
  const SessionDto({
    required this.sessionId,
    required this.deviceId,
    required this.clientVersion,
    required this.platform,
    required this.remoteAddr,
    required this.symbol,
    required this.interval,
    required this.connectedAt,
    required this.disconnectedAt,
    required this.disconnectReason,
    required this.initialTier,
    required this.finalTier,
    required this.overrideTier,
    required this.uptimeMs,
    required this.messagesSent,
    required this.messagesReceived,
    required this.bytesSent,
    required this.protocolErrors,
  });

  /// Decodes a session record.
  factory SessionDto.fromJson(Map<String, dynamic> json) =>
      _$SessionDtoFromJson(json);

  /// Full session id.
  @JsonKey(name: 'SessionID')
  final String sessionId;

  /// Device identifier reported by the client.
  @JsonKey(name: 'DeviceID')
  final String deviceId;

  /// Client build version.
  @JsonKey(name: 'ClientVersion')
  final String clientVersion;

  /// Client platform string.
  @JsonKey(name: 'Platform')
  final String platform;

  /// Peer address of the socket.
  @JsonKey(name: 'RemoteAddr')
  final String remoteAddr;

  /// Subscribed symbol.
  @JsonKey(name: 'Symbol')
  final String symbol;

  /// Subscribed interval.
  @JsonKey(name: 'Interval')
  final String interval;

  /// Connection time, RFC3339 UTC.
  @JsonKey(name: 'ConnectedAt')
  final String connectedAt;

  /// Disconnect time, RFC3339 UTC; null while the session is live.
  @JsonKey(name: 'DisconnectedAt')
  final String? disconnectedAt;

  /// Why the session ended, when it has.
  @JsonKey(name: 'DisconnectReason')
  final String disconnectReason;

  /// Tier the session started at.
  @JsonKey(name: 'InitialTier')
  final String initialTier;

  /// Tier the session ended at.
  @JsonKey(name: 'FinalTier')
  final String finalTier;

  /// Manual override that was in force.
  @JsonKey(name: 'OverrideTier')
  final String overrideTier;

  /// Session uptime in milliseconds.
  @JsonKey(name: 'UptimeMs')
  final int uptimeMs;

  /// Frames the backend sent.
  @JsonKey(name: 'MessagesSent')
  final int messagesSent;

  /// Frames the client sent.
  @JsonKey(name: 'MessagesReceived')
  final int messagesReceived;

  /// Bytes written to the socket.
  @JsonKey(name: 'BytesSent')
  final int bytesSent;

  /// Protocol errors observed on this session.
  @JsonKey(name: 'ProtocolErrors')
  final int protocolErrors;

  /// Encodes this record.
  Map<String, dynamic> toJson() => _$SessionDtoToJson(this);
}

/// `GET /api/v1/metrics/delivery` — delivered versus target rate windows.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class DeliveryResponseDto {
  /// Creates a delivery response.
  const DeliveryResponseDto({
    required this.sessionId,
    required this.from,
    required this.to,
    required this.windows,
  });

  /// Decodes a delivery response.
  factory DeliveryResponseDto.fromJson(Map<String, dynamic> json) =>
      _$DeliveryResponseDtoFromJson(json);

  /// The session that was queried, or the empty string for all sessions.
  final String sessionId;

  /// Start of the queried range, RFC3339 UTC.
  final String from;

  /// End of the queried range, RFC3339 UTC.
  final String to;

  /// The delivery windows, oldest first.
  final List<DeliveryWindowDto> windows;

  /// Encodes this response.
  Map<String, dynamic> toJson() => _$DeliveryResponseDtoToJson(this);
}

/// One five-second delivery summary per session. Wire keys are Go field names.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class DeliveryWindowDto {
  /// Creates a delivery window row.
  const DeliveryWindowDto({
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

  /// Decodes a delivery window row.
  factory DeliveryWindowDto.fromJson(Map<String, dynamic> json) =>
      _$DeliveryWindowDtoFromJson(json);

  /// Session the window belongs to.
  @JsonKey(name: 'SessionID')
  final String sessionId;

  /// Window start, RFC3339 UTC.
  @JsonKey(name: 'WindowStart')
  final String windowStart;

  /// Window length in milliseconds.
  @JsonKey(name: 'WindowMs')
  final int windowMs;

  /// Tier in force during the window.
  @JsonKey(name: 'Tier')
  final String tier;

  /// Messages per second targeted.
  @JsonKey(name: 'TargetRate')
  final double targetRate;

  /// Messages per second delivered.
  @JsonKey(name: 'EffectiveRate')
  final double effectiveRate;

  /// Candle updates delivered.
  @JsonKey(name: 'CandleUpdates')
  final int candleUpdates;

  /// Trade messages delivered.
  @JsonKey(name: 'TradeMessages')
  final int tradeMessages;

  /// Book deltas delivered.
  @JsonKey(name: 'BookDeltas')
  final int bookDeltas;

  /// Health frames delivered.
  @JsonKey(name: 'HealthMessages')
  final int healthMessages;

  /// Messages coalesced away.
  @JsonKey(name: 'Coalesced')
  final int coalesced;

  /// Messages suppressed by the tier.
  @JsonKey(name: 'Suppressed')
  final int suppressed;

  /// Bytes written to the socket.
  @JsonKey(name: 'BytesSent')
  final int bytesSent;

  /// Encodes this row.
  Map<String, dynamic> toJson() => _$DeliveryWindowDtoToJson(this);
}
