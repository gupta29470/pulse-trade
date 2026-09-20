import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';

/// `order_book_snapshot` — a full book image.
final class OrderBookSnapshotMessage extends ServerMessage {
  /// Creates a snapshot message.
  const OrderBookSnapshotMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.snapshot,
  });

  /// The book image.
  final OrderBookSnapshot snapshot;

  @override
  String get type => 'order_book_snapshot';

  @override
  List<Object?> get props => <Object?>[...super.props, snapshot];
}

/// `order_book_delta` — one contiguous range of engine update ids.
///
/// The range is what makes per-tier coalescing safe: continuity is provable.
/// `firstUpdateId <= applied + 1 <= lastUpdateId` even when several engine
/// updates were merged into one frame.
final class OrderBookDeltaMessage extends ServerMessage {
  /// Creates a delta message.
  const OrderBookDeltaMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.symbol,
    required this.epoch,
    required this.firstUpdateId,
    required this.lastUpdateId,
    required this.bids,
    required this.asks,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Engine epoch the range belongs to.
  final int epoch;

  /// First engine update id covered.
  final int firstUpdateId;

  /// Last engine update id covered.
  final int lastUpdateId;

  /// Absolute bid levels in the range; zero quantity means delete.
  final List<OrderBookLevel> bids;

  /// Absolute ask levels in the range.
  final List<OrderBookLevel> asks;

  /// Number of engine updates the range covers.
  int get rangeLength => lastUpdateId - firstUpdateId + 1;

  @override
  String get type => 'order_book_delta';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    symbol,
    epoch,
    firstUpdateId,
    lastUpdateId,
    bids,
    asks,
  ];
}

/// `trade` — one canonical execution.
final class TradeMessage extends ServerMessage {
  /// Creates a trade message.
  const TradeMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.trade,
  });

  /// The execution.
  final Trade trade;

  @override
  String get type => 'trade';

  @override
  List<Object?> get props => <Object?>[...super.props, trade];
}

/// `trade_batch` — compacted trades for the DEGRADED and MINIMAL tiers.
final class TradeBatchMessage extends ServerMessage {
  /// Creates a trade batch message.
  const TradeBatchMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.symbol,
    required this.trades,
    required this.compacted,
    required this.omittedCount,
  });

  /// Canonical symbol id.
  final String symbol;

  /// The trades that survived compaction, oldest first.
  final List<Trade> trades;

  /// Whether any intermediate trade was omitted.
  final bool compacted;

  /// How many were omitted. Shown in the UI rather than hidden.
  final int omittedCount;

  @override
  String get type => 'trade_batch';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    symbol,
    trades,
    compacted,
    omittedCount,
  ];
}

/// `candle_update` — the complete active candle.
///
/// The whole candle is sent rather than a diff, so a coalesced or missed
/// intermediate update cannot leave the client with a partial bucket.
final class CandleUpdateMessage extends ServerMessage {
  /// Creates a candle update message.
  const CandleUpdateMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.symbol,
    required this.interval,
    required this.candle,
    required this.sourceSequence,
    required this.active,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Bucket length.
  final CandleInterval interval;

  /// The complete bucket state.
  final Candle candle;

  /// Last trade id folded into the bucket.
  final int sourceSequence;

  /// False when the bucket has already closed.
  final bool active;

  @override
  String get type => 'candle_update';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    symbol,
    interval,
    candle,
    sourceSequence,
    active,
  ];
}

/// `candle_closed` — the immutable final bucket.
final class CandleClosedMessage extends ServerMessage {
  /// Creates a candle closed message.
  const CandleClosedMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.symbol,
    required this.interval,
    required this.candle,
    required this.epoch,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Bucket length.
  final CandleInterval interval;

  /// The final bucket.
  final Candle candle;

  /// Engine epoch the bucket belongs to.
  final int epoch;

  @override
  String get type => 'candle_closed';

  @override
  List<Object?> get props => <Object?>[
    ...super.props,
    symbol,
    interval,
    candle,
    epoch,
  ];
}

/// `market_summary` — the rolling 24h view.
final class MarketSummaryMessage extends ServerMessage {
  /// Creates a summary message.
  const MarketSummaryMessage({
    required super.version,
    required super.serverTime,
    required super.seq,
    required this.summary,
  });

  /// The summary.
  final MarketSummary summary;

  @override
  String get type => 'market_summary';

  @override
  List<Object?> get props => <Object?>[...super.props, summary];
}

/// The market a frame belongs to, or `null` for a frame that names none.
///
/// One socket carries one market at a time, but switching markets leaves the
/// previous subscription's frames in flight. A bloc has to be able to ask "is
/// this mine?" before it merges anything, or a delta from the market it just
/// left lands in the market it just opened.
extension ServerMessageMarket on ServerMessage {
  /// The symbol this frame describes, when it describes one.
  String? get marketSymbol => switch (this) {
    final OrderBookSnapshotMessage m => m.snapshot.symbol,
    final OrderBookDeltaMessage m => m.symbol,
    final TradeMessage m => m.trade.symbol,
    final TradeBatchMessage m => m.symbol,
    final CandleUpdateMessage m => m.symbol,
    final CandleClosedMessage m => m.symbol,
    final MarketSummaryMessage m => m.summary.symbol,
    _ => null,
  };
}
