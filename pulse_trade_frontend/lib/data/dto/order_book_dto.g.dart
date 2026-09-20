// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'order_book_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

OrderBookSnapshotDto _$OrderBookSnapshotDtoFromJson(
  Map<String, dynamic> json,
) => OrderBookSnapshotDto(
  symbol: json['symbol'] as String,
  epoch: (json['epoch'] as num).toInt(),
  updateId: (json['updateId'] as num).toInt(),
  bids: (json['bids'] as List<dynamic>)
      .map((e) => (e as List<dynamic>).map((e) => e as String).toList())
      .toList(),
  asks: (json['asks'] as List<dynamic>)
      .map((e) => (e as List<dynamic>).map((e) => e as String).toList())
      .toList(),
  serverTime: json['serverTime'] as String,
);

Map<String, dynamic> _$OrderBookSnapshotDtoToJson(
  OrderBookSnapshotDto instance,
) => <String, dynamic>{
  'symbol': instance.symbol,
  'epoch': instance.epoch,
  'updateId': instance.updateId,
  'bids': instance.bids,
  'asks': instance.asks,
  'serverTime': instance.serverTime,
};

OrderBookDeltaDto _$OrderBookDeltaDtoFromJson(Map<String, dynamic> json) =>
    OrderBookDeltaDto(
      symbol: json['symbol'] as String,
      epoch: (json['epoch'] as num).toInt(),
      firstUpdateId: (json['firstUpdateId'] as num).toInt(),
      lastUpdateId: (json['lastUpdateId'] as num).toInt(),
      bids: (json['bids'] as List<dynamic>)
          .map((e) => (e as List<dynamic>).map((e) => e as String).toList())
          .toList(),
      asks: (json['asks'] as List<dynamic>)
          .map((e) => (e as List<dynamic>).map((e) => e as String).toList())
          .toList(),
    );

Map<String, dynamic> _$OrderBookDeltaDtoToJson(OrderBookDeltaDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'epoch': instance.epoch,
      'firstUpdateId': instance.firstUpdateId,
      'lastUpdateId': instance.lastUpdateId,
      'bids': instance.bids,
      'asks': instance.asks,
    };
