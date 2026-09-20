import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_status.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';

/// The candle/price layer's own liveness.
///
/// This is deliberately independent of internet reachability and of the
/// backend's engine state: a `LIVE` engine with a dropped socket still renders
/// as [stale] here. There is no `cached` member because "came from disk" is
/// carried by [MarketState.candleProvenance], not by the status — collapsing the
/// two is exactly how a cached value gets promoted to live.
enum MarketDataStatus {
  /// Nothing has been loaded yet; the screen shows skeletons.
  initialLoading,

  /// Fresh data arrived from the backend in this session.
  live,

  /// An interval switch or an explicit refresh is in flight; old candles stay
  /// on screen.
  refreshing,

  /// The backend answered and there is genuinely no history for this interval.
  empty,

  /// A load failed and there is nothing usable to render.
  error,

  /// Data is on screen but is not live: served from disk, or frozen because the
  /// socket dropped.
  stale,
}

/// Everything the market screen renders, in one immutable value.
///
/// Immutability is what lets a widget compare two states cheaply and what lets
/// `BlocSelector` isolate the 10 Hz price tick from the chart and the tape.
///
/// Provenance travels *with* each payload rather than being inferred, because
/// the UI contract is a per-section `CACHED · as of` tag.
///
final class MarketState extends Equatable {
  /// Creates a market state.
  ///
  /// Every list defaults to a `const` empty list so [MarketState.initial] is a
  /// single allocation and so `copyWith` never has to guard against `null`.
  const MarketState({
    required this.symbol,
    required this.status,
    required this.interval,
    this.candles = const <Candle>[],
    this.activeCandle,
    this.candleProvenance,
    this.candleAsOf,
    this.trades = const <Trade>[],
    this.tradesProvenance,
    this.tradesAsOf,
    this.summary,
    this.summaryAsOf,
    this.bookSnapshot,
    this.bookProvenance,
    this.bookAsOf,
    this.omittedTradeCount = 0,
    this.marketStatus,
    this.failure,
    this.isRefreshing = false,
    this.markets = const <MarketInfo>[],
    this.hasLoadedMarkets = false,
  });

  /// The state a freshly mounted market screen starts from.
  ///
  /// [interval] defaults to the app's default chart interval, so a caller that
  /// does not care about persistence gets the documented behaviour for free.
  factory MarketState.initial(
    String symbol, {
    CandleInterval interval = CandleInterval.defaultInterval,
  }) => MarketState(
    symbol: symbol,
    status: MarketDataStatus.initialLoading,
    interval: interval,
  );

  /// Sentinel distinguishing "argument omitted" from "explicitly set to null" in
  /// [copyWith]. Without it, clearing a provenance or an active candle would be
  /// impossible and a stale value would leak into the next interval.
  static const Object _unset = Object();

  /// Canonical symbol id this state describes.
  final String symbol;

  /// The candle/price layer's liveness.
  final MarketDataStatus status;

  /// Currently selected candle interval.
  final CandleInterval interval;

  /// Ascending candle series for [interval], bounded by the bloc's retention.
  final List<Candle> candles;

  /// The bucket still forming, or `null` when the newest bucket is closed.
  final Candle? activeCandle;

  /// Where [candles] came from, so the chart can be tagged honestly.
  final DataProvenance? candleProvenance;

  /// When [candles] were produced; `null` before any load.
  final DateTime? candleAsOf;

  /// Recent trades, newest first, capped by the collector.
  final List<Trade> trades;

  /// Where [trades] came from.
  final DataProvenance? tradesProvenance;

  /// When [trades] were produced.
  final DateTime? tradesAsOf;

  /// Rolling 24h summary, computed by the backend.
  final MarketSummary? summary;

  /// When the summary was produced by the backend.
  final DateTime? summaryAsOf;

  /// First-paint book image loaded over REST. The live book is owned by
  /// `OrderBookBloc`; this copy exists only so the market screen has something
  /// to show before the order-book bloc has synchronised.
  final OrderBookSnapshot? bookSnapshot;

  /// Where [bookSnapshot] came from.
  final DataProvenance? bookProvenance;

  /// When [bookSnapshot] was produced.
  final DateTime? bookAsOf;

  /// How many executions the backend omitted when compacting trade batches.
  /// Surfaced in the UI rather than hidden.
  final int omittedTradeCount;

  /// The engine's own lifecycle state, used for the engine-condition notice.
  final MarketStatus? marketStatus;

  /// The last failure that is relevant to this screen, or `null`.
  final AppFailure? failure;

  /// True while an interval switch or explicit refresh is in flight.
  final bool isRefreshing;

  /// The market roster, once loaded. Kept here so the market screen can prove a
  /// symbol is unknown without asking a second bloc.
  final List<MarketInfo> markets;

  /// True once a roster load has succeeded. Absence of a symbol only means "not
  /// found" after this flips; before it, absence means "not loaded yet".
  final bool hasLoadedMarkets;

  /// True when there is a series to draw.
  bool get hasCandles => candles.isNotEmpty;

  /// True when the engine reports itself paused: values are frozen rather than
  /// missing, and the two render differently.
  bool get isPaused => marketStatus?.isPaused ?? false;

  /// The oldest of the per-section timestamps, for a single section tag.
  ///
  /// The market screen shows one tag per section, but some surfaces (the price
  /// summary card) summarise several; using the oldest is the only honest
  /// choice, because it cannot overstate how fresh the composite is.
  DateTime? get oldestAsOf {
    final List<DateTime> stamps = <DateTime>[
      ?candleAsOf,
      ?tradesAsOf,
      ?bookAsOf,
    ];
    if (stamps.isEmpty) return null;
    var oldest = stamps.first;
    for (final DateTime stamp in stamps) {
      if (stamp.isBefore(oldest)) oldest = stamp;
    }
    return oldest;
  }

  /// A copy with selected fields replaced.
  ///
  /// Nullable fields use the [_unset] sentinel so `copyWith(activeCandle: null)`
  /// clears the value while omitting the argument keeps it. [clearFailure] is
  /// the spelled-out equivalent for the one field callers clear most often, so a
  /// handler that recovers reads as intent rather than as a trick.
  MarketState copyWith({
    String? symbol,
    MarketDataStatus? status,
    CandleInterval? interval,
    List<Candle>? candles,
    Object? activeCandle = _unset,
    Object? candleProvenance = _unset,
    Object? candleAsOf = _unset,
    List<Trade>? trades,
    Object? tradesProvenance = _unset,
    Object? tradesAsOf = _unset,
    Object? summary = _unset,
    Object? summaryAsOf = _unset,
    Object? bookSnapshot = _unset,
    Object? bookProvenance = _unset,
    Object? bookAsOf = _unset,
    int? omittedTradeCount,
    Object? marketStatus = _unset,
    Object? failure = _unset,
    bool clearFailure = false,
    bool? isRefreshing,
    List<MarketInfo>? markets,
    bool? hasLoadedMarkets,
  }) {
    return MarketState(
      symbol: symbol ?? this.symbol,
      status: status ?? this.status,
      interval: interval ?? this.interval,
      candles: candles ?? this.candles,
      activeCandle: identical(activeCandle, _unset)
          ? this.activeCandle
          : activeCandle as Candle?,
      candleProvenance: identical(candleProvenance, _unset)
          ? this.candleProvenance
          : candleProvenance as DataProvenance?,
      candleAsOf: identical(candleAsOf, _unset)
          ? this.candleAsOf
          : candleAsOf as DateTime?,
      trades: trades ?? this.trades,
      tradesProvenance: identical(tradesProvenance, _unset)
          ? this.tradesProvenance
          : tradesProvenance as DataProvenance?,
      tradesAsOf: identical(tradesAsOf, _unset)
          ? this.tradesAsOf
          : tradesAsOf as DateTime?,
      summary: identical(summary, _unset)
          ? this.summary
          : summary as MarketSummary?,
      summaryAsOf: identical(summaryAsOf, _unset)
          ? this.summaryAsOf
          : summaryAsOf as DateTime?,
      bookSnapshot: identical(bookSnapshot, _unset)
          ? this.bookSnapshot
          : bookSnapshot as OrderBookSnapshot?,
      bookProvenance: identical(bookProvenance, _unset)
          ? this.bookProvenance
          : bookProvenance as DataProvenance?,
      bookAsOf: identical(bookAsOf, _unset)
          ? this.bookAsOf
          : bookAsOf as DateTime?,
      omittedTradeCount: omittedTradeCount ?? this.omittedTradeCount,
      marketStatus: identical(marketStatus, _unset)
          ? this.marketStatus
          : marketStatus as MarketStatus?,
      failure: clearFailure
          ? null
          : identical(failure, _unset)
          ? this.failure
          : failure as AppFailure?,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      markets: markets ?? this.markets,
      hasLoadedMarkets: hasLoadedMarkets ?? this.hasLoadedMarkets,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    symbol,
    status,
    interval,
    candles,
    activeCandle,
    candleProvenance,
    candleAsOf,
    trades,
    tradesProvenance,
    tradesAsOf,
    summary,
    summaryAsOf,
    bookSnapshot,
    bookProvenance,
    bookAsOf,
    omittedTradeCount,
    marketStatus,
    failure,
    isRefreshing,
    markets,
    hasLoadedMarkets,
  ];

  @override
  String toString() =>
      'MarketState($symbol, ${interval.wire}, ${status.name}, '
      'candles=${candles.length}, trades=${trades.length}, '
      'candle=${candleProvenance?.name ?? 'none'}, '
      'book=${bookProvenance?.name ?? 'none'})';
}
