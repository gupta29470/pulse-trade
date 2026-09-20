import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/channel.dart';
import 'package:pulse_trade_frontend/domain/entities/local_order_book.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/orderbook/order_book_synchronizer.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/order_book_repository.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_event.dart';
import 'package:pulse_trade_frontend/features/orderbook/order_book_state.dart';

/// Owns one market's order book: the state machine, the applied levels,
/// the top-N projection the UI renders.
///
/// Every sequencing decision — buffering during a snapshot, gap detection,
/// ordered draining, giving up after three attempts — lives in
/// [OrderBookSynchronizer], a pure class with an injected `Clock`. This file
/// performs only the effects that class returns (fetch an image, apply levels,
/// mirror a transition) and turns them into an immutable
/// [OrderBookStateModel]; that split is what keeps the unit tests
/// socket-free.
final class OrderBookBloc extends Bloc<OrderBookEvent, OrderBookStateModel> {
  /// Creates the bloc for [symbol].
  ///
  /// [clock] and [_metrics] are injected so tests get deterministic timestamps
  /// and per-test counters, and [depth] so the rendered depth is a construction
  /// decision rather than a magic number in a widget. The symbol follows a later
  /// [OrderBookStarted] that names one.
  OrderBookBloc({
    required this._repository,
    required this._stream,
    required String symbol,
    Clock? clock,
    this._metrics,
    int depth = 10,
  }) : _symbol = symbol,
       _clock = clock ?? SystemClock(),
       super(OrderBookStateModel.initial.copyWith(depth: depth)) {
    _book = LocalOrderBook(symbol: symbol, epoch: 0, appliedUpdateId: 0);
    _synchronizer = OrderBookSynchronizer(clock: _clock);
    on<OrderBookStarted>(_onStarted);
    on<OrderBookSnapshotReceived>(_onSnapshotReceived);
    on<OrderBookDeltaReceived>(_onDeltaReceived);
    on<OrderBookConnectionLost>(_onConnectionLost);
    on<OrderBookEpochReset>(_onEpochReset);
    on<OrderBookRetryRequested>(_onRetryRequested);
    on<OrderBookDepthChanged>(_onDepthChanged);
    on<OrderBookStreamFailed>(_onStreamFailed);
  }

  final OrderBookRepository _repository;
  final MarketStreamRepository _stream;

  /// The market this bloc currently describes; follows [OrderBookStarted].
  String _symbol;

  final Clock _clock;
  final OnDeviceMetrics? _metrics;

  late final OrderBookSynchronizer _synchronizer;

  /// The mutable book the synchronizer's `ApplyLevels` effects land on. Never
  /// handed to the UI: `state.top` is the immutable projection.
  late LocalOrderBook _book;

  StreamSubscription<ServerMessage>? _messageSubscription;
  StreamSubscription<AppFailure>? _failureSubscription;

  /// Bumped by every [OrderBookStarted], so a subscribe or a fetch that
  /// completes after a restart cannot write into the new session.
  int _generation = 0;

  /// Provenance and timestamp of the image being applied, consumed by the
  /// matching snapshot `ApplyLevels` so a cached image is labelled honestly.
  DataProvenance? _pendingProvenance;
  DateTime? _pendingAsOf;

  /// `serverTime` of the range being applied, used as `asOf` once it is live.
  DateTime? _deltaAsOf;

  /// REST provenance keyed by `updateId`, so two loads in flight cannot
  /// overwrite each other's label before their events are reduced.
  final Map<int, DataProvenance> _snapshotProvenance = <int, DataProvenance>{};

  /// `firstUpdateId` keyed by `lastUpdateId`, so the reported range start stays
  /// right when one drain applies several buffered ranges in a single turn.
  final Map<int, int> _rangeFirstUpdateId = <int, int>{};

  /// Caps for the two bookkeeping maps: they are diagnostics aids, and an
  /// unbounded map would be a slow leak in a 10 Hz stream.
  static const int _provenanceCap = 8;
  static const int _rangeCap = 64;

  /// The two fields every record from this bloc carries.
  Map<String, Object?> _fields([
    Map<String, Object?> extra = const <String, Object?>{},
  ]) => <String, Object?>{
    LogFields.component: LogComponents.orderbook,
    LogFields.symbol: _symbol,
    ...extra,
  };

  void _onStarted(OrderBookStarted event, Emitter<OrderBookStateModel> emit) {
    if (event.symbol != null) _symbol = event.symbol!;
    _generation++;
    final int generation = _generation;
    // The previous session's subscription is released before the new one
    // is issued, so a stale socket cannot keep feeding this bloc.
    unawaited(_cancelStreams());

    _book = LocalOrderBook(symbol: _symbol, epoch: 0, appliedUpdateId: 0);
    _pendingProvenance = null;
    _pendingAsOf = null;
    _deltaAsOf = null;
    _rangeFirstUpdateId.clear();
    emit(OrderBookStateModel.initial.copyWith(depth: state.depth));

    _bindStreams(generation);
    unawaited(_subscribe(generation));
    // `start` resets the sequencing state and asks for the first image; the
    // `RequestSnapshot` effect it returns is what triggers the repository call.
    _applyEffects(
      _synchronizer.start(epoch: _stream.welcome?.epoch ?? 0),
      emit,
    );
  }

  /// True while an image this bloc asked for is in flight because the book was known to
  /// be discontinuous — a gap, an epoch change, a buffer overflow.
  ///
  /// A recovery image must be installed even when it lands *behind* the locally applied
  /// update id, which is the normal case: the client keeps applying deltas while the REST
  /// fetch is in flight, so the answer is almost always older than what the socket has
  /// already delivered. Dropping it as stale was the bug — the levels the missed range
  /// would have removed stayed in the book for good, which showed up as a bid frozen
  /// above a market that had moved away from it.
  bool _recoveryPending = false;

  /// Attaches to the typed feed. The generation guard means a listener that was
  /// not cancelled in time cannot deliver a frame into the new session.
  void _bindStreams(int generation) {
    _messageSubscription = _stream.messages.listen(
      (ServerMessage message) {
        if (isClosed || generation != _generation) return;
        _onMessage(message);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (isClosed || generation != _generation) return;
        AppLogger.error(
          'order_book_stream_error',
          fields: _fields(),
          error: error,
          stackTrace: stackTrace,
        );
        add(
          OrderBookStreamFailed(
            NetworkFailure(message: 'The market feed stopped', cause: error),
          ),
        );
      },
    );
    _failureSubscription = _stream.failures.listen((AppFailure failure) {
      if (isClosed || generation != _generation) return;
      add(OrderBookStreamFailed(failure));
    });
  }

  /// Replaces the session subscription with the order-book channel only: the
  /// bloc asks for exactly what it renders.
  Future<void> _subscribe(int generation) async {
    try {
      await _stream.subscribe(
        SubscriptionSpec(
          symbol: _symbol,
          interval: CandleInterval.m1,
          channels: const <Channel>{Channel.orderBook},
        ),
      );
    } on Object catch (error, stackTrace) {
      // Nothing may throw into the widget tree: a failed subscribe is
      // reported as a typed failure event instead.
      AppLogger.error(
        'order_book_subscribe_failed',
        fields: _fields(),
        error: error,
        stackTrace: stackTrace,
      );
      if (isClosed || generation != _generation) return;
      add(
        OrderBookStreamFailed(
          NetworkFailure(
            message: 'Could not subscribe to the order-book channel',
            cause: error,
          ),
        ),
      );
    }
  }

  /// Translates one decoded frame into the single event that describes it. An
  /// `if` chain, so an unrelated frame is ignored rather than falling into a
  /// default that mutates something.
  void _onMessage(ServerMessage message) {
    // Switching markets leaves the previous subscription's frames in flight, and a
    // book is rebuilt from a snapshot while its update ids restart. Without this
    // check those late frames land on the new market's book, which showed up as one
    // market's bids priced against another market's asks.
    final String? market = message.marketSymbol;
    if (market != null && market != _symbol) return;
    if (message is OrderBookDeltaMessage) {
      add(OrderBookDeltaReceived(message));
      return;
    }
    if (message is OrderBookSnapshotMessage) {
      add(
        OrderBookSnapshotReceived(
          message.snapshot,
          fromCache: false,
          asOf: message.serverTime,
        ),
      );
      return;
    }
    if (message is GoodbyeMessage) {
      AppLogger.info(
        LogEvents.wsDisconnected,
        fields: _fields(<String, Object?>{LogFields.reason: message.reason}),
      );
      add(const OrderBookConnectionLost());
      return;
    }
    // Only a fatal error closes the socket; a non-fatal one belongs to another
    // section and must not freeze this book.
    if (message is ErrorMessage && message.fatal) {
      add(const OrderBookConnectionLost());
    }
  }

  void _onSnapshotReceived(
    OrderBookSnapshotReceived event,
    Emitter<OrderBookStateModel> emit,
  ) {
    final OrderBookState syncState = _synchronizer.state;
    final int applied = _synchronizer.appliedUpdateId;

    // A cached image may seed an empty book but must never rewind a book that
    // already holds live data.
    if (event.fromCache && syncState == OrderBookState.live) {
      AppLogger.debug(
        'order_book_cached_snapshot_dropped',
        fields: _fields(<String, Object?>{LogFields.updateId: applied}),
      );
      return;
    }
    // A REST image is taken outside the socket's ordering, so it can land after
    // the deltas it predates. Installing it would silently rewind the book and
    // make the next range look contiguous when it is not.
    final bool behind = applied > 0 && event.snapshot.updateId <= applied;
    final bool installed =
        syncState == OrderBookState.live ||
        syncState == OrderBookState.applying;
    if (behind && installed && !_recoveryPending) {
      AppLogger.debug(
        'order_book_stale_snapshot_dropped',
        fields: _fields(<String, Object?>{
          LogFields.updateId: event.snapshot.updateId,
        }),
      );
      return;
    }

    // Remember where the image came from so the `ApplyLevels` it produces can be
    // labelled cached/stale/live without guessing.
    _pendingProvenance = event.fromCache
        ? (_snapshotProvenance.remove(event.snapshot.updateId) ??
              DataProvenance.cached)
        : DataProvenance.live;
    _pendingAsOf = event.asOf ?? event.snapshot.serverTime;
    _pump(SnapshotArrived(event.snapshot), emit);
  }

  void _onDeltaReceived(
    OrderBookDeltaReceived event,
    Emitter<OrderBookStateModel> emit,
  ) {
    _deltaAsOf = event.delta.serverTime;
    _rangeFirstUpdateId[event.delta.lastUpdateId] = event.delta.firstUpdateId;
    if (_rangeFirstUpdateId.length > _rangeCap) {
      _rangeFirstUpdateId.remove(_rangeFirstUpdateId.keys.first);
    }
    _pump(DeltaArrived(event.delta), emit);
  }

  /// The socket dropped: freeze, never clear, so the last known liquidity stays
  /// on screen under a `STALE` tag.
  void _onConnectionLost(
    OrderBookConnectionLost event,
    Emitter<OrderBookStateModel> emit,
  ) {
    _pump(const ConnectionLost(), emit);
  }

  void _onEpochReset(
    OrderBookEpochReset event,
    Emitter<OrderBookStateModel> emit,
  ) {
    _pump(ResetEpoch(epoch: event.epoch), emit);
  }

  void _onRetryRequested(
    OrderBookRetryRequested event,
    Emitter<OrderBookStateModel> emit,
  ) {
    _pump(const RecoveryRetryRequested(), emit);
  }

  /// Re-projects at a new depth. No fetch and no resync: the applied book
  /// already holds the levels.
  void _onDepthChanged(
    OrderBookDepthChanged event,
    Emitter<OrderBookStateModel> emit,
  ) {
    if (event.depth == state.depth) return;
    emit(state.copyWith(depth: event.depth, top: _book.top(event.depth)));
  }

  void _onStreamFailed(
    OrderBookStreamFailed event,
    Emitter<OrderBookStateModel> emit,
  ) {
    _pump(const ConnectionLost(), emit);
    emit(state.copyWith(failure: event.failure));
  }

  void _pump(OrderBookInput input, Emitter<OrderBookStateModel> emit) {
    _applyEffects(_dispatch(input), emit);
  }

  /// Runs one input through the synchronizer, counts what it decided, then
  /// performs the effects in order.
  List<OrderBookEffect> _dispatch(OrderBookInput input) {
    final int gaps = _synchronizer.gapCount;
    final int duplicates = _synchronizer.duplicateCount;
    final int stale = _synchronizer.staleCount;
    final int recoveries = _synchronizer.recoveryCount;
    final List<OrderBookEffect> effects = _synchronizer.handle(input);

    // The synchronizer owns the truth; the registry is incremented by the
    // difference so a counter can never drift from it.
    _countMetric(MetricNames.gapsDetectedTotal, _synchronizer.gapCount - gaps);
    _countMetric(
      MetricNames.duplicateDeltasTotal,
      _synchronizer.duplicateCount - duplicates,
    );
    _countMetric(
      MetricNames.staleDeltasTotal,
      _synchronizer.staleCount - stale,
    );
    _countMetric(
      MetricNames.recoveriesTotal,
      _synchronizer.recoveryCount - recoveries,
    );

    if (_synchronizer.gapCount > gaps) {
      AppLogger.warn(
        LogEvents.bookGapDetected,
        fields: _fields(<String, Object?>{
          LogFields.updateId: _synchronizer.appliedUpdateId,
          LogFields.count: _synchronizer.gapCount,
        }),
      );
    }
    if (_synchronizer.duplicateCount > duplicates) {
      AppLogger.debug(
        LogEvents.bookDuplicateDelta,
        fields: _fields(<String, Object?>{
          LogFields.count: _synchronizer.duplicateCount,
        }),
      );
    }
    if (_synchronizer.staleCount > stale) {
      AppLogger.debug(
        LogEvents.bookStaleDelta,
        fields: _fields(<String, Object?>{
          LogFields.count: _synchronizer.staleCount,
        }),
      );
    }
    if (_synchronizer.recoveryCount > recoveries) {
      AppLogger.info(
        LogEvents.bookRecoveryCompleted,
        fields: _fields(<String, Object?>{
          LogFields.updateId: _synchronizer.appliedUpdateId,
        }),
      );
    }
    return effects;
  }

  void _applyEffects(
    List<OrderBookEffect> effects,
    Emitter<OrderBookStateModel> emit,
  ) {
    for (final OrderBookEffect effect in effects) {
      if (effect is ApplyLevels) {
        _applyLevels(effect, emit);
      } else if (effect is RequestSnapshot) {
        if (effect.reason != 'subscribe') {
          AppLogger.info(
            LogEvents.bookRecoveryStarted,
            fields: _fields(<String, Object?>{
              LogFields.reason: effect.reason,
              LogFields.count: effect.attempt,
            }),
          );
        }
        if (effect.reason != 'subscribe') {
          _recoveryPending = true;
        }
        unawaited(_loadSnapshot(effect, _generation));
      } else if (effect is OrderBookStateChanged) {
        _mirrorState(effect, emit);
      }
    }
  }

  /// Applies absolute levels and republishes the projection. A snapshot clears
  /// first: it is a complete image, and applying it over the existing levels
  /// would keep liquidity the engine no longer publishes.
  void _applyLevels(ApplyLevels effect, Emitter<OrderBookStateModel> emit) {
    final bool isSnapshot = effect.isSnapshot;
    if (isSnapshot) {
      _book.resetEpoch(_synchronizer.epoch);
    }
    _book.applyLevels(effect.bids, isBid: true);
    _book.applyLevels(effect.asks, isBid: false);
    _book.epoch = _synchronizer.epoch;
    _book.appliedUpdateId = effect.appliedUpdateId;

    final DateTime appliedAt = _clock.now();
    final int firstUpdateId = isSnapshot
        ? effect.appliedUpdateId
        : (_rangeFirstUpdateId[effect.appliedUpdateId] ??
              effect.appliedUpdateId);

    // Live data is the only thing that may promote the book to `LIVE`: a cached
    // image keeps its provenance until a live image or a live range lands.
    final DataProvenance provenance = isSnapshot
        ? (_pendingProvenance ?? DataProvenance.cached)
        : DataProvenance.live;
    final DateTime asOf = (isSnapshot ? _pendingAsOf : _deltaAsOf) ?? appliedAt;
    if (isSnapshot) {
      _pendingProvenance = null;
      _pendingAsOf = null;
    }

    emit(
      state.copyWith(
        // Recomputed on every mutation, so `build` never sorts or accumulates.
        top: _book.top(state.depth),
        epoch: _synchronizer.epoch,
        // The effect's own id, not the synchronizer's post-turn one: when a
        // snapshot drains several ranges in one turn, each emitted state must
        // describe the book as it stands after that effect.
        appliedUpdateId: effect.appliedUpdateId,
        lastAppliedFirstUpdateId: firstUpdateId,
        lastAppliedLastUpdateId: effect.appliedUpdateId,
        provenance: provenance,
        asOf: asOf,
        lastUpdatedAt: appliedAt,
      ),
    );
  }

  /// Mirrors a sequencing transition and the counters that explain it.
  void _mirrorState(
    OrderBookStateChanged effect,
    Emitter<OrderBookStateModel> emit,
  ) {
    final bool failed = effect.to == OrderBookState.error;
    if (failed) {
      AppLogger.error(
        LogEvents.bookRecoveryFailed,
        fields: _fields(<String, Object?>{
          LogFields.updateId: _synchronizer.appliedUpdateId,
          LogFields.count: _synchronizer.recoveryAttempts,
        }),
        error: const OrderBookSyncFailure(),
      );
    }
    emit(
      state.copyWith(
        syncState: effect.to,
        gapCount: _synchronizer.gapCount,
        duplicateCount: _synchronizer.duplicateCount,
        staleCount: _synchronizer.staleCount,
        recoveryCount: _synchronizer.recoveryCount,
        recoveryAttempts: _synchronizer.recoveryAttempts,
        failure: failed ? const OrderBookSyncFailure() : null,
      ),
    );
  }

  /// Asks the repository for an image and feeds the answer back as events.
  /// Recovery forces a refresh: the cache entry just proven discontinuous must
  /// not be allowed to answer the resync.
  Future<void> _loadSnapshot(RequestSnapshot request, int generation) async {
    final bool forceRefresh = request.reason != 'subscribe';
    final Result<Sourced<OrderBookSnapshot>> result = await _repository
        .loadSnapshot(_symbol, forceRefresh: forceRefresh);
    if (isClosed || generation != _generation) return;

    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      AppLogger.warn(
        'order_book_snapshot_failed',
        fields: _fields(<String, Object?>{
          LogFields.reason: request.reason,
          LogFields.errorCode: failure.code ?? failure.runtimeType.toString(),
          LogFields.error: failure.message,
        }),
      );
      _recoveryPending = false;
      add(OrderBookStreamFailed(failure));
      return;
    }

    final Sourced<OrderBookSnapshot>? sourced = result.valueOrNull;
    if (sourced == null) return;
    _recoveryPending = false;
    _snapshotProvenance[sourced.value.updateId] = sourced.provenance;
    if (_snapshotProvenance.length > _provenanceCap) {
      _snapshotProvenance.remove(_snapshotProvenance.keys.first);
    }
    add(
      OrderBookSnapshotReceived(
        sourced.value,
        fromCache: sourced.isFromCache,
        asOf: sourced.asOf,
      ),
    );
  }

  void _countMetric(String name, int delta) {
    if (delta <= 0) return;
    _metrics?.increment(name, by: delta);
  }

  /// Cancels both listeners. `cancel` is invoked through the fields so the
  /// release is explicit, and the fields are cleared before the first `await` so
  /// a concurrent restart cannot bind a listener this call would then null out.
  Future<void> _cancelStreams() async {
    final Future<void>? messages = _messageSubscription?.cancel();
    final Future<void>? failures = _failureSubscription?.cancel();
    _messageSubscription = null;
    _failureSubscription = null;
    if (messages != null) await messages;
    if (failures != null) await failures;
  }

  @override
  Future<void> close() async {
    // Every subscription this bloc created is released here, so a closed
    // bloc can never be resurrected by a late frame.
    await _cancelStreams();
    return super.close();
  }
}
