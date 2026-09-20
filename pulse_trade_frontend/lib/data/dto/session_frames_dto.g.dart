// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session_frames_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SubscribedDto _$SubscribedDtoFromJson(Map<String, dynamic> json) =>
    SubscribedDto(
      symbol: json['symbol'] as String,
      interval: json['interval'] as String,
      channels: (json['channels'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      epoch: (json['epoch'] as num).toInt(),
    );

Map<String, dynamic> _$SubscribedDtoToJson(SubscribedDto instance) =>
    <String, dynamic>{
      'symbol': instance.symbol,
      'interval': instance.interval,
      'channels': instance.channels,
      'epoch': instance.epoch,
    };

UnsubscribedDto _$UnsubscribedDtoFromJson(Map<String, dynamic> json) =>
    UnsubscribedDto(
      channels: (json['channels'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$UnsubscribedDtoToJson(UnsubscribedDto instance) =>
    <String, dynamic>{'channels': instance.channels};

PongDto _$PongDtoFromJson(Map<String, dynamic> json) => PongDto(
  id: (json['id'] as num).toInt(),
  clientTimeMs: (json['clientTimeMs'] as num).toInt(),
  serverTimeMs: (json['serverTimeMs'] as num).toInt(),
);

Map<String, dynamic> _$PongDtoToJson(PongDto instance) => <String, dynamic>{
  'id': instance.id,
  'clientTimeMs': instance.clientTimeMs,
  'serverTimeMs': instance.serverTimeMs,
};

PingDto _$PingDtoFromJson(Map<String, dynamic> json) =>
    PingDto(id: (json['id'] as num).toInt());

Map<String, dynamic> _$PingDtoToJson(PingDto instance) => <String, dynamic>{
  'id': instance.id,
};

GoodbyeDto _$GoodbyeDtoFromJson(Map<String, dynamic> json) =>
    GoodbyeDto(reason: json['reason'] as String);

Map<String, dynamic> _$GoodbyeDtoToJson(GoodbyeDto instance) =>
    <String, dynamic>{'reason': instance.reason};

ErrorDto _$ErrorDtoFromJson(Map<String, dynamic> json) => ErrorDto(
  code: json['code'] as String,
  message: json['message'] as String,
  fatal: json['fatal'] as bool? ?? false,
  requestId: json['requestId'] as String?,
);

Map<String, dynamic> _$ErrorDtoToJson(ErrorDto instance) => <String, dynamic>{
  'code': instance.code,
  'message': instance.message,
  'fatal': instance.fatal,
  'requestId': instance.requestId,
};
