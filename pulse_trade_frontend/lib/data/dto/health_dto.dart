import 'package:json_annotation/json_annotation.dart';

part 'health_dto.g.dart';

/// `health` — the backend's report of how it is delivering to this session.
///
/// This frame is the app's single source of truth for tier, override, target
/// rate and effective rate. The client renders these numbers; it never infers a
/// tier.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class HealthDto {
  /// Creates a health payload.
  const HealthDto({
    required this.tier,
    required this.tierOverride,
    required this.reason,
    required this.targetRatePerSec,
    required this.effectiveRatePerSec,
    required this.rttMs,
    required this.jitterMs,
    required this.lastReportAgeMs,
    required this.uptimeMs,
    required this.bookEpoch,
    required this.bookUpdateId,
    required this.coalescedCount,
    required this.suppressedCount,
    required this.queuedMessages,
    required this.droppedMessages,
  });

  /// Decodes a health payload.
  factory HealthDto.fromJson(Map<String, dynamic> json) =>
      _$HealthDtoFromJson(json);

  /// Tier the backend has selected (`FULL`, `DEGRADED`, `MINIMAL`).
  final String tier;

  /// Manual override in force (`AUTO`, `FULL`, …).
  ///
  /// The wire key is exactly `override`; the Dart field is named
  /// `tierOverride` to match the `DeliveryHealth` entity, because `dart:core`
  /// already exports a top-level `override` annotation constant.
  @JsonKey(name: 'override')
  final String tierOverride;

  /// Machine-readable reason slug (`GOOD_HEALTH`, `HIGH_RTT`, …).
  final String reason;

  /// Messages per second the tier targets.
  final double targetRatePerSec;

  /// Messages per second actually delivered.
  final double effectiveRatePerSec;

  /// The RTT the backend last received from this client.
  final double rttMs;

  /// The jitter the backend last received from this client.
  final double jitterMs;

  /// Age of the most recent latency report.
  final int lastReportAgeMs;

  /// Session uptime in milliseconds.
  final int uptimeMs;

  /// Engine epoch the session is bound to.
  final int bookEpoch;

  /// Engine book update id at the time of the frame.
  final int bookUpdateId;

  /// Messages merged into a coalesced delivery.
  final int coalescedCount;

  /// Messages suppressed by the tier's coalescing.
  final int suppressedCount;

  /// Outbound queue depth.
  final int queuedMessages;

  /// Messages dropped by backpressure.
  final int droppedMessages;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$HealthDtoToJson(this);
}
