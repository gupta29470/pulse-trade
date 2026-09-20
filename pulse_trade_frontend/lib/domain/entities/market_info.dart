import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';

/// One row of `GET /api/v1/markets`.
///
/// Every row is a live market: it carries the backend's latest traded price and
/// its 24h change, so there is no separate "reference" shape to model.
final class MarketInfo extends Equatable {
  /// Creates a market row.
  const MarketInfo({
    required this.symbol,
    required this.display,
    required this.name,
    required this.glyph,
    required this.priceDigits,
    required this.quantityDigits,
    this.lastPrice,
    this.changeBasisPoints,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Display pair, e.g. `BTC/USDT`.
  final String display;

  /// Human name, e.g. `Bitcoin`.
  final String name;

  /// Single-character asset glyph.
  final String glyph;

  /// Digits used when formatting a price for this symbol.
  final int priceDigits;

  /// Digits used when formatting a quantity for this symbol.
  final int quantityDigits;

  /// The backend's latest traded price.
  final Money? lastPrice;

  /// Change in basis points, when the backend supplies one for the row.
  final int? changeBasisPoints;

  @override
  List<Object?> get props => <Object?>[
    symbol,
    display,
    name,
    glyph,
    priceDigits,
    quantityDigits,
    lastPrice,
    changeBasisPoints,
  ];

  @override
  String toString() => 'MarketInfo($symbol, lastPrice=$lastPrice)';
}
