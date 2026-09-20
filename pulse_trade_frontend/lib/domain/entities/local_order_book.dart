import 'dart:collection';

import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/top_of_book.dart';

/// The client's application of the canonical book.
///
/// Two ordered maps rather than sorted lists: a delta is a `O(log n)` keyed
/// replacement, and the ordering invariant (bids descending, asks ascending) is
/// maintained by the comparator instead of by a sort. Nothing sorts in a render
/// path.
///
/// This type is deliberately mutable — the synchronizer owns it and hands an
/// immutable [TopOfBook] projection to the UI — but it is never shared across
/// isolates or mutated while a widget is reading it in the same turn.
final class LocalOrderBook {
  /// Creates an empty book for [symbol] at [epoch].
  LocalOrderBook({
    required this.symbol,
    required this.epoch,
    required this.appliedUpdateId,
    SplayTreeMap<Money, Quantity>? bids,
    SplayTreeMap<Money, Quantity>? asks,
    this._priceScale = 100,
    this._quantityScale = 100000000,
  }) : _bids = bids ?? SplayTreeMap<Money, Quantity>(descending),
       _asks = asks ?? SplayTreeMap<Money, Quantity>(ascending);

  /// Builds a book directly from a snapshot image.
  factory LocalOrderBook.fromSnapshot(OrderBookSnapshot snapshot) {
    final book = LocalOrderBook(
      symbol: snapshot.symbol,
      epoch: snapshot.epoch,
      appliedUpdateId: snapshot.updateId,
      priceScale: snapshot.bestBid?.scale ?? snapshot.bestAsk?.scale ?? 100,
    );
    book.applyLevels(snapshot.bids, isBid: true);
    book.applyLevels(snapshot.asks, isBid: false);
    return book;
  }

  /// Comparator that keeps bids best-first (highest price first).
  static int descending(Money a, Money b) => b.compareTo(a);

  /// Comparator that keeps asks best-first (lowest price first).
  static int ascending(Money a, Money b) => a.compareTo(b);

  /// Canonical symbol id.
  final String symbol;

  /// Engine epoch this book belongs to.
  int epoch;

  /// The last engine update id whose levels are fully applied.
  int appliedUpdateId;

  final SplayTreeMap<Money, Quantity> _bids;
  final SplayTreeMap<Money, Quantity> _asks;
  int _priceScale;
  int _quantityScale;

  /// Bid levels, best first. Read-only: mutate through [applyLevels].
  SplayTreeMap<Money, Quantity> get bids => _bids;

  /// Ask levels, best first.
  SplayTreeMap<Money, Quantity> get asks => _asks;

  /// The scale every quantity in this book uses.
  int get quantityScale => _quantityScale;

  /// The scale every price in this book uses.
  int get priceScale => _priceScale;

  /// Number of resting bid levels.
  int get bidLevelCount => _bids.length;

  /// Number of resting ask levels.
  int get askLevelCount => _asks.length;

  /// True when neither side holds a level.
  bool get isEmpty => _bids.isEmpty && _asks.isEmpty;

  /// Highest bid, or `null` for an empty side.
  Money? get bestBid => _bids.isEmpty ? null : _bids.firstKey();

  /// Lowest ask, or `null` for an empty side.
  Money? get bestAsk => _asks.isEmpty ? null : _asks.firstKey();

  /// Exact spread, or `null` when either side is empty.
  Money? get spread {
    final Money? bid = bestBid;
    final Money? ask = bestAsk;
    if (bid == null || ask == null) return null;
    return ask - bid;
  }

  /// True when the best bid is at or above the best ask, which is a crossed book
  /// and therefore a bug worth surfacing rather than rendering.
  bool get isCrossed {
    final Money? bid = bestBid;
    final Money? ask = bestAsk;
    if (bid == null || ask == null) return false;
    return bid >= ask;
  }

  /// Applies absolute levels. A zero quantity deletes the level.
  ///
  /// Returns how many levels were touched, purely for diagnostics.
  int applyLevels(Iterable<OrderBookLevel> levels, {required bool isBid}) {
    final SplayTreeMap<Money, Quantity> target = isBid ? _bids : _asks;
    var touched = 0;
    for (final OrderBookLevel level in levels) {
      _priceScale = level.price.scale;
      _quantityScale = level.quantity.scale;
      if (level.isDelete) {
        if (target.remove(level.price) != null) touched++;
      } else {
        target[level.price] = level.quantity;
        touched++;
      }
    }
    return touched;
  }

  /// Replaces the whole book with [snapshot].
  void replaceWith(OrderBookSnapshot snapshot) {
    _bids.clear();
    _asks.clear();
    epoch = snapshot.epoch;
    appliedUpdateId = snapshot.updateId;
    applyLevels(snapshot.bids, isBid: true);
    applyLevels(snapshot.asks, isBid: false);
  }

  /// Empties both sides and moves to [newEpoch].
  void resetEpoch(int newEpoch) {
    _bids.clear();
    _asks.clear();
    epoch = newEpoch;
    appliedUpdateId = 0;
  }

  /// Projects the best [depth] levels per side together with cumulative
  /// quantities, so the depth bars need no arithmetic in `build`.
  TopOfBook top(int depth) {
    final List<OrderBookLevel> bidLevels = <OrderBookLevel>[];
    final List<OrderBookLevel> askLevels = <OrderBookLevel>[];
    final List<Quantity> bidCumulative = <Quantity>[];
    final List<Quantity> askCumulative = <Quantity>[];

    var running = Quantity.fromScaled(0, _quantityScale);
    for (final MapEntry<Money, Quantity> entry in _bids.entries) {
      if (bidLevels.length >= depth) break;
      running = running + entry.value;
      bidLevels.add(OrderBookLevel(price: entry.key, quantity: entry.value));
      bidCumulative.add(running);
    }

    running = Quantity.fromScaled(0, _quantityScale);
    for (final MapEntry<Money, Quantity> entry in _asks.entries) {
      if (askLevels.length >= depth) break;
      running = running + entry.value;
      askLevels.add(OrderBookLevel(price: entry.key, quantity: entry.value));
      askCumulative.add(running);
    }

    return TopOfBook(
      bids: bidLevels,
      asks: askLevels,
      bidCumulative: bidCumulative,
      askCumulative: askCumulative,
    );
  }

  /// A detached copy, so a bloc can publish an immutable snapshot of the book
  /// without exposing the mutable instance it keeps applying deltas to.
  LocalOrderBook copy() {
    final SplayTreeMap<Money, Quantity> bidCopy = SplayTreeMap<Money, Quantity>(
      descending,
    );
    final SplayTreeMap<Money, Quantity> askCopy = SplayTreeMap<Money, Quantity>(
      ascending,
    );
    bidCopy.addAll(_bids);
    askCopy.addAll(_asks);
    return LocalOrderBook(
      symbol: symbol,
      epoch: epoch,
      appliedUpdateId: appliedUpdateId,
      bids: bidCopy,
      asks: askCopy,
      priceScale: _priceScale,
      quantityScale: _quantityScale,
    );
  }

  @override
  String toString() =>
      'LocalOrderBook($symbol, epoch=$epoch, applied=$appliedUpdateId, '
      'bids=${_bids.length}, asks=${_asks.length})';
}
