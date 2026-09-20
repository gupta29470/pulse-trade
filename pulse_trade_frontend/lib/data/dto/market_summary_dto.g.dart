// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'market_summary_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MarketSummaryDto _$MarketSummaryDtoFromJson(Map<String, dynamic> json) =>
    MarketSummaryDto(
      symbol: json['symbol'] as String,
      last: json['last'] as String,
      open24h: json['open24h'] as String,
      high24h: json['high24h'] as String,
      low24h: json['low24h'] as String,
      volume24h: json['volume24h'] as String,
      change: json['change'] as String,
      changeBasisPoints: (json['changeBasisPoints'] as num).toInt(),
      trades24h: (json['trades24h'] as num).toInt(),
      updatedAt: json['updatedAt'] as String,
    );

Map<String, dynamic> _$MarketSummaryDtoToJson(MarketSummaryDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'last': instance.last,
      'open24h': instance.open24h,
      'high24h': instance.high24h,
      'low24h': instance.low24h,
      'volume24h': instance.volume24h,
      'change': instance.change,
      'changeBasisPoints': instance.changeBasisPoints,
      'trades24h': instance.trades24h,
      'updatedAt': instance.updatedAt,
    };
