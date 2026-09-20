import 'dart:async';

import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/core/networking/market_websocket_client.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/data/parser/market_message_parser.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';

/// The socket-backed [MarketStreamRepository].
///
/// It owns exactly one subscription to the transport's event stream and turns it
/// into three typed streams: decoded messages, connection failures, and status
/// transitions. A malformed frame becomes neither an error nor a status change —
/// it is counted and dropped, because a single bad frame must not tear down a
/// healthy feed.
final class SocketMarketStreamRepository implements MarketStreamRepository {
  /// Creates the repository. The socket is not dialed until [connect].
  SocketMarketStreamRepository({
    required this._client,
    required this._parser,
    required this._url,
    required FailureMapper failureMapper,
    OnDeviceMetrics? metrics,
  }) : _mapper = failureMapper,
       _metrics = metrics ?? OnDeviceMetrics() {
    _subscription = _client.events.listen(_onEvent);
  }

  final MarketWebSocketClient _client;
  final MarketMessageParser _parser;
  final Uri _url;
  final FailureMapper _mapper;
  final OnDeviceMetrics _metrics;

  final StreamController<ServerMessage> _messages =
      StreamController<ServerMessage>.broadcast();
  final StreamController<AppFailure> _failures =
      StreamController<AppFailure>.broadcast();
  final StreamController<ConnectionStatus> _statusChanges =
      StreamController<ConnectionStatus>.broadcast();

  StreamSubscription<SocketEvent>? _subscription;
  WelcomeMessage? _welcome;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  SubscriptionSpec? _currentSubscription;
  bool _disposed = false;
  int _reconnects = 0;

  @override
  Stream<ServerMessage> get messages => _messages.stream;

  @override
  Stream<AppFailure> get failures => _failures.stream;

  @override
  ConnectionStatus get status => _status;

  @override
  Stream<ConnectionStatus> get statusStream => _statusChanges.stream;

  @override
  WelcomeMessage? get welcome => _welcome;

  @override
  SubscriptionSpec? get currentSubscription => _currentSubscription;

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _setStatus(ConnectionStatus.connecting);
    try {
      await _client.connect(_url);
    } on Object catch (error) {
      // A refused dial is reported on the failure stream; the transport owns the
      // retry schedule, so this method never rethrows into a bloc.
      _reportFailure(_mapper.map(error));
    }
  }

  @override
  Future<void> subscribe(SubscriptionSpec spec) async {
    // Recorded before the send: this is the subscription the session should be
    // on, so a subscribe that could not reach the wire is still the one a
    // reconnect restores.
    _currentSubscription = spec;
    try {
      await _client.subscribe(spec);
    } on Object catch (error) {
      _reportFailure(_mapper.map(error));
    }
  }

  @override
  Future<void> send(ClientMessage message) async {
    try {
      await _client.send(message);
    } on Object catch (error) {
      _reportFailure(_mapper.map(error));
    }
  }

  @override
  Future<void> disconnect({String reason = 'client'}) async {
    _setStatus(ConnectionStatus.disconnected);
    try {
      await _client.disconnect(reason: reason);
    } on Object catch (error) {
      _reportFailure(_mapper.map(error));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    AppLogger.clearSession();
    await _messages.close();
    await _failures.close();
    await _statusChanges.close();
  }

  void _onEvent(SocketEvent event) {
    switch (event) {
      case SocketConnected():
        _metrics.increment(MetricNames.wsConnectsTotal);
        _setStatus(ConnectionStatus.connected);
        AppLogger.info(
          LogEvents.wsConnected,
          fields: <String, Object?>{
            LogFields.component: LogComponents.transport,
            LogFields.count: _reconnects,
          },
        );
      case SocketDisconnected():
        _setStatus(ConnectionStatus.disconnected);
        AppLogger.info(
          LogEvents.wsDisconnected,
          fields: <String, Object?>{
            LogFields.component: LogComponents.transport,
            LogFields.reason: event.reason,
          },
        );
      case SocketFailure():
        _reportFailure(event.failure);
      case SocketMessage():
        _handleFrame(event.text);
    }
  }

  void _handleFrame(String text) {
    final ParseOutcome outcome = _parser.parse(text);
    switch (outcome) {
      case ParsedFrame():
        final ServerMessage message = outcome.message;
        if (message is WelcomeMessage) {
          _welcome = message;
          AppLogger.setSession(
            sessionId: message.sessionId,
            shortId: message.shortId,
          );
        }
        if (!_messages.isClosed) _messages.add(message);
      case MalformedFrame():
        // Counted by the parser; nothing reaches the message stream, so no bloc
        // can act on a frame that failed validation.
        break;
    }
  }

  void _reportFailure(AppFailure failure) {
    if (_status == ConnectionStatus.connected) {
      _reconnects++;
      _metrics.increment(MetricNames.wsReconnectsTotal);
    }
    if (!_failures.isClosed) _failures.add(failure);
    _setStatus(ConnectionStatus.disconnected);
    AppLogger.warn(
      'ws_failure',
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        LogFields.errorCode: failure.code,
        LogFields.error: failure.message,
      },
    );
  }

  void _setStatus(ConnectionStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_statusChanges.isClosed) _statusChanges.add(next);
  }
}
