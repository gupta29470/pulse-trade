// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'health_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

HealthDto _$HealthDtoFromJson(Map<String, dynamic> json) => HealthDto(
  tier: json['tier'] as String,
  tierOverride: json['override'] as String,
  reason: json['reason'] as String,
  targetRatePerSec: (json['targetRatePerSec'] as num).toDouble(),
  effectiveRatePerSec: (json['effectiveRatePerSec'] as num).toDouble(),
  rttMs: (json['rttMs'] as num).toDouble(),
  jitterMs: (json['jitterMs'] as num).toDouble(),
  lastReportAgeMs: (json['lastReportAgeMs'] as num).toInt(),
  uptimeMs: (json['uptimeMs'] as num).toInt(),
  bookEpoch: (json['bookEpoch'] as num).toInt(),
  bookUpdateId: (json['bookUpdateId'] as num).toInt(),
  coalescedCount: (json['coalescedCount'] as num).toInt(),
  suppressedCount: (json['suppressedCount'] as num).toInt(),
  queuedMessages: (json['queuedMessages'] as num).toInt(),
  droppedMessages: (json['droppedMessages'] as num).toInt(),
);

Map<String, dynamic> _$HealthDtoToJson(HealthDto instance) => <String, dynamic>{
  'tier': instance.tier,
  'override': instance.tierOverride,
  'reason': instance.reason,
  'targetRatePerSec': instance.targetRatePerSec,
  'effectiveRatePerSec': instance.effectiveRatePerSec,
  'rttMs': instance.rttMs,
  'jitterMs': instance.jitterMs,
  'lastReportAgeMs': instance.lastReportAgeMs,
  'uptimeMs': instance.uptimeMs,
  'bookEpoch': instance.bookEpoch,
  'bookUpdateId': instance.bookUpdateId,
  'coalescedCount': instance.coalescedCount,
  'suppressedCount': instance.suppressedCount,
  'queuedMessages': instance.queuedMessages,
  'droppedMessages': instance.droppedMessages,
};
