import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';

/// Candle history and the recent-trade seed, cache-first and REST-backed.
///
/// Returns [Result] rather than throwing so a bloc has to handle the failure
/// case, and so an offline call can be answered from cache without an exception
/// in the middle of the widget tree. The payload is a
/// [Sourced] so the caller can tag it `CACHED`/`STALE` instead of guessing.
abstract interface class MarketHistoryRepository {
  /// Loads up to [limit] ascending candles for [symbol] at [interval].
  ///
  /// Implementations serve cache before network. When the network is
  /// unreachable and a cache entry exists, the cached value is returned with its
  /// provenance rather than an [OfflineFailure], because a blank chart is worse
  /// than a labelled stale one.
  Future<Result<Sourced<List<Candle>>>> loadHistory(
    String symbol,
    CandleInterval interval, {
    int limit = 500,
    bool forceRefresh = false,
  });

  /// Loads up to [limit] recent trades for [symbol], newest first, cache-first.
  ///
  /// This is what lets a cold start render the trades panel from disk before the
  /// socket is up; live trades then take over through the stream. It is
  /// deliberately on the same interface as history because both are the
  /// "backfill from the REST/cache tier" concern, not live state.
  Future<Result<Sourced<List<Trade>>>> loadRecentTrades(
    String symbol, {
    int limit = 50,
    bool forceRefresh = false,
  });
}
