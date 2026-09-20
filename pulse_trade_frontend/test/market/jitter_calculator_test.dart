import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/domain/market/jitter_calculator.dart';

void main() {
  group('JitterCalculator (M-02)', () {
    test('the first sample reports zero jitter', () {
      final JitterCalculator jitter = JitterCalculator();
      expect(jitter.add(74), 0);
      expect(jitter.jitterMs, 0);
      expect(jitter.sampleCount, 1);
      expect(jitter.hasInsufficientSamples, isTrue);
    });

    test('fewer than two samples report zero', () {
      final JitterCalculator jitter = JitterCalculator();
      jitter.add(10);
      expect(jitter.jitterMs, 0);
      expect(jitter.hasInsufficientSamples, isTrue);
    });

    test('jitter is the mean absolute consecutive difference', () {
      final JitterCalculator jitter = JitterCalculator();
      jitter.add(100);
      jitter.add(110); // |110-100| = 10
      expect(jitter.jitterMs, closeTo(10, 1e-9));
      jitter.add(130); // |130-110| = 20 -> mean 15
      expect(jitter.jitterMs, closeTo(15, 1e-9));
      jitter.add(130); // third difference 0 -> mean 10
      expect(jitter.jitterMs, closeTo(10, 1e-9));
    });

    test('a flat series reports zero jitter', () {
      final JitterCalculator jitter = JitterCalculator();
      for (var i = 0; i < 6; i++) {
        jitter.add(50);
      }
      expect(jitter.jitterMs, 0);
      expect(jitter.sampleCount, 6);
    });

    test('the window is bounded to the documented size', () {
      final JitterCalculator jitter = JitterCalculator();
      for (var i = 0; i < 25; i++) {
        jitter.add(10 + i.toDouble());
      }
      expect(jitter.sampleCount, 10);
      // The retained window is 25..34, so every consecutive difference is 1.
      expect(jitter.jitterMs, closeTo(1, 1e-9));
    });

    test('an outlier above 3x the window median is capped and counted', () {
      final JitterCalculator jitter = JitterCalculator();
      for (var i = 0; i < 10; i++) {
        jitter.add(100);
      }
      expect(jitter.cappedCount, 0);
      expect(jitter.windowMedianMs, closeTo(100, 1e-9));

      jitter.add(5000);
      expect(jitter.cappedCount, 1);
      // 3 x median = 300 enters the window instead of 5000. The window now holds
      // nine 100s and one 300, so the mean absolute difference is 200 / 9.
      expect(jitter.jitterMs, closeTo(200 / 9, 1e-9));
    });

    test('a sample inside the cap is not capped', () {
      final JitterCalculator jitter = JitterCalculator();
      for (var i = 0; i < 10; i++) {
        jitter.add(100);
      }
      jitter.add(250); // below 3 x 100
      expect(jitter.cappedCount, 0);
      expect(jitter.jitterMs, closeTo(150 / 9, 1e-9));
    });

    test(
      'the median of an even-sized window is the mean of the two middles',
      () {
        final JitterCalculator jitter = JitterCalculator();
        for (final double value in <double>[10, 20, 30, 40]) {
          jitter.add(value);
        }
        expect(jitter.windowMedianMs, closeTo(25, 1e-9));
      },
    );

    test('reset clears the window and the cap counter', () {
      final JitterCalculator jitter = JitterCalculator();
      jitter.add(100);
      jitter.add(100);
      jitter.add(5000);
      expect(jitter.cappedCount, 1);

      jitter.reset();
      expect(jitter.sampleCount, 0);
      expect(jitter.cappedCount, 0);
      expect(jitter.jitterMs, 0);
      expect(jitter.hasInsufficientSamples, isTrue);
    });

    test('the safe-band check is informational only', () {
      final JitterCalculator jitter = JitterCalculator();
      jitter.add(100);
      jitter.add(110);
      expect(jitter.isWithinSafeBand(50), isTrue);
      expect(jitter.isWithinSafeBand(5), isFalse);
    });
  });

  group('standardDeviationOf', () {
    test('returns zero for fewer than two values', () {
      expect(standardDeviationOf(<double>[]), 0);
      expect(standardDeviationOf(<double>[42]), 0);
    });

    test('returns the population standard deviation', () {
      expect(
        standardDeviationOf(<double>[2, 4, 4, 4, 5, 5, 7, 9]),
        closeTo(2, 1e-9),
      );
    });
  });
}
