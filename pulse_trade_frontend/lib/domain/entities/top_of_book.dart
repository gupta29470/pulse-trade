import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';

/// An immutable best-N projection of the book, ready to render.
///
/// The cumulative quantities are precomputed here so the depth bars are a
/// division in the painter and never an accumulation inside `build`.
/// Cumulative depth is the one derived value the client computes because it is a
/// pure projection of the levels the backend sent.
final class TopOfBook extends Equatable {
  /// Creates a projection. All four lists must share the same length ordering.
  const TopOfBook({
    required this.bids,
    required this.asks,
    required this.bidCumulative,
    required this.askCumulative,
  });

  /// An empty projection, used before the first snapshot arrives.
  static const TopOfBook empty = TopOfBook(
    bids: <OrderBookLevel>[],
    asks: <OrderBookLevel>[],
    bidCumulative: <Quantity>[],
    askCumulative: <Quantity>[],
  );

  /// Bid levels, best first.
  final List<OrderBookLevel> bids;

  /// Ask levels, best first.
  final List<OrderBookLevel> asks;

  /// Running bid quantity totals, aligned with [bids].
  final List<Quantity> bidCumulative;

  /// Running ask quantity totals, aligned with [asks].
  final List<Quantity> askCumulative;

  /// Highest bid, or `null` when the book has no bids.
  Money? get bestBid => bids.isEmpty ? null : bids.first.price;

  /// Lowest ask, or `null` when the book has no asks.
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

  /// The largest cumulative quantity on either side, which is the denominator
  /// for every depth-bar width.
  Quantity get maxCumulative {
    Quantity max = Quantity.fromScaled(0, quantityScale);
    for (final Quantity value in bidCumulative) {
      if (value > max) max = value;
    }
    for (final Quantity value in askCumulative) {
      if (value > max) max = value;
    }
    return max;
  }

  /// The scale shared by every cumulative quantity.
  int get quantityScale => bidCumulative.isNotEmpty
      ? bidCumulative.first.scale
      : (askCumulative.isNotEmpty ? askCumulative.first.scale : 100000000);

  /// The 0..1 depth-bar width for one row.
  ///
  /// This is a rendering ratio, not a market value: it is the single place a
  /// quantity becomes a `double`, and it exists so the painter performs no
  /// accumulation and no comparison.
  double depthRatio(int index, {required bool isBid}) {
    final List<Quantity> series = isBid ? bidCumulative : askCumulative;
    if (index < 0 || index >= series.length) return 0;
    final Quantity max = maxCumulative;
    if (max.isZero) return 0;
    return series[index].scaled / max.scaled;
  }

  @override
  List<Object?> get props => <Object?>[
    bids,
    asks,
    bidCumulative,
    askCumulative,
  ];

  @override
  String toString() =>
      'TopOfBook(bids=${bids.length}, asks=${asks.length}, '
      'spread=${spread?.format() ?? '—'})';
}
