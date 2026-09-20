/// Local persistence for the watchlist order, favourites and pin.
///
/// A corrupt or unknown-version payload falls back to defaults and is logged;
/// it is never fatal. Writes are allowed to fail so the cubit can
/// roll back an optimistic reorder.
abstract interface class WatchlistStorage {
  /// The persisted symbol order, or an empty list when nothing is stored.
  Future<List<String>> loadOrder();

  /// Persists the symbol order. Throws on failure so the caller can roll back.
  Future<void> saveOrder(List<String> symbols);

  /// Persisted favourite symbols.
  Future<Set<String>> loadFavourites();

  /// Persists the favourite set.
  Future<void> saveFavourites(Set<String> symbols);

  /// The pinned symbol, if any.
  Future<String?> loadPinned();

  /// Persists the pinned symbol; `null` clears it.
  Future<void> savePinned(String? symbol);
}
