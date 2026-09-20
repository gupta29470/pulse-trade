import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/data/dto/market_summary_dto.dart';
import 'package:pulse_trade_frontend/data/dto/rest_market_dto.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';

/// Maps the `market_summary` frame onto the domain summary.
extension MarketSummaryDtoMapper on MarketSummaryDto {
  /// The domain summary.
  MarketSummary toEntity() => MarketSummary(
    symbol: symbol,
    last: Money.parse(last),
    open24h: Money.parse(open24h),
    high24h: Money.parse(high24h),
    low24h: Money.parse(low24h),
    volume24h: Quantity.parse(volume24h),
    change: Money.parse(change),
    changeBasisPoints: changeBasisPoints,
    trades24h: trades24h,
    updatedAt: DateTime.parse(updatedAt).toUtc(),
  );
}

/// Maps one `GET /api/v1/markets` row onto the domain market row.
extension MarketInfoDtoMapper on MarketInfoDto {
  /// The domain market row.
  MarketInfo toEntity() {
    final String? last = lastPrice;
    return MarketInfo(
      symbol: symbol,
      display: display,
      name: name,
      glyph: glyph,
      priceDigits: priceDigits,
      quantityDigits: quantityDigits,
      lastPrice: last == null ? null : Money.parse(last),
      changeBasisPoints: changeBasisPoints,
    );
  }
}

/// Maps the symbol registry response onto domain market rows.
extension MarketsResponseDtoMapper on MarketsResponseDto {
  /// Every market row, in registry order.
  List<MarketInfo> toEntities() => <MarketInfo>[
    for (final MarketInfoDto market in markets) market.toEntity(),
  ];
}

/// Maps the backend health document onto the domain snapshot.
///
/// One mapper serves both probes: every block the minimal liveness answer omits
/// stays `null` on the snapshot rather than being invented.
extension BackendHealthDtoMapper on BackendHealthDto {
  /// The domain health snapshot.
  HealthSnapshot toEntity() {
    final EngineHealthDto? engineDto = engine;
    final MetricsStoreHealthDto? metricsDto = metrics;
    final SessionsHealthDto? sessionsDto = sessions;
    return HealthSnapshot(
      status: status,
      version: version ?? '',
      uptimeMs: uptimeMs ?? 0,
      serverTime: DateTime.parse(time).toUtc(),
      engineState: engineDto?.state,
      engineSymbol: engineDto?.symbol,
      engineEpoch: engineDto?.epoch,
      engineEventIndex: engineDto?.eventIndex,
      engineUpdateId: engineDto?.updateId,
      warmupComplete: engineDto?.warmupComplete,
      metricsDriver: metricsDto?.driver,
      metricsStatus: metricsDto?.status,
      metricsQueueDepth: metricsDto?.queueDepth,
      metricsDroppedTotal: metricsDto?.droppedTotal,
      metricsLastFlushMs: metricsDto?.lastFlushMs,
      sessionsActive: sessionsDto?.active,
      sessionsTotal: sessionsDto?.total,
      reasons: reasons ?? const <String>[],
    );
  }
}
