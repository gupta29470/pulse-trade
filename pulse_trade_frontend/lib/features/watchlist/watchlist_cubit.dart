import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_summary_repository.dart';
import 'package:pulse_trade_frontend/domain/repositories/watchlist_storage.dart';
import 'package:pulse_trade_frontend/features/watchlist/watchlist_state.dart';

/// Owns the watchlist: order, favourites, pin and the rendered rows.
///
/// The screen is deliberately thin: this cubit reads the persisted
/// order and the backend roster, and derives nothing the backend can compute —
/// every row's latest price and 24h change arrive as values on the roster, which
/// a poll re-reads for the whole list.
///
/// **Failure contract.** No storage or network failure ever escapes this cubit
/// as an exception. A failed *read* leaves the default list in place; a failed
/// *write* first restores the value the user was looking at and then emits a
/// state carrying [WatchlistState.failure] so the page can explain the rollback.
final class WatchlistCubit extends Cubit<WatchlistState> {
  /// Creates the cubit.
  ///
  /// [marketStream] is optional so the watchlist keeps working on a session whose
  /// socket never came up; when it is present, incoming `market_summary` frames
  /// keep the subscribed row current between REST reads.
  WatchlistCubit({
    required this.storage,
    required this.summaries,
    this.marketStream,
    this.metrics,
  }) : super(WatchlistState.initial) {
    final MarketStreamRepository? source = marketStream;
    if (source != null) {
      _subscription = source.messages.listen(_onServerMessage);
    }
  }

  /// Live and cached reads of the market roster.
  final MarketSummaryRepository summaries;

  /// The persisted order, favourites and pin.
  final WatchlistStorage storage;

  /// The socket, when one is available. Optional because the watchlist is
  /// readable offline and must not depend on a connected session.
  final MarketStreamRepository? marketStream;

  /// On-device counters, so a storage failure is observable in diagnostics
  /// rather than only in a SnackBar.
  final OnDeviceMetrics? metrics;

  StreamSubscription<ServerMessage>? _subscription;

  /// The order as it existed before the most recent destructive action, so
  /// [undoRemove] can restore exactly what the user had.
  List<WatchlistEntry>? _beforeRemoval;

  /// The rows as they were last written successfully, used to roll a failed
  /// write back to the last persisted order rather than to a guess.
  List<WatchlistEntry> _lastPersisted = <WatchlistEntry>[];

  /// The first read failure seen while loading, surfaced once the roster has
  /// been read so one broken preference key cannot blank the whole screen.
  AppFailure? _pendingReadFailure;

  /// True while a price poll is in flight. The next tick is dropped rather than
  /// queued, so a slow read can never stack requests or apply an older answer
  /// after a newer one.
  bool _pollInFlight = false;

  /// Reads the persisted order, favourites and pin, then the market roster, and
  /// builds the rows.
  ///
  /// Any symbol in the stored order that no longer exists in the roster is
  /// dropped, and any roster symbol missing from the stored order is appended in
  /// roster order — so an upgrade that adds a market shows it without discarding
  /// the user's arrangement. Each row's price and 24h change come straight from
  /// the roster the backend just sent, so a cached read is labelled cached rather
  /// than being promoted to a live quote.
  Future<void> load() async {
    emit(state.copyWith(isLoading: true, clearFailure: true));

    final List<String> order = await _loadOrder();
    final Set<String> favourites = await _loadFavourites();
    final String? pinned = await _loadPinned();

    final Result<Sourced<List<MarketInfo>>> roster = await summaries
        .loadMarkets();
    final AppFailure? rosterFailure = roster.failureOrNull;
    if (rosterFailure != null) {
      emit(
        state.copyWith(
          isLoading: false,
          marketsLoaded: true,
          failure: _pendingReadFailure ?? rosterFailure,
        ),
      );
      return;
    }

    final Sourced<List<MarketInfo>>? sourcedRoster = roster.valueOrNull;
    final List<MarketInfo> markets =
        sourcedRoster?.value ?? const <MarketInfo>[];

    // Reconcile the stored order with the roster without losing either side:
    // the user's order first, then anything the backend added, minus anything
    // the backend removed.
    final Set<String> known = <String>{
      for (final MarketInfo market in markets) market.symbol,
    };
    final Set<String> stored = order.toSet();
    final List<MarketInfo> ordered = <MarketInfo>[
      for (final String symbol in order)
        if (known.contains(symbol)) _marketFor(markets, symbol),
      for (final MarketInfo market in markets)
        if (!stored.contains(market.symbol)) market,
    ];

    final List<WatchlistEntry> entries = <WatchlistEntry>[
      for (final MarketInfo market in ordered)
        _baseEntry(
          market,
          favourites: favourites,
          pinnedSymbol: pinned,
          provenance: sourcedRoster?.provenance,
          asOf: sourcedRoster?.asOf,
        ),
    ];
    _lastPersisted = entries;

    // `entries` is deliberately not emitted here: on a first load the list is
    // still empty so the page keeps its skeletons, and on a refresh the previous
    // rows stay on screen instead of blanking for the length of a REST call.
    emit(
      state.copyWith(
        favourites: favourites,
        pinnedSymbol: pinned,
        isLoading: true,
        marketsLoaded: true,
        failure: _pendingReadFailure,
        clearFailure: _pendingReadFailure == null,
      ),
    );

    emit(state.copyWith(entries: entries, isLoading: false));
  }

  /// Re-reads the market roster and folds every row's latest price and 24h
  /// change into the list.
  ///
  /// This is the poll's entry point: one read at a time, so a slow response
  /// cannot stack a second request behind it. A read that fails or is refused
  /// offline leaves the rows exactly as they were — the last known values stay
  /// on screen and no movement is invented.
  Future<void> refreshPrices() async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      final Result<Sourced<List<MarketInfo>>> result = await summaries
          .loadMarkets(forceRefresh: true);
      if (isClosed) return;
      final Sourced<List<MarketInfo>>? sourced = result.valueOrNull;
      if (sourced == null) return;

      final Map<String, MarketInfo> bySymbol = <String, MarketInfo>{
        for (final MarketInfo market in sourced.value) market.symbol: market,
      };

      var changed = false;
      final List<WatchlistEntry> next = <WatchlistEntry>[];
      for (final WatchlistEntry entry in state.entries) {
        final WatchlistEntry updated = _changedByMarket(
          entry,
          bySymbol[entry.symbol],
          sourced.provenance,
          sourced.asOf,
        );
        if (!identical(updated, entry)) changed = true;
        next.add(updated);
      }
      if (!changed) return;

      // `_lastPersisted` is deliberately left alone: it is the rollback target
      // for the persisted *order*, and a price refresh landing mid-drag must not
      // become the order a failed write restores.
      emit(state.copyWith(entries: next));
    } finally {
      _pollInFlight = false;
    }
  }

  /// Moves a row within the list, optimistically.
  ///
  /// Two call shapes are supported, because the page can show either the whole
  /// list or a filtered slice of it:
  ///
  /// * [reorder] uses raw list indices, matching `ReorderableListView`'s
  ///   callback and the index convention the reorder tests drive.
  /// * [reorderSymbol] moves one symbol to the position currently held by
  ///   another, which is how the page maps a drag in the favourites filter back
  ///   onto the full list without disturbing the rows the user cannot see.
  ///
  /// **Optimistic-update-then-rollback contract.** The new order is
  /// emitted *before* the write is attempted, because a drag that waited for
  /// disk before the row moved would feel broken. Flutter's
  /// `ReorderableListView` reports its new index in the pre-removal coordinate
  /// space, so an upward move is decremented once; the reordered list is then
  /// persisted with [WatchlistStorage.saveOrder]. If that write throws, the
  /// previously persisted list is restored and the emitted state carries an
  /// [AppFailure] so the page can show a SnackBar explaining why the order
  /// reverted. Neither method rethrows.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final List<WatchlistEntry> current = state.entries;
    if (oldIndex < 0 || oldIndex >= current.length) return;

    final int target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target == oldIndex) return;

    final List<WatchlistEntry> reordered = List<WatchlistEntry>.of(current);
    final WatchlistEntry moved = reordered.removeAt(oldIndex);
    reordered.insert(target.clamp(0, reordered.length), moved);
    await _commitOrder(reordered);
  }

  /// Moves [symbol] to sit where [before] currently sits, or to the end when
  /// [before] is null. Used by the page when a filter hides part of the list.
  Future<void> reorderSymbol(String symbol, {String? before}) async {
    final List<WatchlistEntry> current = state.entries;
    final int from = current.indexWhere(
      (WatchlistEntry entry) => entry.symbol == symbol,
    );
    if (from < 0) return;

    final List<WatchlistEntry> reordered = List<WatchlistEntry>.of(current);
    final WatchlistEntry moved = reordered.removeAt(from);

    if (before == null) {
      reordered.add(moved);
    } else {
      final int target = reordered.indexWhere(
        (WatchlistEntry entry) => entry.symbol == before,
      );
      reordered.insert(target < 0 ? reordered.length : target, moved);
    }

    var unchanged = reordered.length == current.length;
    if (unchanged) {
      for (var i = 0; i < reordered.length; i++) {
        if (reordered[i].symbol != current[i].symbol) {
          unchanged = false;
          break;
        }
      }
    }
    if (unchanged) return;
    await _commitOrder(reordered);
  }

  /// Emits [reordered], then persists it; on failure restores the last
  /// successfully persisted order and reports the failure in the state.
  Future<void> _commitOrder(List<WatchlistEntry> reordered) async {
    emit(
      state.copyWith(
        entries: reordered,
        isDragging: false,
        clearDragIndex: true,
        clearFailure: true,
      ),
    );

    final Object? failure = await _persistOrder(reordered);
    if (failure == null) {
      _lastPersisted = reordered;
      return;
    }
    _reportStorageFailure(failure, 'watchlist_order_save_failed');
    emit(
      state.copyWith(
        entries: _lastPersisted,
        failure: _asFailure(failure, 'The new order could not be saved'),
      ),
    );
  }

  /// Removes [symbol] after persisting the shorter order.
  Future<void> remove(String symbol) async {
    if (_locate(symbol) == null) return;

    final List<WatchlistEntry> previous = List<WatchlistEntry>.of(
      state.entries,
    );
    final List<WatchlistEntry> next = List<WatchlistEntry>.of(state.entries)
      ..removeWhere((WatchlistEntry entry) => entry.symbol == symbol);

    emit(state.copyWith(entries: next, clearFailure: true));
    final Object? failure = await _persistOrder(next);
    if (failure == null) {
      _beforeRemoval = previous;
      _lastPersisted = next;
      return;
    }
    _reportStorageFailure(failure, 'watchlist_remove_save_failed');
    emit(
      state.copyWith(
        entries: previous,
        failure: _asFailure(failure, 'The market could not be removed'),
      ),
    );
  }

  /// Restores the list as it was before the most recent [remove].
  ///
  /// The undo is persisted too: restoring the row on screen but not on disk
  /// would silently lose it at the next cold start.
  Future<void> undoRemove() async {
    final List<WatchlistEntry>? previous = _beforeRemoval;
    if (previous == null) return;

    emit(state.copyWith(entries: previous, clearFailure: true));
    final Object? failure = await _persistOrder(previous);
    if (failure == null) {
      _beforeRemoval = null;
      _lastPersisted = previous;
      return;
    }
    _reportStorageFailure(failure, 'watchlist_undo_save_failed');
    emit(
      state.copyWith(
        entries: _lastPersisted,
        failure: _asFailure(failure, 'The undo could not be saved'),
      ),
    );
  }

  /// Pins [symbol] to the top of the list and persists the choice.
  Future<void> pin(String symbol) async {
    final String? previous = state.pinnedSymbol;
    emit(state.copyWith(pinnedSymbol: symbol, clearFailure: true));
    try {
      await storage.savePinned(symbol);
      _applyPinMarkers(symbol);
    } on Object catch (error) {
      _reportStorageFailure(error, 'watchlist_pin_save_failed');
      emit(
        state.copyWith(
          pinnedSymbol: previous,
          failure: _asFailure(error, 'The pin could not be saved'),
        ),
      );
    }
  }

  /// Clears the pin and persists the choice.
  Future<void> unpin() async {
    final String? previous = state.pinnedSymbol;
    emit(state.copyWith(clearPin: true, clearFailure: true));
    try {
      await storage.savePinned(null);
      _applyPinMarkers(null);
    } on Object catch (error) {
      _reportStorageFailure(error, 'watchlist_pin_save_failed');
      emit(
        state.copyWith(
          pinnedSymbol: previous,
          failure: _asFailure(error, 'The pin could not be cleared'),
        ),
      );
    }
  }

  /// Adds or removes [symbol] from the favourites and persists the set.
  ///
  /// The favourite set is persisted separately from the order so starring a row
  /// can never disturb the arrangement.
  Future<void> toggleFavourite(String symbol) async {
    final Set<String> previous = state.favourites;
    final Set<String> next = <String>{...previous};
    if (!next.remove(symbol)) {
      next.add(symbol);
    }

    emit(
      state.copyWith(
        favourites: next,
        entries: _markFavourites(next),
        clearFailure: true,
      ),
    );
    try {
      await storage.saveFavourites(next);
    } on Object catch (error) {
      _reportStorageFailure(error, 'watchlist_favourite_save_failed');
      emit(
        state.copyWith(
          favourites: previous,
          entries: _markFavourites(previous),
          failure: _asFailure(error, 'The favourite could not be saved'),
        ),
      );
    }
  }

  /// Projects one favourite set onto the rows, so a row's star and the
  /// favourites filter agree with the set the app actually persisted.
  List<WatchlistEntry> _markFavourites(Set<String> favourites) =>
      <WatchlistEntry>[
        for (final WatchlistEntry entry in state.entries)
          entry.copyWith(isFavourite: favourites.contains(entry.symbol)),
      ];

  /// Selects a filter chip. Purely presentational, so nothing is persisted.
  void setFilter(WatchlistFilter filter) {
    if (filter == state.filter) return;
    emit(state.copyWith(filter: filter));
  }

  /// Records that a drag started or ended, so the page can show the
  /// `Position #n of m` overlay.
  void setDragging({required bool isDragging, int? index}) {
    emit(
      state.copyWith(
        isDragging: isDragging,
        dragIndex: index,
        clearDragIndex: index == null,
      ),
    );
  }

  /// Clears the last failure once the page has shown it, so one rollback
  /// produces exactly one SnackBar.
  void acknowledgeFailure() {
    if (state.failure == null) return;
    emit(state.copyWith(clearFailure: true));
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    return super.close();
  }

  // ---------------------------------------------------------------------------
  // Roster → rows
  // ---------------------------------------------------------------------------

  /// The first roster row for [symbol]. Only symbols already known to be in
  /// [markets] are passed in, so the fallback is defensive; it keeps this a
  /// total function over the roster.
  MarketInfo _marketFor(List<MarketInfo> markets, String symbol) {
    for (final MarketInfo market in markets) {
      if (market.symbol == symbol) return market;
    }
    return markets.first;
  }

  /// Projects one roster row onto a watchlist row.
  WatchlistEntry _baseEntry(
    MarketInfo market, {
    required Set<String> favourites,
    required String? pinnedSymbol,
    required DataProvenance? provenance,
    required DateTime? asOf,
  }) {
    return WatchlistEntry(
      symbol: market.symbol,
      display: market.display,
      name: market.name,
      glyph: market.glyph,
      price: market.lastPrice,
      changeBasisPoints: market.changeBasisPoints,
      isFavourite: favourites.contains(market.symbol),
      isPinned: pinnedSymbol == market.symbol,
      provenance: provenance,
      asOf: asOf,
    );
  }

  /// Applies one roster row's values to one watchlist row, returning the same
  /// instance when nothing changed so an unchanged poll emits nothing.
  WatchlistEntry _changedByMarket(
    WatchlistEntry entry,
    MarketInfo? market,
    DataProvenance provenance,
    DateTime? asOf,
  ) {
    if (market == null) return entry;
    final WatchlistEntry updated = entry.copyWith(
      price: market.lastPrice,
      changeBasisPoints: market.changeBasisPoints,
      provenance: provenance,
      asOf: asOf,
    );
    return updated == entry ? entry : updated;
  }

  // ---------------------------------------------------------------------------
  // Server frames
  // ---------------------------------------------------------------------------

  /// Routes an incoming frame to the one handler this cubit owns.
  ///
  /// Summary frames are the only thing the watchlist consumes; every other frame
  /// belongs to another bloc, so an unknown type is ignored rather than guessed
  /// at.
  void _onServerMessage(ServerMessage message) {
    switch (message) {
      case MarketSummaryMessage(:final MarketSummary summary):
        _applySummaryMessage(summary);
      default:
        return;
    }
  }

  /// Updates exactly one row from a live summary frame, with no REST call.
  ///
  /// The socket only carries the symbol the session is bound to, so this is a
  /// fast path for that row; the other rows are kept current by [refreshPrices].
  void _applySummaryMessage(MarketSummary summary) {
    var changed = false;
    final List<WatchlistEntry> next = <WatchlistEntry>[
      for (final WatchlistEntry entry in state.entries)
        if (entry.symbol == summary.symbol)
          _changedBySummary(entry, summary)
        else
          entry,
    ];
    for (var i = 0; i < next.length; i++) {
      if (next[i] != state.entries[i]) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    _lastPersisted = next;
    emit(state.copyWith(entries: next));
  }

  /// Applies a live frame's values to one row, marking the provenance live.
  WatchlistEntry _changedBySummary(
    WatchlistEntry entry,
    MarketSummary summary,
  ) {
    return entry.copyWith(
      price: summary.last,
      changeBasisPoints: summary.changeBasisPoints,
      provenance: DataProvenance.live,
      asOf: summary.updatedAt,
    );
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers
  // ---------------------------------------------------------------------------

  /// Persists the order of [entries]. Returns `null` on success, or the thrown
  /// object so the caller can decide how to explain it.
  Future<Object?> _persistOrder(List<WatchlistEntry> entries) async {
    try {
      await storage.saveOrder(<String>[
        for (final WatchlistEntry entry in entries) entry.symbol,
      ]);
      return null;
    } on Object catch (error) {
      return error;
    }
  }

  /// Re-marks exactly one entry as pinned, so pin/unpin is visible without
  /// rebuilding the whole list from scratch.
  void _applyPinMarkers(String? pinnedSymbol) {
    emit(
      state.copyWith(
        entries: <WatchlistEntry>[
          for (final WatchlistEntry entry in state.entries)
            entry.copyWith(isPinned: entry.symbol == pinnedSymbol),
        ],
      ),
    );
  }

  /// Finds an entry by symbol, returning `null` when it is gone. A missing row
  /// is not an error worth interrupting the user for — the swipe has already
  /// been applied to a stale list.
  WatchlistEntry? _locate(String symbol) {
    for (final WatchlistEntry entry in state.entries) {
      if (entry.symbol == symbol) return entry;
    }
    return null;
  }

  /// Reads the persisted order, tolerating a broken preference store.
  Future<List<String>> _loadOrder() async {
    try {
      return await storage.loadOrder();
    } on Object catch (error) {
      _pendingReadFailure ??= _asFailure(
        error,
        'The saved watchlist order was unreadable',
      );
      return const <String>[];
    }
  }

  /// Reads the persisted favourites, tolerating a broken preference store.
  Future<Set<String>> _loadFavourites() async {
    try {
      return await storage.loadFavourites();
    } on Object catch (error) {
      _pendingReadFailure ??= _asFailure(
        error,
        'The saved favourites were unreadable',
      );
      return const <String>{};
    }
  }

  /// Reads the persisted pin, tolerating a broken preference store.
  Future<String?> _loadPinned() async {
    try {
      return await storage.loadPinned();
    } on Object catch (error) {
      _pendingReadFailure ??= _asFailure(error, 'The saved pin was unreadable');
      return null;
    }
  }

  /// Converts an arbitrary thrown object into the typed failure the UI speaks,
  /// keeping an [AppFailure] intact because it already carries the right copy.
  AppFailure _asFailure(Object error, String fallbackMessage) {
    if (error is AppFailure) return error;
    return CacheFailure(message: fallbackMessage, cause: error);
  }

  /// Counts and logs a failed storage write.
  ///
  /// Storage is a device-local concern, so a failure is shown to the user once
  /// and recorded in diagnostics — it is never rethrown into the widget tree.
  void _reportStorageFailure(Object error, String slug) {
    metrics?.increment(MetricNames.cacheWriteFailuresTotal);
    AppLogger.warn(
      slug,
      fields: <String, Object?>{
        LogFields.component: LogComponents.cache,
        LogFields.error: error.toString(),
      },
    );
  }
}
