// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'candle_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

CandleDto _$CandleDtoFromJson(Map<String, dynamic> json) => CandleDto(
  startTime: json['startTime'] as String,
  open: json['open'] as String,
  high: json['high'] as String,
  low: json['low'] as String,
  close: json['close'] as String,
  volume: json['volume'] as String,
  tradeCount: (json['tradeCount'] as num).toInt(),
  sourceSequence: (json['sourceSequence'] as num).toInt(),
  active: json['active'] as bool? ?? false,
);

Map<String, dynamic> _$CandleDtoToJson(CandleDto instance) => <String, dynamic>{
  'startTime': instance.startTime,
  'open': instance.open,
  'high': instance.high,
  'low': instance.low,
  'close': instance.close,
  'volume': instance.volume,
  'tradeCount': instance.tradeCount,
  'sourceSequence': instance.sourceSequence,
  'active': instance.active,
};

CandleUpdateDto _$CandleUpdateDtoFromJson(Map<String, dynamic> json) =>
    CandleUpdateDto(
      symbol: json['symbol'] as String,
      interval: json['interval'] as String,
      candle: CandleDto.fromJson(json['candle'] as Map<String, dynamic>),
      sourceSequence: (json['sourceSequence'] as num).toInt(),
      active: json['active'] as bool,
    );

Map<String, dynamic> _$CandleUpdateDtoToJson(CandleUpdateDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'interval': instance.interval,
      'candle': instance.candle.toJson(),
      'sourceSequence': instance.sourceSequence,
      'active': instance.active,
    };

CandleClosedDto _$CandleClosedDtoFromJson(Map<String, dynamic> json) =>
    CandleClosedDto(
      symbol: json['symbol'] as String,
      interval: json['interval'] as String,
      candle: CandleDto.fromJson(json['candle'] as Map<String, dynamic>),
      epoch: (json['epoch'] as num).toInt(),
    );

Map<String, dynamic> _$CandleClosedDtoToJson(CandleClosedDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'interval': instance.interval,
      'candle': instance.candle.toJson(),
      'epoch': instance.epoch,
    };
