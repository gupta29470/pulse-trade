import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';

/// One input the order-book bloc reacts to.
///
/// Events are data rather than method calls, so a whole scenario — subscribe, a
/// snapshot, a gap, a disconnect, a retry — can be written as a list,
/// replayed in a `bloc_test` with no socket, no repository and a `FakeClock`.
/// Every subclass is `const` so a test can hold them in a
/// `const` list.
sealed class OrderBookEvent extends Equatable {
  /// Base constructor. Kept `const` so subclasses can be `const` too.
  const OrderBookEvent();
}

/// The order-book section was mounted (or the symbol changed): find the epoch,
/// resubscribe, then resynchronise from a snapshot.
final class OrderBookStarted extends OrderBookEvent {
  /// Creates the start event.
  ///
  /// [symbol] switches the bloc to another market when the route opens one; a
  /// `null` symbol keeps the one the bloc was constructed with.
  const OrderBookStarted({this.symbol});

  /// The market to bind to, or `null` to keep the current one.
  final String? symbol;

  @override
  List<Object?> get props => <Object?>[symbol];
}

/// A full book image arrived, from the socket or from the repository.
///
/// [fromCache] is the field that keeps the book honest: a cached image is
/// applied so the user sees something real, but it must never promote the book
/// to `LIVE`. [asOf] is the cache entry's write time for a cached image, or the
/// server time for a live one.
final class OrderBookSnapshotReceived extends OrderBookEvent {
  /// Creates a snapshot event.
  const OrderBookSnapshotReceived(
    this.snapshot, {
    required this.fromCache,
    this.asOf,
  });

  /// The book image.
  final OrderBookSnapshot snapshot;

  /// True when the image came from disk rather than the backend.
  final bool fromCache;

  /// When the image was produced, for the `CACHED · as of …` label.
  final DateTime? asOf;

  @override
  List<Object?> get props => <Object?>[snapshot, fromCache, asOf];
}

/// One delta range arrived. The range, not the levels, is what the synchronizer
/// sequences on.
final class OrderBookDeltaReceived extends OrderBookEvent {
  /// Creates a delta event.
  const OrderBookDeltaReceived(this.delta);

  /// The range, with absolute quantities and its `first`/`last` update ids.
  final OrderBookDeltaMessage delta;

  @override
  List<Object?> get props => <Object?>[delta];
}

/// The socket dropped. The book is preserved and frozen, never cleared, so the
/// last known liquidity stays on screen under a `STALE` tag.
final class OrderBookConnectionLost extends OrderBookEvent {
  /// Creates a connection-lost event.
  const OrderBookConnectionLost();

  @override
  List<Object?> get props => const <Object?>[];
}

/// The engine epoch changed, so every buffered range and every level in the
/// local book is obsolete and a fresh image is required.
final class OrderBookEpochReset extends OrderBookEvent {
  /// Creates an epoch-reset event.
  const OrderBookEpochReset(this.epoch);

  /// The new epoch.
  final int epoch;

  @override
  List<Object?> get props => <Object?>[epoch];
}

/// The user pressed Retry in the terminal error state. Recovery attempts are
/// reset; this is the only way out of `OrderBookState.error`.
final class OrderBookRetryRequested extends OrderBookEvent {
  /// Creates a retry event.
  const OrderBookRetryRequested();

  @override
  List<Object?> get props => const <Object?>[];
}

/// The rendered depth per side changed. The projection is recomputed from the
/// already-applied book, so no network work is triggered.
final class OrderBookDepthChanged extends OrderBookEvent {
  /// Creates a depth-change event.
  const OrderBookDepthChanged(this.depth);

  /// New level count per side.
  final int depth;

  @override
  List<Object?> get props => <Object?>[depth];
}

/// The market stream reported a typed failure.
///
/// Carried as an event rather than thrown so the failure travels through the
/// same reducer as everything else and no exception ever reaches the widget
/// tree.
final class OrderBookStreamFailed extends OrderBookEvent {
  /// Creates a stream-failure event.
  const OrderBookStreamFailed(this.failure);

  /// The typed failure, rendered as user-facing copy by the state.
  final AppFailure failure;

  @override
  List<Object?> get props => <Object?>[failure];
}
