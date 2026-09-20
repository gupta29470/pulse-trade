import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/cache/market_cache_repository.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/data/repositories/caching_market_history_repository.dart';
import 'package:pulse_trade_frontend/data/repositories/caching_market_summary_repository.dart';
import 'package:pulse_trade_frontend/data/repositories/caching_order_book_repository.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/entities/trade_side.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/features/market/market_bloc.dart';
import 'package:pulse_trade_frontend/features/market/market_event.dart';
import 'package:pulse_trade_frontend/features/market/market_state.dart';

final DateTime _now = DateTime.utc(2026, 9, 17, 12, 41, 3);

/// An in-memory [CacheStore] that honours the entry contract exactly like the
/// real stores: a version mismatch deletes, a decode failure misses.
final class _MemoryCacheStore implements CacheStore {
  _MemoryCacheStore({required this.clock, required this.metrics});

  final Clock clock;
  final OnDeviceMetrics metrics;

  int schemaVersion = kCacheSchemaVersion;

  final Map<String, Map<String, Object?>> _payloads =
      <String, Map<String, Object?>>{};
  final Map<String, DateTime> _writtenAt = <String, DateTime>{};
  final Map<String, Duration> _ttl = <String, Duration>{};
  final Map<String, int> _version = <String, int>{};

  @override
  Future<CacheEntry<T>?> read<T>(
    String key,
    T Function(Map<String, dynamic>) decode,
  ) async {
    final Map<String, Object?>? raw = _payloads[key];
    final DateTime? writtenAt = _writtenAt[key];
    final Duration? ttl = _ttl[key];
    if (raw == null || writtenAt == null || ttl == null) {
      metrics.increment(MetricNames.cacheMissesTotal);
      return null;
    }
    if (_version[key] != schemaVersion) {
      _payloads.remove(key);
      metrics.increment(MetricNames.cacheMissesTotal);
      return null;
    }
    try {
      final T payload = decode(Map<String, dynamic>.from(raw));
      metrics.increment(MetricNames.cacheHitsTotal);
      return CacheEntry<T>(
        key: key,
        schemaVersion: schemaVersion,
        writtenAt: writtenAt,
        ttl: ttl,
        payload: payload,
      );
    } on Object {
      _payloads.remove(key);
      metrics.increment(MetricNames.cacheMissesTotal);
      return null;
    }
  }

  @override
  Future<void> write<T>(
    String key,
    T value, {
    required Duration ttl,
    required Map<String, dynamic> Function(T) encode,
  }) async {
    _payloads[key] = encode(value);
    _writtenAt[key] = clock.now();
    _ttl[key] = ttl;
    _version[key] = schemaVersion;
    metrics.increment(MetricNames.cacheWritesTotal);
  }

  @override
  Future<void> invalidate(String key) async {
    _payloads.remove(key);
  }

  @override
  Future<void> clear() async {
    _payloads.clear();
  }

  @override
  Future<CacheStats> stats() async => CacheStats(
    entries: _payloads.length,
    bytes: 0,
    hits: metrics.value(MetricNames.cacheHitsTotal),
    misses: metrics.value(MetricNames.cacheMissesTotal),
    writes: metrics.value(MetricNames.cacheWritesTotal),
    writeFailures: metrics.value(MetricNames.cacheWriteFailuresTotal),
    evictions: 0,
  );
}

/// A transport double that must record **zero** calls in an offline cold start.
final class _RecordingMarketApi implements MarketApi {
  int calls = 0;

  void _count() => calls++;

  @override
  Future<List<MarketInfo>> getMarkets() async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<MarketSummary> getSummary(String symbol) async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<OrderBookSnapshot> getOrderBook(String symbol) async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<List<Candle>> getCandles(
    String symbol,
    CandleInterval interval, {
    int limit = 500,
  }) async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<List<Trade>> getRecentTrades(String symbol, {int limit = 50}) async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<HealthSnapshot> getHealth() async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<HealthSnapshot> getDetailedHealth() async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<MetricsSnapshot> getMetricsSummary() async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<List<LatencyBucket>> getLatencyBuckets({
    String? sessionId,
    required Duration window,
    required Duration bucket,
  }) async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<List<TierTransitionRecord>> getTierTransitions({
    Duration? window,
  }) async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<List<SessionRecord>> getSessions({int limit = 50}) async {
    _count();
    throw const NetworkFailure();
  }

  @override
  Future<List<DeliveryWindow>> getDeliveryWindows({
    String? sessionId,
    Duration? window,
  }) async {
    _count();
    throw const NetworkFailure();
  }
}

/// Always-offline gate, so the decorator refuses before the transport is touched.
final class _OfflineGate implements OfflineGate {
  int calls = 0;

  @override
  Future<bool> canCall() async {
    calls++;
    return false;
  }
}

/// A stream repository double: the socket never delivers in this test.
final class _SilentStreamRepository implements MarketStreamRepository {
  int subscribeCalls = 0;

  /// Every subscription the blocs asked for, in order.
  final List<SubscriptionSpec> specs = <SubscriptionSpec>[];

  final StreamController<ServerMessage> _messages =
      StreamController<ServerMessage>.broadcast();
  final StreamController<AppFailure> _failures =
      StreamController<AppFailure>.broadcast();
  final StreamController<ConnectionStatus> _status =
      StreamController<ConnectionStatus>.broadcast();

  @override
  Stream<ServerMessage> get messages => _messages.stream;

  @override
  Stream<AppFailure> get failures => _failures.stream;

  @override
  ConnectionStatus get status => ConnectionStatus.connected;

  @override
  Stream<ConnectionStatus> get statusStream => _status.stream;

  @override
  WelcomeMessage? get welcome => null;

  @override
  SubscriptionSpec? get currentSubscription =>
      specs.isEmpty ? null : specs.last;

  @override
  Future<void> connect() async {}

  @override
  Future<void> subscribe(SubscriptionSpec spec) async {
    subscribeCalls++;
    specs.add(spec);
  }

  @override
  Future<void> send(ClientMessage message) async {}

  @override
  Future<void> disconnect({String reason = 'client'}) async {}

  @override
  Future<void> dispose() async {
    await _messages.close();
    await _failures.close();
    await _status.close();
  }
}

void main() {
  group('M-18 cache-first cold start', () {
    late FakeClock clock;
    late OnDeviceMetrics metrics;
    late _MemoryCacheStore store;
    late MarketCacheRepository cache;
    late _RecordingMarketApi transport;
    late MarketApi api;
    late _SilentStreamRepository stream;
    late FailureMapper mapper;

    setUp(() {
      clock = FakeClock(start: _now);
      metrics = OnDeviceMetrics();
      store = _MemoryCacheStore(clock: clock, metrics: metrics);
      cache = MarketCacheRepository(
        store: store,
        clock: clock,
        metrics: metrics,
      );
      transport = _RecordingMarketApi();
      api = OfflineGatedMarketApi(
        inner: transport,
        gate: _OfflineGate(),
        metrics: metrics,
      );
      stream = _SilentStreamRepository();
      mapper = const FailureMapper();
    });

    Future<void> populateCache() async {
      await cache.writeCandles('BTCUSDT', CandleInterval.m1, <Candle>[
        Candle(
          interval: CandleInterval.m1,
          startTime: _now.subtract(const Duration(minutes: 1)),
          open: Money.parse('67400.00'),
          high: Money.parse('67450.00'),
          low: Money.parse('67390.00'),
          close: Money.parse('67421.35'),
          volume: Quantity.parse('12.50000000'),
          tradeCount: 40,
          sourceSequence: 900,
          closed: true,
        ),
      ]);
      await cache.writeOrderBook(
        'BTCUSDT',
        OrderBookSnapshot(
          symbol: 'BTCUSDT',
          epoch: 1,
          updateId: 10428,
          bids: <OrderBookLevel>[
            OrderBookLevel(
              price: Money.parse('67420.90'),
              quantity: Quantity.parse('0.38000000'),
            ),
          ],
          asks: <OrderBookLevel>[
            OrderBookLevel(
              price: Money.parse('67421.10'),
              quantity: Quantity.parse('0.22000000'),
            ),
          ],
          serverTime: _now,
        ),
      );
      await cache.writeTrades('BTCUSDT', <Trade>[
        Trade(
          tradeId: 894120,
          symbol: 'BTCUSDT',
          timestamp: _now,
          price: Money.parse('67421.35'),
          quantity: Quantity.parse('0.18400000'),
          side: TradeSide.buy,
        ),
      ]);
    }

    /// Seeds a cached ETHUSDT series so a symbol switch has something to render.
    Future<void> populateEthCache() async {
      await cache.writeCandles('ETHUSDT', CandleInterval.m1, <Candle>[
        Candle(
          interval: CandleInterval.m1,
          startTime: _now.subtract(const Duration(minutes: 1)),
          open: Money.parse('2500.00'),
          high: Money.parse('2510.00'),
          low: Money.parse('2490.00'),
          close: Money.parse('2505.00'),
          volume: Quantity.parse('120.00000000'),
          tradeCount: 80,
          sourceSequence: 400,
          closed: true,
        ),
      ]);
    }

    MarketBloc buildBloc() => MarketBloc(
      history: CachingMarketHistoryRepository(
        api: api,
        cache: cache,
        failureMapper: mapper,
        clock: clock,
      ),
      summaries: CachingMarketSummaryRepository(
        api: api,
        cache: cache,
        failureMapper: mapper,
        clock: clock,
      ),
      orderBooks: CachingOrderBookRepository(
        api: api,
        cache: cache,
        failureMapper: mapper,
        clock: clock,
      ),
      stream: stream,
      symbol: 'BTCUSDT',
      clock: clock,
      metrics: metrics,
    );

    test(
      'emits cached candles, book and trades without touching the network',
      () async {
        await populateCache();
        final MarketBloc bloc = buildBloc();

        final Future<MarketState> settled = bloc.stream.firstWhere(
          (MarketState state) => state.candles.isNotEmpty,
        );
        bloc.add(const MarketStarted('BTCUSDT'));
        final MarketState state = await settled;

        expect(state.candles, hasLength(1));
        expect(state.candleProvenance, DataProvenance.cached);
        expect(state.candleAsOf, isNotNull);
        expect(state.bookSnapshot, isNotNull);
        expect(state.bookProvenance, DataProvenance.cached);
        expect(state.bookAsOf, isNotNull);
        expect(state.trades, hasLength(1));
        expect(state.tradesProvenance, DataProvenance.cached);
        expect(state.tradesAsOf, isNotNull);
        expect(state.trades.first.tradeId, 894120);

        // Cached data is never presented as live.
        expect(state.candleProvenance, isNot(DataProvenance.live));
        expect(state.bookProvenance, isNot(DataProvenance.live));
        expect(state.tradesProvenance, isNot(DataProvenance.live));

        expect(
          transport.calls,
          0,
          reason: 'the offline gate must block every transport call',
        );
        expect(
          metrics.value(MetricNames.offlineCallsBlockedTotal),
          greaterThan(0),
        );

        await bloc.close();
        await stream.dispose();
      },
    );

    test(
      'a stale cache entry is returned labelled stale, still offline',
      () async {
        await populateCache();
        // Move past every TTL, so the cached values are stale but still usable.
        clock.advance(const Duration(hours: 25));

        final MarketBloc bloc = buildBloc();
        final Future<MarketState> settled = bloc.stream.firstWhere(
          (MarketState state) => state.candles.isNotEmpty,
        );
        bloc.add(const MarketStarted('BTCUSDT'));
        final MarketState state = await settled;

        expect(state.candles, hasLength(1));
        expect(state.candleProvenance, DataProvenance.stale);
        expect(state.bookProvenance, DataProvenance.stale);
        expect(state.tradesProvenance, DataProvenance.stale);
        expect(
          transport.calls,
          0,
          reason: 'a stale entry is served instead of a refused network call',
        );

        await bloc.close();
        await stream.dispose();
      },
    );

    test(
      'an empty cache degrades to a failure without inventing data',
      () async {
        final MarketBloc bloc = buildBloc();
        final Future<MarketState> settled = bloc.stream.firstWhere(
          (MarketState state) => state.failure != null,
        );
        bloc.add(const MarketStarted('BTCUSDT'));
        final MarketState state = await settled;

        expect(state.candles, isEmpty);
        expect(state.bookSnapshot, isNull);
        expect(state.failure, isA<OfflineFailure>());
        expect(store.schemaVersion, kCacheSchemaVersion);

        await bloc.close();
        await stream.dispose();
      },
    );

    test(
      'starting another symbol renders its cache and resubscribes it',
      () async {
        await populateCache();
        await populateEthCache();
        final MarketBloc bloc = buildBloc();

        bloc.add(const MarketStarted('BTCUSDT'));
        await bloc.stream.firstWhere(
          (MarketState state) =>
              state.symbol == 'BTCUSDT' && state.candles.isNotEmpty,
        );

        stream.specs.clear();
        bloc.add(const MarketStarted('ETHUSDT'));
        final MarketState eth = await bloc.stream.firstWhere(
          (MarketState state) =>
              state.symbol == 'ETHUSDT' && state.candles.isNotEmpty,
        );

        // The route symbol's cached series renders straight away, labelled as
        // cached rather than promoted to live.
        expect(eth.candleProvenance, DataProvenance.cached);
        expect(eth.candles.single.close, Money.parse('2505.00'));

        // The session is rebound to the symbol the route opened.
        await pumpEventQueue();
        expect(stream.specs, isNotEmpty);
        expect(stream.specs.last.symbol, 'ETHUSDT');

        await bloc.close();
        await stream.dispose();
      },
    );
  });
}
