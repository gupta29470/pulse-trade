import 'package:pulse_trade_frontend/core/cache/cache_store.dart';

/// A [CacheStore] that routes each key to one of two backing tiers.
///
/// The cache defines two tiers with different limits: a small
/// `shared_preferences` tier (≤ 64 KB: the watchlist roster and other small
/// documents) and an 8 MB file tier (candles per interval, book images, trade
/// lists). A single [MarketCacheRepository] facade writes both, so the choice is
/// made here, once, by key family, instead of at every call site — a call site
/// that forgot the routing rule would silently put a 500-candle series into
/// `shared_preferences`.
final class TieredCacheStore implements CacheStore {
  /// Creates the router.
  ///
  /// [prefersPrefsTier] decides, per key, whether the small tier is used. The
  /// default keeps every key that is not a small document on the file tier.
  TieredCacheStore({
    required this._prefsTier,
    required this._fileTier,
    bool Function(String key)? prefersPrefsTier,
  }) : _prefersPrefsTier = prefersPrefsTier ?? defaultRouting;

  /// The small `shared_preferences` tier.
  final CacheStore _prefsTier;

  /// The 8 MB file tier.
  final CacheStore _fileTier;

  final bool Function(String key) _prefersPrefsTier;

  /// The default routing rule: the market roster is small and read often, so it
  /// lives in `shared_preferences`; every candle, book and trade payload goes to
  /// the file tier.
  static bool defaultRouting(String key) => key == 'markets';

  @override
  Future<CacheEntry<T>?> read<T>(
    String key,
    T Function(Map<String, dynamic>) decode,
  ) => _tierFor(key).read<T>(key, decode);

  @override
  Future<void> write<T>(
    String key,
    T value, {
    required Duration ttl,
    required Map<String, dynamic> Function(T) encode,
  }) => _tierFor(key).write<T>(key, value, ttl: ttl, encode: encode);

  @override
  Future<void> invalidate(String key) => _tierFor(key).invalidate(key);

  @override
  Future<void> clear() async {
    // Both tiers are cleared: a partial clear would leave a stale roster behind.
    await _prefsTier.clear();
    await _fileTier.clear();
  }

  @override
  Future<CacheStats> stats() async {
    final CacheStats prefs = await _prefsTier.stats();
    final CacheStats file = await _fileTier.stats();
    return CacheStats(
      entries: prefs.entries + file.entries,
      bytes: prefs.bytes + file.bytes,
      hits: prefs.hits + file.hits,
      misses: prefs.misses + file.misses,
      writes: prefs.writes + file.writes,
      writeFailures: prefs.writeFailures + file.writeFailures,
      evictions: prefs.evictions + file.evictions,
    );
  }

  CacheStore _tierFor(String key) =>
      _prefersPrefsTier(key) ? _prefsTier : _fileTier;
}
