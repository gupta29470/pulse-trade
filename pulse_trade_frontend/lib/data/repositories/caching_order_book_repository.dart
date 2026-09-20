import 'dart:async';

import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/market_cache_repository.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/repositories/order_book_repository.dart';

/// The snapshot source for [OrderBookSynchronizer].
///
/// Cache-first with a 30 s TTL: a snapshot in flight is already the slow path of
/// recovery, so a slightly old image that arrives instantly is better than a
/// blank book while the request is pending. A stale image is only used when the
/// backend is unreachable.
final class CachingOrderBookRepository implements OrderBookRepository {
  /// Creates the repository.
  CachingOrderBookRepository({
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
  Future<Result<Sourced<OrderBookSnapshot>>> loadSnapshot(
    String symbol, {
    bool forceRefresh = false,
  }) async {
    final CacheEntry<OrderBookSnapshot>? entry = await _cache.readOrderBook(
      symbol,
    );
    final DateTime now = _clock.now();

    if (entry != null && !forceRefresh && !entry.isStaleAt(now)) {
      return Ok<Sourced<OrderBookSnapshot>>(
        Sourced<OrderBookSnapshot>.fromCache(
          entry.payload,
          writtenAt: entry.writtenAt,
          stale: false,
        ),
      );
    }

    try {
      final OrderBookSnapshot snapshot = await _api.getOrderBook(symbol);
      unawaited(_cache.writeOrderBook(symbol, snapshot));
      return Ok<Sourced<OrderBookSnapshot>>(
        Sourced<OrderBookSnapshot>.live(snapshot, asOf: now),
      );
    } on AppFailure catch (failure) {
      if (entry != null && _isTransportFailure(failure)) {
        return Ok<Sourced<OrderBookSnapshot>>(
          Sourced<OrderBookSnapshot>.fromCache(
            entry.payload,
            writtenAt: entry.writtenAt,
            stale: true,
          ),
        );
      }
      return Err<Sourced<OrderBookSnapshot>>(failure);
    } on Object catch (error) {
      return Err<Sourced<OrderBookSnapshot>>(_mapper.map(error));
    }
  }

  static bool _isTransportFailure(AppFailure failure) =>
      failure is OfflineFailure ||
      failure is NetworkFailure ||
      failure is TimeoutFailure ||
      failure is ServerFailure;
}
