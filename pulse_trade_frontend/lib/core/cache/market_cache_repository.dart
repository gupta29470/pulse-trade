import 'package:pulse_trade_frontend/core/cache/cache_codecs.dart';
import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';

/// Domain-level facade over a [CacheStore].
///
/// Owns the key vocabulary and the TTLs, so no repository or bloc has to know
/// which tier holds what. Every read returns the entry with its `writtenAt` and
/// `ttl` intact: **TTL expiry marks data `STALE`, it never hides it**, and a
/// stale entry is still returned so the screen keeps rendering last-known
/// values with an age tag. Nothing here ever promotes cached data to live; only
/// fresh backend data does that.
///
/// Every method is non-throwing. Reads return `null` on any failure and count a
/// miss; writes swallow failures with one WARN from the store.
final class MarketCacheRepository {
  /// Creates the facade over an already-open store.
  ///
  /// [_clock] is the time source used by [isStale], so staleness in a test moves
  /// only when the test moves it.
  MarketCacheRepository({
    required this._store,
    required this._clock,
    this._metrics,
  });

  /// Candle series: five minutes.
  ///
  /// Long enough that an interval switch or a cold start almost always hits,
  /// short enough that a chart is never visibly wrong after a gap.
  static const Duration candlesTtl = Duration(minutes: 5);

  /// Order-book snapshot: thirty seconds.
  ///
  /// A book is only useful if it is roughly current, so this is the shortest
  /// TTL; anything older renders as `STALE` and is resynchronised on reconnect.
  static const Duration orderBookTtl = Duration(seconds: 30);

  /// Recent trades: sixty seconds.
  static const Duration tradesTtl = Duration(seconds: 60);

  /// Rolling 24h summary: sixty seconds.
  static const Duration summaryTtl = Duration(seconds: 60);

  /// Market catalogue (the watchlist roster): twenty-four hours.
  static const Duration marketsTtl = Duration(hours: 24);

  final CacheStore _store;
  final Clock _clock;
  final OnDeviceMetrics? _metrics;

  /// The metric registry the injected store counts into.
  ///
  /// Exposed so the composition root and the Diagnostics screen can read the
  /// cache counters from the same registry rather than constructing a second
  /// one that would always read zero.
  OnDeviceMetrics? get metrics => _metrics;

  /// The key for one symbol's candle series at one interval, e.g.
  /// `candles:BTCUSDT:1m`.
  static String candlesKey(String symbol, CandleInterval interval) =>
      'candles:$symbol:${interval.wire}';

  /// The key for one symbol's order-book snapshot.
  static String bookKey(String symbol) => 'book:$symbol';

  /// The key for one symbol's recent trades.
  static String tradesKey(String symbol) => 'trades:$symbol';

  /// The key for one symbol's rolling 24h summary.
  static String summaryKey(String symbol) => 'summary:$symbol';

  /// The key for the market catalogue shared by every watchlist row.
  static String marketsKey() => 'markets';

  /// True when [entry] is past its TTL at the repository's current time.
  ///
  /// A `null` entry is not stale, it is absent; callers distinguish "render
  /// with a `STALE` tag" from "render a skeleton" on exactly this difference.
  bool isStale<T>(CacheEntry<T>? entry) =>
      entry != null && entry.isStaleAt(_clock.now());

  /// Reads the cached candle series for [symbol] and [interval].
  Future<CacheEntry<List<Candle>>?> readCandles(
    String symbol,
    CandleInterval interval,
  ) => _store.read<List<Candle>>(
    candlesKey(symbol, interval),
    CacheCodecs.decodeCandles,
  );

  /// Writes the candle series; callers on the delivery path use `unawaited`.
  Future<void> writeCandles(
    String symbol,
    CandleInterval interval,
    List<Candle> candles,
  ) => _store.write<List<Candle>>(
    candlesKey(symbol, interval),
    candles,
    ttl: candlesTtl,
    encode: CacheCodecs.encodeCandles,
  );

  /// Reads the cached order-book snapshot for [symbol].
  Future<CacheEntry<OrderBookSnapshot>?> readOrderBook(String symbol) =>
      _store.read<OrderBookSnapshot>(
        bookKey(symbol),
        CacheCodecs.decodeOrderBookSnapshot,
      );

  /// Writes the order-book snapshot.
  Future<void> writeOrderBook(String symbol, OrderBookSnapshot snapshot) =>
      _store.write<OrderBookSnapshot>(
        bookKey(symbol),
        snapshot,
        ttl: orderBookTtl,
        encode: CacheCodecs.encodeOrderBookSnapshot,
      );

  /// Reads the cached recent-trade list for [symbol].
  Future<CacheEntry<List<Trade>>?> readTrades(String symbol) =>
      _store.read<List<Trade>>(tradesKey(symbol), CacheCodecs.decodeTrades);

  /// Writes the recent-trade list.
  Future<void> writeTrades(String symbol, List<Trade> trades) =>
      _store.write<List<Trade>>(
        tradesKey(symbol),
        trades,
        ttl: tradesTtl,
        encode: CacheCodecs.encodeTrades,
      );

  /// Reads the cached rolling 24h summary for [symbol].
  Future<CacheEntry<MarketSummary>?> readSummary(String symbol) => _store
      .read<MarketSummary>(summaryKey(symbol), CacheCodecs.decodeMarketSummary);

  /// Writes the rolling 24h summary.
  Future<void> writeSummary(String symbol, MarketSummary summary) =>
      _store.write<MarketSummary>(
        summaryKey(symbol),
        summary,
        ttl: summaryTtl,
        encode: CacheCodecs.encodeMarketSummary,
      );

  /// Reads the cached market catalogue.
  Future<CacheEntry<List<MarketInfo>>?> readMarkets() =>
      _store.read<List<MarketInfo>>(marketsKey(), CacheCodecs.decodeMarkets);

  /// Writes the market catalogue.
  Future<void> writeMarkets(List<MarketInfo> markets) =>
      _store.write<List<MarketInfo>>(
        marketsKey(),
        markets,
        ttl: marketsTtl,
        encode: CacheCodecs.encodeMarkets,
      );

  /// Measures the underlying store, for the Diagnostics screen.
  Future<CacheStats> stats() => _store.stats();

  /// Drops every cached payload.
  Future<void> clear() => _store.clear();
}
