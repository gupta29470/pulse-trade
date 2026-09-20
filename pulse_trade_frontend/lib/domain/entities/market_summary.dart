import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';

/// The rolling 24h view of one market.
///
/// Every field is computed by the backend — the `market_summary` frame or
/// `GET /api/v1/markets/{symbol}/summary` — and the app formats and caches it
/// but never recomputes it.
final class MarketSummary extends Equatable {
  /// Creates a summary.
  const MarketSummary({
    required this.symbol,
    required this.last,
    required this.open24h,
    required this.high24h,
    required this.low24h,
    required this.volume24h,
    required this.change,
    required this.changeBasisPoints,
    required this.trades24h,
    required this.updatedAt,
  });

  /// Canonical symbol id.
  final String symbol;

  /// Latest trade price.
  final Money last;

  /// Price 24h ago.
  final Money open24h;

  /// Highest price in the window.
  final Money high24h;

  /// Lowest price in the window.
  final Money low24h;

  /// Exact sum of quantities traded in the window.
  final Quantity volume24h;

  /// Absolute change over the window (`last - open24h`, computed by the backend).
  final Money change;

  /// Change in basis points; 100 bp = 1 %.
  final int changeBasisPoints;

  /// Number of trades in the window.
  final int trades24h;

  /// When the backend produced this summary.
  final DateTime updatedAt;

  /// True when the market is up on the day, used for the ▲/▼ pill direction.
  bool get isUp => changeBasisPoints >= 0;

  /// The change as a percentage for display only. 1 bp = 0.01 %.
  double get changePercent => changeBasisPoints / 100;

  @override
  List<Object?> get props => <Object?>[
    symbol,
    last,
    open24h,
    high24h,
    low24h,
    volume24h,
    change,
    changeBasisPoints,
    trades24h,
    updatedAt,
  ];

  @override
  String toString() =>
      'MarketSummary($symbol, last=${last.format()}, bp=$changeBasisPoints)';
}
