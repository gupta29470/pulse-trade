import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/error/failure_mapper.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// One observable transport event, in arrival order.
///
/// A sealed hierarchy rather than four callbacks, so a consumer `switch` is
/// exhaustive and one listener observes the whole socket. Plain classes rather
/// than `equatable`: an event is consumed as it arrives, never compared.
sealed class SocketEvent {
  /// Base constructor.
  const SocketEvent();
}

/// The socket completed its handshake and can accept frames.
final class SocketConnected extends SocketEvent {
  /// Creates a connected event for one attempt.
  const SocketConnected({required this.url, required this.attemptId});

  /// The endpoint that was dialled.
  final Uri url;

  /// Id of the attempt that owns this connection.
  final String attemptId;
}

/// The socket is gone; [reason] is a stable slug, [code] the peer's close code.
final class SocketDisconnected extends SocketEvent {
  /// Creates a disconnected event.
  const SocketDisconnected({required this.reason, this.code});

  /// Why the socket closed (`client`, `stream_closed`, `dial_failed`, …).
  final String reason;

  /// WebSocket close code, when the peer supplied one.
  final int? code;
}

/// One raw text frame from the server.
///
/// The transport deliberately does not decode: parsing lives in the stream
/// repository, so a malformed frame cannot throw inside a socket callback and
/// kill a healthy connection.
final class SocketMessage extends SocketEvent {
  /// Wraps one raw frame.
  const SocketMessage({required this.text});

  /// The frame exactly as it arrived.
  final String text;
}

/// The attempt failed; [failure] is already mapped to the typed hierarchy.
final class SocketFailure extends SocketEvent {
  /// Wraps one mapped failure.
  const SocketFailure({required this.failure});

  /// The typed failure to surface.
  final AppFailure failure;
}

/// The socket transport, expressed only in typed events.
///
/// The transport knows nothing about frames, symbols or parsing; consumers see
/// [SocketMessage] text and the stream repository turns it into domain messages.
abstract interface class MarketWebSocketClient {
  /// Every transport event, in order.
  Stream<SocketEvent> get events;

  /// The current lifecycle state.
  ConnectionStatus get status;

  /// Starts (or restarts) an attempt against [url].
  Future<void> connect(Uri url);

  /// Replaces the session subscription on the open socket.
  Future<void> subscribe(SubscriptionSpec spec);

  /// Sends one typed client frame.
  Future<void> send(ClientMessage message);

  /// Closes the socket without closing [events], because blocs resubscribe
  /// after a reconnect and must still see the next attempt's events.
  Future<void> disconnect({String reason = 'client'});
}

/// A [MarketWebSocketClient] decorator that refuses to dial while offline.
///
/// When the gate says no, [connect] does not reach the inner client at all
/// (the test asserts the fake recorded zero calls): it counts the refusal, logs one
/// WARN and emits [SocketFailure] carrying [OfflineFailure] on its own merged
/// stream, so a consumer still learns why nothing happened. `send`, `subscribe`
/// and `disconnect` pass straight through — they act on a socket that already
/// exists, and blocking them offline would only surprise an in-flight bloc.
final class OfflineGatedWebSocketClient implements MarketWebSocketClient {
  /// Wraps [_inner] and consults [_gate] before every dial.
  OfflineGatedWebSocketClient({
    required this._inner,
    required this._gate,
    required this._metrics,
  }) {
    _innerSubscription = _inner.events.listen(_forward);
  }

  final MarketWebSocketClient _inner;
  final OfflineGate _gate;
  final OnDeviceMetrics _metrics;
  final StreamController<SocketEvent> _events =
      StreamController<SocketEvent>.broadcast();
  late final StreamSubscription<SocketEvent> _innerSubscription;

  void _forward(SocketEvent event) => _events.add(event);

  @override
  Stream<SocketEvent> get events => _events.stream;

  @override
  ConnectionStatus get status => _inner.status;

  @override
  Future<void> connect(Uri url) async {
    if (await _gate.canCall()) {
      await _inner.connect(url);
      return;
    }
    _metrics.increment(MetricNames.offlineCallsBlockedTotal);
    AppLogger.warn(
      LogEvents.offlineCallBlocked,
      fields: const <String, Object?>{
        LogFields.component: LogComponents.transport,
      },
    );
    _events.add(const SocketFailure(failure: OfflineFailure()));
  }

  @override
  Future<void> subscribe(SubscriptionSpec spec) => _inner.subscribe(spec);

  @override
  Future<void> send(ClientMessage message) => _inner.send(message);

  @override
  Future<void> disconnect({String reason = 'client'}) =>
      _inner.disconnect(reason: reason);

  /// Stops forwarding the inner stream and closes the merged one.
  ///
  /// Not part of [MarketWebSocketClient]: only the composition root owns the
  /// decorator's lifetime, and `disconnect` must stay reopenable.
  Future<void> dispose() async {
    await _innerSubscription.cancel();
    await _events.close();
  }
}

/// The real [MarketWebSocketClient], backed by `package:web_socket_channel`.
///
/// Reconnect policy: bounded exponential backoff
/// `1, 2, 4, 8, 16, 30, 30…` seconds with ±20 % jitter, reset after 30 s of
/// stable connection. Each attempt carries an id, and any stream event or timer
/// callback whose captured id is no longer active is ignored, so a superseded
/// callback can never race a fresh socket. At most one socket, one reconnect
/// timer and one stream subscription exist at any moment.
final class WebSocketMarketClient implements MarketWebSocketClient {
  /// Creates the client.
  ///
  /// [_stableResetAfter] is the quiet period that resets the backoff counter.
  /// [_onReconnectScheduled] is a test seam reporting the chosen delay, so a test
  /// can assert the schedule without waiting on wall time. [random] makes the
  /// jitter deterministic under a seeded generator; [_metrics] is optional and
  /// only receives `ws_frames_dropped_total` — the connect/reconnect counters
  /// belong to the stream repository, which sees the typed events.
  WebSocketMarketClient({
    required this._failureMapper,
    ConnectionStatus initialStatus = ConnectionStatus.disconnected,
    this._stableResetAfter = const Duration(seconds: 30),
    this._onReconnectScheduled,
    Random? random,
    this._metrics,
  }) : _status = initialStatus,
       _random = random ?? Random();

  /// Backoff ladder in seconds; the last entry repeats forever.
  static const List<int> _backoffSeconds = <int>[1, 2, 4, 8, 16, 30];

  /// Log slug for a frame dropped because the socket was not connected.
  static const String _frameDroppedEvent = 'ws_frame_dropped';

  final FailureMapper _failureMapper;
  final Duration _stableResetAfter;
  final void Function(Duration)? _onReconnectScheduled;
  final Random _random;
  final OnDeviceMetrics? _metrics;
  // ignore: cancel_subscriptions — the subscription is cancelled by disconnect()
  // and dispose(); this field is only reassigned when a new attempt takes over.
  final StreamController<SocketEvent> _events =
      StreamController<SocketEvent>.broadcast();

  ConnectionStatus _status;
  WebSocketChannel? _channel;
  // Cancelled in disconnect and dispose; this field is only reassigned when a
  // new attempt takes over the live socket.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  Timer? _stableTimer;
  Uri? _url;

  /// The attempt that owns the live socket and stream subscription.
  String? _activeAttemptId;

  /// The attempt that owns the pending reconnect timer.
  String? _pendingAttemptId;

  int _attemptCount = 0;
  int _attemptSequence = 0;
  bool _connected = false;
  bool _disconnectRequested = false;
  bool _disposed = false;

  @override
  Stream<SocketEvent> get events => _events.stream;

  @override
  ConnectionStatus get status => _status;

  /// The delay before attempt [attempt] (zero based), with ±20 % jitter.
  ///
  /// Jitter is applied per attempt rather than to the ladder itself, so a fleet
  /// that dropped together does not reconnect in lockstep.
  Duration nextBackoffFor(int attempt) {
    final int positive = attempt <= 0 ? 0 : attempt;
    final int index = positive >= _backoffSeconds.length
        ? _backoffSeconds.length - 1
        : positive;
    final int baseMs = _backoffSeconds[index] * 1000;
    final double factor = 0.8 + (_random.nextDouble() * 0.4);
    return Duration(milliseconds: (baseMs * factor).round());
  }

  @override
  Future<void> connect(Uri url) async {
    if (_disposed) return;
    _url = url;
    _disconnectRequested = false;
    // An explicit connect is a fresh intention, so the ladder restarts instead
    // of inheriting the delay of a previous failure burst.
    _attemptCount = 0;
    await _startAttempt();
  }

  @override
  Future<void> subscribe(SubscriptionSpec spec) => send(
    SubscribeMessage(
      symbol: spec.symbol,
      interval: spec.interval,
      channels: spec.channels,
    ),
  );

  @override
  Future<void> send(ClientMessage message) async {
    final WebSocketChannel? channel = _channel;
    if (channel == null || !_connected || _disposed) {
      // Dropping is correct: throwing into a bloc would surface a transport
      // detail the bloc cannot act on, and the reconnect resubscribes anyway.
      _metrics?.increment(MetricNames.wsFramesDroppedTotal);
      AppLogger.debug(
        _frameDroppedEvent,
        fields: const <String, Object?>{
          LogFields.component: LogComponents.transport,
        },
      );
      return;
    }
    channel.sink.add(jsonEncode(message.toJson()));
  }

  @override
  Future<void> disconnect({String reason = 'client'}) async {
    _disconnectRequested = true;
    _activeAttemptId = null;
    _attemptCount = 0;
    await _teardownSocket();
    _setStatus(ConnectionStatus.disconnected);
    AppLogger.info(
      LogEvents.wsDisconnected,
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        LogFields.reason: reason,
      },
    );
    if (!_events.isClosed) {
      _events.add(SocketDisconnected(reason: reason));
    }
  }

  /// Releases the socket, timers and the event controller. Call once, at
  /// teardown; [disconnect] deliberately leaves the controller open.
  Future<void> dispose() async {
    _disposed = true;
    _activeAttemptId = null;
    await _teardownSocket();
    if (!_events.isClosed) await _events.close();
  }

  /// Starts one dial. Any previous attempt is torn down first.
  Future<void> _startAttempt() async {
    final Uri? url = _url;
    if (_disposed || url == null) return;

    await _teardownSocket();

    final String attemptId = (++_attemptSequence).toString();
    _activeAttemptId = attemptId;
    _setStatus(ConnectionStatus.connecting);

    final WebSocketChannel? channel = await _dial(url, attemptId);
    if (channel == null) return;
    if (!_isActiveAttempt(attemptId)) {
      await _closeChannel(channel);
      return;
    }

    _channel = channel;
    _connected = true;
    // `ws_connects_total` and `ws_reconnects_total` belong to the stream
    // repository, which sees the typed events; counting them here too would
    // double every dashboard number.
    _setStatus(ConnectionStatus.connected);
    _armStableReset(attemptId);
    _subscription = channel.stream.listen(
      (Object? frame) => _onFrame(attemptId, frame),
      onError: (Object error, StackTrace stackTrace) =>
          _onSocketError(attemptId, error),
      onDone: () => _onSocketDone(attemptId),
      cancelOnError: false,
    );
    AppLogger.info(
      LogEvents.wsConnected,
      fields: const <String, Object?>{
        LogFields.component: LogComponents.transport,
      },
    );
    _events.add(SocketConnected(url: url, attemptId: attemptId));
  }

  /// Opens a channel and waits for its handshake, or reports the drop.
  Future<WebSocketChannel?> _dial(Uri url, String attemptId) async {
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(url);
      await channel.ready;
      return channel;
    } on Object catch (error) {
      final WebSocketChannel? pending = channel;
      if (pending != null) await _closeChannel(pending);
      _handleDrop(
        attemptId,
        reason: 'dial_failed',
        failure: _failureMapper.map(error),
      );
      return null;
    }
  }

  void _onFrame(String attemptId, Object? frame) {
    if (!_isActiveAttempt(attemptId)) return;
    // The protocol is text-only; a binary frame is not one we can parse, so it
    // is ignored rather than allowed to disturb the connection.
    if (frame is! String) return;
    _events.add(SocketMessage(text: frame));
  }

  void _onSocketError(String attemptId, Object error) => _handleDrop(
    attemptId,
    reason: 'socket_error',
    failure: _failureMapper.map(error),
  );

  void _onSocketDone(String attemptId) => _handleDrop(
    attemptId,
    reason: _channel?.closeReason ?? 'stream_closed',
    code: _channel?.closeCode,
  );

  /// Handles a dropped socket exactly once per attempt.
  ///
  /// The attempt id is cleared before anything else, so the `done` that follows
  /// an `error` (or a second callback from a superseded attempt) is ignored and
  /// cannot schedule two reconnects.
  void _handleDrop(
    String attemptId, {
    required String reason,
    int? code,
    AppFailure? failure,
  }) {
    if (!_isActiveAttempt(attemptId)) return;
    _activeAttemptId = null;
    _connected = false;

    final StreamSubscription<Object?>? subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());

    if (failure != null) {
      _events.add(SocketFailure(failure: failure));
    }
    if (_disconnectRequested || _disposed) {
      _setStatus(ConnectionStatus.disconnected);
      return;
    }

    AppLogger.warn(
      LogEvents.wsDisconnected,
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        LogFields.reason: reason,
      },
    );
    _events.add(SocketDisconnected(reason: reason, code: code));
    _scheduleReconnect(reason);
  }

  /// Schedules the next attempt on the backoff ladder.
  void _scheduleReconnect(String reason) {
    if (_disposed || _disconnectRequested || _url == null) return;
    if (_pendingAttemptId != null) return;

    final String scheduledId = (++_attemptSequence).toString();
    _pendingAttemptId = scheduledId;
    final Duration delay = nextBackoffFor(_attemptCount);
    _attemptCount++;
    _setStatus(ConnectionStatus.reconnecting);
    _onReconnectScheduled?.call(delay);
    AppLogger.info(
      LogEvents.wsReconnectScheduled,
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        LogFields.reason: reason,
        LogFields.durationMs: delay.inMilliseconds,
      },
    );

    _reconnectTimer = Timer(delay, () {
      if (_disposed ||
          _disconnectRequested ||
          _pendingAttemptId != scheduledId) {
        return;
      }
      _reconnectTimer = null;
      _pendingAttemptId = null;
      unawaited(_startAttempt());
    });
  }

  /// Resets the backoff counter once the connection has been stable long enough.
  void _armStableReset(String attemptId) {
    _stableTimer?.cancel();
    _stableTimer = Timer(_stableResetAfter, () {
      if (!_isActiveAttempt(attemptId)) return;
      _attemptCount = 0;
    });
  }

  /// Cancels the subscription, both timers and the socket.
  ///
  /// Idempotent, and the only place that releases transport resources, so the
  /// one-socket/one-timer/one-subscription invariant is enforced by
  /// construction rather than by discipline.
  Future<void> _teardownSocket() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    _pendingAttemptId = null;

    final StreamSubscription<Object?>? subscription = _subscription;
    _subscription = null;
    if (subscription != null) await subscription.cancel();

    final WebSocketChannel? channel = _channel;
    _channel = null;
    _connected = false;
    if (channel != null) await _closeChannel(channel);
  }

  /// Closes a channel, swallowing a failure that is already moot.
  Future<void> _closeChannel(WebSocketChannel channel) async {
    try {
      await channel.sink.close();
    } on Object catch (error) {
      // The peer may already be gone; that must not mask the reconnect logic.
      AppLogger.debug(
        LogEvents.wsDisconnected,
        fields: <String, Object?>{
          LogFields.component: LogComponents.transport,
          LogFields.error: error.toString(),
        },
      );
    }
  }

  bool _isActiveAttempt(String attemptId) =>
      !_disposed && _activeAttemptId == attemptId;

  void _setStatus(ConnectionStatus next) {
    if (_status == next) return;
    _status = next;
  }
}
