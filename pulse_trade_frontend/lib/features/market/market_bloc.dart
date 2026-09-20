import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/channel.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/market/interval_request_guard.dart';
import 'package:pulse_trade_frontend/domain/market/trade_collector.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/orderbook/candle_merger.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_history_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_summary_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/order_book_repository.dart';
import 'package:pulse_trade_frontend/features/market/market_event.dart';
import 'package:pulse_trade_frontend/features/market/market_state.dart';

/// The candle and price block of the market screen.
///
/// Owns exactly five things: the selected interval, the candle series, the
/// active bucket, the rolling summary and the recent-trade tape. It deliberately
/// does **not** own the order book, the socket lifecycle or the delivery tier —
/// those are `OrderBookBloc`, `ConnectionBloc` and `AdaptiveDeliveryCubit`.
///
/// Two invariants drive the whole implementation:
///
/// * **Cache is never promoted to live.** The transition out of
/// [DataProvenance.cached]/[DataProvenance.stale] happens only when a frame
/// arrives on the stream. A REST response that the repository
/// served from disk keeps its provenance all the way into the state.
/// * **Only state changes are emitted.** A duplicate candle, a replayed trade or
/// a stale history response produces no emission at all, so the 10 Hz hot path
/// never rebuilds a widget for nothing.
final class MarketBloc extends Bloc<MarketEvent, MarketState> {
  /// Creates the bloc, initially describing [symbol].
  ///
  /// [initialInterval] is the persisted chart interval, if the caller has one;
  /// [historyLimit] bounds the in-memory series and is passed to
  /// [CandleMerger.retention] so the model and the UI agree on the window.
  /// The symbol follows [MarketStarted] afterwards.
  MarketBloc({
    required this._history,
    required this._summaries,
    required this._orderBooks,
    required this._stream,
    required String symbol,
    CandleInterval initialInterval = CandleInterval.m1,
    Clock? clock,
    OnDeviceMetrics? metrics,
    int historyLimit = 500,
  }) : _symbol = symbol,
       initialInterval = initialInterval,
       historyLimit = historyLimit,
       _clock = clock ?? SystemClock(),
       _merger = CandleMerger(retention: historyLimit),
       super(MarketState.initial(symbol, interval: initialInterval)) {
    // One registry instance shared by the guard and the collector: two
    // registries would each report half the counters the diagnostics screen
    // promises to copy out.
    final OnDeviceMetrics resolvedMetrics = metrics ?? OnDeviceMetrics();
    _guard = IntervalRequestGuard(metrics: resolvedMetrics);
    _collector = TradeCollector(metrics: resolvedMetrics);

    _messages = _stream.messages.listen(_onServerMessage);
    _failures = _stream.failures.listen(_onFailure);

    on<MarketStarted>(_onStarted);
    on<MarketIntervalSelected>(_onIntervalSelected);
    on<MarketHistoryRefreshRequested>(_onRefreshRequested);
    on<MarketCandleUpdateReceived>(_onCandleUpdate);
    on<MarketCandleClosedReceived>(_onCandleClosed);
    on<MarketTradeReceived>(_onTrade);
    on<MarketTradeBatchReceived>(_onTradeBatch);
    on<MarketSummaryReceived>(_onSummary);
    on<MarketStatusReceived>(_onStatus);
    on<MarketStreamFailed>(_onStreamFailed);
    on<MarketConnectivityChanged>(_onConnectivity);
  }

  /// The market this bloc currently describes, e.g. `BTCUSDT`.
  ///
  /// It starts at the construction symbol and follows [MarketStarted], so one
  /// bloc can serve whichever market the route opened. Every read and every
  /// resubscribe uses this value, which is what keeps the socket and the chart
  /// pointed at the same symbol.
  String _symbol;

  /// The interval used before the user has chosen one.
  final CandleInterval initialInterval;

  /// Maximum candles retained in [MarketState.candles].
  final int historyLimit;

  final MarketHistoryRepository _history;
  final MarketSummaryRepository _summaries;
  final OrderBookRepository _orderBooks;
  final MarketStreamRepository _stream;
  final Clock _clock;
  final CandleMerger _merger;

  late final IntervalRequestGuard _guard;
  late final TradeCollector _collector;
  late final StreamSubscription<ServerMessage> _messages;
  late final StreamSubscription<AppFailure> _failures;

  /// How many recent trades the cold-start seed requests. Matches the UI cap, so
  /// the panel is full on a cold start without over-fetching.
  static const int _tradeLimit = 50;

  /// Bloc-owned compaction tally. The collector also counts per-trade
  /// `omittedCount`, but a batch stamps every surviving trade with the *batch's*
  /// count, so using it there would multiply one omission by the batch size.
  int _omittedTradeCount = 0;

  /// Cold start: roster, candles, 24h summary and a first-paint book image.
  ///
  /// Everything is loaded through the repositories, which are cache-first,
  /// offline-gated, so a cold start with a populated cache emits a state full of
  /// `CACHED`-tagged values and performs no network call. A start for a
  /// different symbol first drops the previous market's values — its candles and
  /// trades are not this market's — and then rebinds the session with
  /// [SubscriptionSpec], so the socket follows the screen without a reconnect.
  Future<void> _onStarted(
    MarketStarted event,
    Emitter<MarketState> emit,
  ) async {
    final bool switched = event.symbol != _symbol;
    _symbol = event.symbol;
    if (switched) {
      _collector.reset();
      _omittedTradeCount = 0;
    }

    final int requestId = _guard.begin(state.interval);
    emit(
      _withoutPreviousMarket(state, switched: switched).copyWith(
        symbol: event.symbol,
        status: MarketDataStatus.initialLoading,
        isRefreshing: false,
        clearFailure: true,
      ),
    );

    await _loadRoster(emit);
    if (isClosed) return;

    final Result<Sourced<List<Candle>>> historyResult = await _history
        .loadHistory(event.symbol, state.interval, limit: historyLimit);
    if (isClosed) return;
    final Result<Sourced<MarketSummary>> summaryResult = await _summaries
        .loadSummary(event.symbol);
    if (isClosed) return;
    final Result<Sourced<OrderBookSnapshot>> bookResult = await _orderBooks
        .loadSnapshot(event.symbol);
    if (isClosed) return;
    // The recent-trade seed comes from the same cache-first seam as history, so
    // an offline cold start renders the trades panel from disk with a CACHED tag
    // instead of an empty box. Live trades replace it through the stream.
    final Result<Sourced<List<Trade>>> tradesResult = await _history
        .loadRecentTrades(event.symbol, limit: _tradeLimit);
    if (isClosed) return;

    if (!_guard.accept(requestId, state.interval)) {
      _logStaleHistory(requestId, state.interval);
      return;
    }
    _guard.complete(requestId);

    MarketState next = _applyHistory(state, historyResult, state.interval);
    next = _applySummary(next, summaryResult);
    next = _applyBook(next, bookResult);
    next = _applyTradeSeed(next, tradesResult);
    emit(next.copyWith(status: _statusFrom(next), isRefreshing: false));

    await _resubscribe(state.interval, emit);
  }

  /// Clears the per-market payloads when the route moved to a different symbol.
  ///
  /// The roster is symbol-independent, so it is kept; everything else would
  /// otherwise be rendered under the new symbol's name.
  MarketState _withoutPreviousMarket(
    MarketState base, {
    required bool switched,
  }) {
    if (!switched) return base;
    return base.copyWith(
      candles: const <Candle>[],
      activeCandle: null,
      candleProvenance: null,
      candleAsOf: null,
      trades: const <Trade>[],
      tradesProvenance: null,
      tradesAsOf: null,
      summary: null,
      summaryAsOf: null,
      bookSnapshot: null,
      bookProvenance: null,
      bookAsOf: null,
      omittedTradeCount: 0,
    );
  }

  /// Seeds the collector from a cached or freshly fetched trade list.
  ///
  /// The collector is reset first because the seed is authoritative for the
  /// session's history; live frames then extend it. Trades are added in
  /// ascending id order, which is the only order the collector accepts.
  MarketState _applyTradeSeed(
    MarketState base,
    Result<Sourced<List<Trade>>> result,
  ) {
    final Sourced<List<Trade>>? sourced = result.valueOrNull;
    if (sourced == null) return base;
    if (sourced.value.isEmpty && base.trades.isNotEmpty) return base;

    final List<Trade> ascending = List<Trade>.of(sourced.value)
      ..sort((Trade a, Trade b) => a.tradeId.compareTo(b.tradeId));
    _collector.reset();
    _collector.addBatch(ascending);

    return base.copyWith(
      trades: _collector.trades,
      tradesProvenance: sourced.provenance,
      tradesAsOf: sourced.asOf ?? _clock.now(),
      omittedTradeCount: 0,
    );
  }

  /// Interval switch: load the new interval's history and resubscribe the
  /// stream.
  Future<void> _onIntervalSelected(
    MarketIntervalSelected event,
    Emitter<MarketState> emit,
  ) async {
    final CandleInterval interval = event.interval;
    final int requestId = _guard.begin(interval);
    emit(
      state.copyWith(
        interval: interval,
        status: MarketDataStatus.refreshing,
        isRefreshing: true,
        // The highlighted bucket belongs to the interval being left; keeping it
        // would print two intervals' OHLCV into one readout.
        activeCandle: null,
        clearFailure: true,
      ),
    );

    final Result<Sourced<List<Candle>>> result = await _history.loadHistory(
      _symbol,
      interval,
      limit: historyLimit,
    );
    if (isClosed) return;

    if (!_guard.accept(requestId, interval)) {
      // A newer request owns the chart; this response must not be committed.
      _logStaleHistory(requestId, interval);
      return;
    }
    _guard.complete(requestId);
    emit(_swapHistory(state, result, interval));

    await _resubscribe(interval, emit);
  }

  /// Explicit history reload for the current interval.
  Future<void> _onRefreshRequested(
    MarketHistoryRefreshRequested event,
    Emitter<MarketState> emit,
  ) async {
    final CandleInterval interval = state.interval;
    final int requestId = _guard.begin(interval);
    emit(
      state.copyWith(status: MarketDataStatus.refreshing, isRefreshing: true),
    );

    final Result<Sourced<List<Candle>>> result = await _history.loadHistory(
      _symbol,
      interval,
      limit: historyLimit,
      forceRefresh: event.forceRefresh,
    );
    if (isClosed) return;

    if (!_guard.accept(requestId, interval)) {
      _logStaleHistory(requestId, interval);
      return;
    }
    _guard.complete(requestId);
    emit(_swapHistory(state, result, interval));
  }

  void _onCandleUpdate(
    MarketCandleUpdateReceived event,
    Emitter<MarketState> emit,
  ) => _mergeCandle(event.message.interval, event.message.candle, emit);

  void _onCandleClosed(
    MarketCandleClosedReceived event,
    Emitter<MarketState> emit,
  ) =>
      // A close is authoritative even if the payload's own flag lags;
      // the frame *is* the finalisation.
      _mergeCandle(
        event.message.interval,
        event.message.candle.copyWith(closed: true),
        emit,
      );

  void _onTrade(MarketTradeReceived event, Emitter<MarketState> emit) {
    final bool accepted = _collector.add(event.message.trade);
    _omittedTradeCount += event.message.trade.omittedCount;
    if (!accepted) return;
    emit(_withTrades(state));
  }

  void _onTradeBatch(
    MarketTradeBatchReceived event,
    Emitter<MarketState> emit,
  ) {
    final int accepted = _collector.addBatch(event.message.trades);
    // Counted once per batch, never once per surviving trade: the batch reports
    // the total it compacted away.
    _omittedTradeCount += event.message.omittedCount;
    if (accepted == 0) return;
    emit(_withTrades(state));
  }

  void _onSummary(MarketSummaryReceived event, Emitter<MarketState> emit) {
    emit(
      state.copyWith(
        summary: event.message.summary,
        summaryAsOf: event.message.summary.updatedAt,
        status: _liveStatus(state),
      ),
    );
  }

  void _onStatus(MarketStatusReceived event, Emitter<MarketState> emit) {
    // Engine lifecycle is stored, never folded into MarketDataStatus: PAUSED is
    // frozen-but-honest data while STALE is missing data.
    emit(state.copyWith(marketStatus: event.status));
  }

  void _onStreamFailed(MarketStreamFailed event, Emitter<MarketState> emit) {
    emit(
      _demoteLiveToStale(
        state,
      ).copyWith(status: MarketDataStatus.stale, failure: event.failure),
    );
  }

  void _onConnectivity(
    MarketConnectivityChanged event,
    Emitter<MarketState> emit,
  ) {
    // Coming back online changes nothing here on purpose: recovery is driven by
    // the connection bloc's resubscribe and by the frames that follow, and a
    // connectivity edge must never be the thing that promotes cache to live.
    if (!event.offline) return;
    final bool hasData =
        state.hasCandles ||
        state.bookSnapshot != null ||
        state.trades.isNotEmpty;
    final MarketState demoted = _demoteLiveToStale(state);
    emit(
      hasData
          ? demoted.copyWith(status: MarketDataStatus.stale, clearFailure: true)
          : demoted.copyWith(
              status: MarketDataStatus.error,
              failure: const OfflineFailure(),
            ),
    );
  }

  /// Merges [candle] into the series, ignoring it when its identity, sequence or
  /// interval says it is not new.
  void _mergeCandle(
    CandleInterval interval,
    Candle candle,
    Emitter<MarketState> emit,
  ) {
    if (interval != state.interval) return;
    final List<Candle> base = _seriesForInterval(state.candles, interval);
    final List<Candle> merged = _merger.merge(base, candle);
    if (identical(merged, base)) return;
    emit(
      state.copyWith(
        candles: merged,
        activeCandle: _activeOf(merged, interval),
        candleProvenance: DataProvenance.live,
        candleAsOf: _clock.now(),
        status: _liveStatus(state),
        clearFailure: true,
      ),
    );
  }

  /// The 24h card, the chart and the tape in one state.
  MarketState _applyHistory(
    MarketState base,
    Result<Sourced<List<Candle>>> result,
    CandleInterval interval,
  ) {
    final Sourced<List<Candle>>? sourced = result.valueOrNull;
    if (sourced == null) {
      return base.copyWith(failure: result.failureOrNull);
    }
    final List<Candle> series = _merger.mergeHistory(
      // Keep live candles that arrived while history was in flight; mergeHistory
      // deduplicates them against the page by identity.
      _seriesForInterval(base.candles, interval),
      sourced.value,
    );
    return base.copyWith(
      candles: series,
      activeCandle: _activeOf(series, interval),
      candleProvenance: sourced.provenance,
      candleAsOf: sourced.asOf ?? _clock.now(),
      clearFailure: true,
    );
  }

  MarketState _applySummary(
    MarketState base,
    Result<Sourced<MarketSummary>> result,
  ) {
    final Sourced<MarketSummary>? sourced = result.valueOrNull;
    if (sourced == null) return base.copyWith(failure: result.failureOrNull);
    return base.copyWith(
      summary: sourced.value,
      summaryAsOf: sourced.asOf ?? sourced.value.updatedAt,
      clearFailure: true,
    );
  }

  MarketState _applyBook(
    MarketState base,
    Result<Sourced<OrderBookSnapshot>> result,
  ) {
    final Sourced<OrderBookSnapshot>? sourced = result.valueOrNull;
    if (sourced == null) return base.copyWith(failure: result.failureOrNull);
    return base.copyWith(
      bookSnapshot: sourced.value,
      bookProvenance: sourced.provenance,
      bookAsOf: sourced.asOf ?? sourced.value.serverTime,
      clearFailure: true,
    );
  }

  /// Commits a history response for [interval], keeping the previous series when
  /// the load failed so the chart never blinks to empty.
  MarketState _swapHistory(
    MarketState base,
    Result<Sourced<List<Candle>>> result,
    CandleInterval interval,
  ) {
    final Sourced<List<Candle>>? sourced = result.valueOrNull;
    if (sourced == null) {
      return base.copyWith(
        isRefreshing: false,
        failure: result.failureOrNull,
        status: base.hasCandles
            ? MarketDataStatus.stale
            : MarketDataStatus.error,
      );
    }
    final List<Candle> series = _merger.mergeHistory(
      _seriesForInterval(base.candles, interval),
      sourced.value,
    );
    final MarketState merged = base.copyWith(
      candles: series,
      activeCandle: _activeOf(series, interval),
      candleProvenance: sourced.provenance,
      candleAsOf: sourced.asOf ?? _clock.now(),
      isRefreshing: false,
      clearFailure: true,
    );
    return merged.copyWith(status: _statusFrom(merged));
  }

  MarketState _withTrades(MarketState base) => base.copyWith(
    trades: _collector.trades,
    tradesProvenance: DataProvenance.live,
    tradesAsOf: _clock.now(),
    omittedTradeCount: _omittedTradeCount,
    status: _liveStatus(base),
    clearFailure: true,
  );

  /// Records the roster so the screen can tell "unknown symbol" from "not loaded
  /// yet". A failed roster load deliberately leaves the flag false.
  Future<void> _loadRoster(Emitter<MarketState> emit) async {
    final Result<Sourced<List<MarketInfo>>> result = await _summaries
        .loadMarkets();
    if (isClosed) return;
    final Sourced<List<MarketInfo>>? sourced = result.valueOrNull;
    if (sourced == null) return;
    emit(state.copyWith(markets: sourced.value, hasLoadedMarkets: true));
  }

  /// Rebinds the session to the current symbol and interval after a symbol
  /// switch or an interval change. A failure here is a degraded session, not a
  /// crash: it is logged and the data stays on screen, because no exception may
  /// reach a widget.
  Future<void> _resubscribe(
    CandleInterval interval,
    Emitter<MarketState> emit,
  ) async {
    try {
      await _stream.subscribe(
        SubscriptionSpec(
          symbol: _symbol,
          interval: interval,
          channels: Channel.defaults,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (isClosed) return;
      AppLogger.error(
        LogEvents.wsDisconnected,
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{
          LogFields.component: LogComponents.session,
          LogFields.symbol: _symbol,
          LogFields.interval: interval.wire,
          LogFields.reason: 'subscribe_failed',
        },
      );
    }
  }

  /// A frame arrived on the stream, so the layer is live unless an interval
  /// switch is still settling.
  MarketDataStatus _liveStatus(MarketState base) =>
      base.isRefreshing ? MarketDataStatus.refreshing : MarketDataStatus.live;

  /// Roll-up status after a cold start or a completed swap.
  MarketDataStatus _statusFrom(MarketState next) {
    final bool hasAny =
        next.hasCandles ||
        next.bookSnapshot != null ||
        next.summary != null ||
        next.trades.isNotEmpty;
    if (!hasAny) {
      return next.failure != null
          ? MarketDataStatus.error
          : MarketDataStatus.empty;
    }
    // `live` requires at least one payload that came off the wire in this
    // session. Cached and stale payloads never qualify.
    final bool anyLive =
        next.candleProvenance == DataProvenance.live ||
        next.tradesProvenance == DataProvenance.live ||
        next.bookProvenance == DataProvenance.live;
    return anyLive ? MarketDataStatus.live : MarketDataStatus.stale;
  }

  /// Demotes live provenance to stale so a dropped socket is visible per
  /// section. Never promotes: cached and stale values are left alone.
  MarketState _demoteLiveToStale(MarketState base) => base.copyWith(
    candleProvenance: base.candleProvenance == DataProvenance.live
        ? DataProvenance.stale
        : base.candleProvenance,
    tradesProvenance: base.tradesProvenance == DataProvenance.live
        ? DataProvenance.stale
        : base.tradesProvenance,
    bookProvenance: base.bookProvenance == DataProvenance.live
        ? DataProvenance.stale
        : base.bookProvenance,
  );

  /// The bucket still forming, or `null` when the newest bucket is closed.
  Candle? _activeOf(List<Candle> series, CandleInterval interval) {
    if (series.isEmpty) return null;
    final Candle last = series.last;
    if (last.interval != interval || last.closed) return null;
    return last;
  }

  /// Drops candles belonging to an interval the user has left.
  ///
  /// Allocates only when a foreign interval is actually present, so the 10 Hz
  /// candle path stays allocation-free in the steady state.
  List<Candle> _seriesForInterval(
    List<Candle> candles,
    CandleInterval interval,
  ) {
    for (final Candle candle in candles) {
      if (candle.interval != interval) {
        return <Candle>[
          for (final Candle candidate in candles)
            if (candidate.interval == interval) candidate,
        ];
      }
    }
    return candles;
  }

  void _logStaleHistory(int requestId, CandleInterval interval) {
    // The guard has already incremented stale_history_responses_total; logging
    // here is the human-readable half of the same fact.
    AppLogger.warn(
      LogEvents.historyResponseStale,
      fields: <String, Object?>{
        LogFields.component: LogComponents.candle,
        LogFields.symbol: _symbol,
        LogFields.interval: interval.wire,
        LogFields.correlationId: 'history_$requestId',
      },
    );
  }

  void _onServerMessage(ServerMessage message) {
    // Only market-facing frames become events; `ping`, `welcome`, book frames
    // and errors belong to other blocs, and re-publishing them here would
    // duplicate their handling.
    if (message is CandleUpdateMessage) {
      add(MarketCandleUpdateReceived(message));
    } else if (message is CandleClosedMessage) {
      add(MarketCandleClosedReceived(message));
    } else if (message is TradeMessage) {
      add(MarketTradeReceived(message));
    } else if (message is TradeBatchMessage) {
      add(MarketTradeBatchReceived(message));
    } else if (message is MarketSummaryMessage) {
      add(MarketSummaryReceived(message));
    } else if (message is MarketStatusMessage) {
      add(MarketStatusReceived(message.status));
    }
  }

  void _onFailure(AppFailure failure) => add(MarketStreamFailed(failure));

  @override
  Future<void> close() async {
    // after close there must be no live subscription to the stream, or a
    // disposed bloc would keep mutating state from a socket it no longer owns.
    await _messages.cancel();
    await _failures.cancel();
    _guard.reset();
    return super.close();
  }
}
