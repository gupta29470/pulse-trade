import 'package:json_annotation/json_annotation.dart';

part 'session_frames_dto.g.dart';

/// `subscribed` — the session's subscription was (re)applied.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class SubscribedDto {
  /// Creates a subscribed payload.
  const SubscribedDto({
    required this.symbol,
    required this.interval,
    required this.channels,
    required this.epoch,
  });

  /// Decodes a subscribed payload.
  factory SubscribedDto.fromJson(Map<String, dynamic> json) =>
      _$SubscribedDtoFromJson(json);

  /// Subscribed symbol id.
  final String symbol;

  /// Subscribed candle interval id (`1m`, `5m`, …).
  final String interval;

  /// Channel names now active on the session.
  final List<String> channels;

  /// Engine epoch the subscription was applied against.
  final int epoch;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$SubscribedDtoToJson(this);
}

/// `unsubscribed` — channels were removed from the session.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class UnsubscribedDto {
  /// Creates an unsubscribed payload.
  const UnsubscribedDto({required this.channels});

  /// Decodes an unsubscribed payload.
  factory UnsubscribedDto.fromJson(Map<String, dynamic> json) =>
      _$UnsubscribedDtoFromJson(json);

  /// Channel names that were removed.
  final List<String> channels;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$UnsubscribedDtoToJson(this);
}

/// `pong` — the reply whose arrival closes an RTT sample.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class PongDto {
  /// Creates a pong payload.
  const PongDto({
    required this.id,
    required this.clientTimeMs,
    required this.serverTimeMs,
  });

  /// Decodes a pong payload.
  factory PongDto.fromJson(Map<String, dynamic> json) =>
      _$PongDtoFromJson(json);

  /// Pulse id echoed from the client `ping`.
  final int id;

  /// The client time the server echoed back. Informational only.
  final int clientTimeMs;

  /// The server's own clock. Recorded for skew display, never used for RTT.
  final int serverTimeMs;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$PongDtoToJson(this);
}

/// `ping` — a server-side keepalive. Not used to measure RTT.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class PingDto {
  /// Creates a ping payload.
  const PingDto({required this.id});

  /// Decodes a ping payload.
  factory PingDto.fromJson(Map<String, dynamic> json) =>
      _$PingDtoFromJson(json);

  /// Keepalive id.
  final int id;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$PingDtoToJson(this);
}

/// `goodbye` — the server is closing the socket deliberately.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class GoodbyeDto {
  /// Creates a goodbye payload.
  const GoodbyeDto({required this.reason});

  /// Decodes a goodbye payload.
  factory GoodbyeDto.fromJson(Map<String, dynamic> json) =>
      _$GoodbyeDtoFromJson(json);

  /// Why the server is closing the socket.
  final String reason;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$GoodbyeDtoToJson(this);
}

/// `error` — a typed protocol error from the shared error vocabulary.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class ErrorDto {
  /// Creates an error payload.
  const ErrorDto({
    required this.code,
    required this.message,
    this.fatal = false,
    this.requestId,
  });

  /// Decodes an error payload. An absent `fatal` means the socket survives.
  factory ErrorDto.fromJson(Map<String, dynamic> json) =>
      _$ErrorDtoFromJson(json);

  /// Error code (`MALFORMED_FRAME`, `RATE_LIMITED`, …).
  final String code;

  /// Backend-supplied explanation.
  final String message;

  /// True when the server closed the socket after sending this frame.
  @JsonKey(defaultValue: false)
  final bool fatal;

  /// Request the error refers to, when applicable.
  final String? requestId;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$ErrorDtoToJson(this);
}
