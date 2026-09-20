import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';

/// The backend's own report of how it is delivering to this session.
///
/// This is the `health` frame verbatim. The app renders these numbers and never
/// infers a tier, because a client that guessed would disagree with the server
/// under throttling: the backend reports the tier it has
/// chosen and the rate it is achieving, and the app renders both.
final class DeliveryHealth extends Equatable {
  /// Creates a health report.
  const DeliveryHealth({
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
    required this.receivedAt,
  });

  /// An unknown-health placeholder used before the first `health` frame.
  static const DeliveryHealth unknown = DeliveryHealth(
    tier: DeliveryTier.full,
    tierOverride: DeliveryOverride.automatic,
    reason: 'AWAITING_FIRST_REPORT',
    targetRatePerSec: 0,
    effectiveRatePerSec: 0,
    rttMs: 0,
    jitterMs: 0,
    lastReportAgeMs: 0,
    uptimeMs: 0,
    bookEpoch: 0,
    bookUpdateId: 0,
    coalescedCount: 0,
    suppressedCount: 0,
    queuedMessages: 0,
    droppedMessages: 0,
    receivedAt: null,
  );

  /// The tier the backend has selected.
  final DeliveryTier tier;

  /// Manual override in force, or [DeliveryOverride.automatic].
  final DeliveryOverride tierOverride;

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

  /// Session uptime.
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

  /// Local receipt time, used to age the readout. `null` for [unknown].
  final DateTime? receivedAt;

  /// True when a human pinned the tier.
  bool get isOverridden => tierOverride.isActive;

  @override
  List<Object?> get props => <Object?>[
    tier,
    tierOverride,
    reason,
    targetRatePerSec,
    effectiveRatePerSec,
    rttMs,
    jitterMs,
    lastReportAgeMs,
    uptimeMs,
    bookEpoch,
    bookUpdateId,
    coalescedCount,
    suppressedCount,
    queuedMessages,
    droppedMessages,
    receivedAt,
  ];

  @override
  String toString() =>
      'DeliveryHealth(${tier.wire}, reason=$reason, '
      'target=${targetRatePerSec.toStringAsFixed(1)}/s, '
      'effective=${effectiveRatePerSec.toStringAsFixed(1)}/s, '
      'rtt=${rttMs.toStringAsFixed(1)}ms)';
}
