// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trade_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TradeDto _$TradeDtoFromJson(Map<String, dynamic> json) => TradeDto(
  tradeId: (json['tradeId'] as num).toInt(),
  symbol: json['symbol'] as String,
  timestamp: json['timestamp'] as String,
  price: json['price'] as String,
  quantity: json['quantity'] as String,
  side: json['side'] as String,
);

Map<String, dynamic> _$TradeDtoToJson(TradeDto instance) => <String, dynamic>{
  'tradeId': instance.tradeId,
  'symbol': instance.symbol,
  'timestamp': instance.timestamp,
  'price': instance.price,
  'quantity': instance.quantity,
  'side': instance.side,
};

TradeBatchDto _$TradeBatchDtoFromJson(Map<String, dynamic> json) =>
    TradeBatchDto(
      symbol: json['symbol'] as String,
      trades: (json['trades'] as List<dynamic>)
          .map((e) => TradeDto.fromJson(e as Map<String, dynamic>))
          .toList(),
      compacted: json['compacted'] as bool,
      omittedCount: (json['omittedCount'] as num).toInt(),
    );

Map<String, dynamic> _$TradeBatchDtoToJson(TradeBatchDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'trades': instance.trades.map((e) => e.toJson()).toList(),
      'compacted': instance.compacted,
      'omittedCount': instance.omittedCount,
    };
