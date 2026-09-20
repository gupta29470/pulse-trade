import 'package:json_annotation/json_annotation.dart';

/// A price held as a fixed-point integer scaled by a power of ten.
///
/// Prices arrive as decimal **strings** (`"67421.35"`) and are never parsed with
/// `double.parse`: a binary float cannot represent `0.1`, and the spread, the
/// change and the candle body would all drift. [scaled] is the exact integer and
/// [scale] is the power of ten it is divided by (`100` for a 2-digit tick).
///
/// Conversion to `double` is allowed exactly once, at the chart/depth rendering
/// boundary, via [toDouble].
final class Money implements Comparable<Money> {
  /// Wraps an already-scaled integer. Prefer [parse] for wire values.
  const Money.fromScaled(this.scaled, this.scale);

  /// The exact decimal value of [value] parsed at [scale].
  ///
  /// When [scale] is omitted it is inferred from the number of fraction digits
  /// in the string, which preserves the backend's exact formatting on the way
  /// back out. A value with more non-zero fraction digits than [scale] allows is
  /// rejected instead of rounded, mirroring the backend's `ErrInexactValue`.
  factory Money.parse(String value, {int? scale}) {
    final parsed = _parseFixed(value, scale);
    if (parsed == null) {
      throw FormatException('not an exact decimal value', value);
    }
    return Money.fromScaled(parsed.scaled, parsed.scale);
  }

  /// Zero at [scale].
  factory Money.zero(int scale) => Money.fromScaled(0, scale);

  /// Like [parse] but returns `null` instead of throwing, for user input.
  static Money? tryParse(String value, {int? scale}) {
    final parsed = _parseFixed(value, scale);
    return parsed == null
        ? null
        : Money.fromScaled(parsed.scaled, parsed.scale);
  }

  /// The exact integer value, already multiplied by [scale].
  final int scaled;

  /// The power of ten dividing [scaled].
  final int scale;

  /// Digits shown after the decimal point for this [scale].
  int get fractionDigits => _digitsForScale(scale);

  /// True when the value is exactly zero.
  bool get isZero => scaled == 0;

  /// `-1`, `0` or `1`.
  int get sign => scaled.sign;

  /// The exact decimal string, e.g. `Money.parse('67421.35').format() == '67421.35'`.
  String format() => _formatFixed(scaled, scale);

  /// The rendering-boundary conversion. Never use this for arithmetic.
  double toDouble() => scaled / scale;

  /// Exact addition; the result takes the wider of the two scales.
  Money operator +(Money other) {
    final (int left, int right, int scale) = _align(
      scaled,
      this.scale,
      other.scaled,
      other.scale,
    );
    return Money.fromScaled(left + right, scale);
  }

  /// Exact subtraction; the result takes the wider of the two scales.
  Money operator -(Money other) {
    final (int left, int right, int scale) = _align(
      scaled,
      this.scale,
      other.scaled,
      other.scale,
    );
    return Money.fromScaled(left - right, scale);
  }

  /// Arithmetic negation, used to render a negative 24h change.
  Money operator -() => Money.fromScaled(-scaled, scale);

  @override
  int compareTo(Money other) {
    final (int left, int right, _) = _align(
      scaled,
      scale,
      other.scaled,
      other.scale,
    );
    return left.compareTo(right);
  }

  /// True when this value is strictly less than [other].
  bool operator <(Money other) => compareTo(other) < 0;

  /// True when this value is less than or equal to [other].
  bool operator <=(Money other) => compareTo(other) <= 0;

  /// True when this value is strictly greater than [other].
  bool operator >(Money other) => compareTo(other) > 0;

  /// True when this value is greater than or equal to [other].
  bool operator >=(Money other) => compareTo(other) >= 0;

  /// Equality is scale-sensitive so a value parsed from the wire compares equal
  /// to a literal built with the same scale, and so `==` stays cheap.
  @override
  bool operator ==(Object other) =>
      other is Money && other.scaled == scaled && other.scale == scale;

  @override
  int get hashCode => Object.hash(scaled, scale);

  @override
  String toString() => format();
}

/// A traded quantity held as a fixed-point integer.
///
/// Identical shape to [Money] because the wire treats both as decimal strings;
/// keeping them as distinct types means a quantity can never be passed where a
/// price is expected.
final class Quantity implements Comparable<Quantity> {
  /// Wraps an already-scaled integer. Prefer [parse] for wire values.
  const Quantity.fromScaled(this.scaled, this.scale);

  /// The exact decimal value of [value] parsed at [scale].
  factory Quantity.parse(String value, {int? scale}) {
    final parsed = _parseFixed(value, scale);
    if (parsed == null) {
      throw FormatException('not an exact decimal value', value);
    }
    return Quantity.fromScaled(parsed.scaled, parsed.scale);
  }

  /// Zero at [scale].
  factory Quantity.zero(int scale) => Quantity.fromScaled(0, scale);

  /// Like [parse] but returns `null` instead of throwing, for user input.
  static Quantity? tryParse(String value, {int? scale}) {
    final parsed = _parseFixed(value, scale);
    return parsed == null
        ? null
        : Quantity.fromScaled(parsed.scaled, parsed.scale);
  }

  /// The exact integer value, already multiplied by [scale].
  final int scaled;

  /// The power of ten dividing [scaled].
  final int scale;

  /// Digits shown after the decimal point for this [scale].
  int get fractionDigits => _digitsForScale(scale);

  /// True when the value is exactly zero, which for a book level means delete.
  bool get isZero => scaled == 0;

  /// `-1`, `0` or `1`.
  int get sign => scaled.sign;

  /// The exact decimal string.
  String format() => _formatFixed(scaled, scale);

  /// The rendering-boundary conversion used for depth-bar proportions only.
  double toDouble() => scaled / scale;

  /// Exact addition; the result takes the wider of the two scales.
  Quantity operator +(Quantity other) {
    final (int left, int right, int scale) = _align(
      scaled,
      this.scale,
      other.scaled,
      other.scale,
    );
    return Quantity.fromScaled(left + right, scale);
  }

  /// Exact subtraction; the result takes the wider of the two scales.
  Quantity operator -(Quantity other) {
    final (int left, int right, int scale) = _align(
      scaled,
      this.scale,
      other.scaled,
      other.scale,
    );
    return Quantity.fromScaled(left - right, scale);
  }

  @override
  int compareTo(Quantity other) {
    final (int left, int right, _) = _align(
      scaled,
      scale,
      other.scaled,
      other.scale,
    );
    return left.compareTo(right);
  }

  /// True when this value is strictly less than [other].
  bool operator <(Quantity other) => compareTo(other) < 0;

  /// True when this value is strictly greater than [other].
  bool operator >(Quantity other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Quantity && other.scaled == scaled && other.scale == scale;

  @override
  int get hashCode => Object.hash(scaled, scale);

  @override
  String toString() => format();
}

/// Generated-codec bridge that keeps prices out of `double`.
final class MoneyConverter implements JsonConverter<Money, String> {
  /// Const so a field annotation can construct it.
  const MoneyConverter();

  @override
  Money fromJson(String json) => Money.parse(json);

  @override
  String toJson(Money object) => object.format();
}

/// Nullable counterpart of [MoneyConverter].
final class NullableMoneyConverter implements JsonConverter<Money?, String?> {
  /// Const so a field annotation can construct it.
  const NullableMoneyConverter();

  @override
  Money? fromJson(String? json) => json == null ? null : Money.parse(json);

  @override
  String? toJson(Money? object) => object?.format();
}

/// Generated-codec bridge that keeps quantities out of `double`.
final class QuantityConverter implements JsonConverter<Quantity, String> {
  /// Const so a field annotation can construct it.
  const QuantityConverter();

  @override
  Quantity fromJson(String json) => Quantity.parse(json);

  @override
  String toJson(Quantity object) => object.format();
}

/// Nullable counterpart of [QuantityConverter].
final class NullableQuantityConverter
    implements JsonConverter<Quantity?, String?> {
  /// Const so a field annotation can construct it.
  const NullableQuantityConverter();

  @override
  Quantity? fromJson(String? json) =>
      json == null ? null : Quantity.parse(json);

  @override
  String? toJson(Quantity? object) => object?.format();
}

/// The outcome of parsing one fixed-point decimal string.
final class _ParsedFixed {
  const _ParsedFixed(this.scaled, this.scale);

  final int scaled;
  final int scale;
}

_ParsedFixed? _parseFixed(String raw, int? requestedScale) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  var negative = false;
  if (text.startsWith('-')) {
    negative = true;
    text = text.substring(1);
  } else if (text.startsWith('+')) {
    text = text.substring(1);
  }
  if (text.isEmpty) return null;

  final int dot = text.indexOf('.');
  final String whole;
  String fraction;
  if (dot < 0) {
    whole = text;
    fraction = '';
  } else {
    whole = text.substring(0, dot);
    fraction = text.substring(dot + 1);
    if (fraction.contains('.')) return null;
  }

  final digits = whole.isEmpty ? '0' : whole;
  if (!_isAllDigits(digits)) return null;
  if (fraction.isNotEmpty && !_isAllDigits(fraction)) return null;

  final int scale;
  if (requestedScale == null) {
    scale = _pow10(fraction.length);
  } else {
    if (requestedScale < 1) return null;
    scale = requestedScale;
    final int allowed = _digitsForScale(scale);
    if (fraction.length > allowed) {
      // Excess precision is tolerated only when it is entirely zeros: the
      // backend formats to the symbol's exact scale, so a non-zero here is a
      // contract violation worth rejecting rather than rounding away.
      for (var i = allowed; i < fraction.length; i++) {
        if (fraction[i] != '0') return null;
      }
      fraction = fraction.substring(0, allowed);
    }
    fraction = fraction.padRight(allowed, '0');
  }

  final int magnitude;
  try {
    magnitude = int.parse('$digits$fraction');
  } on FormatException {
    return null;
  }
  return _ParsedFixed(negative ? -magnitude : magnitude, scale);
}

bool _isAllDigits(String value) {
  for (var i = 0; i < value.length; i++) {
    final int code = value.codeUnitAt(i);
    if (code < 0x30 || code > 0x39) return false;
  }
  return true;
}

int _pow10(int power) {
  var out = 1;
  for (var i = 0; i < power; i++) {
    out *= 10;
  }
  return out;
}

int _digitsForScale(int scale) {
  if (scale < 1) {
    throw ArgumentError.value(
      scale,
      'scale',
      'must be a positive power of ten',
    );
  }
  var remainder = scale;
  var digits = 0;
  while (remainder > 1 && remainder % 10 == 0) {
    remainder ~/= 10;
    digits++;
  }
  if (remainder != 1) {
    throw ArgumentError.value(scale, 'scale', 'must be a power of ten');
  }
  return digits;
}

String _formatFixed(int scaled, int scale) {
  final int digits = _digitsForScale(scale);
  final bool negative = scaled < 0;
  final int magnitude = scaled.abs();
  final String sign = negative ? '-' : '';
  if (digits == 0) return '$sign$magnitude';
  final text = magnitude.toString().padLeft(digits + 1, '0');
  final int split = text.length - digits;
  return '$sign${text.substring(0, split)}.${text.substring(split)}';
}

/// Brings two fixed-point values onto a common scale by multiplying the smaller
/// scale up. Both scales are powers of ten, so the multiplication is exact.
(int, int, int) _align(int left, int leftScale, int right, int rightScale) {
  if (leftScale == rightScale) return (left, right, leftScale);
  if (leftScale > rightScale) {
    return (left, right * (leftScale ~/ rightScale), leftScale);
  }
  return (left * (rightScale ~/ leftScale), right, rightScale);
}
