// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'welcome_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

WelcomeDto _$WelcomeDtoFromJson(Map<String, dynamic> json) => WelcomeDto(
  sessionId: json['sessionId'] as String,
  shortId: json['shortId'] as String,
  symbol: json['symbol'] as String,
  epoch: (json['epoch'] as num).toInt(),
  engineState: json['engineState'] as String,
  serverTime: json['serverTime'] as String,
  protocolMin: (json['protocolMin'] as num).toInt(),
  protocolMax: (json['protocolMax'] as num).toInt(),
  intervals: (json['intervals'] as List<dynamic>)
      .map((e) => e as String)
      .toList(),
  channels: (json['channels'] as List<dynamic>)
      .map((e) => e as String)
      .toList(),
  heartbeatMs: (json['heartbeatMs'] as num).toInt(),
  tierRatesPerSec: (json['tierRatesPerSec'] as Map<String, dynamic>).map(
    (k, e) => MapEntry(k, (e as num).toDouble()),
  ),
  tierThresholds: TierThresholdsDto.fromJson(
    json['tierThresholds'] as Map<String, dynamic>,
  ),
);

Map<String, dynamic> _$WelcomeDtoToJson(WelcomeDto instance) =>
    <String, dynamic>{
      'sessionId': instance.sessionId,
      'shortId': instance.shortId,
      'symbol': instance.symbol,
      'epoch': instance.epoch,
      'engineState': instance.engineState,
      'serverTime': instance.serverTime,
      'protocolMin': instance.protocolMin,
      'protocolMax': instance.protocolMax,
      'intervals': instance.intervals,
      'channels': instance.channels,
      'heartbeatMs': instance.heartbeatMs,
      'tierRatesPerSec': instance.tierRatesPerSec,
      'tierThresholds': instance.tierThresholds.toJson(),
    };

TierThresholdsDto _$TierThresholdsDtoFromJson(Map<String, dynamic> json) =>
    TierThresholdsDto(
      fullMaxRttMs: (json['fullMaxRttMs'] as num).toDouble(),
      fullMaxJitterMs: (json['fullMaxJitterMs'] as num).toDouble(),
      minimalMinRttMs: (json['minimalMinRttMs'] as num).toDouble(),
      minimalMinJitterMs: (json['minimalMinJitterMs'] as num).toDouble(),
      degradeStreak: (json['degradeStreak'] as num).toInt(),
      recoverStreak: (json['recoverStreak'] as num).toInt(),
      reportHoldMs: (json['reportHoldMs'] as num).toInt(),
      reportDegradeMs: (json['reportDegradeMs'] as num).toInt(),
    );

Map<String, dynamic> _$TierThresholdsDtoToJson(TierThresholdsDto instance) =>
    <String, dynamic>{
      'fullMaxRttMs': instance.fullMaxRttMs,
      'fullMaxJitterMs': instance.fullMaxJitterMs,
      'minimalMinRttMs': instance.minimalMinRttMs,
      'minimalMinJitterMs': instance.minimalMinJitterMs,
      'degradeStreak': instance.degradeStreak,
      'recoverStreak': instance.recoverStreak,
      'reportHoldMs': instance.reportHoldMs,
      'reportDegradeMs': instance.reportDegradeMs,
    };
