// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'market_status_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MarketStatusDto _$MarketStatusDtoFromJson(Map<String, dynamic> json) =>
    MarketStatusDto(
      state: json['state'] as String,
      epoch: (json['epoch'] as num).toInt(),
      message: json['message'] as String,
      at: json['at'] as String,
    );

Map<String, dynamic> _$MarketStatusDtoToJson(MarketStatusDto instance) =>
    <String, dynamic>{
      'state': instance.state,
      'epoch': instance.epoch,
      'message': instance.message,
      'at': instance.at,
    };
