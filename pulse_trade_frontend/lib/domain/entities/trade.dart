import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/trade_side.dart';

/// One executed trade.
///
/// `tradeId` is a strictly increasing engine id, which is what makes both
/// duplicate collapsing and out-of-order rejection possible without a clock.
final class Trade extends Equatable {
  /// Creates a trade.
  const Trade({
    required this.tradeId,
    required this.symbol,
    required this.timestamp,
    required this.price,
    required this.quantity,
    required this.side,
    this.omittedCount = 0,
  });

  /// Engine trade id.
  final int tradeId;

  /// Canonical symbol id.
  final String symbol;

  /// Execution time, UTC.
  final DateTime timestamp;

  /// Execution price, exact.
  final Money price;

  /// Executed quantity, exact.
  final Quantity quantity;

  /// Aggressor side.
  final TradeSide side;

  /// How many intermediate trades the backend omitted when compacting a batch.
  /// Surfaced in the UI rather than hidden.
  final int omittedCount;

  /// True when this row stands in for more than one execution.
  bool get isCompacted => omittedCount > 0;

  @override
  List<Object?> get props => <Object?>[
    tradeId,
    symbol,
    timestamp,
    price,
    quantity,
    side,
    omittedCount,
  ];

  @override
  String toString() =>
      'Trade(#$tradeId, ${price.format()} × ${quantity.format()}, ${side.wire})';
}
