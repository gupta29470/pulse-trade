import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';

/// The snapshot half of order-book synchronisation.
///
/// The synchronizer asks for a snapshot through this interface and never knows
/// whether it arrived over REST or from disk, which is what keeps it pure for
/// unit tests with no socket.
abstract interface class OrderBookRepository {
  /// Fetches a full book image for [symbol].
  ///
  /// A cached image is returned inside its 30 s TTL, and outside the TTL when
  /// the network is unavailable — marked `STALE` rather than withheld.
  Future<Result<Sourced<OrderBookSnapshot>>> loadSnapshot(
    String symbol, {
    bool forceRefresh = false,
  });
}
