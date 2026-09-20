/// A subscription channel.
///
/// The `wire` values are the exact names the backend validates against
/// `protocol.Channels`; anything else is a `400 UNSUPPORTED_CHANNEL`.
/// Modelled as an enum so an unknown channel cannot be sent by accident.
enum Channel {
  /// L2 order-book snapshot and delta ranges.
  orderBook('order_book'),

  /// Individual trades and compacted trade batches.
  trades('trades'),

  /// Active and closed candles.
  candles('candles'),

  /// Rolling 24h summary.
  summary('summary'),

  /// Backend-reported delivery health.
  health('health');

  const Channel(this.wire);

  /// The exact channel name the backend validates.
  final String wire;

  /// Parses a wire channel name, returning `null` for anything unknown so a
  /// caller can reject the frame rather than invent a channel.
  static Channel? tryParse(String value) {
    for (final Channel channel in Channel.values) {
      if (channel.wire == value) return channel;
    }
    return null;
  }

  /// The default subscription applied when the caller names no channels.
  static const Set<Channel> defaults = <Channel>{
    Channel.orderBook,
    Channel.trades,
    Channel.candles,
    Channel.summary,
    Channel.health,
  };
}
