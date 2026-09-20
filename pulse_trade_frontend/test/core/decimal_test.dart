import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';

void main() {
  group('Money exact parsing (M-11)', () {
    test('a wire decimal string parses to an exact scaled integer', () {
      final Money price = Money.parse('67421.35');
      expect(price.scaled, 6742135);
      expect(price.scale, 100);
      expect(price.fractionDigits, 2);
      expect(price.format(), '67421.35');
      expect(price, const Money.fromScaled(6742135, 100));
    });

    test('parsing and formatting round-trips every wire shape', () {
      const List<String> values = <String>[
        '0',
        '0.00',
        '0.18400000',
        '67421.35',
        '67421.30',
        '1000000.01',
        '-142.12',
        '-0.05',
        '67391.2',
      ];
      for (final String value in values) {
        expect(Money.parse(value).format(), value, reason: value);
      }
    });

    test('no double round-trip changes a value', () {
      // With binary floating point, 0.1 + 0.2 != 0.3. Exact fixed point does not
      // have that failure mode, which is the whole point of this type.
      expect(Money.parse('0.1') + Money.parse('0.2'), Money.parse('0.3'));
      expect(
        (0.1 + 0.2) == 0.3,
        isFalse,
        reason: 'documents the double behaviour the type avoids',
      );

      final Money sum = Money.parse('67421.35') + Money.parse('0.05');
      expect(sum.format(), '67421.40');
      expect(sum.scaled, 6742140);
    });

    test('spread arithmetic is exact', () {
      final Money bid = Money.parse('67420.90');
      final Money ask = Money.parse('67421.10');
      final Money spread = ask - bid;
      expect(spread.format(), '0.20');
      expect(spread.scaled, 20);
      expect(spread, Money.parse('0.20'));
    });

    test('subtraction can produce an exact negative change', () {
      final Money change = Money.parse('67300.00') - Money.parse('67442.12');
      expect(change.format(), '-142.12');
      expect(change.sign, -1);
      expect(-change, Money.parse('142.12'));
    });

    test('ordering compares across scales without loss', () {
      expect(Money.parse('100.00').compareTo(Money.parse('100.01')), -1);
      expect(Money.parse('100.01') > Money.parse('100.00'), isTrue);
      expect(Money.parse('100.00') < Money.parse('100.01'), isTrue);
      expect(Money.parse('100.00') >= Money.parse('100.00'), isTrue);
      expect(
        Money.parse(
          '1.0',
          scale: 10,
        ).compareTo(Money.parse('1.00', scale: 100)),
        0,
      );
      expect(
        Money.parse('1.0', scale: 10) + Money.parse('0.50', scale: 100),
        Money.parse('1.50'),
      );
    });

    test('an explicit scale rejects excess precision instead of rounding', () {
      expect(
        () => Money.parse('67421.355', scale: 100),
        throwsA(isA<FormatException>()),
      );
      // Excess digits that are all zeros are accepted: they carry no value.
      expect(Money.parse('67421.3500', scale: 100), Money.parse('67421.35'));
    });

    test('an inferred scale keeps the backend formatting', () {
      final Money price = Money.parse('67421.3500');
      expect(price.scale, 10000);
      expect(price.format(), '67421.3500');

      final Quantity volume = Quantity.parse('0.18400000');
      expect(volume.scale, 100000000);
      expect(volume.format(), '0.18400000');
      expect(volume.scaled, 18400000);
    });

    test('tryParse returns null instead of throwing on malformed input', () {
      expect(Money.tryParse(''), isNull);
      expect(Money.tryParse('abc'), isNull);
      expect(Money.tryParse('1.2.3'), isNull);
      expect(Money.tryParse('1,000.00'), isNull);
      expect(Money.tryParse('  67421.35  '), Money.parse('67421.35'));
      expect(Money.tryParse('.5'), Money.parse('0.5'));
      expect(Money.tryParse('+5.00'), Money.parse('5.00'));
      expect(Money.tryParse('-5.00'), Money.parse('-5.00'));
    });

    test('a scale that is not a power of ten is rejected', () {
      expect(
        () => const Money.fromScaled(1, 3).format(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('toDouble is a rendering-boundary conversion only', () {
      // The conversion is allowed exactly once, at the chart/depth boundary.
      expect(Money.parse('67421.35').toDouble(), 67421.35);
      expect(const Money.fromScaled(1, 100).toDouble(), 0.01);
    });

    test('zero and sign helpers behave', () {
      expect(Money.zero(100).isZero, isTrue);
      expect(Money.parse('0.00').isZero, isTrue);
      expect(Money.parse('0.01').isZero, isFalse);
      expect(Money.parse('0.00').sign, 0);
      expect(Money.parse('-0.01').sign, -1);
      expect(Money.parse('0.01').sign, 1);
    });
  });

  group('Quantity exact parsing', () {
    test('parses and formats exactly', () {
      final Quantity quantity = Quantity.parse('0.18400000');
      expect(quantity.scaled, 18400000);
      expect(quantity.scale, 100000000);
      expect(quantity.format(), '0.18400000');
    });

    test('zero means delete for a book level and is detectable', () {
      expect(Quantity.parse('0').isZero, isTrue);
      expect(Quantity.parse('0.00000000').isZero, isTrue);
      expect(Quantity.parse('0.00000001').isZero, isFalse);
    });

    test('addition is exact across scales', () {
      expect(
        Quantity.parse('0.1') + Quantity.parse('0.2'),
        Quantity.parse('0.3'),
      );
      expect(
        Quantity.parse('0.38000000') + Quantity.parse('0.40000000'),
        Quantity.parse('0.78000000'),
      );
    });

    test('ordering is exact', () {
      expect(
        Quantity.parse('0.00000010') > Quantity.parse('0.00000009'),
        isTrue,
      );
      expect(Quantity.parse('0.5') < Quantity.parse('0.50'), isFalse);
    });

    test('tryParse returns null for malformed input', () {
      expect(Quantity.tryParse('nope'), isNull);
      expect(Quantity.tryParse(''), isNull);
    });
  });
}
