import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/networking/market_websocket_client.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/channel.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/entities/trade_side.dart';

final DateTime _time = DateTime.utc(2026, 9, 17, 12, 41, 3);

/// A gate whose answer the test controls.
final class _FakeGate implements OfflineGate {
  _FakeGate({required this.online});

  bool online;
  int calls = 0;

  @override
  Future<bool> canCall() async {
    calls++;
    return online;
  }
}

/// A transport double that records every invocation, so "zero calls" is
/// provable rather than assumed.
final class _RecordingMarketApi implements MarketApi {
  int calls = 0;

  @override
  Future<List<MarketInfo>> getMarkets() async {
    calls++;
    return <MarketInfo>[
      const MarketInfo(
        symbol: 'BTCUSDT',
        display: 'BTC/USDT',
        name: 'Bitcoin',
        glyph: 'B',
        priceDigits: 2,
        quantityDigits: 8,
      ),
    ];
  }

  @override
  Future<MarketSummary> getSummary(String symbol) async {
    calls++;
    return MarketSummary(
      symbol: symbol,
      last: Money.parse('67421.35'),
      open24h: Money.parse('67300.00'),
      high24h: Money.parse('67500.00'),
      low24h: Money.parse('67200.00'),
      volume24h: Quantity.parse('184.22000000'),
      change: Money.parse('121.35'),
      changeBasisPoints: 18,
      trades24h: 412,
      updatedAt: _time,
    );
  }

  @override
  Future<OrderBookSnapshot> getOrderBook(String symbol) async {
    calls++;
    return OrderBookSnapshot(
      symbol: symbol,
      epoch: 1,
      updateId: 10428,
      bids: <OrderBookLevel>[],
      asks: <OrderBookLevel>[],
      serverTime: _time,
    );
  }

  @override
  Future<List<Candle>> getCandles(
    String symbol,
    CandleInterval interval, {
    int limit = 500,
  }) async {
    calls++;
    return <Candle>[
      Candle(
        interval: interval,
        startTime: _time,
        open: Money.parse('67400.00'),
        high: Money.parse('67450.00'),
        low: Money.parse('67390.00'),
        close: Money.parse('67421.35'),
        volume: Quantity.parse('1.00000000'),
        tradeCount: 4,
        sourceSequence: 10,
      ),
    ];
  }

  @override
  Future<List<Trade>> getRecentTrades(String symbol, {int limit = 50}) async {
    calls++;
    return <Trade>[
      Trade(
        tradeId: 1,
        symbol: symbol,
        timestamp: _time,
        price: Money.parse('67421.35'),
        quantity: Quantity.parse('0.10000000'),
        side: TradeSide.buy,
      ),
    ];
  }

  @override
  Future<HealthSnapshot> getHealth() async {
    calls++;
    return HealthSnapshot(
      status: 'ok',
      version: '1.0.0',
      uptimeMs: 1,
      serverTime: _time,
    );
  }

  @override
  Future<HealthSnapshot> getDetailedHealth() async {
    calls++;
    return HealthSnapshot(
      status: 'ok',
      version: '1.0.0',
      uptimeMs: 1,
      serverTime: _time,
    );
  }

  @override
  Future<MetricsSnapshot> getMetricsSummary() async {
    calls++;
    return MetricsSnapshot(
      generatedAt: _time,
      uptimeMs: 1,
      activeSessions: 1,
      totalSessions: 1,
      tierDistribution: const <String, int>{'FULL': 1},
      rtt: RttStats.empty,
      jitterMsMean: 0,
      reconnects: 0,
      bookRecoveries: 0,
      bookGapsDetected: 0,
      malformedMessages: 0,
      duplicateDeltas: 0,
      staleDeltas: 0,
      outOfOrderTrades: 0,
      tierTransitions: 0,
      candlesClosed: 0,
      candleInvariantViolations: 0,
      latencySamples: 0,
      deliveryWindows: 0,
      counters: const <String, int>{},
    );
  }

  @override
  Future<List<LatencyBucket>> getLatencyBuckets({
    String? sessionId,
    required Duration window,
    required Duration bucket,
  }) async {
    calls++;
    return const <LatencyBucket>[];
  }

  @override
  Future<List<TierTransitionRecord>> getTierTransitions({
    Duration? window,
  }) async {
    calls++;
    return const <TierTransitionRecord>[];
  }

  @override
  Future<List<SessionRecord>> getSessions({int limit = 50}) async {
    calls++;
    return const <SessionRecord>[];
  }

  @override
  Future<List<DeliveryWindow>> getDeliveryWindows({
    String? sessionId,
    Duration? window,
  }) async {
    calls++;
    return const <DeliveryWindow>[];
  }
}

/// A socket double recording dials.
final class _RecordingWebSocketClient implements MarketWebSocketClient {
  int connectCalls = 0;
  int subscribeCalls = 0;
  int sendCalls = 0;
  int disconnectCalls = 0;

  final StreamController<SocketEvent> _events =
      StreamController<SocketEvent>.broadcast();

  void emit(SocketEvent event) => _events.add(event);

  @override
  Stream<SocketEvent> get events => _events.stream;

  @override
  ConnectionStatus get status => ConnectionStatus.disconnected;

  @override
  Future<void> connect(Uri url) async {
    connectCalls++;
  }

  @override
  Future<void> subscribe(SubscriptionSpec spec) async {
    subscribeCalls++;
  }

  @override
  Future<void> send(ClientMessage message) async {
    sendCalls++;
  }

  @override
  Future<void> disconnect({String reason = 'client'}) async {
    disconnectCalls++;
  }

  Future<void> close() => _events.close();
}

void main() {
  group('M-16 offline gating', () {
    test(
      'every MarketApi method is refused without touching the transport',
      () async {
        final _RecordingMarketApi transport = _RecordingMarketApi();
        final OnDeviceMetrics metrics = OnDeviceMetrics();
        final _FakeGate gate = _FakeGate(online: false);
        final MarketApi api = OfflineGatedMarketApi(
          inner: transport,
          gate: gate,
          metrics: metrics,
        );

        final List<Future<Object?> Function()> calls =
            <Future<Object?> Function()>[
              api.getMarkets,
              () => api.getSummary('BTCUSDT'),
              () => api.getOrderBook('BTCUSDT'),
              () => api.getCandles('BTCUSDT', CandleInterval.m1),
              () => api.getRecentTrades('BTCUSDT'),
              api.getHealth,
              api.getDetailedHealth,
              api.getMetricsSummary,
              () => api.getLatencyBuckets(
                window: const Duration(minutes: 15),
                bucket: const Duration(seconds: 5),
              ),
              api.getTierTransitions,
              api.getSessions,
              api.getDeliveryWindows,
            ];

        for (final Future<Object?> Function() call in calls) {
          await expectLater(
            call(),
            throwsA(isA<OfflineFailure>()),
            reason: 'a gated call must surface OfflineFailure',
          );
        }

        expect(
          transport.calls,
          0,
          reason: 'the transport must never be invoked',
        );
        expect(gate.calls, calls.length);
        expect(
          metrics.value(MetricNames.offlineCallsBlockedTotal),
          calls.length,
        );
      },
    );

    test('an online gate passes every call through exactly once', () async {
      final _RecordingMarketApi transport = _RecordingMarketApi();
      final OnDeviceMetrics metrics = OnDeviceMetrics();
      final MarketApi api = OfflineGatedMarketApi(
        inner: transport,
        gate: _FakeGate(online: true),
        metrics: metrics,
      );

      await api.getMarkets();
      await api.getSummary('BTCUSDT');
      await api.getCandles('BTCUSDT', CandleInterval.m1);
      await api.getRecentTrades('BTCUSDT');
      await api.getOrderBook('BTCUSDT');
      await api.getHealth();
      await api.getDetailedHealth();
      await api.getMetricsSummary();
      await api.getLatencyBuckets(
        window: const Duration(minutes: 15),
        bucket: const Duration(seconds: 5),
      );
      await api.getTierTransitions();
      await api.getSessions();
      await api.getDeliveryWindows();

      expect(transport.calls, 12);
      expect(metrics.value(MetricNames.offlineCallsBlockedTotal), 0);
    });

    test(
      'a WebSocket connect is refused while offline and emits a failure',
      () async {
        final _RecordingWebSocketClient transport = _RecordingWebSocketClient();
        final OnDeviceMetrics metrics = OnDeviceMetrics();
        final MarketWebSocketClient client = OfflineGatedWebSocketClient(
          inner: transport,
          gate: _FakeGate(online: false),
          metrics: metrics,
        );

        final Future<SocketEvent> firstEvent = client.events.first;
        await client.connect(Uri.parse('ws://10.0.2.2:8080/ws'));
        final SocketEvent event = await firstEvent;

        expect(transport.connectCalls, 0);
        expect(event, isA<SocketFailure>());
        expect((event as SocketFailure).failure, isA<OfflineFailure>());
        expect(metrics.value(MetricNames.offlineCallsBlockedTotal), 1);

        await transport.close();
      },
    );

    test('a WebSocket connect passes through while online', () async {
      final _RecordingWebSocketClient transport = _RecordingWebSocketClient();
      final MarketWebSocketClient client = OfflineGatedWebSocketClient(
        inner: transport,
        gate: _FakeGate(online: true),
        metrics: OnDeviceMetrics(),
      );

      await client.connect(Uri.parse('ws://10.0.2.2:8080/ws'));
      expect(transport.connectCalls, 1);

      await client.subscribe(
        const SubscriptionSpec(symbol: 'BTCUSDT', interval: CandleInterval.m1),
      );
      expect(transport.subscribeCalls, 1);
      expect(
        const SubscriptionSpec(
          symbol: 'BTCUSDT',
          interval: CandleInterval.m1,
        ).channels,
        Channel.defaults,
      );

      await client.disconnect(reason: 'test');
      expect(transport.disconnectCalls, 1);
      await transport.close();
    });
  });
}
