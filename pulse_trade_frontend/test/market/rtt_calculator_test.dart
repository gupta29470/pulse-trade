import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/market/rtt_calculator.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart'
    hide PingMessage;

final DateTime _serverTime = DateTime.utc(2026, 9, 17, 12, 41, 3);

PongMessage _pong(int id, {int serverTimeMs = 1000}) => PongMessage(
  version: 1,
  serverTime: _serverTime,
  seq: id,
  id: id,
  clientTimeMs: 0,
  serverTimeMs: serverTimeMs,
);

void main() {
  group('RttCalculator (M-01)', () {
    test('RTT is recv minus send on the monotonic clock', () {
      final FakeClock clock = FakeClock();
      final RttCalculator calculator = RttCalculator(clock: clock);

      final PingMessage ping = calculator.nextPing();
      expect(ping.clientTimeMs, 0, reason: 'the monotonic origin is zero');
      expect(calculator.pendingCount, 1);

      clock.advance(const Duration(milliseconds: 74));
      final RttSample? sample = calculator.onPong(_pong(ping.id));

      expect(sample, isNotNull);
      expect(sample!.rttMs, 74);
      expect(sample.sentAtMonoMs, 0);
      expect(sample.receivedAtMonoMs, 74);
      expect(calculator.latestRttMs, 74);
      expect(calculator.pendingCount, 0);
      expect(calculator.missedPongs, 0);
    });

    test('a pong after the 4 s timeout is discarded and counted as missed', () {
      final FakeClock clock = FakeClock();
      final OnDeviceMetrics metrics = OnDeviceMetrics();
      final RttCalculator calculator = RttCalculator(
        clock: clock,
        metrics: metrics,
      );

      final PingMessage ping = calculator.nextPing();
      clock.advance(const Duration(milliseconds: 4001));

      expect(calculator.onPong(_pong(ping.id)), isNull);
      expect(calculator.missedPongs, 1);
      expect(calculator.samples, isEmpty);
      expect(metrics.value(MetricNames.missedPongsTotal), 1);
    });

    test('a pong exactly at the timeout boundary is still accepted', () {
      final FakeClock clock = FakeClock();
      final RttCalculator calculator = RttCalculator(clock: clock);
      final PingMessage ping = calculator.nextPing();
      clock.advance(const Duration(seconds: 4));
      expect(calculator.onPong(_pong(ping.id))?.rttMs, 4000);
      expect(calculator.missedPongs, 0);
    });

    test('an unknown or duplicate pong id is ignored', () {
      final FakeClock clock = FakeClock();
      final RttCalculator calculator = RttCalculator(clock: clock);
      final PingMessage ping = calculator.nextPing();
      clock.advance(const Duration(milliseconds: 10));

      expect(calculator.onPong(_pong(ping.id + 99)), isNull);
      expect(calculator.missedPongs, 0);

      expect(calculator.onPong(_pong(ping.id)), isNotNull);
      // The same pong cannot complete a sample twice.
      expect(calculator.onPong(_pong(ping.id)), isNull);
      expect(calculator.samples.length, 1);
    });

    test('expirePending counts pulses that were never answered', () {
      final FakeClock clock = FakeClock();
      final OnDeviceMetrics metrics = OnDeviceMetrics();
      final RttCalculator calculator = RttCalculator(
        clock: clock,
        metrics: metrics,
      );

      calculator.nextPing();
      clock.advance(const Duration(seconds: 2));
      final PingMessage second = calculator.nextPing();
      clock.advance(const Duration(seconds: 3));

      // The first pulse is 5 s old and expired; the second is 3 s old and alive.
      expect(calculator.expirePending(), 1);
      expect(calculator.pendingCount, 1);
      expect(calculator.missedPongs, 1);
      expect(metrics.value(MetricNames.missedPongsTotal), 1);

      // Answering the survivor still produces a sample.
      clock.advance(const Duration(milliseconds: 1));
      final RttSample? sample = calculator.onPong(_pong(second.id));
      expect(sample, isNotNull);
      expect(sample!.rttMs, 3001);
    });

    test('the aggregate readout is exact over the retained history', () {
      final FakeClock clock = FakeClock();
      final RttCalculator calculator = RttCalculator(clock: clock);

      for (final int rtt in <int>[70, 90, 110]) {
        final PingMessage ping = calculator.nextPing();
        clock.advance(Duration(milliseconds: rtt));
        calculator.onPong(_pong(ping.id));
      }

      expect(calculator.samples.length, 3);
      expect(calculator.minRttMs, 70);
      expect(calculator.maxRttMs, 110);
      expect(calculator.averageRttMs, closeTo(90, 1e-9));
    });

    test('the history is bounded', () {
      final FakeClock clock = FakeClock();
      final RttCalculator calculator = RttCalculator(
        clock: clock,
        historyLimit: 3,
      );
      for (var i = 0; i < 6; i++) {
        final PingMessage ping = calculator.nextPing();
        clock.advance(const Duration(milliseconds: 10));
        calculator.onPong(_pong(ping.id));
      }
      expect(calculator.samples.length, 3);
    });

    test('reset clears pending pulses and history but not the miss count', () {
      final FakeClock clock = FakeClock();
      final RttCalculator calculator = RttCalculator(clock: clock);
      final PingMessage ping = calculator.nextPing();
      clock.advance(const Duration(milliseconds: 5));
      calculator.onPong(_pong(ping.id));
      calculator.nextPing();

      calculator.reset();
      expect(calculator.samples, isEmpty);
      expect(calculator.pendingCount, 0);
      expect(calculator.latestRttMs, 0);
    });

    test('the server clock is recorded but never used for the RTT', () {
      final FakeClock clock = FakeClock();
      final RttCalculator calculator = RttCalculator(clock: clock);
      final PingMessage ping = calculator.nextPing();
      clock.advance(const Duration(milliseconds: 42));

      // A wildly different server clock must not change the measurement.
      final RttSample? sample = calculator.onPong(
        _pong(ping.id, serverTimeMs: 999999999999),
      );
      expect(sample!.rttMs, 42);
      expect(sample.serverTimeMs, 999999999999);
    });
  });
}
