import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/market/interval_request_guard.dart';

void main() {
  group('IntervalRequestGuard (M-06 interval race)', () {
    test(
      'a late response for the previous interval is rejected and counted',
      () {
        final OnDeviceMetrics metrics = OnDeviceMetrics();
        final IntervalRequestGuard guard = IntervalRequestGuard(
          metrics: metrics,
        );

        final int oneMinute = guard.begin(CandleInterval.m1);
        expect(oneMinute, 1);
        expect(guard.isCurrent(oneMinute), isTrue);

        final int fiveMinute = guard.begin(CandleInterval.m5);
        expect(fiveMinute, 2);
        expect(guard.currentInterval, CandleInterval.m5);

        // The 5m response arrives first and is committed.
        expect(guard.accept(fiveMinute, CandleInterval.m5), isTrue);

        // The 1m response arrives late: rejected, and observable in metrics.
        expect(guard.isCurrent(oneMinute), isFalse);
        expect(guard.accept(oneMinute, CandleInterval.m1), isFalse);
        expect(guard.rejectedCount, 1);
        expect(metrics.value(MetricNames.staleHistoryResponsesTotal), 1);

        // The selected interval is untouched by the rejection.
        expect(guard.currentInterval, CandleInterval.m5);
        expect(guard.currentRequestId, fiveMinute);
      },
    );

    test(
      'a response with the current id but the wrong interval is rejected',
      () {
        final OnDeviceMetrics metrics = OnDeviceMetrics();
        final IntervalRequestGuard guard = IntervalRequestGuard(
          metrics: metrics,
        );

        final int request = guard.begin(CandleInterval.m1);
        expect(guard.accept(request, CandleInterval.m5), isFalse);
        expect(guard.rejectedCount, 1);
        expect(metrics.value(MetricNames.staleHistoryResponsesTotal), 1);
      },
    );

    test('request ids are monotonic and never reused', () {
      final IntervalRequestGuard guard = IntervalRequestGuard();
      final List<int> ids = <int>[
        guard.begin(CandleInterval.m1),
        guard.begin(CandleInterval.m5),
        guard.begin(CandleInterval.m15),
      ];
      expect(ids, <int>[1, 2, 3]);
    });

    test('complete clears the pending request for the current id only', () {
      final IntervalRequestGuard guard = IntervalRequestGuard();
      final int first = guard.begin(CandleInterval.m1);
      final int second = guard.begin(CandleInterval.m5);

      guard.complete(first);
      expect(guard.hasPendingRequest, isTrue);
      expect(guard.currentRequestId, second);

      guard.complete(second);
      expect(guard.hasPendingRequest, isFalse);
      expect(guard.currentInterval, isNull);
    });

    test('a fresh guard rejects id zero', () {
      final IntervalRequestGuard guard = IntervalRequestGuard();
      expect(guard.isCurrent(0), isFalse);
      expect(guard.accept(0, CandleInterval.m1), isFalse);
    });
  });
}
