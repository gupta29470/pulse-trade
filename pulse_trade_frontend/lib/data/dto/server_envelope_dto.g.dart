// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_envelope_dto.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ServerEnvelopeDto _$ServerEnvelopeDtoFromJson(Map<String, dynamic> json) =>
    ServerEnvelopeDto(
      type: json['type'] as String,
      version: (json['version'] as num).toInt(),
      serverTime: json['serverTime'] as String,
      seq: (json['seq'] as num).toInt(),
      payload: json['payload'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$ServerEnvelopeDtoToJson(ServerEnvelopeDto instance) =>
    <String, dynamic>{
      'type': instance.type,
      'version': instance.version,
      'serverTime': instance.serverTime,
      'seq': instance.seq,
      'payload': instance.payload,
    };
