import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/market_status.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';

/// Everything `MarketBloc` reacts to.
///
/// A sealed hierarchy rather than a bag of strings: a `switch` over these types
/// is exhaustive at compile time, so adding a market event cannot silently
/// bypass the handlers. Every event is `const` and `Equatable` so a test can
/// assert on the exact event a widget produced.
sealed class MarketEvent extends Equatable {
  /// Const constructor so concrete events can be `const`.
  const MarketEvent();

  @override
  List<Object?> get props => const <Object?>[];
}

/// The market screen has mounted and wants its first paint.
///
/// Carries the symbol rather than reading it from the bloc because the same bloc
/// instance is retired when the route changes symbol; an explicit symbol makes
/// the cold-start load reproducible in a test.
final class MarketStarted extends MarketEvent {
  /// Creates the start event for [symbol].
  const MarketStarted(this.symbol);

  /// Canonical symbol id to load.
  final String symbol;

  @override
  List<Object?> get props => <Object?>[symbol];
}

/// The user picked a different candle interval in `IntervalSelector`.
///
/// Modelled as an event rather than a setter so the interval race
/// is a property of the event stream — two rapid selections produce two
/// requests in order, and the guard decides which response may be committed.
final class MarketIntervalSelected extends MarketEvent {
  /// Creates an interval selection.
  const MarketIntervalSelected(this.interval);

  /// The interval the user selected.
  final CandleInterval interval;

  @override
  List<Object?> get props => <Object?>[interval];
}

/// History should be reloaded for the current interval.
///
/// [forceRefresh] bypasses a still-fresh cache entry; it is separate from
/// `MarketStarted` so a pull-to-refresh does not re-run the roster and summary
/// loads.
final class MarketHistoryRefreshRequested extends MarketEvent {
  /// Creates a refresh request.
  const MarketHistoryRefreshRequested({this.forceRefresh = false});

  /// True to bypass the cache TTL.
  final bool forceRefresh;

  @override
  List<Object?> get props => <Object?>[forceRefresh];
}

/// A `candle_update` frame arrived: the full active bucket.
final class MarketCandleUpdateReceived extends MarketEvent {
  /// Creates the event.
  const MarketCandleUpdateReceived(this.message);

  /// The decoded frame.
  final CandleUpdateMessage message;

  @override
  List<Object?> get props => <Object?>[message];
}

/// A `candle_closed` frame arrived: the immutable final bucket.
final class MarketCandleClosedReceived extends MarketEvent {
  /// Creates the event.
  const MarketCandleClosedReceived(this.message);

  /// The decoded frame.
  final CandleClosedMessage message;

  @override
  List<Object?> get props => <Object?>[message];
}

/// A single `trade` frame arrived (FULL tier).
final class MarketTradeReceived extends MarketEvent {
  /// Creates the event.
  const MarketTradeReceived(this.message);

  /// The decoded frame.
  final TradeMessage message;

  @override
  List<Object?> get props => <Object?>[message];
}

/// A compacted `trade_batch` frame arrived (DEGRADED/MINIMAL).
final class MarketTradeBatchReceived extends MarketEvent {
  /// Creates the event.
  const MarketTradeBatchReceived(this.message);

  /// The decoded frame.
  final TradeBatchMessage message;

  @override
  List<Object?> get props => <Object?>[message];
}

/// A rolling 24h `market_summary` frame arrived.
final class MarketSummaryReceived extends MarketEvent {
  /// Creates the event.
  const MarketSummaryReceived(this.message);

  /// The decoded frame.
  final MarketSummaryMessage message;

  @override
  List<Object?> get props => <Object?>[message];
}

/// A `market_status` frame arrived: the engine paused, reset or resumed.
///
/// The engine's lifecycle is *not* the client's market liveness, so
/// this event never changes `MarketDataStatus`; it is stored so the screen can
/// render the engine-condition `InlineNotice`.
final class MarketStatusReceived extends MarketEvent {
  /// Creates the event.
  const MarketStatusReceived(this.status);

  /// The engine status.
  final MarketStatus status;

  @override
  List<Object?> get props => <Object?>[status];
}

/// The socket dropped or the transport reported a failure.
///
/// The payload is a typed [AppFailure] because no exception ever crosses out
/// of the data layer.
final class MarketStreamFailed extends MarketEvent {
  /// Creates the event.
  const MarketStreamFailed(this.failure);

  /// Why the stream stopped.
  final AppFailure failure;

  @override
  List<Object?> get props => <Object?>[failure];
}

/// Internet reachability changed.
///
/// The offline flag is a *gate*, not a rendering mode: an offline client still
/// renders cached values, it simply stops attempting network work.
final class MarketConnectivityChanged extends MarketEvent {
  /// Creates the event.
  const MarketConnectivityChanged({required this.offline});

  /// True when the device lost internet reachability.
  final bool offline;

  @override
  List<Object?> get props => <Object?>[offline];
}
