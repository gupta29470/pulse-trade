import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_health.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/messages/delivery_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/features/adaptive_delivery/adaptive_delivery_state.dart';

/// A `health` frame was projected into the state.
const String _msgHealthProjected = 'health_projected';

/// A tier override frame was sent, or failed to send.
const String _msgOverrideSent = 'tier_override_sent';

/// The tier the backend just reported, in a compact projection of `health`.
///
/// **It never decides the tier.** The backend owns the hysteresis machine, the
/// missing-report fallback and the target rate; this cubit
/// filters `HealthMessage` frames out of the stream and republishes them as an
/// immutable snapshot, so the UI cannot drift from the server's view and cannot
/// invent a rate. The only thing it *sends* is the user's own
/// override request, which the backend may accept, reject in a release build,
/// or replace on the next `health` frame — which is why no optimistic state is
/// emitted for it.
final class AdaptiveDeliveryCubit extends Cubit<AdaptiveDeliveryState> {
  /// Creates the cubit and starts projecting `health` frames.
  ///
  /// [clock] stamps a snapshot when a frame arrives without a local receipt
  /// time, so the readout can still be aged.
  AdaptiveDeliveryCubit({required MarketStreamRepository stream, Clock? clock})
    : _stream = stream,
      _clock = clock ?? SystemClock(),
      super(AdaptiveDeliveryState.initial) {
    _subscription = stream.messages.listen(
      _onMessage,
      onError: (Object error, StackTrace stackTrace) {
        // The repository promises never to error on this stream; a listener that
        // threw anyway must not tear the cubit down.
        AppLogger.error(
          _msgHealthProjected,
          fields: <String, Object?>{
            LogFields.component: LogComponents.tier,
            LogFields.reason: 'stream_error',
          },
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  final MarketStreamRepository _stream;
  final Clock _clock;

  StreamSubscription<ServerMessage>? _subscription;

  /// Asks the backend to pin this session's tier.
  ///
  /// Sends `tier_override{tier}`. Nothing is emitted on success: the
  /// authoritative answer is the next `health` frame, and showing the pinned
  /// tier before the backend agrees would be the client deciding a tier after
  /// all. A send failure is logged and swallowed, because a cubit that threw
  /// would surface as a widget-tree exception.
  Future<void> applyTierOverride(DeliveryOverride override) =>
      _sendOverride(override, reason: 'apply');

  /// Asks the backend to hand the tier back to its hysteresis machine.
  Future<void> resetToAutomatic() =>
      _sendOverride(DeliveryOverride.automatic, reason: 'reset');

  Future<void> _sendOverride(
    DeliveryOverride override, {
    required String reason,
  }) async {
    if (isClosed) return;
    try {
      await _stream.send(TierOverrideMessage(tier: override.wire));
      AppLogger.info(
        _msgOverrideSent,
        fields: <String, Object?>{
          LogFields.component: LogComponents.tier,
          LogFields.override: override.wire,
          LogFields.reason: reason,
        },
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        _msgOverrideSent,
        fields: <String, Object?>{
          LogFields.component: LogComponents.tier,
          LogFields.reason: 'send_failed',
        },
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _onMessage(ServerMessage message) {
    if (isClosed) return;
    // This cubit is a projection of exactly one frame type; everything else is
    // another cubit's or bloc's business.
    if (message is! HealthMessage) return;

    final DeliveryHealth health = message.health;
    // Logged before the emit, so `fromTier` is genuinely the previous tier.
    AppLogger.info(
      _msgHealthProjected,
      fields: <String, Object?>{
        LogFields.component: LogComponents.tier,
        LogFields.tier: health.tier.wire,
        LogFields.fromTier: state.tier.wire,
        LogFields.reason: health.reason,
        LogFields.rttMs: health.rttMs,
        LogFields.jitterMs: health.jitterMs,
        LogFields.targetRate: health.targetRatePerSec,
        LogFields.effectiveRate: health.effectiveRatePerSec,
      },
    );

    emit(
      AdaptiveDeliveryState(
        tier: health.tier,
        tierOverride: health.tierOverride,
        reason: health.reason,
        targetRatePerSec: health.targetRatePerSec,
        effectiveRatePerSec: health.effectiveRatePerSec,
        rttMs: health.rttMs,
        jitterMs: health.jitterMs,
        coalescedCount: health.coalescedCount,
        suppressedCount: health.suppressedCount,
        queuedMessages: health.queuedMessages,
        droppedMessages: health.droppedMessages,
        lastUpdatedAt: health.receivedAt ?? _clock.now(),
      ),
    );
  }

  /// Cancels the health subscription, then closes the cubit.
  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    return super.close();
  }
}
