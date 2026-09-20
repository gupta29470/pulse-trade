import 'package:pulse_trade_frontend/data/dto/health_dto.dart';
import 'package:pulse_trade_frontend/data/dto/market_status_dto.dart';
import 'package:pulse_trade_frontend/data/dto/session_frames_dto.dart';
import 'package:pulse_trade_frontend/data/dto/welcome_dto.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/channel.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_health.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';
import 'package:pulse_trade_frontend/domain/entities/market_status.dart';
import 'package:pulse_trade_frontend/domain/messages/delivery_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';

/// Maps the welcome payload's threshold table onto the domain table.
extension TierThresholdsDtoMapper on TierThresholdsDto {
  /// The domain threshold table.
  TierThresholds toEntity() => TierThresholds(
    fullMaxRttMs: fullMaxRttMs,
    fullMaxJitterMs: fullMaxJitterMs,
    minimalMinRttMs: minimalMinRttMs,
    minimalMinJitterMs: minimalMinJitterMs,
    degradeStreak: degradeStreak,
    recoverStreak: recoverStreak,
    reportHoldMs: reportHoldMs,
    reportDegradeMs: reportDegradeMs,
  );
}

/// Maps session-lifecycle frames onto their domain messages.
///
/// Every mapper takes the envelope header, because a [ServerMessage] carries
/// `version`, `serverTime` and `seq` from the envelope rather than from its
/// payload.
extension WelcomeDtoMapper on WelcomeDto {
  /// The domain welcome message.
  WelcomeMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
  }) => WelcomeMessage(
    version: version,
    serverTime: serverTime,
    seq: seq,
    sessionId: sessionId,
    shortId: shortId,
    symbol: symbol,
    epoch: epoch,
    engineState: MarketEngineState.parse(engineState),
    protocolMin: protocolMin,
    protocolMax: protocolMax,
    intervals: intervals,
    channels: channels,
    heartbeatMs: heartbeatMs,
    tierRatesPerSec: tierRatesPerSec,
    tierThresholds: tierThresholds.toEntity(),
  );
}

/// Maps a `subscribed` acknowledgement onto its domain message.
extension SubscribedDtoMapper on SubscribedDto {
  /// The domain acknowledgement.
  ///
  /// An unknown interval id is a parse failure; unknown channel names are
  /// dropped rather than invented, so a newer server cannot crash an older
  /// client.
  SubscribedMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
  }) {
    final CandleInterval? parsedInterval = CandleInterval.tryParse(interval);
    if (parsedInterval == null) {
      throw FormatException('unknown candle interval', interval);
    }
    return SubscribedMessage(
      version: version,
      serverTime: serverTime,
      seq: seq,
      symbol: symbol,
      interval: parsedInterval,
      channels: _channelsFrom(channels),
      epoch: epoch,
    );
  }
}

/// Maps an `unsubscribed` acknowledgement onto its domain message.
extension UnsubscribedDtoMapper on UnsubscribedDto {
  /// The domain acknowledgement, with unknown channel names dropped.
  UnsubscribedMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
  }) => UnsubscribedMessage(
    version: version,
    serverTime: serverTime,
    seq: seq,
    channels: _channelsFrom(channels),
  );
}

/// Maps RTT and keepalive frames onto their domain messages.
extension PongDtoMapper on PongDto {
  /// The domain pong.
  PongMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
  }) => PongMessage(
    version: version,
    serverTime: serverTime,
    seq: seq,
    id: id,
    clientTimeMs: clientTimeMs,
    serverTimeMs: serverTimeMs,
  );
}

/// Maps a server `ping` onto its domain message.
extension PingDtoMapper on PingDto {
  /// The domain ping.
  PingMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
  }) => PingMessage(version: version, serverTime: serverTime, seq: seq, id: id);
}

/// Maps a `market_status` frame onto its domain message.
extension MarketStatusDtoMapper on MarketStatusDto {
  /// The domain status message. [receivedAt] is the local clock reading used to
  /// age the notice; `at` is the backend's own timestamp.
  MarketStatusMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
    required DateTime receivedAt,
  }) => MarketStatusMessage(
    version: version,
    serverTime: serverTime,
    seq: seq,
    status: MarketStatus(
      state: MarketEngineState.parse(state),
      epoch: epoch,
      message: message,
      at: DateTime.parse(at).toUtc(),
      receivedAt: receivedAt,
    ),
  );
}

/// Maps a typed protocol `error` frame onto its domain message.
extension ErrorDtoMapper on ErrorDto {
  /// The domain error message.
  ErrorMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
  }) => ErrorMessage(
    version: version,
    serverTime: serverTime,
    seq: seq,
    code: code,
    message: message,
    fatal: fatal,
    requestId: requestId,
  );
}

/// Maps a `goodbye` frame onto its domain message.
extension GoodbyeDtoMapper on GoodbyeDto {
  /// The domain goodbye message.
  GoodbyeMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
  }) => GoodbyeMessage(
    version: version,
    serverTime: serverTime,
    seq: seq,
    reason: reason,
  );
}

/// Maps a `health` frame onto its domain message.
///
/// The tier and the override are parsed leniently: an unrecognised value falls
/// back to FULL / AUTOMATIC so a readout is still rendered, because the app
/// displays what the backend reports and never gates on its own vocabulary.
extension HealthDtoMapper on HealthDto {
  /// The domain health message. [receivedAt] is the local clock reading.
  HealthMessage toEntity({
    required int version,
    required DateTime serverTime,
    required int seq,
    required DateTime receivedAt,
  }) => HealthMessage(
    version: version,
    serverTime: serverTime,
    seq: seq,
    health: DeliveryHealth(
      tier: DeliveryTier.tryParse(tier) ?? DeliveryTier.full,
      tierOverride:
          DeliveryOverride.tryParse(tierOverride) ?? DeliveryOverride.automatic,
      reason: reason,
      targetRatePerSec: targetRatePerSec,
      effectiveRatePerSec: effectiveRatePerSec,
      rttMs: rttMs,
      jitterMs: jitterMs,
      lastReportAgeMs: lastReportAgeMs,
      uptimeMs: uptimeMs,
      bookEpoch: bookEpoch,
      bookUpdateId: bookUpdateId,
      coalescedCount: coalescedCount,
      suppressedCount: suppressedCount,
      queuedMessages: queuedMessages,
      droppedMessages: droppedMessages,
      receivedAt: receivedAt,
    ),
  );
}

/// Converts wire channel names, skipping any this build does not know.
List<Channel> _channelsFrom(List<String> wire) {
  final List<Channel> channels = <Channel>[];
  for (final String name in wire) {
    final Channel? channel = Channel.tryParse(name);
    if (channel != null) channels.add(channel);
  }
  return channels;
}
