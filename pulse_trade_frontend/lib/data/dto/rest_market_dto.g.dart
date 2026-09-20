// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rest_market_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MarketsResponseDto _$MarketsResponseDtoFromJson(Map<String, dynamic> json) =>
    MarketsResponseDto(
      markets: (json['markets'] as List<dynamic>)
          .map((e) => MarketInfoDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$MarketsResponseDtoToJson(MarketsResponseDto instance) =>
    <String, dynamic>{
      'markets': instance.markets.map((e) => e.toJson()).toList(),
    };

MarketInfoDto _$MarketInfoDtoFromJson(Map<String, dynamic> json) =>
    MarketInfoDto(
      symbol: json['symbol'] as String,
      display: json['display'] as String,
      name: json['name'] as String,
      glyph: json['glyph'] as String,
      priceDigits: (json['priceDigits'] as num).toInt(),
      quantityDigits: (json['quantityDigits'] as num).toInt(),
      lastPrice: json['lastPrice'] as String?,
      changeBasisPoints: (json['changeBasisPoints'] as num?)?.toInt(),
    );

Map<String, dynamic> _$MarketInfoDtoToJson(MarketInfoDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'display': instance.display,
      'name': instance.name,
      'glyph': instance.glyph,
      'priceDigits': instance.priceDigits,
      'quantityDigits': instance.quantityDigits,
      'lastPrice': instance.lastPrice,
      'changeBasisPoints': instance.changeBasisPoints,
    };

CandlesResponseDto _$CandlesResponseDtoFromJson(Map<String, dynamic> json) =>
    CandlesResponseDto(
      symbol: json['symbol'] as String,
      interval: json['interval'] as String,
      limit: (json['limit'] as num).toInt(),
      candles: (json['candles'] as List<dynamic>)
          .map((e) => CandleDto.fromJson(e as Map<String, dynamic>))
          .toList(),
      serverTime: json['serverTime'] as String,
    );

Map<String, dynamic> _$CandlesResponseDtoToJson(CandlesResponseDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'interval': instance.interval,
      'limit': instance.limit,
      'candles': instance.candles.map((e) => e.toJson()).toList(),
      'serverTime': instance.serverTime,
    };

TradesResponseDto _$TradesResponseDtoFromJson(Map<String, dynamic> json) =>
    TradesResponseDto(
      symbol: json['symbol'] as String,
      limit: (json['limit'] as num).toInt(),
      trades: (json['trades'] as List<dynamic>)
          .map((e) => TradeDto.fromJson(e as Map<String, dynamic>))
          .toList(),
      serverTime: json['serverTime'] as String,
    );

Map<String, dynamic> _$TradesResponseDtoToJson(TradesResponseDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'limit': instance.limit,
      'trades': instance.trades.map((e) => e.toJson()).toList(),
      'serverTime': instance.serverTime,
    };

BackendHealthDto _$BackendHealthDtoFromJson(
  Map<String, dynamic> json,
) => BackendHealthDto(
  status: json['status'] as String,
  time: json['time'] as String,
  version: json['version'] as String?,
  uptimeMs: (json['uptimeMs'] as num?)?.toInt(),
  engine: json['engine'] == null
      ? null
      : EngineHealthDto.fromJson(json['engine'] as Map<String, dynamic>),
  metrics: json['metrics'] == null
      ? null
      : MetricsStoreHealthDto.fromJson(json['metrics'] as Map<String, dynamic>),
  sessions: json['sessions'] == null
      ? null
      : SessionsHealthDto.fromJson(json['sessions'] as Map<String, dynamic>),
  reasons: (json['reasons'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
);

Map<String, dynamic> _$BackendHealthDtoToJson(BackendHealthDto instance) =>
    <String, dynamic>{
      'status': instance.status,
      'time': instance.time,
      'version': instance.version,
      'uptimeMs': instance.uptimeMs,
      'engine': instance.engine?.toJson(),
      'metrics': instance.metrics?.toJson(),
      'sessions': instance.sessions?.toJson(),
      'reasons': instance.reasons,
    };

EngineHealthDto _$EngineHealthDtoFromJson(Map<String, dynamic> json) =>
    EngineHealthDto(
      state: json['state'] as String,
      symbol: json['symbol'] as String,
      epoch: (json['epoch'] as num).toInt(),
      eventIndex: (json['eventIndex'] as num).toInt(),
      updateId: (json['updateId'] as num).toInt(),
      warmupComplete: json['warmupComplete'] as bool,
    );

Map<String, dynamic> _$EngineHealthDtoToJson(EngineHealthDto instance) =>
    <String, dynamic>{
      'state': instance.state,
      'symbol': instance.symbol,
      'epoch': instance.epoch,
      'eventIndex': instance.eventIndex,
      'updateId': instance.updateId,
      'warmupComplete': instance.warmupComplete,
    };

MetricsStoreHealthDto _$MetricsStoreHealthDtoFromJson(
  Map<String, dynamic> json,
) => MetricsStoreHealthDto(
  driver: json['driver'] as String,
  status: json['status'] as String,
  queueDepth: (json['queueDepth'] as num).toInt(),
  droppedTotal: (json['droppedTotal'] as num).toInt(),
  lastFlushMs: (json['lastFlushMs'] as num).toInt(),
);

Map<String, dynamic> _$MetricsStoreHealthDtoToJson(
  MetricsStoreHealthDto instance,
) => <String, dynamic>{
  'driver': instance.driver,
  'status': instance.status,
  'queueDepth': instance.queueDepth,
  'droppedTotal': instance.droppedTotal,
  'lastFlushMs': instance.lastFlushMs,
};

SessionsHealthDto _$SessionsHealthDtoFromJson(Map<String, dynamic> json) =>
    SessionsHealthDto(
      active: (json['active'] as num).toInt(),
      total: (json['total'] as num).toInt(),
    );

Map<String, dynamic> _$SessionsHealthDtoToJson(SessionsHealthDto instance) =>
    <String, dynamic>{'active': instance.active, 'total': instance.total};

LivenessDto _$LivenessDtoFromJson(Map<String, dynamic> json) => LivenessDto(
  status: json['status'] as String,
  time: json['time'] as String,
  version: json['version'] as String?,
  uptimeMs: (json['uptimeMs'] as num?)?.toInt(),
);

Map<String, dynamic> _$LivenessDtoToJson(LivenessDto instance) =>
    <String, dynamic>{
      'status': instance.status,
      'time': instance.time,
      'version': instance.version,
      'uptimeMs': instance.uptimeMs,
    };
