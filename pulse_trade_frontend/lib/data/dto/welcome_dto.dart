import 'package:json_annotation/json_annotation.dart';

part 'welcome_dto.g.dart';

/// `welcome` — the first frame a client receives after connecting.
///
/// It carries the engine epoch, the channel and interval vocabulary, and the
/// backend's own tier thresholds, so the app never hardcodes a second copy of
/// the delivery configuration.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class WelcomeDto {
  /// Creates a welcome payload.
  const WelcomeDto({
    required this.sessionId,
    required this.shortId,
    required this.symbol,
    required this.epoch,
    required this.engineState,
    required this.serverTime,
    required this.protocolMin,
    required this.protocolMax,
    required this.intervals,
    required this.channels,
    required this.heartbeatMs,
    required this.tierRatesPerSec,
    required this.tierThresholds,
  });

  /// Decodes a welcome payload.
  factory WelcomeDto.fromJson(Map<String, dynamic> json) =>
      _$WelcomeDtoFromJson(json);

  /// Full session id (`sess_…`).
  final String sessionId;

  /// Six-character display id shown on the diagnostics screen.
  final String shortId;

  /// Canonical symbol id this session is bound to.
  final String symbol;

  /// Current engine epoch.
  final int epoch;

  /// Engine state at connect time (`STARTING`, `LIVE`, `PAUSED`, …).
  final String engineState;

  /// Server time at connect, RFC3339 with milliseconds, UTC.
  final String serverTime;

  /// Lowest protocol version the server speaks.
  final int protocolMin;

  /// Highest protocol version the server speaks.
  final int protocolMax;

  /// Every interval id the server supports (`1m`, `5m`, … `1D`).
  final List<String> intervals;

  /// Every channel name the server supports (`order_book`, `trades`, …).
  final List<String> channels;

  /// Server heartbeat cadence in milliseconds.
  final int heartbeatMs;

  /// Target messages per second, keyed by tier wire name (`FULL`, …).
  final Map<String, double> tierRatesPerSec;

  /// The backend's tier threshold table.
  final TierThresholdsDto tierThresholds;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$WelcomeDtoToJson(this);
}

/// The delivery thresholds the backend actually applies.
///
/// Shipped on `welcome` so the app can explain *why* a tier changed without
/// guessing at the hysteresis configuration.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class TierThresholdsDto {
  /// Creates a threshold table.
  const TierThresholdsDto({
    required this.fullMaxRttMs,
    required this.fullMaxJitterMs,
    required this.minimalMinRttMs,
    required this.minimalMinJitterMs,
    required this.degradeStreak,
    required this.recoverStreak,
    required this.reportHoldMs,
    required this.reportDegradeMs,
  });

  /// Decodes a threshold table.
  factory TierThresholdsDto.fromJson(Map<String, dynamic> json) =>
      _$TierThresholdsDtoFromJson(json);

  /// RTT above which the session leaves FULL.
  final double fullMaxRttMs;

  /// Jitter above which the session leaves FULL.
  final double fullMaxJitterMs;

  /// RTT above which the session enters MINIMAL.
  final double minimalMinRttMs;

  /// Jitter above which the session enters MINIMAL.
  final double minimalMinJitterMs;

  /// Consecutive bad reports required to degrade.
  final int degradeStreak;

  /// Consecutive good reports required to recover.
  final int recoverStreak;

  /// Age at which a health report is considered stale.
  final int reportHoldMs;

  /// Age at which the missing-report fallback degrades a tier.
  final int reportDegradeMs;

  /// Encodes this threshold table.
  Map<String, dynamic> toJson() => _$TierThresholdsDtoToJson(this);
}
