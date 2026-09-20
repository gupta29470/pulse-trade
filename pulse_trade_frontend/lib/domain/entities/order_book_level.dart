import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/serialization/decimal.dart';

/// One absolute price level of the order book.
///
/// Deltas carry **absolute** quantities, never increments, so applying a level
/// is a pure replacement. A zero quantity is not a value: it is the instruction
/// to delete the level.
final class OrderBookLevel extends Equatable {
  /// Creates a level.
  const OrderBookLevel({required this.price, required this.quantity});

  /// Level price.
  final Money price;

  /// Absolute resting quantity at [price]; zero means delete.
  final Quantity quantity;

  /// True when this level removes its price from the book.
  bool get isDelete => quantity.isZero;

  @override
  List<Object?> get props => <Object?>[price, quantity];

  @override
  String toString() => 'Level(${price.format()} × ${quantity.format()})';
}
