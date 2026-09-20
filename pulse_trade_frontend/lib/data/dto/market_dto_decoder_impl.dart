import 'package:pulse_trade_frontend/core/networking/market_dto_decoder.dart';
import 'package:pulse_trade_frontend/data/dto/market_summary_dto.dart';
import 'package:pulse_trade_frontend/data/dto/metrics_dto.dart';
import 'package:pulse_trade_frontend/data/dto/order_book_dto.dart';
import 'package:pulse_trade_frontend/data/dto/rest_market_dto.dart';
import 'package:pulse_trade_frontend/data/mappers/candle_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/market_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/metrics_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/order_book_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/trade_mapper.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';

/// The `data/` half of the REST seam.
///
/// `DioMarketApi` (in `core/networking/`) performs transport only and delegates
/// decoding here, so the generated DTO codecs and the hand-written mappers stay
/// on the `data/` side of the dependency rule and can never be imported by
/// `presentation/`.
///
/// Every method narrows the decoded JSON to a concrete DTO and maps it to a
/// domain entity. A malformed body throws a [ProtocolFailure] rather than a
/// `TypeError`, so the failure vocabulary stays closed.
final class MarketDtoDecoderImpl implements MarketDtoDecoder {
  /// Const so the composition root can hold one instance cheaply.
  const MarketDtoDecoderImpl();

  @override
  List<MarketInfo> decodeMarkets(Map<String, Object?> json) =>
      MarketsResponseDto.fromJson(_asDynamicMap(json)).toEntities();

  @override
  MarketSummary decodeSummary(Map<String, Object?> json) =>
      MarketSummaryDto.fromJson(_asDynamicMap(json)).toEntity();

  @override
  OrderBookSnapshot decodeOrderBook(Map<String, Object?> json) =>
      OrderBookSnapshotDto.fromJson(_asDynamicMap(json)).toEntity();

  @override
  List<Candle> decodeCandles(Map<String, Object?> json) =>
      CandlesResponseDto.fromJson(_asDynamicMap(json)).toEntities();

  @override
  List<Trade> decodeTrades(Map<String, Object?> json) =>
      TradesResponseDto.fromJson(_asDynamicMap(json)).toEntities();

  @override
  HealthSnapshot decodeHealth(Map<String, Object?> json) =>
      BackendHealthDto.fromJson(_asDynamicMap(json)).toEntity();

  @override
  MetricsSnapshot decodeMetricsSummary(Map<String, Object?> json) =>
      MetricsSummaryDto.fromJson(_asDynamicMap(json)).toEntity();

  @override
  List<LatencyBucket> decodeLatencyBuckets(Map<String, Object?> json) {
    final LatencyBucketsResponseDto response =
        LatencyBucketsResponseDto.fromJson(_asDynamicMap(json));
    return <LatencyBucket>[
      for (final LatencyBucketDto bucket in response.buckets) bucket.toEntity(),
    ];
  }

  @override
  List<TierTransitionRecord> decodeTierTransitions(Map<String, Object?> json) {
    final TierTransitionsResponseDto response =
        TierTransitionsResponseDto.fromJson(_asDynamicMap(json));
    return <TierTransitionRecord>[
      for (final TierTransitionDto row in response.transitions) row.toEntity(),
    ];
  }

  @override
  List<SessionRecord> decodeSessions(Map<String, Object?> json) {
    final SessionsResponseDto response = SessionsResponseDto.fromJson(
      _asDynamicMap(json),
    );
    return <SessionRecord>[
      for (final SessionDto row in response.sessions) row.toEntity(),
    ];
  }

  @override
  List<DeliveryWindow> decodeDeliveryWindows(Map<String, Object?> json) {
    final DeliveryResponseDto response = DeliveryResponseDto.fromJson(
      _asDynamicMap(json),
    );
    return <DeliveryWindow>[
      for (final DeliveryWindowDto row in response.windows) row.toEntity(),
    ];
  }

  /// The generated `fromJson` factories take `Map<String, dynamic>`, while dio
  /// hands back `Map<String, Object?>`. The conversion copies only the top-level
  /// keys; the nested values are shared, so it costs one small map allocation
  /// per response and removes every cast from this file.
  static Map<String, dynamic> _asDynamicMap(Map<String, Object?> json) =>
      Map<String, dynamic>.from(json);
}
