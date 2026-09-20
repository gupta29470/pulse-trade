import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/channel.dart';
import 'package:pulse_trade_frontend/domain/entities/market_status.dart';

/// The threshold table the backend publishes in `welcome`.
///
/// Shipped so the app can explain *why* a tier changed without hardcoding a
/// second copy of the backend's configuration.
final class TierThresholds extends Equatable {
  /// Creates a thresholds table.
  const TierThresholds({
    required this.fullMaxRttMs,
    required this.fullMaxJitterMs,
    required this.minimalMinRttMs,
    required this.minimalMinJitterMs,
    required this.degradeStreak,
    required this.recoverStreak,
    required this.reportHoldMs,
    required this.reportDegradeMs,
  });

  /// A permissive default used before `welcome` arrives.
  static const TierThresholds unknown = TierThresholds(
    fullMaxRttMs: 150,
    fullMaxJitterMs: 50,
    minimalMinRttMs: 500,
    minimalMinJitterMs: 150,
    degradeStreak: 3,
    recoverStreak: 5,
    reportHoldMs: 5000,
    reportDegradeMs: 10000,
  );

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

  @override
  List<Object?> get props => <Object?>[
    fullMaxRttMs,
    fullMaxJitterMs,
    minimalMinRttMs,
    minimalMinJitterMs,
    degradeStreak,
    recoverStreak,
    reportHoldMs,
    reportDegradeMs,
  ];
}

/// One decoded server frame.
///
/// The envelope header is carried on every message so the diagnostics screen can
/// show frame ordering without re-reading the socket, and so a dropped frame is
/// detectable from the `seq` gap.
abstract class ServerMessage extends Equatable {
  /// Base constructor taking the envelope header fields.
  const ServerMessage({
    required this.version,
    required this.serverTime,
    required this.seq,
  });

  /// Protocol version on the envelope.
  final int version;

  /// Server time on the envelope, UTC.
  final DateTime serverTime;

  /// Per-connection frame sequence number.
  final int seq;

  /// The wire `type` string, used for logging.
  String get type;

  @override
  List<Object?> get props => <Object?>[version, serverTime, seq];
}

/// `welcome` — the first frame after connecting.
final class WelcomeMessage extends ServerMessage {
  /// Creates a welcome message.
  const WelcomeMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.sessionId,
    required this.shortId,
    required this.symbol,
    required this.epoch,
    required this.engineState,
    required this.protocolMin,
    required this.protocolMax,
    required this.intervals,
    required this.channels,
    required this.heartbeatMs,
    required this.tierRatesPerSec,
    required this.tierThresholds,
  });

  /// Full session id.
  final String sessionId;

  /// Six-character display id.
  final String shortId;

  /// The symbol this session is bound to.
  final String symbol;

  /// Current engine epoch.
  final int epoch;

  /// Engine state at connect time.
  final MarketEngineState engineState;

  /// Lowest protocol version the server speaks.
  final int protocolMin;

  /// Highest protocol version the server speaks.
  final int protocolMax;

  /// Every interval the server supports.
  final List<String> intervals;

  /// Every channel the server supports.
  final List<String> channels;

  /// Server heartbeat cadence.
  final int heartbeatMs;

  /// Target rate per tier wire name.
  final Map<String, double> tierRatesPerSec;

  /// The backend's tier thresholds.
  final TierThresholds tierThresholds;

  /// Every supported channel, as domain values. Unknown names are dropped
  /// rather than invented, so a newer server cannot crash an older client.
  List<Channel> get supportedChannels {
    final List<Channel> out = <Channel>[];
    for (final String name in channels) {
      final Channel? channel = Channel.tryParse(name);
      if (channel != null) out.add(channel);
    }
    return out;
  }

  /// Every supported interval, as domain values.
  List<CandleInterval> get supportedIntervals {
    final List<CandleInterval> out = <CandleInterval>[];
    for (final String name in intervals) {
      final CandleInterval? interval = CandleInterval.tryParse(name);
      if (interval != null) out.add(interval);
    }
    return out;
  }

  @override
  String get type => 'welcome';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    sessionId,
    shortId,
    symbol,
    epoch,
    engineState,
    protocolMin,
    protocolMax,
    intervals,
    channels,
    heartbeatMs,
    tierRatesPerSec,
    tierThresholds,
  ];
}

/// `subscribed` — the session's subscription was replaced.
final class SubscribedMessage extends ServerMessage {
  /// Creates a subscribed acknowledgement.
  const SubscribedMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.symbol,
    required this.interval,
    required this.channels,
    required this.epoch,
  });

  /// Subscribed symbol.
  final String symbol;

  /// Subscribed interval.
  final CandleInterval interval;

  /// Subscribed channels.
  final List<Channel> channels;

  /// Engine epoch of the subscription.
  final int epoch;

  @override
  String get type => 'subscribed';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    symbol,
    interval,
    channels,
    epoch,
  ];
}

/// `unsubscribed` — channels were removed.
final class UnsubscribedMessage extends ServerMessage {
  /// Creates an unsubscribed acknowledgement.
  const UnsubscribedMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.channels,
  });

  /// Channels that were removed.
  final List<Channel> channels;

  @override
  String get type => 'unsubscribed';

  @override
  List<Object?> get props => <Object?>[...super.props, channels];
}

/// `pong` — the reply whose arrival closes an RTT sample.
final class PongMessage extends ServerMessage {
  /// Creates a pong.
  const PongMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.id,
    required this.clientTimeMs,
    required this.serverTimeMs,
  });

  /// Pulse id echoed from the `ping`.
  final int id;

  /// The client time the server echoed back. Informational only.
  final int clientTimeMs;

  /// The server's own clock. Recorded for skew display, never used for RTT.
  final int serverTimeMs;

  @override
  String get type => 'pong';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    id,
    clientTimeMs,
    serverTimeMs,
  ];
}

/// `ping` — a server keepalive. Not used to measure RTT.
final class PingMessage extends ServerMessage {
  /// Creates a server ping.
  const PingMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.id,
  });

  /// Keepalive id.
  final int id;

  @override
  String get type => 'ping';

  @override
  List<Object?> get props => <Object?>[...super.props, id];
}

/// `market_status` — the engine's own lifecycle transition.
final class MarketStatusMessage extends ServerMessage {
  /// Creates a market status message.
  const MarketStatusMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.status,
  });

  /// The engine status.
  final MarketStatus status;

  @override
  String get type => 'market_status';

  @override
  List<Object?> get props => <Object?>[...super.props, status];
}

/// `error` — a typed protocol error.
final class ErrorMessage extends ServerMessage {
  /// Creates an error message.
  const ErrorMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.code,
    required this.message,
    required this.fatal,
    this.requestId,
  });

  /// Error code from the shared vocabulary (`protocol/codes.go`).
  final String code;

  /// Backend-supplied explanation.
  final String message;

  /// True when the server closed the socket after sending this.
  final bool fatal;

  /// Request the error refers to, when applicable.
  final String? requestId;

  @override
  String get type => 'error';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    code,
    message,
    fatal,
    requestId,
  ];
}

/// `goodbye` — the server is closing deliberately.
final class GoodbyeMessage extends ServerMessage {
  /// Creates a goodbye message.
  const GoodbyeMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.reason,
  });

  /// Why the server is closing the socket.
  final String reason;

  @override
  String get type => 'goodbye';

  @override
  List<Object?> get props => <Object?>[...super.props, reason];
}
