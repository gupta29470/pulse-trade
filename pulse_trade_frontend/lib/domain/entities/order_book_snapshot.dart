import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';

/// A full book image at one engine `updateId`.
///
/// The same object backs the WS `order_book_snapshot` frame and the REST
/// `GET /api/v1/markets/{symbol}/orderbook` response, which is what lets the
/// synchronizer treat both sources identically.
final class OrderBookSnapshot extends Equatable {
  /// Creates a snapshot. [bids] are descending and [asks] ascending.
  const OrderBookSnapshot({
    required this.symbol,
    required this.epoch,
    required this.updateId,
    required this.bids,
    required this.asks,
    required this.serverTime,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Engine epoch; a change invalidates every buffered delta.
  final int epoch;

  /// The engine update id this image corresponds to.
  final int updateId;

  /// Bid levels, best (highest) first.
  final List<OrderBookLevel> bids;

  /// Ask levels, best (lowest) first.
  final List<OrderBookLevel> asks;

  /// Server time the image was taken.
  final DateTime serverTime;

  /// Highest bid, or `null` for an empty book.
  Money? get bestBid => bids.isEmpty ? null : bids.first.price;

  /// Lowest ask, or `null` for an empty book.
  Money? get bestAsk => asks.isEmpty ? null : asks.first.price;

  /// Exact spread, or `null` when either side is empty.
  Money? get spread {
    final Money? bid = bestBid;
    final Money? ask = bestAsk;
    if (bid == null || ask == null) return null;
    return ask - bid;
  }

  /// True when neither side has a level.
  bool get isEmpty => bids.isEmpty && asks.isEmpty;

  @override
  List<Object?> get props => <Object?>[
    symbol,
    epoch,
    updateId,
    bids,
    asks,
    serverTime,
  ];

  @override
  String toString() =>
      'OrderBookSnapshot($symbol, epoch=$epoch, updateId=$updateId, '
      'bids=${bids.length}, asks=${asks.length})';
}
