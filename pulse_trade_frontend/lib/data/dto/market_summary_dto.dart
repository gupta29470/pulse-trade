import 'package:json_annotation/json_annotation.dart';

part 'market_summary_dto.g.dart';

/// `market_summary` — the rolling 24h view, computed entirely by the backend.
///
/// The app formats and caches these values but never recomputes them.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class MarketSummaryDto {
  /// Creates a market summary payload.
  const MarketSummaryDto({
    required this.symbol,
    required this.last,
    required this.open24h,
    required this.high24h,
    required this.low24h,
    required this.volume24h,
    required this.change,
    required this.changeBasisPoints,
    required this.trades24h,
    required this.updatedAt,
  });

  /// Decodes a market summary payload.
  factory MarketSummaryDto.fromJson(Map<String, dynamic> json) =>
      _$MarketSummaryDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// Latest trade price, exact.
  final String last;

  /// Price 24h ago, exact.
  final String open24h;

  /// Highest price in the window, exact.
  final String high24h;

  /// Lowest price in the window, exact.
  final String low24h;

  /// Exact sum of quantities traded in the window.
  final String volume24h;

  /// Absolute change over the window, computed by the backend.
  final String change;

  /// Change in basis points; 100 bp = 1 %.
  final int changeBasisPoints;

  /// Number of trades in the window.
  final int trades24h;

  /// When the backend produced this summary, RFC3339 UTC.
  final String updatedAt;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$MarketSummaryDtoToJson(this);
}
