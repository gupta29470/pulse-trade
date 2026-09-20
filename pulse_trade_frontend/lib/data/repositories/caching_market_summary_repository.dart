import 'dart:async';

import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/market_cache_repository.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_summary_repository.dart';

/// The 24h summary and the market roster, cache-first.
///
/// TTLs are 60 s for a summary and 24 h for the roster: the roster
/// changes only when the backend does, so re-fetching it per screen open would
/// be pure waste.
final class CachingMarketSummaryRepository implements MarketSummaryRepository {
  /// Creates the repository.
  CachingMarketSummaryRepository({
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
  Future<Result<Sourced<MarketSummary>>> loadSummary(
    String symbol, {
    bool forceRefresh = false,
  }) async {
    final CacheEntry<MarketSummary>? entry = await _cache.readSummary(symbol);
    final DateTime now = _clock.now();

    if (entry != null && !forceRefresh && !entry.isStaleAt(now)) {
      return Ok<Sourced<MarketSummary>>(
        Sourced<MarketSummary>.fromCache(
          entry.payload,
          writtenAt: entry.writtenAt,
          stale: false,
        ),
      );
    }

    try {
      final MarketSummary summary = await _api.getSummary(symbol);
      unawaited(_cache.writeSummary(symbol, summary));
      return Ok<Sourced<MarketSummary>>(
        Sourced<MarketSummary>.live(summary, asOf: now),
      );
    } on AppFailure catch (failure) {
      if (entry != null && _isTransportFailure(failure)) {
        return Ok<Sourced<MarketSummary>>(
          Sourced<MarketSummary>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: true,
          ),
        );
      }
      return Err<Sourced<MarketSummary>>(failure);
    } on Object catch (error) {
      return Err<Sourced<MarketSummary>>(_mapper.map(error));
    }
  }

  @override
  Future<Result<Sourced<List<MarketInfo>>>> loadMarkets({
    bool forceRefresh = false,
  }) async {
    final CacheEntry<List<MarketInfo>>? entry = await _cache.readMarkets();
    final DateTime now = _clock.now();

    if (entry != null && !forceRefresh && !entry.isStaleAt(now)) {
      return Ok<Sourced<List<MarketInfo>>>(
        Sourced<List<MarketInfo>>.fromCache(
          entry.payload,
          writtenAt: entry.writtenAt,
          stale: false,
        ),
      );
    }

    try {
      final List<MarketInfo> markets = await _api.getMarkets();
      if (markets.isEmpty && entry != null) {
        return Ok<Sourced<List<MarketInfo>>>(
          Sourced<List<MarketInfo>>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: true,
          ),
        );
      }
      unawaited(_cache.writeMarkets(markets));
      return Ok<Sourced<List<MarketInfo>>>(
        Sourced<List<MarketInfo>>.live(markets, asOf: now),
      );
    } on AppFailure catch (failure) {
      if (entry != null && _isTransportFailure(failure)) {
        return Ok<Sourced<List<MarketInfo>>>(
          Sourced<List<MarketInfo>>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: true,
          ),
        );
      }
      return Err<Sourced<List<MarketInfo>>>(failure);
    } on Object catch (error) {
      return Err<Sourced<List<MarketInfo>>>(_mapper.map(error));
    }
  }

  static bool _isTransportFailure(AppFailure failure) =>
      failure is OfflineFailure ||
      failure is NetworkFailure ||
      failure is TimeoutFailure ||
      failure is ServerFailure;
}
