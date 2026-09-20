import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';

/// Which slice of the watchlist the filter chips are showing.
enum WatchlistFilter {
  /// Every row.
  all,

  /// Only the symbols the user starred.
  favourites,
}

/// One renderable watchlist row.
///
/// This is a presentation-layer projection: the market roster is backend-owned
/// (`MarketInfo`), and this type exists only so the row widget receives one flat
/// value instead of reaching into a repository.
final class WatchlistEntry extends Equatable {
  /// Creates a row.
  const WatchlistEntry({
    required this.symbol,
    required this.display,
    required this.name,
    required this.glyph,
    this.price,
    this.changeBasisPoints,
    this.isFavourite = false,
    this.isPinned = false,
    this.provenance,
    this.asOf,
  });

  /// Canonical symbol id, e.g. `BTCUSDT`.
  final String symbol;

  /// Display pair, e.g. `BTC/USDT`.
  final String display;

  /// Human asset name, e.g. `Bitcoin`.
  final String name;

  /// Single-character asset glyph used in the row's avatar.
  final String glyph;

  /// Latest traded price for this market. `null` until a first price is known;
  /// the row renders a dash rather than a fabricated number.
  final Money? price;

  /// 24h change in basis points, computed by the backend. Percentages are
  /// derived from this integer, never from a `double` on the wire.
  final int? changeBasisPoints;

  /// True when the user starred this symbol.
  final bool isFavourite;

  /// True when this symbol is the pinned "top of the list" row.
  final bool isPinned;

  /// Where [price] came from, so the row can tag cached data honestly.
  final DataProvenance? provenance;

  /// When the backend produced [price]. `null` for a live value that arrived
  /// without a timestamp.
  final DateTime? asOf;

  /// True when the row has a price to show.
  bool get hasPrice => price != null;

  /// The row's current change in basis points, when one is known.
  int get basisPoints => changeBasisPoints ?? 0;

  /// Copy with the mutable presentation fields.
  WatchlistEntry copyWith({
    Money? price,
    int? changeBasisPoints,
    bool? isFavourite,
    bool? isPinned,
    DataProvenance? provenance,
    DateTime? asOf,
  }) {
    return WatchlistEntry(
      symbol: symbol,
      display: display,
      name: name,
      glyph: glyph,
      price: price ?? this.price,
      changeBasisPoints: changeBasisPoints ?? this.changeBasisPoints,
      isFavourite: isFavourite ?? this.isFavourite,
      isPinned: isPinned ?? this.isPinned,
      provenance: provenance ?? this.provenance,
      asOf: asOf ?? this.asOf,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    symbol,
    display,
    name,
    glyph,
    price,
    changeBasisPoints,
    isFavourite,
    isPinned,
    provenance,
    asOf,
  ];

  @override
  String toString() => 'WatchlistEntry($symbol, price=$price)';
}

/// Everything the watchlist screen renders.
final class WatchlistState extends Equatable {
  /// Creates a state. Prefer [WatchlistState.initial] for the first frame.
  const WatchlistState({
    required this.entries,
    required this.favourites,
    required this.pinnedSymbol,
    required this.filter,
    required this.isLoading,
    required this.isDragging,
    required this.dragIndex,
    required this.failure,
    required this.marketsLoaded,
  });

  /// The state before anything has been read from disk or the network.
  static const WatchlistState initial = WatchlistState(
    entries: <WatchlistEntry>[],
    favourites: <String>{},
    pinnedSymbol: null,
    filter: WatchlistFilter.all,
    isLoading: true,
    isDragging: false,
    dragIndex: null,
    failure: null,
    marketsLoaded: false,
  );

  /// Rows in the user's persisted order, before the filter is applied.
  final List<WatchlistEntry> entries;

  /// Symbols the user starred, used by the app-bar star and the rows.
  final Set<String> favourites;

  /// The symbol pinned to the top, if any.
  final String? pinnedSymbol;

  /// The active filter chip.
  final WatchlistFilter filter;

  /// True while the roster or the summaries are still loading.
  final bool isLoading;

  /// True while a row is being dragged, which switches the page into its
  /// reorder presentation.
  final bool isDragging;

  /// The index of the row being dragged, in the *visible* list, so the drag
  /// overlay can read `Position #n of m`.
  final int? dragIndex;

  /// The last failure, surfaced by the page as a SnackBar explaining why an
  /// order was restored. Never thrown out of the cubit.
  final AppFailure? failure;

  /// True once the market roster has been read, successfully or not. Lets the
  /// page distinguish "still loading" from "nothing to show".
  final bool marketsLoaded;

  /// [entries] narrowed by [filter], in list order.
  ///
  /// Computed here rather than in the widget so the filter has exactly one
  /// implementation and the row count in the footer always agrees with the
  /// rows on screen.
  List<WatchlistEntry> get visibleEntries {
    switch (filter) {
      case WatchlistFilter.all:
        return entries;
      case WatchlistFilter.favourites:
        return <WatchlistEntry>[
          for (final WatchlistEntry entry in entries)
            if (entry.isFavourite) entry,
        ];
    }
  }

  /// How many rows survive the current filter.
  int get visibleCount => visibleEntries.length;

  /// How many rows the user starred. Favourites are independent of the filter.
  int get favouriteCount => favourites.length;

  /// True when the roster loaded and contains no rows at all.
  bool get isEmpty => marketsLoaded && entries.isEmpty;

  /// Copy with the next frame's values.
  ///
  /// [pinnedSymbol] cannot be cleared with `null` alone because `null` also
  /// means "leave it alone"; pass `clearPin: true` to unpin. The same shape is
  /// used for [failure] with `clearFailure`, so a SnackBar is shown once and not
  /// re-shown on the next rebuild.
  WatchlistState copyWith({
    List<WatchlistEntry>? entries,
    Set<String>? favourites,
    String? pinnedSymbol,
    bool clearPin = false,
    WatchlistFilter? filter,
    bool? isLoading,
    bool? isDragging,
    int? dragIndex,
    bool clearDragIndex = false,
    AppFailure? failure,
    bool clearFailure = false,
    bool? marketsLoaded,
  }) {
    return WatchlistState(
      entries: entries ?? this.entries,
      favourites: favourites ?? this.favourites,
      pinnedSymbol: clearPin ? null : (pinnedSymbol ?? this.pinnedSymbol),
      filter: filter ?? this.filter,
      isLoading: isLoading ?? this.isLoading,
      isDragging: isDragging ?? this.isDragging,
      dragIndex: clearDragIndex ? null : (dragIndex ?? this.dragIndex),
      failure: clearFailure ? null : (failure ?? this.failure),
      marketsLoaded: marketsLoaded ?? this.marketsLoaded,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    entries,
    favourites,
    pinnedSymbol,
    filter,
    isLoading,
    isDragging,
    dragIndex,
    failure,
    marketsLoaded,
  ];

  @override
  String toString() =>
      'WatchlistState(${entries.length} rows, filter=${filter.name}, '
      'loading=$isLoading)';
}
