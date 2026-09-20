import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/data/dto/rest_market_dto.dart';
import 'package:pulse_trade_frontend/data/dto/trade_dto.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/entities/trade_side.dart';

/// Maps the `trade` and `trade_batch` payloads onto [Trade] entities.
extension TradeDtoMapper on TradeDto {
  /// The domain trade.
  ///
  /// [omittedCount] is zero for a frame that carries one execution and is the
  /// batch's count for a trade that survived compaction.
  Trade toEntity({int omittedCount = 0}) {
    final TradeSide? parsedSide = TradeSide.tryParse(side);
    if (parsedSide == null) {
      throw FormatException('unknown trade side', side);
    }
    return Trade(
      tradeId: tradeId,
      symbol: symbol,
      timestamp: DateTime.parse(timestamp).toUtc(),
      price: Money.parse(price),
      quantity: Quantity.parse(quantity),
      side: parsedSide,
      omittedCount: omittedCount,
    );
  }
}

/// Maps a compacted `trade_batch` payload onto its surviving trades.
extension TradeBatchDtoMapper on TradeBatchDto {
  /// The batch's trades, oldest first, each carrying the batch's
  /// [TradeBatchDto.omittedCount] so the UI can surface what was dropped.
  List<Trade> toEntities() => <Trade>[
    for (final TradeDto trade in trades)
      trade.toEntity(omittedCount: omittedCount),
  ];
}

/// Maps the `GET /api/v1/markets/{symbol}/trades` response onto domain trades.
extension TradesResponseDtoMapper on TradesResponseDto {
  /// The recent tape, in the order the backend returned it (newest first).
  List<Trade> toEntities() => <Trade>[
    for (final TradeDto trade in trades) trade.toEntity(),
  ];
}
