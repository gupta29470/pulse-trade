import 'package:json_annotation/json_annotation.dart';

part 'market_status_dto.g.dart';

/// `market_status` — the engine's own lifecycle transition.
///
/// This is the backend's market state, not this device's data liveness: a
/// `LIVE` engine with a dropped socket still renders as stale locally.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class MarketStatusDto {
  /// Creates a market status payload.
  const MarketStatusDto({
    required this.state,
    required this.epoch,
    required this.message,
    required this.at,
  });

  /// Decodes a market status payload.
  factory MarketStatusDto.fromJson(Map<String, dynamic> json) =>
      _$MarketStatusDtoFromJson(json);

  /// Engine state (`STARTING`, `WARMING`, `LIVE`, `PAUSED`, …).
  final String state;

  /// Engine epoch this status applies to.
  final int epoch;

  /// Human-readable explanation supplied by the backend.
  final String message;

  /// Backend timestamp of the transition, RFC3339 with milliseconds, UTC.
  final String at;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$MarketStatusDtoToJson(this);
}
