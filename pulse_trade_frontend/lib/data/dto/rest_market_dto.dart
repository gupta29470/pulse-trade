import 'package:json_annotation/json_annotation.dart';
import 'package:pulse_trade_frontend/data/dto/candle_dto.dart';
import 'package:pulse_trade_frontend/data/dto/trade_dto.dart';

part 'rest_market_dto.g.dart';

/// `GET /api/v1/markets` — the symbol registry.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class MarketsResponseDto {
  /// Creates a markets response.
  const MarketsResponseDto({required this.markets});

  /// Decodes a markets response.
  factory MarketsResponseDto.fromJson(Map<String, dynamic> json) =>
      _$MarketsResponseDtoFromJson(json);

  /// Every market the backend knows about.
  final List<MarketInfoDto> markets;

  /// Encodes this response.
  Map<String, dynamic> toJson() => _$MarketsResponseDtoToJson(this);
}

/// One row of `GET /api/v1/markets`.
///
/// Every row is a live market, so the DTO carries the latest traded price for
/// each of them rather than a fixed one.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class MarketInfoDto {
  /// Creates a market row.
  const MarketInfoDto({
    required this.symbol,
    required this.display,
    required this.name,
    required this.glyph,
    required this.priceDigits,
    required this.quantityDigits,
    this.lastPrice,
    this.changeBasisPoints,
  });

  /// Decodes a market row.
  factory MarketInfoDto.fromJson(Map<String, dynamic> json) =>
      _$MarketInfoDtoFromJson(json);

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

  /// The backend's latest traded price, as an exact decimal string.
  final String? lastPrice;

  /// Change in basis points, when the backend supplies one for the row.
  final int? changeBasisPoints;

  /// Encodes this row.
  Map<String, dynamic> toJson() => _$MarketInfoDtoToJson(this);
}

/// `GET /api/v1/markets/{symbol}/candles` — history for one interval.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class CandlesResponseDto {
  /// Creates a candles response.
  const CandlesResponseDto({
    required this.symbol,
    required this.interval,
    required this.limit,
    required this.candles,
    required this.serverTime,
  });

  /// Decodes a candles response.
  factory CandlesResponseDto.fromJson(Map<String, dynamic> json) =>
      _$CandlesResponseDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// The interval id that was requested and served (`1m`, `5m`, …).
  final String interval;

  /// The bounded limit that was applied.
  final int limit;

  /// The history, oldest first. Empty is a valid, non-error answer.
  final List<CandleDto> candles;

  /// Server time the response was produced, RFC3339 UTC.
  final String serverTime;

  /// Encodes this response.
  Map<String, dynamic> toJson() => _$CandlesResponseDtoToJson(this);
}

/// `GET /api/v1/markets/{symbol}/trades` — the recent tape.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class TradesResponseDto {
  /// Creates a trades response.
  const TradesResponseDto({
    required this.symbol,
    required this.limit,
    required this.trades,
    required this.serverTime,
  });

  /// Decodes a trades response.
  factory TradesResponseDto.fromJson(Map<String, dynamic> json) =>
      _$TradesResponseDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// The bounded limit that was applied.
  final int limit;

  /// The recent trades, oldest first.
  final List<TradeDto> trades;

  /// Server time the response was produced, RFC3339 UTC.
  final String serverTime;

  /// Encodes this response.
  Map<String, dynamic> toJson() => _$TradesResponseDtoToJson(this);
}

/// The backend's process/engine/metrics health document.
///
/// One DTO serves both probes: `GET /health` is a subset of
/// `GET /api/v1/health`, so every nested object and every extra field is
/// nullable and the shared mapper fills only what was sent.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class BackendHealthDto {
  /// Creates a health document.
  const BackendHealthDto({
    required this.status,
    required this.time,
    this.version,
    this.uptimeMs,
    this.engine,
    this.metrics,
    this.sessions,
    this.reasons,
  });

  /// Decodes a health document.
  factory BackendHealthDto.fromJson(Map<String, dynamic> json) =>
      _$BackendHealthDtoFromJson(json);

  /// `ok` or `degraded`.
  final String status;

  /// Server time the document was produced, RFC3339 UTC.
  final String time;

  /// Backend build version, absent from the minimal liveness probe.
  final String? version;

  /// Process uptime in milliseconds, absent from the minimal liveness probe.
  final int? uptimeMs;

  /// Engine health, absent from the minimal liveness probe.
  final EngineHealthDto? engine;

  /// Metrics-store health, absent from the minimal liveness probe.
  final MetricsStoreHealthDto? metrics;

  /// Session counters, absent from the minimal liveness probe.
  final SessionsHealthDto? sessions;

  /// Why the status is `degraded`, when it is.
  final List<String>? reasons;

  /// Encodes this document.
  Map<String, dynamic> toJson() => _$BackendHealthDtoToJson(this);
}

/// The engine layer of the health document.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class EngineHealthDto {
  /// Creates an engine health block.
  const EngineHealthDto({
    required this.state,
    required this.symbol,
    required this.epoch,
    required this.eventIndex,
    required this.updateId,
    required this.warmupComplete,
  });

  /// Decodes an engine health block.
  factory EngineHealthDto.fromJson(Map<String, dynamic> json) =>
      _$EngineHealthDtoFromJson(json);

  /// Engine state (`STARTING`, `LIVE`, `PAUSED`, …).
  final String state;

  /// The engine's symbol id.
  final String symbol;

  /// Engine epoch.
  final int epoch;

  /// Monotonic engine event index.
  final int eventIndex;

  /// Current book update id.
  final int updateId;

  /// Whether warmup finished.
  final bool warmupComplete;

  /// Encodes this block.
  Map<String, dynamic> toJson() => _$EngineHealthDtoToJson(this);
}

/// The metrics-store layer of the health document.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class MetricsStoreHealthDto {
  /// Creates a metrics-store health block.
  const MetricsStoreHealthDto({
    required this.driver,
    required this.status,
    required this.queueDepth,
    required this.droppedTotal,
    required this.lastFlushMs,
  });

  /// Decodes a metrics-store health block.
  factory MetricsStoreHealthDto.fromJson(Map<String, dynamic> json) =>
      _$MetricsStoreHealthDtoFromJson(json);

  /// Storage driver (`sqlite`, `memory`).
  final String driver;

  /// Store status (`ok`, `degraded`, `disabled`).
  final String status;

  /// Pending rows in the writer queue.
  final int queueDepth;

  /// Rows dropped because the queue was full.
  final int droppedTotal;

  /// Duration of the last flush in milliseconds.
  final int lastFlushMs;

  /// Encodes this block.
  Map<String, dynamic> toJson() => _$MetricsStoreHealthDtoToJson(this);
}

/// The session layer of the health document.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class SessionsHealthDto {
  /// Creates a sessions health block.
  const SessionsHealthDto({required this.active, required this.total});

  /// Decodes a sessions health block.
  factory SessionsHealthDto.fromJson(Map<String, dynamic> json) =>
      _$SessionsHealthDtoFromJson(json);

  /// Sessions connected right now.
  final int active;

  /// Sessions seen since the backend started.
  final int total;

  /// Encodes this block.
  Map<String, dynamic> toJson() => _$SessionsHealthDtoToJson(this);
}

/// `GET /health` — the minimal liveness probe.
///
/// The probe answers with `status` and `time`; [version] and [uptimeMs] are
/// therefore nullable so the same document parses whether or not the server
/// enriches it.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class LivenessDto {
  /// Creates a liveness document.
  const LivenessDto({
    required this.status,
    required this.time,
    this.version,
    this.uptimeMs,
  });

  /// Decodes a liveness document.
  factory LivenessDto.fromJson(Map<String, dynamic> json) =>
      _$LivenessDtoFromJson(json);

  /// `ok` while the process is serving.
  final String status;

  /// Server time, RFC3339 with milliseconds, UTC.
  final String time;

  /// Backend build version, when the probe reports one.
  final String? version;

  /// Process uptime in milliseconds, when the probe reports one.
  final int? uptimeMs;

  /// Encodes this document.
  Map<String, dynamic> toJson() => _$LivenessDtoToJson(this);
}
