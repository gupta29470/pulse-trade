import 'package:json_annotation/json_annotation.dart';

part 'server_envelope_dto.g.dart';

/// The envelope every server-to-client frame carries.
///
/// The envelope is decoded first so a frame can be rejected on its `type` and
/// `version` alone, before a payload this build may not understand is touched.
/// Timestamps stay [String] here: RFC3339 parsing belongs to the
/// mapping layer, never to generated code.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class ServerEnvelopeDto {
  /// Creates an envelope.
  const ServerEnvelopeDto({
    required this.type,
    required this.version,
    required this.serverTime,
    required this.seq,
    this.payload,
  });

  /// Decodes one envelope from an already-decoded JSON object.
  factory ServerEnvelopeDto.fromJson(Map<String, dynamic> json) =>
      _$ServerEnvelopeDtoFromJson(json);

  /// Wire message type (`welcome`, `trade`, `order_book_delta`, …).
  final String type;

  /// Protocol version carried on the frame.
  final int version;

  /// Server time, RFC3339 with milliseconds, UTC.
  final String serverTime;

  /// Per-connection frame sequence number. A `uint64` on the wire, held as an
  /// `int` because Dart integers are 64-bit on the VM.
  final int seq;

  /// The raw payload object, absent for frames that carry no body.
  ///
  /// Declared as `Map<String, dynamic>` (not `Map<String, Object?>`) because
  /// `json_serializable` maps a decoded JSON object to that type directly; the
  /// parser re-wraps it as `Map<String, Object?>` before handing it on.
  final Map<String, dynamic>? payload;

  /// Encodes this envelope back to a JSON object.
  Map<String, dynamic> toJson() => _$ServerEnvelopeDtoToJson(this);
}
