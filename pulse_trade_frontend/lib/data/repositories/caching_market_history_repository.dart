import 'dart:async';

import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/market_cache_repository.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_history_repository.dart';

/// Candle history that always has something to render.
///
/// Order of preference:
/// 1. a fresh cache entry inside its 5-minute TTL, which avoids the request
///    entirely on a cold start,
/// 2. the backend,
/// 3. a stale cache entry, when the backend is unreachable — a labelled stale
///    chart beats a blank one,
/// 4. a typed failure, only when there is nothing at all to show.
final class CachingMarketHistoryRepository implements MarketHistoryRepository {
  /// Creates the repository.
  CachingMarketHistoryRepository({
    required this._api,
    required this._cache,
    required FailureMapper failureMapper,
    Clock? clock,
  }) : _mapper = failureMapper,
       _clock = clock ?? SystemClock();

  final MarketApi _api;
  final MarketCacheRepository _cache;
  final FailureMapper _mapper;
  final Clock _clock;

  @override
  Future<Result<Sourced<List<Candle>>>> loadHistory(
    String symbol,
    CandleInterval interval, {
    int limit = 500,
    bool forceRefresh = false,
  }) async {
    final CacheEntry<List<Candle>>? entry = await _cache.readCandles(
      symbol,
      interval,
    );
    final DateTime now = _clock.now();

    if (entry != null && entry.payload.isNotEmpty) {
      if (!forceRefresh && !entry.isStaleAt(now)) {
        return Ok<Sourced<List<Candle>>>(
          Sourced<List<Candle>>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: false,
          ),
        );
      }
    }

    try {
      final List<Candle> candles = await _api.getCandles(
        symbol,
        interval,
        limit: limit,
      );
      if (candles.isEmpty) {
        // An empty history is a real answer, but replacing a populated chart
        // with nothing is worse than showing the older data as stale.
        if (entry != null && entry.payload.isNotEmpty) {
          return Ok<Sourced<List<Candle>>>(
            Sourced<List<Candle>>.fromCache(
              entry.payload,
              writtenAt: entry.writtenAt,
              stale: true,
            ),
          );
        }
        return const Err<Sourced<List<Candle>>>(
          HistoryFailure(message: 'No historical data available'),
        );
      }
      // Cache writes are off the critical path and never block the chart.
      unawaited(_cache.writeCandles(symbol, interval, candles));
      return Ok<Sourced<List<Candle>>>(
        Sourced<List<Candle>>.live(candles, asOf: now),
      );
    } on AppFailure catch (failure) {
      if (entry != null &&
          entry.payload.isNotEmpty &&
          _isTransportFailure(failure)) {
        AppLogger.warn(
          'history_served_from_cache',
          fields: <String, Object?>{
            LogFields.component: LogComponents.cache,
            LogFields.symbol: symbol,
            LogFields.interval: interval.wire,
            LogFields.errorCode: failure.code,
            LogFields.count: entry.payload.length,
          },
        );
        return Ok<Sourced<List<Candle>>>(
          Sourced<List<Candle>>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: true,
          ),
        );
      }
      return Err<Sourced<List<Candle>>>(failure);
    } on Object catch (error) {
      return Err<Sourced<List<Candle>>>(_mapper.map(error));
    }
  }

  static bool _isTransportFailure(AppFailure failure) =>
      failure is OfflineFailure ||
      failure is NetworkFailure ||
      failure is TimeoutFailure ||
      failure is ServerFailure;

  @override
  Future<Result<Sourced<List<Trade>>>> loadRecentTrades(
    String symbol, {
    int limit = 50,
    bool forceRefresh = false,
  }) async {
    final CacheEntry<List<Trade>>? entry = await _cache.readTrades(symbol);
    final DateTime now = _clock.now();

    if (entry != null && entry.payload.isNotEmpty) {
      if (!forceRefresh && !entry.isStaleAt(now)) {
        return Ok<Sourced<List<Trade>>>(
          Sourced<List<Trade>>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: false,
          ),
        );
      }
    }

    try {
      final List<Trade> trades = await _api.getRecentTrades(
        symbol,
        limit: limit,
      );
      if (trades.isEmpty) {
        if (entry != null && entry.payload.isNotEmpty) {
          return Ok<Sourced<List<Trade>>>(
            Sourced<List<Trade>>.fromCache(
              entry.payload,
              writtenAt: entry.writtenAt,
              stale: true,
            ),
          );
        }
        return Ok<Sourced<List<Trade>>>(
          Sourced<List<Trade>>.live(const <Trade>[], asOf: now),
        );
      }
      unawaited(_cache.writeTrades(symbol, trades));
      return Ok<Sourced<List<Trade>>>(
        Sourced<List<Trade>>.live(trades, asOf: now),
      );
    } on AppFailure catch (failure) {
      if (entry != null &&
          entry.payload.isNotEmpty &&
          _isTransportFailure(failure)) {
        return Ok<Sourced<List<Trade>>>(
          Sourced<List<Trade>>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: true,
          ),
        );
      }
      return Err<Sourced<List<Trade>>>(failure);
    } on Object catch (error) {
      return Err<Sourced<List<Trade>>>(_mapper.map(error));
    }
  }
}
