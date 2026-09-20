import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';

/// The seam between the REST transport and the generated wire DTOs.
///
/// The generated `lib/data/dto/` classes and their `fromJson` mappers are owned
/// by the data layer. The transport must not import them directly: that would
/// couple `core/` to generated code and would make a DTO rename a compile error
/// in two layers at once. Instead `DioMarketApi` depends on this narrow
/// interface, whose implementation lives next to the DTOs, so the only thing
/// shared between the two layers is the domain type each endpoint returns.
///
/// Every method receives the already-decoded JSON object of the REST response
/// body (for list endpoints that is the *envelope*, e.g. `{"candles": [...]}`,
/// so the decoder can read whatever key the backend uses) and returns domain
/// entities. A decoder is expected to throw [FormatException] on a malformed
/// body; `FailureMapper` turns that into a `ProtocolFailure`.
abstract interface class MarketDtoDecoder {
  /// Decodes `GET /api/v1/markets` into the market roster.
  List<MarketInfo> decodeMarkets(Map<String, Object?> json);

  /// Decodes `GET /api/v1/markets/{symbol}/summary` into one 24h summary.
  MarketSummary decodeSummary(Map<String, Object?> json);

  /// Decodes `GET /api/v1/markets/{symbol}/orderbook` into a book image.
  OrderBookSnapshot decodeOrderBook(Map<String, Object?> json);

  /// Decodes `GET /api/v1/markets/{symbol}/candles` into ascending candles.
  List<Candle> decodeCandles(Map<String, Object?> json);

  /// Decodes `GET /api/v1/markets/{symbol}/trades` into newest-first trades.
  List<Trade> decodeTrades(Map<String, Object?> json);

  /// Decodes `GET /health` or `GET /api/v1/health` into one health snapshot.
  ///
  /// Both endpoints share this method because the detailed response is a
  /// superset of the liveness response, and the detail fields are nullable on
  /// [HealthSnapshot] for exactly that reason.
  HealthSnapshot decodeHealth(Map<String, Object?> json);

  /// Decodes `GET /api/v1/metrics/summary` into the aggregate counters.
  MetricsSnapshot decodeMetricsSummary(Map<String, Object?> json);

  /// Decodes `GET /api/v1/metrics/latency` into the bucketed RTT series.
  List<LatencyBucket> decodeLatencyBuckets(Map<String, Object?> json);

  /// Decodes `GET /api/v1/metrics/tiers` into tier transition rows.
  List<TierTransitionRecord> decodeTierTransitions(Map<String, Object?> json);

  /// Decodes `GET /api/v1/metrics/sessions` into session rows.
  List<SessionRecord> decodeSessions(Map<String, Object?> json);

  /// Decodes `GET /api/v1/metrics/delivery` into delivery windows.
  List<DeliveryWindow> decodeDeliveryWindows(Map<String, Object?> json);
}
