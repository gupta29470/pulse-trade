/// The aggressor side of a trade.
enum TradeSide {
  /// Buyer lifted the offer.
  buy('BUY'),

  /// Seller hit the bid.
  sell('SELL');

  const TradeSide(this.wire);

  /// The exact wire value.
  final String wire;

  /// Parses a wire side, returning `null` for anything unexpected so a caller
  /// can reject the frame rather than invent a side.
  static TradeSide? tryParse(String value) {
    for (final TradeSide side in TradeSide.values) {
      if (side.wire == value) return side;
    }
    return null;
  }

  /// Opposite side, used when rendering the mirrored depth columns.
  TradeSide get opposite =>
      this == TradeSide.buy ? TradeSide.sell : TradeSide.buy;
}
