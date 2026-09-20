import 'package:equatable/equatable.dart';

/// The market engine's own lifecycle state, as reported by the backend.
///
/// These are the backend's `market.State` values. They are *not* the client's
/// market-data liveness: a `LIVE` engine with a dropped socket still renders,
/// stale on this device.
enum MarketEngineState {
  /// Engine constructed, not yet generating.
  starting('STARTING'),

  /// Replay/warmup in progress; history is being rebuilt.
  warming('WARMING'),

  /// Generating trades and book mutations.
  live('LIVE'),

  /// Paused by a debug control; sockets stay open and values freeze.
  paused('PAUSED'),

  /// An invariant violation was recorded; generation continues loudly.
  degraded('DEGRADED'),

  /// Engine stopped.
  stopped('STOPPED'),

  /// A state this build does not know. Rendered verbatim rather than guessed.
  unknown('UNKNOWN');

  const MarketEngineState(this.wire);

  /// The wire value.
  final String wire;

  /// Parses a wire state, falling back to [unknown].
  static MarketEngineState parse(String value) {
    for (final MarketEngineState state in MarketEngineState.values) {
      if (state.wire == value) return state;
    }
    return MarketEngineState.unknown;
  }
}

/// A `market_status` frame: whether the engine is trading, and why not.
final class MarketStatus extends Equatable {
  /// Creates a status.
  const MarketStatus({
    required this.state,
    required this.epoch,
    required this.message,
    required this.at,
    this.receivedAt,
  });

  /// The engine state.
  final MarketEngineState state;

  /// Engine epoch this status applies to.
  final int epoch;

  /// Human-readable explanation supplied by the backend.
  final String message;

  /// Backend timestamp of the transition.
  final DateTime at;

  /// Local receipt time, used to age the `InlineNotice`.
  final DateTime? receivedAt;

  /// True when the engine is frozen rather than unreachable. The two render
  /// differently: `PAUSED` is honest data, `STALE` is missing data.
  bool get isPaused => state == MarketEngineState.paused;

  @override
  List<Object?> get props => <Object?>[state, epoch, message, at, receivedAt];

  @override
  String toString() => 'MarketStatus(${state.wire}, epoch=$epoch, $message)';
}
