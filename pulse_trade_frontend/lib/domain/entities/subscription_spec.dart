import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/channel.dart';

/// What a session is subscribed to.
///
/// Passed to `MarketWebSocketClient.subscribe` so the transport never has to
/// know about channel names or interval ids as loose strings.
final class SubscriptionSpec extends Equatable {
  /// Creates a subscription request.
  const SubscriptionSpec({
    required this.symbol,
    required this.interval,
    this.channels = Channel.defaults,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Candle interval for the session.
  final CandleInterval interval;

  /// Channels to receive.
  final Set<Channel> channels;

  /// The wire form of the channel set, in a stable order.
  List<String> get wireChannels {
    final List<Channel> ordered = channels.toList()
      ..sort((Channel a, Channel b) => a.index.compareTo(b.index));
    return <String>[for (final Channel channel in ordered) channel.wire];
  }

  /// Copy with different channels, used when only the feed set changes.
  SubscriptionSpec withChannels(Set<Channel> channels) =>
      SubscriptionSpec(symbol: symbol, interval: interval, channels: channels);

  @override
  List<Object?> get props => <Object?>[symbol, interval, channels];

  @override
  String toString() =>
      'SubscriptionSpec($symbol, ${interval.wire}, ${wireChannels.join('+')})';
}
