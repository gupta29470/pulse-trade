import 'package:json_annotation/json_annotation.dart';

part 'order_book_dto.g.dart';

/// `order_book_snapshot` — a full book image at one engine `updateId`.
///
/// The same payload backs the WS frame and the REST order-book endpoint, which
/// is what lets the synchronizer treat both sources identically.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class OrderBookSnapshotDto {
  /// Creates a snapshot payload.
  const OrderBookSnapshotDto({
    required this.symbol,
    required this.epoch,
    required this.updateId,
    required this.bids,
    required this.asks,
    required this.serverTime,
  });

  /// Decodes a snapshot payload.
  factory OrderBookSnapshotDto.fromJson(Map<String, dynamic> json) =>
      _$OrderBookSnapshotDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// Engine epoch; a change invalidates every buffered delta.
  final int epoch;

  /// The engine update id this image corresponds to.
  final int updateId;

  /// Bid levels as `[price, quantity]` decimal-string pairs, best first.
  final List<List<String>> bids;

  /// Ask levels as `[price, quantity]` decimal-string pairs, best first.
  final List<List<String>> asks;

  /// Server time the image was taken, RFC3339 with milliseconds, UTC.
  final String serverTime;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$OrderBookSnapshotDtoToJson(this);
}

/// `order_book_delta` — one contiguous range of engine update ids.
///
/// The range is what makes per-tier coalescing safe: continuity is provable
/// with `firstUpdateId <= applied + 1 <= lastUpdateId` even when several engine
/// updates were merged into one frame. A zero quantity is preserved
/// on purpose: it is how a delta deletes a level.
@JsonSerializable(explicitToJson: true, fieldRename: FieldRename.none)
final class OrderBookDeltaDto {
  /// Creates a delta payload.
  const OrderBookDeltaDto({
    required this.symbol,
    required this.epoch,
    required this.firstUpdateId,
    required this.lastUpdateId,
    required this.bids,
    required this.asks,
  });

  /// Decodes a delta payload.
  factory OrderBookDeltaDto.fromJson(Map<String, dynamic> json) =>
      _$OrderBookDeltaDtoFromJson(json);

  /// Canonical symbol id.
  final String symbol;

  /// Engine epoch the range belongs to.
  final int epoch;

  /// First engine update id covered by the range.
  final int firstUpdateId;

  /// Last engine update id covered by the range.
  final int lastUpdateId;

  /// Absolute bid levels in the range, as `[price, quantity]` pairs.
  final List<List<String>> bids;

  /// Absolute ask levels in the range, as `[price, quantity]` pairs.
  final List<List<String>> asks;

  /// Encodes this payload.
  Map<String, dynamic> toJson() => _$OrderBookDeltaDtoToJson(this);
}
