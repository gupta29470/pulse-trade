import 'package:pulse_trade_frontend/core/serialization/decimal.dart';
import 'package:pulse_trade_frontend/domain/entities/candle.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/entities/market_info.dart';
import 'package:pulse_trade_frontend/domain/entities/market_summary.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_level.dart';
import 'package:pulse_trade_frontend/domain/entities/order_book_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/trade.dart';
import 'package:pulse_trade_frontend/domain/entities/trade_side.dart';

/// Hand-written JSON codecs for the cache payloads.
///
/// Cache DTOs would normally be generated, but the cache stores **domain
/// entities** here, and the domain is deliberately hand-written. Two rules make
/// hand-written safe:
///
/// * every price and quantity is written as the exact decimal string produced
/// by `Money.format`/`Quantity.format` and read back by
/// `Money.parse`/`Quantity.parse` — a `double` never appears;
/// * every timestamp is an RFC3339 UTC string, and every candidate list is a
/// JSON array.
///
/// Each payload is tagged by [wrap] so a key that holds candles can never be
/// decoded as an order book: [unwrap] rejects a foreign kind with a
/// [FormatException], which the store turns into a cache miss instead of a type
/// error in the UI.
abstract final class CacheCodecs {
  const CacheCodecs._();

  static const String _fieldKind = 'kind';
  static const String _fieldPayload = 'payload';

  static const String _kindCandles = 'candles';
  static const String _kindOrderBook = 'order_book';
  static const String _kindTrades = 'trades';
  static const String _kindSummary = 'summary';
  static const String _kindMarkets = 'markets';

  /// Tags [payload] with the entity family it holds.
  ///
  /// The tag is what makes a payload type mismatch detectable at read time
  /// rather than at the first field access.
  static Map<String, dynamic> wrap(String kind, Object? payload) =>
      <String, dynamic>{_fieldKind: kind, _fieldPayload: payload};

  /// Splits a wrapped payload into its kind tag and body.
  ///
  /// Throws a [FormatException] when the tag is missing or the body is absent;
  /// callers pass this straight to `CacheStore.read`, which converts the throw
  /// into a miss.
  static ({String kind, Object? payload}) unwrap(
    Map<String, dynamic> envelope,
  ) {
    final Object? kind = envelope[_fieldKind];
    if (kind is! String) {
      throw FormatException('cache payload has no kind tag', envelope);
    }
    if (!envelope.containsKey(_fieldPayload)) {
      throw FormatException('cache payload has no body', envelope);
    }
    return (kind: kind, payload: envelope[_fieldPayload]);
  }

  /// Encodes a candle series as a dated `candles` payload.
  static Map<String, dynamic> encodeCandles(List<Candle> candles) =>
      wrap(_kindCandles, candles.map(_encodeCandle).toList(growable: false));

  /// Decodes a `candles` payload.
  ///
  /// Throws a [FormatException] for a kind mismatch, a malformed field or an
  /// unknown interval; the store treats that as a corrupt entry.
  static List<Candle> decodeCandles(Map<String, dynamic> payload) {
    final ({String kind, Object? payload}) envelope = unwrap(payload);
    _expectKind(envelope.kind, _kindCandles);
    final List<Object?> items = _requireList(envelope.payload, _kindCandles);
    return List<Candle>.unmodifiable(
      items.map((Object? item) => _decodeCandle(_requireMap(item, 'candle'))),
    );
  }

  /// Encodes one order-book image.
  static Map<String, dynamic> encodeOrderBookSnapshot(
    OrderBookSnapshot snapshot,
  ) => wrap(_kindOrderBook, <String, Object?>{
    'symbol': snapshot.symbol,
    'epoch': snapshot.epoch,
    'updateId': snapshot.updateId,
    'serverTime': snapshot.serverTime.toUtc().toIso8601String(),
    'bids': snapshot.bids.map(_encodeLevel).toList(growable: false),
    'asks': snapshot.asks.map(_encodeLevel).toList(growable: false),
  });

  /// Decodes one order-book image.
  static OrderBookSnapshot decodeOrderBookSnapshot(
    Map<String, dynamic> payload,
  ) {
    final ({String kind, Object? payload}) envelope = unwrap(payload);
    _expectKind(envelope.kind, _kindOrderBook);
    final Map<String, Object?> json = _requireMap(
      envelope.payload,
      _kindOrderBook,
    );
    return OrderBookSnapshot(
      symbol: _requireString(json, 'symbol'),
      epoch: _requireInt(json, 'epoch'),
      updateId: _requireInt(json, 'updateId'),
      serverTime: _requireTime(json, 'serverTime'),
      bids: _decodeLevels(json, 'bids'),
      asks: _decodeLevels(json, 'asks'),
    );
  }

  /// Encodes a recent-trade list, newest first as the UI keeps it.
  static Map<String, dynamic> encodeTrades(List<Trade> trades) =>
      wrap(_kindTrades, trades.map(_encodeTrade).toList(growable: false));

  /// Decodes a recent-trade list.
  static List<Trade> decodeTrades(Map<String, dynamic> payload) {
    final ({String kind, Object? payload}) envelope = unwrap(payload);
    _expectKind(envelope.kind, _kindTrades);
    final List<Object?> items = _requireList(envelope.payload, _kindTrades);
    return List<Trade>.unmodifiable(
      items.map((Object? item) => _decodeTrade(_requireMap(item, 'trade'))),
    );
  }

  /// Encodes the rolling 24h summary.
  static Map<String, dynamic> encodeMarketSummary(MarketSummary summary) =>
      wrap(_kindSummary, <String, Object?>{
        'symbol': summary.symbol,
        'last': summary.last.format(),
        'open24h': summary.open24h.format(),
        'high24h': summary.high24h.format(),
        'low24h': summary.low24h.format(),
        'volume24h': summary.volume24h.format(),
        'change': summary.change.format(),
        'changeBasisPoints': summary.changeBasisPoints,
        'trades24h': summary.trades24h,
        'updatedAt': summary.updatedAt.toUtc().toIso8601String(),
      });

  /// Decodes the rolling 24h summary.
  static MarketSummary decodeMarketSummary(Map<String, dynamic> payload) {
    final ({String kind, Object? payload}) envelope = unwrap(payload);
    _expectKind(envelope.kind, _kindSummary);
    final Map<String, Object?> json = _requireMap(
      envelope.payload,
      _kindSummary,
    );
    return MarketSummary(
      symbol: _requireString(json, 'symbol'),
      last: _requireMoney(json, 'last'),
      open24h: _requireMoney(json, 'open24h'),
      high24h: _requireMoney(json, 'high24h'),
      low24h: _requireMoney(json, 'low24h'),
      volume24h: _requireQuantity(json, 'volume24h'),
      change: _requireMoney(json, 'change'),
      changeBasisPoints: _requireInt(json, 'changeBasisPoints'),
      trades24h: _requireInt(json, 'trades24h'),
      updatedAt: _requireTime(json, 'updatedAt'),
    );
  }

  /// Encodes the market catalogue, which the watchlist renders offline.
  static Map<String, dynamic> encodeMarkets(List<MarketInfo> markets) =>
      wrap(_kindMarkets, markets.map(_encodeMarket).toList(growable: false));

  /// Decodes the market catalogue.
  static List<MarketInfo> decodeMarkets(Map<String, dynamic> payload) {
    final ({String kind, Object? payload}) envelope = unwrap(payload);
    _expectKind(envelope.kind, _kindMarkets);
    final List<Object?> items = _requireList(envelope.payload, _kindMarkets);
    return List<MarketInfo>.unmodifiable(
      items.map((Object? item) => _decodeMarket(_requireMap(item, 'market'))),
    );
  }

  static Map<String, Object?> _encodeCandle(Candle candle) => <String, Object?>{
    'interval': candle.interval.wire,
    'startTime': candle.startTime.toUtc().toIso8601String(),
    'open': candle.open.format(),
    'high': candle.high.format(),
    'low': candle.low.format(),
    'close': candle.close.format(),
    'volume': candle.volume.format(),
    'tradeCount': candle.tradeCount,
    'sourceSequence': candle.sourceSequence,
    'closed': candle.closed,
  };

  static Candle _decodeCandle(Map<String, Object?> json) {
    final String intervalWire = _requireString(json, 'interval');
    final CandleInterval? interval = CandleInterval.tryParse(intervalWire);
    if (interval == null) {
      throw FormatException('unknown candle interval in cache', intervalWire);
    }
    return Candle(
      interval: interval,
      startTime: _requireTime(json, 'startTime'),
      open: _requireMoney(json, 'open'),
      high: _requireMoney(json, 'high'),
      low: _requireMoney(json, 'low'),
      close: _requireMoney(json, 'close'),
      volume: _requireQuantity(json, 'volume'),
      tradeCount: _requireInt(json, 'tradeCount'),
      sourceSequence: _requireInt(json, 'sourceSequence'),
      closed: _requireBool(json, 'closed'),
    );
  }

  static Map<String, Object?> _encodeLevel(OrderBookLevel level) =>
      <String, Object?>{
        'price': level.price.format(),
        'quantity': level.quantity.format(),
      };

  static OrderBookLevel _decodeLevel(Map<String, Object?> json) =>
      OrderBookLevel(
        price: _requireMoney(json, 'price'),
        quantity: _requireQuantity(json, 'quantity'),
      );

  static List<OrderBookLevel> _decodeLevels(
    Map<String, Object?> json,
    String field,
  ) {
    final List<Object?> items = _requireList(json[field], field);
    return List<OrderBookLevel>.unmodifiable(
      items.map((Object? item) => _decodeLevel(_requireMap(item, field))),
    );
  }

  static Map<String, Object?> _encodeTrade(Trade trade) => <String, Object?>{
    'tradeId': trade.tradeId,
    'symbol': trade.symbol,
    'timestamp': trade.timestamp.toUtc().toIso8601String(),
    'price': trade.price.format(),
    'quantity': trade.quantity.format(),
    'side': trade.side.wire,
    'omittedCount': trade.omittedCount,
  };

  static Trade _decodeTrade(Map<String, Object?> json) {
    final String sideWire = _requireString(json, 'side');
    final TradeSide? side = TradeSide.tryParse(sideWire);
    if (side == null) {
      throw FormatException('unknown trade side in cache', sideWire);
    }
    return Trade(
      tradeId: _requireInt(json, 'tradeId'),
      symbol: _requireString(json, 'symbol'),
      timestamp: _requireTime(json, 'timestamp'),
      price: _requireMoney(json, 'price'),
      quantity: _requireQuantity(json, 'quantity'),
      side: side,
      omittedCount: _requireInt(json, 'omittedCount'),
    );
  }

  static Map<String, Object?> _encodeMarket(MarketInfo info) =>
      <String, Object?>{
        'symbol': info.symbol,
        'display': info.display,
        'name': info.name,
        'glyph': info.glyph,
        'priceDigits': info.priceDigits,
        'quantityDigits': info.quantityDigits,
        'lastPrice': info.lastPrice?.format(),
        'changeBasisPoints': info.changeBasisPoints,
      };

  static MarketInfo _decodeMarket(Map<String, Object?> json) => MarketInfo(
    symbol: _requireString(json, 'symbol'),
    display: _requireString(json, 'display'),
    name: _requireString(json, 'name'),
    glyph: _requireString(json, 'glyph'),
    priceDigits: _requireInt(json, 'priceDigits'),
    quantityDigits: _requireInt(json, 'quantityDigits'),
    lastPrice: _optionalMoney(json, 'lastPrice'),
    changeBasisPoints: _optionalInt(json, 'changeBasisPoints'),
  );

  static void _expectKind(String actual, String expected) {
    if (actual != expected) {
      throw FormatException('cache payload kind mismatch', <String, Object?>{
        'expected': expected,
        'actual': actual,
      });
    }
  }

  static Map<String, Object?> _requireMap(Object? value, String field) {
    if (value is! Map<String, Object?>) {
      throw FormatException('cache field is not a JSON object', field);
    }
    return value;
  }

  static List<Object?> _requireList(Object? value, String field) {
    if (value is! List<Object?>) {
      throw FormatException('cache field is not a JSON array', field);
    }
    return value;
  }

  static String _requireString(Map<String, Object?> json, String field) {
    final Object? value = json[field];
    if (value is! String) {
      throw FormatException('cache field is not a string', field);
    }
    return value;
  }

  static String? _optionalString(Map<String, Object?> json, String field) {
    final Object? value = json[field];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('cache field is not a string', field);
    }
    return value;
  }

  static int _requireInt(Map<String, Object?> json, String field) {
    final Object? value = json[field];
    if (value is! int) {
      throw FormatException('cache field is not an integer', field);
    }
    return value;
  }

  static int? _optionalInt(Map<String, Object?> json, String field) {
    final Object? value = json[field];
    if (value == null) return null;
    if (value is! int) {
      throw FormatException('cache field is not an integer', field);
    }
    return value;
  }

  static bool _requireBool(Map<String, Object?> json, String field) {
    final Object? value = json[field];
    if (value is! bool) {
      throw FormatException('cache field is not a boolean', field);
    }
    return value;
  }

  static DateTime _requireTime(Map<String, Object?> json, String field) {
    final String value = _requireString(json, field);
    final DateTime? parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw FormatException('cache field is not an RFC3339 timestamp', field);
    }
    return parsed.toUtc();
  }

  static Money _requireMoney(Map<String, Object?> json, String field) =>
      Money.parse(_requireString(json, field));

  static Money? _optionalMoney(Map<String, Object?> json, String field) {
    final String? value = _optionalString(json, field);
    return value == null ? null : Money.parse(value);
  }

  static Quantity _requireQuantity(Map<String, Object?> json, String field) =>
      Quantity.parse(_requireString(json, field));
}
