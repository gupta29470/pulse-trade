import 'package:json_annotation/json_annotation.dart';

part 'trade_dto.g.dart';

/// `trade` — one canonical execution.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class TradeDto {
  /// Creates a trade payload.
  const TradeDto({
    required this.tradeId,
    required this.symbol,
    required this.timestamp,
    required this.price,
    required this.quantity,
    required this.side,
  });

  /// Decodes a trade payload.
  factory TradeDto.fromJson(Map<String, dynamic> json) =>
      _$TradeDtoFromJson(json);

  /// Engine trade id, strictly increasing.
  final int tradeId;

  /// Canonical symbol id.
  final String symbol;

  /// Execution time, RFC3339 with milliseconds, UTC.
  final String timestamp;

  /// Execution price as an exact decimal string.
  final String price;

  /// Executed quantity as an exact decimal string.
  final String quantity;

  /// Aggressor side (`BUY` or `SELL`).
  final String side;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$TradeDtoToJson(this);
}

/// `trade_batch` — compacted trades for the DEGRADED and MINIMAL tiers.
///
/// Compaction is surfaced rather than hidden: [omittedCount] is shown in the UI
/// so a throttled feed is never mistaken for a quiet market.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class TradeBatchDto {
  /// Creates a trade batch payload.
  const TradeBatchDto({
    required this.symbol,
    required this.trades,
    required this.compacted,
    required this.omittedCount,
  });

  /// Decodes a trade batch payload.
  factory TradeBatchDto.fromJson(Map<String, dynamic> json) =>
      _$TradeBatchDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// The trades that survived compaction, oldest first.
  final List<TradeDto> trades;

  /// Whether any intermediate trade was omitted.
  final bool compacted;

  /// How many trades the backend omitted when compacting.
  final int omittedCount;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$TradeBatchDtoToJson(this);
}
