import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/data/dto/order_book_dto.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';

/// Converts wire `[price, quantity]` decimal-string pairs into domain levels.
///
/// A pair that is not exactly two elements is a contract violation, so it is a
/// parse failure rather than a silently dropped level: dropping one side of the
/// book would corrupt every spread and depth bar drawn afterwards.
extension OrderBookWireLevelsMapper on List<List<String>> {
  /// The domain levels described by this wire list, in wire order.
  List<OrderBookLevel> toLevels() {
    final List<OrderBookLevel> levels = <OrderBookLevel>[];
    for (final List<String> pair in this) {
      if (pair.length != 2) {
        throw FormatException(
          'order book level must be [price, quantity]',
          pair,
        );
      }
      levels.add(
        OrderBookLevel(
          price: Money.parse(pair[0]),
          quantity: Quantity.parse(pair[1]),
        ),
      );
    }
    return levels;
  }
}

/// Maps a `order_book_snapshot` payload onto the domain image.
extension OrderBookSnapshotDtoMapper on OrderBookSnapshotDto {
  /// The domain snapshot. Bids stay descending, asks ascending.
  OrderBookSnapshot toEntity() => OrderBookSnapshot(
    symbol: symbol,
    epoch: epoch,
    updateId: updateId,
    bids: bids.toLevels(),
    asks: asks.toLevels(),
    serverTime: DateTime.parse(serverTime).toUtc(),
  );
}

/// Maps the two level lists of an `order_book_delta` onto domain levels.
extension OrderBookDeltaDtoMapper on OrderBookDeltaDto {
  /// Absolute bid levels carried by this range; zero quantity means delete.
  List<OrderBookLevel> get bidLevels => bids.toLevels();

  /// Absolute ask levels carried by this range.
  List<OrderBookLevel> get askLevels => asks.toLevels();
}
