import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/channel.dart';

/// One frame sent to the server.
///
/// Client frames are plain objects with the fields inline — there is no
/// `payload` wrapper in this direction. Modelling them as a sealed
/// hierarchy means a new message type cannot be sent without also implementing
/// its JSON form.
sealed class ClientMessage extends Equatable {
  /// Base constructor.
  const ClientMessage();

  /// The wire `type` value.
  String get type;

  /// The complete frame, ready to `jsonEncode`.
  Map<String, Object?> toJson();

  @override
  List<Object?> get props => <Object?>[type];
}

/// `hello` — identifies the client for logs and metrics.
final class HelloMessage extends ClientMessage {
  /// Creates a hello frame.
  const HelloMessage({
    required this.clientVersion,
    required this.platform,
    required this.deviceId,
  });

  /// App build version.
  final String clientVersion;

  /// `android` or `ios`.
  final String platform;

  /// Random per-install id. Never a hardware identifier.
  final String deviceId;

  @override
  String get type => 'hello';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'clientVersion': clientVersion,
    'platform': platform,
    'deviceId': deviceId,
  };

  @override
  List<Object?> get props => <Object?>[type, clientVersion, platform, deviceId];
}

/// `subscribe` — replaces the session subscription atomically.
final class SubscribeMessage extends ClientMessage {
  /// Creates a subscribe frame.
  const SubscribeMessage({
    required this.symbol,
    required this.interval,
    required this.channels,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Requested candle interval.
  final CandleInterval interval;

  /// Channels to receive.
  final Set<Channel> channels;

  @override
  String get type => 'subscribe';

  @override
  Map<String, Object?> toJson() {
    final List<Channel> ordered = channels.toList()
      ..sort((Channel a, Channel b) => a.index.compareTo(b.index));
    return <String, Object?>{
      'type': type,
      'symbol': symbol,
      'interval': interval.wire,
      'channels': <String>[for (final Channel channel in ordered) channel.wire],
    };
  }

  @override
  List<Object?> get props => <Object?>[type, symbol, interval, channels];
}

/// `unsubscribe` — removes channels from the current subscription.
final class UnsubscribeMessage extends ClientMessage {
  /// Creates an unsubscribe frame.
  const UnsubscribeMessage({required this.channels});

  /// Channels to remove.
  final Set<Channel> channels;

  @override
  String get type => 'unsubscribe';

  @override
  Map<String, Object?> toJson() {
    final List<Channel> ordered = channels.toList()
      ..sort((Channel a, Channel b) => a.index.compareTo(b.index));
    return <String, Object?>{
      'type': type,
      'channels': <String>[for (final Channel channel in ordered) channel.wire],
    };
  }

  @override
  List<Object?> get props => <Object?>[type, channels];
}

/// `set_interval` — re-subscribes to a different candle interval.
final class SetIntervalMessage extends ClientMessage {
  /// Creates a set-interval frame.
  const SetIntervalMessage({required this.interval});

  /// The requested interval.
  final CandleInterval interval;

  @override
  String get type => 'set_interval';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'interval': interval.wire,
  };

  @override
  List<Object?> get props => <Object?>[type, interval];
}

/// `ping` — the client-initiated RTT pulse.
final class PingMessage extends ClientMessage {
  /// Creates a ping frame.
  const PingMessage({required this.id, required this.clientTimeMs});

  /// Monotonic pulse id.
  final int id;

  /// Monotonic send time, echoed back purely as a correlation aid.
  final int clientTimeMs;

  @override
  String get type => 'ping';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'id': id,
    'clientTimeMs': clientTimeMs,
  };

  @override
  List<Object?> get props => <Object?>[type, id, clientTimeMs];
}

/// `latency_report` — the client's measured transport health.
///
/// This is the only input to the backend's tier decision, which is why the
/// client does the measuring: it owns the round trip.
final class LatencyReportMessage extends ClientMessage {
  /// Creates a latency report frame.
  const LatencyReportMessage({
    required this.rttMs,
    required this.jitterMs,
    required this.samples,
    required this.clientTimeMs,
    required this.window,
    required this.missedPongs,
    required this.cappedSamples,
  });

  /// Rolling mean RTT.
  final double rttMs;

  /// Rolling mean absolute consecutive difference.
  final double jitterMs;

  /// Samples in the window.
  final int samples;

  /// Wall-clock send time, for correlation only.
  final int clientTimeMs;

  /// The window description, e.g. `last10`.
  final String window;

  /// Pings that never received a pong inside the timeout.
  final int missedPongs;

  /// Samples capped as outliers before entering the window.
  final int cappedSamples;

  @override
  String get type => 'latency_report';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'rttMs': rttMs,
    'jitterMs': jitterMs,
    'samples': samples,
    'clientTimeMs': clientTimeMs,
    'window': window,
    'missedPongs': missedPongs,
    'cappedSamples': cappedSamples,
  };

  @override
  List<Object?> get props => <Object?>[
    type,
    rttMs,
    jitterMs,
    samples,
    clientTimeMs,
    window,
    missedPongs,
    cappedSamples,
  ];
}

/// `tier_override` — pins the delivery tier for this session (debug builds).
final class TierOverrideMessage extends ClientMessage {
  /// Creates an override frame.
  const TierOverrideMessage({required this.tier});

  /// `AUTO`, `FULL`, `DEGRADED` or `MINIMAL`.
  final String tier;

  @override
  String get type => 'tier_override';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'tier': tier,
  };

  @override
  List<Object?> get props => <Object?>[type, tier];
}
