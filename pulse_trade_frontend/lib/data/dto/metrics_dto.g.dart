// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'metrics_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MetricsSummaryDto _$MetricsSummaryDtoFromJson(Map<String, dynamic> json) =>
    MetricsSummaryDto(
      generatedAt: json['generatedAt'] as String,
      uptimeMs: (json['uptimeMs'] as num).toInt(),
      activeSessions: (json['activeSessions'] as num).toInt(),
      totalSessions: (json['totalSessions'] as num).toInt(),
      tierDistribution: Map<String, int>.from(json['tierDistribution'] as Map),
      rtt: RttStatsDto.fromJson(json['rtt'] as Map<String, dynamic>),
      jitterMsMean: (json['jitterMsMean'] as num).toDouble(),
      reconnects: (json['reconnects'] as num).toInt(),
      bookRecoveries: (json['bookRecoveries'] as num).toInt(),
      bookGapsDetected: (json['bookGapsDetected'] as num).toInt(),
      malformedMessages: (json['malformedMessages'] as num).toInt(),
      duplicateDeltas: (json['duplicateDeltas'] as num).toInt(),
      staleDeltas: (json['staleDeltas'] as num).toInt(),
      outOfOrderTrades: (json['outOfOrderTrades'] as num).toInt(),
      tierTransitions: (json['tierTransitions'] as num).toInt(),
      candlesClosed: (json['candlesClosed'] as num).toInt(),
      candleInvariantViolations: (json['candleInvariantViolations'] as num)
          .toInt(),
      latencySamples: (json['latencySamples'] as num).toInt(),
      deliveryWindows: (json['deliveryWindows'] as num).toInt(),
      counters: Map<String, int>.from(json['counters'] as Map),
    );

Map<String, dynamic> _$MetricsSummaryDtoToJson(MetricsSummaryDto instance) =>
    <String, dynamic>{
      'generatedAt': instance.generatedAt,
      'uptimeMs': instance.uptimeMs,
      'activeSessions': instance.activeSessions,
      'totalSessions': instance.totalSessions,
      'tierDistribution': instance.tierDistribution,
      'rtt': instance.rtt.toJson(),
      'jitterMsMean': instance.jitterMsMean,
      'reconnects': instance.reconnects,
      'bookRecoveries': instance.bookRecoveries,
      'bookGapsDetected': instance.bookGapsDetected,
      'malformedMessages': instance.malformedMessages,
      'duplicateDeltas': instance.duplicateDeltas,
      'staleDeltas': instance.staleDeltas,
      'outOfOrderTrades': instance.outOfOrderTrades,
      'tierTransitions': instance.tierTransitions,
      'candlesClosed': instance.candlesClosed,
      'candleInvariantViolations': instance.candleInvariantViolations,
      'latencySamples': instance.latencySamples,
      'deliveryWindows': instance.deliveryWindows,
      'counters': instance.counters,
    };

RttStatsDto _$RttStatsDtoFromJson(Map<String, dynamic> json) => RttStatsDto(
  samples: (json['samples'] as num).toInt(),
  minMs: (json['minMs'] as num).toDouble(),
  avgMs: (json['avgMs'] as num).toDouble(),
  p95Ms: (json['p95Ms'] as num).toDouble(),
  maxMs: (json['maxMs'] as num).toDouble(),
);

Map<String, dynamic> _$RttStatsDtoToJson(RttStatsDto instance) =>
    <String, dynamic>{
      'samples': instance.samples,
      'minMs': instance.minMs,
      'avgMs': instance.avgMs,
      'p95Ms': instance.p95Ms,
      'maxMs': instance.maxMs,
    };

LatencyBucketsResponseDto _$LatencyBucketsResponseDtoFromJson(
  Map<String, dynamic> json,
) => LatencyBucketsResponseDto(
  sessionId: json['sessionId'] as String,
  from: json['from'] as String,
  to: json['to'] as String,
  bucketMs: (json['bucketMs'] as num).toInt(),
  buckets: (json['buckets'] as List<dynamic>)
      .map((e) => LatencyBucketDto.fromJson(e as Map<String, dynamic>))
      .toList(),
);

Map<String, dynamic> _$LatencyBucketsResponseDtoToJson(
  LatencyBucketsResponseDto instance,
) => <String, dynamic>{
  'sessionId': instance.sessionId,
  'from': instance.from,
  'to': instance.to,
  'bucketMs': instance.bucketMs,
  'buckets': instance.buckets.map((e) => e.toJson()).toList(),
};

LatencyBucketDto _$LatencyBucketDtoFromJson(Map<String, dynamic> json) =>
    LatencyBucketDto(
      start: json['start'] as String,
      end: json['end'] as String,
      count: (json['count'] as num).toInt(),
      minMs: (json['minMs'] as num).toDouble(),
      avgMs: (json['avgMs'] as num).toDouble(),
      p95Ms: (json['p95Ms'] as num).toDouble(),
      maxMs: (json['maxMs'] as num).toDouble(),
      avgJitterMs: (json['avgJitterMs'] as num).toDouble(),
    );

Map<String, dynamic> _$LatencyBucketDtoToJson(LatencyBucketDto instance) =>
    <String, dynamic>{
      'start': instance.start,
      'end': instance.end,
      'count': instance.count,
      'minMs': instance.minMs,
      'avgMs': instance.avgMs,
      'p95Ms': instance.p95Ms,
      'maxMs': instance.maxMs,
      'avgJitterMs': instance.avgJitterMs,
    };

TierTransitionsResponseDto _$TierTransitionsResponseDtoFromJson(
  Map<String, dynamic> json,
) => TierTransitionsResponseDto(
  from: json['from'] as String,
  to: json['to'] as String,
  transitions: (json['transitions'] as List<dynamic>)
      .map((e) => TierTransitionDto.fromJson(e as Map<String, dynamic>))
      .toList(),
);

Map<String, dynamic> _$TierTransitionsResponseDtoToJson(
  TierTransitionsResponseDto instance,
) => <String, dynamic>{
  'from': instance.from,
  'to': instance.to,
  'transitions': instance.transitions.map((e) => e.toJson()).toList(),
};

TierTransitionDto _$TierTransitionDtoFromJson(Map<String, dynamic> json) =>
    TierTransitionDto(
      sessionId: json['SessionID'] as String,
      at: json['At'] as String,
      from: json['From'] as String,
      to: json['To'] as String,
      reason: json['Reason'] as String,
      rttMs: (json['RTTMs'] as num).toDouble(),
      jitterMs: (json['JitterMs'] as num).toDouble(),
      streak: (json['Streak'] as num).toInt(),
      tierOverride: json['Override'] as String,
    );

Map<String, dynamic> _$TierTransitionDtoToJson(TierTransitionDto instance) =>
    <String, dynamic>{
      'SessionID': instance.sessionId,
      'At': instance.at,
      'From': instance.from,
      'To': instance.to,
      'Reason': instance.reason,
      'RTTMs': instance.rttMs,
      'JitterMs': instance.jitterMs,
      'Streak': instance.streak,
      'Override': instance.tierOverride,
    };

SessionsResponseDto _$SessionsResponseDtoFromJson(Map<String, dynamic> json) =>
    SessionsResponseDto(
      sessions: (json['sessions'] as List<dynamic>)
          .map((e) => SessionDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$SessionsResponseDtoToJson(
  SessionsResponseDto instance,
) => <String, dynamic>{
  'sessions': instance.sessions.map((e) => e.toJson()).toList(),
};

SessionDto _$SessionDtoFromJson(Map<String, dynamic> json) => SessionDto(
  sessionId: json['SessionID'] as String,
  deviceId: json['DeviceID'] as String,
  clientVersion: json['ClientVersion'] as String,
  platform: json['Platform'] as String,
  remoteAddr: json['RemoteAddr'] as String,
  symbol: json['Symbol'] as String,
  interval: json['Interval'] as String,
  connectedAt: json['ConnectedAt'] as String,
  disconnectedAt: json['DisconnectedAt'] as String?,
  disconnectReason: json['DisconnectReason'] as String,
  initialTier: json['InitialTier'] as String,
  finalTier: json['FinalTier'] as String,
  overrideTier: json['OverrideTier'] as String,
  uptimeMs: (json['UptimeMs'] as num).toInt(),
  messagesSent: (json['MessagesSent'] as num).toInt(),
  messagesReceived: (json['MessagesReceived'] as num).toInt(),
  bytesSent: (json['BytesSent'] as num).toInt(),
  protocolErrors: (json['ProtocolErrors'] as num).toInt(),
);

Map<String, dynamic> _$SessionDtoToJson(SessionDto instance) =>
    <String, dynamic>{
      'SessionID': instance.sessionId,
      'DeviceID': instance.deviceId,
      'ClientVersion': instance.clientVersion,
      'Platform': instance.platform,
      'RemoteAddr': instance.remoteAddr,
      'Symbol': instance.symbol,
      'Interval': instance.interval,
      'ConnectedAt': instance.connectedAt,
      'DisconnectedAt': instance.disconnectedAt,
      'DisconnectReason': instance.disconnectReason,
      'InitialTier': instance.initialTier,
      'FinalTier': instance.finalTier,
      'OverrideTier': instance.overrideTier,
      'UptimeMs': instance.uptimeMs,
      'MessagesSent': instance.messagesSent,
      'MessagesReceived': instance.messagesReceived,
      'BytesSent': instance.bytesSent,
      'ProtocolErrors': instance.protocolErrors,
    };

DeliveryResponseDto _$DeliveryResponseDtoFromJson(Map<String, dynamic> json) =>
    DeliveryResponseDto(
      sessionId: json['sessionId'] as String,
      from: json['from'] as String,
      to: json['to'] as String,
      windows: (json['windows'] as List<dynamic>)
          .map((e) => DeliveryWindowDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$DeliveryResponseDtoToJson(
  DeliveryResponseDto instance,
) => <String, dynamic>{
  'sessionId': instance.sessionId,
  'from': instance.from,
  'to': instance.to,
  'windows': instance.windows.map((e) => e.toJson()).toList(),
};

DeliveryWindowDto _$DeliveryWindowDtoFromJson(Map<String, dynamic> json) =>
    DeliveryWindowDto(
      sessionId: json['SessionID'] as String,
      windowStart: json['WindowStart'] as String,
      windowMs: (json['WindowMs'] as num).toInt(),
      tier: json['Tier'] as String,
      targetRate: (json['TargetRate'] as num).toDouble(),
      effectiveRate: (json['EffectiveRate'] as num).toDouble(),
      candleUpdates: (json['CandleUpdates'] as num).toInt(),
      tradeMessages: (json['TradeMessages'] as num).toInt(),
      bookDeltas: (json['BookDeltas'] as num).toInt(),
      healthMessages: (json['HealthMessages'] as num).toInt(),
      coalesced: (json['Coalesced'] as num).toInt(),
      suppressed: (json['Suppressed'] as num).toInt(),
      bytesSent: (json['BytesSent'] as num).toInt(),
    );

Map<String, dynamic> _$DeliveryWindowDtoToJson(DeliveryWindowDto instance) =>
    <String, dynamic>{
      'SessionID': instance.sessionId,
      'WindowStart': instance.windowStart,
      'WindowMs': instance.windowMs,
      'Tier': instance.tier,
      'TargetRate': instance.targetRate,
      'EffectiveRate': instance.effectiveRate,
      'CandleUpdates': instance.candleUpdates,
      'TradeMessages': instance.tradeMessages,
      'BookDeltas': instance.bookDeltas,
      'HealthMessages': instance.healthMessages,
      'Coalesced': instance.coalesced,
      'Suppressed': instance.suppressed,
      'BytesSent': instance.bytesSent,
    };
