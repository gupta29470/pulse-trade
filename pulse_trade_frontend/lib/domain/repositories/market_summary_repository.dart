import 'package:pulse_trade_frontend/core/result/result.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/sourced.dart';

/// The rolling 24h summary and the market roster.
abstract interface class MarketSummaryRepository {
  /// Loads the 24h summary for [symbol], cache-first.
  Future<Result<Sourced<MarketSummary>>> loadSummary(
    String symbol, {
    bool forceRefresh = false,
  });

  /// Loads every market row, cache-first with a 24 h TTL because the roster's
  /// membership changes only when the backend does.
  Future<Result<Sourced<List<MarketInfo>>>> loadMarkets({
    bool forceRefresh = false,
  });
}
