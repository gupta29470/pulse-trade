import 'dart:convert';

import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/data/dto/candle_dto.dart';
import 'package:pulse_trade_frontend/data/dto/health_dto.dart';
import 'package:pulse_trade_frontend/data/dto/market_status_dto.dart';
import 'package:pulse_trade_frontend/data/dto/market_summary_dto.dart';
import 'package:pulse_trade_frontend/data/dto/order_book_dto.dart';
import 'package:pulse_trade_frontend/data/dto/server_envelope_dto.dart';
import 'package:pulse_trade_frontend/data/dto/session_frames_dto.dart';
import 'package:pulse_trade_frontend/data/dto/trade_dto.dart';
import 'package:pulse_trade_frontend/data/dto/welcome_dto.dart';
import 'package:pulse_trade_frontend/data/mappers/candle_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/market_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/order_book_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/session_mapper.dart';
import 'package:pulse_trade_frontend/data/mappers/trade_mapper.dart';
import 'package:pulse_trade_frontend/domain/entities/candle_interval.dart';
import 'package:pulse_trade_frontend/domain/messages/market_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';

/// The result of parsing one raw server frame.
sealed class ParseOutcome {
  /// Base constructor for the two outcomes.
  const ParseOutcome();
}

/// A frame that decoded into a typed [ServerMessage].
final class ParsedFrame extends ParseOutcome {
  /// Creates a successful outcome.
  const ParsedFrame(this.message);

  /// The decoded message, with its envelope header attached.
  final ServerMessage message;
}

/// A frame that was rejected without mutating any state.
///
/// The socket stays usable: a single bad frame is counted and dropped rather
/// than tearing down a healthy feed.
final class MalformedFrame extends ParseOutcome {
  /// Creates a rejection.
  const MalformedFrame({required this.failure, required this.rawType});

  /// The typed failure explaining the rejection.
  final AppFailure failure;

  /// The wire `type`, or the empty string when it could not be read.
  final String rawType;
}

/// The envelope header shared by every message mapper.
typedef _Header = ({int version, DateTime serverTime, int seq});

/// Decodes one raw WebSocket frame into a typed [ServerMessage].
///
/// The parser validates and maps; it owns no state and makes no recovery
/// decision. It never throws — every malformed frame comes back as a
/// [MalformedFrame] so the socket can keep serving.
final class MarketMessageParser {
  /// Creates a parser. [clock] is used for the local receipt time on frames
  /// that carry one; [_metrics] receives the malformed-frame counter.
  MarketMessageParser({this._metrics, Clock? clock})
    : _clock = clock ?? SystemClock();

  /// The protocol version this build understands. A higher server version is
  /// rejected rather than guessed at.
  static const int supportedProtocolVersion = 1;

  static const String _codeMalformedFrame = 'MALFORMED_FRAME';
  static const String _codeUnknownMessageType = 'UNKNOWN_MESSAGE_TYPE';
  static const String _codeProtocolVersionUnsupported =
      'PROTOCOL_VERSION_UNSUPPORTED';

  /// Counter registry that receives `malformed_messages_total`; optional so a
  /// unit test can parse without building a registry.
  final OnDeviceMetrics? _metrics;

  /// Time source for the local receipt timestamp on `health` and
  /// `market_status` frames.
  final Clock _clock;

  /// Decodes [raw], returning either a [ParsedFrame] or a [MalformedFrame].
  ///
  /// A malformed frame is counted in `malformed_messages_total` and logged once
  /// at WARN with the frame type — never with the payload, which would put a
  /// high-frequency dump into the log stream.
  ParseOutcome parse(String raw) {
    String rawType = '';
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return _reject(
          const ProtocolFailure(
            code: _codeMalformedFrame,
            message: 'frame is not a JSON object',
          ),
          rawType,
        );
      }

      final ServerEnvelopeDto envelope = ServerEnvelopeDto.fromJson(
        Map<String, Object?>.from(decoded),
      );
      rawType = envelope.type;

      if (envelope.type.isEmpty) {
        return _reject(
          const ProtocolFailure(
            code: _codeMalformedFrame,
            message: 'frame has no type',
          ),
          rawType,
        );
      }

      if (envelope.version > supportedProtocolVersion) {
        return _reject(
          ProtocolFailure(
            code: _codeProtocolVersionUnsupported,
            message:
                'server speaks protocol ${envelope.version}, this build '
                'supports $supportedProtocolVersion',
          ),
          rawType,
        );
      }

      final Map<String, dynamic>? body = envelope.payload;
      final Map<String, Object?> payload = body == null
          ? const <String, Object?>{}
          : Map<String, Object?>.from(body);

      final ServerMessage? message = _dispatch(envelope, payload);
      if (message == null) {
        return _reject(
          ProtocolFailure(
            code: _codeUnknownMessageType,
            message: 'unknown message type "${envelope.type}"',
          ),
          rawType,
        );
      }
      return ParsedFrame(message);
    } on FormatException catch (error) {
      return _reject(
        ProtocolFailure(
          code: _codeMalformedFrame,
          message: 'frame could not be decoded: ${error.message}',
          cause: error,
        ),
        rawType,
      );
    } on TypeError catch (error) {
      return _reject(
        ProtocolFailure(
          code: _codeMalformedFrame,
          message: 'frame had an unexpected shape',
          cause: error,
        ),
        rawType,
      );
    } catch (error) {
      return _reject(
        ProtocolFailure(
          code: _codeMalformedFrame,
          message: 'frame could not be decoded',
          cause: error,
        ),
        rawType,
      );
    }
  }

  /// Counts, logs and wraps one rejection.
  MalformedFrame _reject(AppFailure failure, String rawType) {
    _metrics?.increment(MetricNames.malformedMessagesTotal);
    AppLogger.warn(
      LogEvents.malformedFrame,
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        LogFields.errorCode: failure.code,
        LogFields.error: failure.message,
        'type': rawType,
      },
    );
    return MalformedFrame(failure: failure, rawType: rawType);
  }

  /// Routes one validated envelope to the DTO and mapper for its type.
  ServerMessage? _dispatch(
    ServerEnvelopeDto envelope,
    Map<String, Object?> payload,
  ) {
    final _Header header = (
      version: envelope.version,
      serverTime: DateTime.parse(envelope.serverTime).toUtc(),
      seq: envelope.seq,
    );
    final DateTime receivedAt = _clock.now();

    return switch (envelope.type) {
      'welcome' => WelcomeDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
      ),
      'subscribed' => SubscribedDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
      ),
      'unsubscribed' => UnsubscribedDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
      ),
      'pong' => PongDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
      ),
      'ping' => PingDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
      ),
      'market_status' => MarketStatusDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
        receivedAt: receivedAt,
      ),
      'order_book_snapshot' => OrderBookSnapshotMessage(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
        snapshot: OrderBookSnapshotDto.fromJson(payload).toEntity(),
      ),
      'order_book_delta' => _deltaMessage(header, payload),
      'trade' => TradeMessage(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
        trade: TradeDto.fromJson(payload).toEntity(),
      ),
      'trade_batch' => _tradeBatchMessage(header, payload),
      'candle_update' => _candleUpdateMessage(header, payload),
      'candle_closed' => _candleClosedMessage(header, payload),
      'market_summary' => MarketSummaryMessage(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
        summary: MarketSummaryDto.fromJson(payload).toEntity(),
      ),
      'health' => HealthDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
        receivedAt: receivedAt,
      ),
      'error' => ErrorDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
      ),
      'goodbye' => GoodbyeDto.fromJson(payload).toEntity(
        version: header.version,
        serverTime: header.serverTime,
        seq: header.seq,
      ),
      _ => null,
    };
  }

  /// Builds an `order_book_delta` message from its wire level pairs.
  OrderBookDeltaMessage _deltaMessage(
    _Header header,
    Map<String, Object?> payload,
  ) {
    final OrderBookDeltaDto dto = OrderBookDeltaDto.fromJson(payload);
    return OrderBookDeltaMessage(
      version: header.version,
      serverTime: header.serverTime,
      seq: header.seq,
      symbol: dto.symbol,
      epoch: dto.epoch,
      firstUpdateId: dto.firstUpdateId,
      lastUpdateId: dto.lastUpdateId,
      bids: dto.bidLevels,
      asks: dto.askLevels,
    );
  }

  /// Builds a `trade_batch` message, stamping each trade with the batch's
  /// omitted count so compaction is visible in the UI.
  TradeBatchMessage _tradeBatchMessage(
    _Header header,
    Map<String, Object?> payload,
  ) {
    final TradeBatchDto dto = TradeBatchDto.fromJson(payload);
    return TradeBatchMessage(
      version: header.version,
      serverTime: header.serverTime,
      seq: header.seq,
      symbol: dto.symbol,
      trades: dto.toEntities(),
      compacted: dto.compacted,
      omittedCount: dto.omittedCount,
    );
  }

  /// Builds a `candle_update` message. The candle is closed exactly when the
  /// frame says the bucket is no longer active.
  CandleUpdateMessage _candleUpdateMessage(
    _Header header,
    Map<String, Object?> payload,
  ) {
    final CandleUpdateDto dto = CandleUpdateDto.fromJson(payload);
    final CandleInterval interval = _intervalOrThrow(dto.interval);
    return CandleUpdateMessage(
      version: header.version,
      serverTime: header.serverTime,
      seq: header.seq,
      symbol: dto.symbol,
      interval: interval,
      candle: dto.candle.toEntity(interval: interval, closed: !dto.active),
      sourceSequence: dto.sourceSequence,
      active: dto.active,
    );
  }

  /// Builds a `candle_closed` message; its bucket is final by definition.
  CandleClosedMessage _candleClosedMessage(
    _Header header,
    Map<String, Object?> payload,
  ) {
    final CandleClosedDto dto = CandleClosedDto.fromJson(payload);
    final CandleInterval interval = _intervalOrThrow(dto.interval);
    return CandleClosedMessage(
      version: header.version,
      serverTime: header.serverTime,
      seq: header.seq,
      symbol: dto.symbol,
      interval: interval,
      candle: dto.candle.toEntity(interval: interval, closed: true),
      epoch: dto.epoch,
    );
  }

  /// Resolves a wire interval id, failing the frame when it is unknown.
  CandleInterval _intervalOrThrow(String wire) {
    final CandleInterval? interval = CandleInterval.tryParse(wire);
    if (interval == null) {
      throw FormatException('unknown candle interval', wire);
    }
    return interval;
  }
}
