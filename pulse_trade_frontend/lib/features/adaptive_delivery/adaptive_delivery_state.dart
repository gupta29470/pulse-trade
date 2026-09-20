import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';

/// What the backend is currently delivering to this session, verbatim.
///
/// Every field is a projection of the last `health` frame: the tier, the
/// override, the target and effective rates, the RTT/jitter the backend
/// received, and the backpressure counters. The client
/// computes none of them and estimates none of them — a client that guessed a
/// tier would disagree with the server exactly when the link is bad, which is
/// the one moment the disagreement matters.
final class AdaptiveDeliveryState extends Equatable {
  /// Creates a snapshot.
  const AdaptiveDeliveryState({
    required this.tier,
    required this.tierOverride,
    required this.reason,
    required this.targetRatePerSec,
    required this.effectiveRatePerSec,
    required this.rttMs,
    required this.jitterMs,
    required this.coalescedCount,
    required this.suppressedCount,
    required this.queuedMessages,
    required this.droppedMessages,
    required this.lastUpdatedAt,
  });

  /// The state before the first `health` frame.
  ///
  /// `FULL` with a zero target rate rather than a guessed nominal rate: the
  /// rates are the backend's to state, and showing `10/s` before it has spoken
  /// would be the client inventing a number. [reason] names that situation
  /// explicitly so the UI can render `awaiting first report` instead of a value.
  static const AdaptiveDeliveryState initial = AdaptiveDeliveryState(
    tier: DeliveryTier.full,
    tierOverride: DeliveryOverride.automatic,
    reason: 'AWAITING_FIRST_REPORT',
    targetRatePerSec: 0,
    effectiveRatePerSec: 0,
    rttMs: 0,
    jitterMs: 0,
    coalescedCount: 0,
    suppressedCount: 0,
    queuedMessages: 0,
    droppedMessages: 0,
    lastUpdatedAt: null,
  );

  /// The tier the backend has selected for this session.
  final DeliveryTier tier;

  /// The manual override in force, or [DeliveryOverride.automatic].
  final DeliveryOverride tierOverride;

  /// Machine-readable reason slug (`GOOD_HEALTH`, `HIGH_RTT`, `MISSING_REPORTS`).
  final String reason;

  /// Messages per second the tier targets.
  final double targetRatePerSec;

  /// Messages per second the backend actually delivered over its window.
  ///
  /// Legitimately lower than [targetRatePerSec] when the market is quiet; the
  /// backend never invents events to reach a rate.
  final double effectiveRatePerSec;

  /// RTT the backend last received from this client, in milliseconds.
  final double rttMs;

  /// Jitter the backend last received from this client, in milliseconds.
  final double jitterMs;

  /// Intermediate updates merged into a delivered message.
  final int coalescedCount;

  /// Updates superseded by coalescing and never sent.
  final int suppressedCount;

  /// Outbound queue depth on the session.
  final int queuedMessages;

  /// Messages dropped by backpressure.
  final int droppedMessages;

  /// When this snapshot was taken, or `null` for [initial].
  final DateTime? lastUpdatedAt;

  /// True when a human pinned the tier rather than the hysteresis machine.
  bool get isOverridden => tierOverride.isActive;

  /// [targetRatePerSec] as the whole number of messages per second a compact
  /// chip can show.
  int get tierRatePerSecondRounded => targetRatePerSec.round();

  /// Copies the snapshot with the given fields replaced.
  AdaptiveDeliveryState copyWith({
    DeliveryTier? tier,
    DeliveryOverride? tierOverride,
    String? reason,
    double? targetRatePerSec,
    double? effectiveRatePerSec,
    double? rttMs,
    double? jitterMs,
    int? coalescedCount,
    int? suppressedCount,
    int? queuedMessages,
    int? droppedMessages,
    DateTime? lastUpdatedAt,
  }) {
    return AdaptiveDeliveryState(
      tier: tier ?? this.tier,
      tierOverride: tierOverride ?? this.tierOverride,
      reason: reason ?? this.reason,
      targetRatePerSec: targetRatePerSec ?? this.targetRatePerSec,
      effectiveRatePerSec: effectiveRatePerSec ?? this.effectiveRatePerSec,
      rttMs: rttMs ?? this.rttMs,
      jitterMs: jitterMs ?? this.jitterMs,
      coalescedCount: coalescedCount ?? this.coalescedCount,
      suppressedCount: suppressedCount ?? this.suppressedCount,
      queuedMessages: queuedMessages ?? this.queuedMessages,
      droppedMessages: droppedMessages ?? this.droppedMessages,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    tier,
    tierOverride,
    reason,
    targetRatePerSec,
    effectiveRatePerSec,
    rttMs,
    jitterMs,
    coalescedCount,
    suppressedCount,
    queuedMessages,
    droppedMessages,
    lastUpdatedAt,
  ];

  @override
  String toString() =>
      'AdaptiveDeliveryState(${tier.wire}, '
      'override=${tierOverride.wire}, reason=$reason, '
      'target=${targetRatePerSec.toStringAsFixed(1)}/s, '
      'effective=${effectiveRatePerSec.toStringAsFixed(1)}/s)';
}
