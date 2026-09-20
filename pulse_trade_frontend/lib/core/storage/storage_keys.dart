/// Every `shared_preferences` key this app is allowed to write.
///
/// Call sites pass the bare logical key to `AppStorage`, which prefixes it with
/// [namespace]; keeping the constants here means a rename is a single edit, and
/// a typo in a raw string literal cannot silently read a different value. The
/// constants are intentionally `dotted.lowerCamel` and are never used as the
/// physical key on their own.
abstract final class StorageKeys {
  const StorageKeys._();

  /// Version prefix applied to every physical key.
  ///
  /// Bumping it abandons the previous generation of values atomically: a
  /// migration reads the old namespace, writes the new one and removes the old
  /// keys, so a half-migrated install can never be read as valid.
  static const String namespace = 'pulsetrade.v1';

  /// JSON array of symbols in the user's watchlist order.
  static const String watchlistOrder = 'watchlist.order';

  /// JSON array of symbols the user starred.
  static const String watchlistFavourites = 'watchlist.favourites';

  /// JSON array of symbols pinned to the top of the watchlist.
  static const String watchlistPinned = 'watchlist.pinned';

  /// Optional gateway base URL override.
  ///
  /// Read once at startup and otherwise never written, so an install that
  /// carries a value keeps pointing at that gateway; a fresh install uses the
  /// compile-time default.
  static const String backendBaseUrl = 'settings.backendBaseUrl';
}
