import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/service/connectivity_service.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/connection_status.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';
import 'package:pulse_trade_frontend/domain/entities/subscription_spec.dart';
import 'package:pulse_trade_frontend/domain/market/jitter_calculator.dart';
import 'package:pulse_trade_frontend/domain/market/rtt_calculator.dart';
import 'package:pulse_trade_frontend/domain/messages/delivery_messages.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/features/connection/connection_event.dart';
import 'package:pulse_trade_frontend/features/connection/connection_state.dart';
import 'package:pulse_trade_frontend/features/connection/reconnect_policy.dart';

// Feature-owned log slugs. `LogEvents` carries the shared vocabulary; these name
// events only this bloc produces, and never interpolate a value into the slug.
const String _msgSubscribed = 'ws_subscribed';
const String _msgStreamCallFailed = 'ws_stream_call_failed';
const String _msgHeartbeat = 'ws_heartbeat';
const String _msgTierObserved = 'tier_observed';
const String _msgLifecycle = 'ws_lifecycle';
const String _msgBackoffIgnored = 'ws_backoff_superseded';

/// Owns the socket's lifecycle: dial, reconnect backoff, heartbeat,
/// resubscription and the connection state machine.
///
/// **What this bloc is not.** It does not parse market frames and does not decide
/// the delivery tier. It reads the three frames that describe *this socket* —
/// `welcome`, `pong`, `health` — and ignores every market frame, because those
/// belong to the blocs that own them. Reachability is an event rather than a
/// state field so market liveness is never derived from it.
///
/// **Exactly one of everything.** One socket is opened
/// by one [Connect]; one backoff timer exists because every arm cancels first and
/// because [BackoffElapsed] carries the attempt id, so a superseded timer is
/// ignored rather than allowed to race; one heartbeat timer exists for the same
/// cancel-before-arm reason; and the subscription is re-sent at most once per
/// socket generation, so repeated lifecycle transitions cannot duplicate it.
///
/// **Heartbeat.** This bloc owns the heartbeat. It pulses every
/// `welcome.heartbeatMs` (2 s by default), computes RTT on the monotonic clock
/// through [RttCalculator], feeds [JitterCalculator] and reports the two to the
/// backend at most once every two seconds — the report is what the
/// backend's tier machine consumes, so a bloc that pinged without reporting
/// would starve it.
///
/// **Never throws.** Every repository call is contained and becomes a state or a
/// log record, so no exception reaches the widget tree.
final class ConnectionBloc extends Bloc<ConnectionEvent, PtConnectionState> {
  /// Creates the bloc.
  ///
  /// [_subscription] is re-sent on every new socket, [_policy] owns the backoff
  /// schedule, [clock] is injectable so tests advance time explicitly.
  /// [metrics] receives the reconnect and missed-pong counters.
  ConnectionBloc({
    required this._stream,
    required this._subscription,
    required this._policy,
    Clock? clock,
    OnDeviceMetrics? metrics,
    Duration? dialTimeout,
  }) : _clock = clock ?? SystemClock(),
       _metrics = metrics ?? OnDeviceMetrics(),
       _dialTimeout = dialTimeout ?? defaultDialTimeout,
       super(const ConnectionDisconnected()) {
    _rtt = RttCalculator(clock: _clock, metrics: _metrics);
    on<Connect>(_onConnect);
    on<Disconnect>(_onDisconnect);
    on<ReconnectNow>(_onReconnectNow);
    on<AppBackgrounded>(_onAppBackgrounded);
    on<AppForegrounded>(_onAppForegrounded);
    on<InternetStatusChanged>(_onInternetStatusChanged);
    on<BackoffElapsed>(_onBackoffElapsed);
    on<ReconnectWatchdogFired>(_onWatchdogFired);
    on<HeartbeatMissed>(_onHeartbeatMissed);
    on<SocketMessageReceived>(_handleSocketMessage);
    on<TransportFailureReported>(_handleTransportFailure);
    on<SocketStatusReported>(_handleSocketStatus);
  }

  /// RTT cadence before `welcome` states the server's own.
  static const Duration _defaultHeartbeatInterval = Duration(seconds: 2);

  /// The slowest cadence that can still satisfy the tier machine: a report older
  /// than this is treated as missing and degrades the connection.
  static const Duration _maxHeartbeatInterval = Duration(seconds: 10);

  /// Reports are throttled to one every two seconds.
  static const int _reportIntervalMs = 2000;

  /// The window description sent with each report.
  static const String _jitterWindow = 'last10';

  final MarketStreamRepository _stream;
  final SubscriptionSpec _subscription;
  final ReconnectPolicy _policy;
  final Clock _clock;
  final OnDeviceMetrics _metrics;

  late final RttCalculator _rtt;
  final JitterCalculator _jitter = JitterCalculator();

  StreamSubscription<ServerMessage>? _messagesSub;
  StreamSubscription<AppFailure>? _failuresSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  Timer? _backoffTimer;

  /// How often the watchdog checks that a retry is still pending.
  ///
  /// Independent of the backoff ladder on purpose: the ladder schedules a retry
  /// when a socket is *known* to be down, and the watchdog covers the cases
  /// where nothing knew.
  static const Duration watchdogInterval = Duration(seconds: 10);

  Timer? _watchdogTimer;
  Timer? _heartbeatTimer;

  ConnectionStatus _lastStatus = ConnectionStatus.disconnected;
  Duration _heartbeatInterval = _defaultHeartbeatInterval;
  DeliveryTier _tier = DeliveryTier.full;

  int _attempt = 0;
  int _currentAttemptId = 0;
  int _rttMs = 0;
  int _lastReportAtMs = -_reportIntervalMs;
  int? _connectedAtMs;
  int _socketGeneration = 0;
  int _resubscribedGeneration = -1;

  bool _started = false;
  bool _socketUp = false;
  bool _offline = false;
  bool _backgrounded = false;
  bool _closing = false;
  bool _dialInFlight = false;

  /// Upper bound on one handshake.
  ///
  /// A dial that never returns must not hold [_dialInFlight]: while it does,
  /// every later `Connect` is swallowed by the guard in [_onConnect] and the app
  /// cannot reconnect at all. That is exactly the state a vanished network leaves
  /// behind — the handshake it was waiting on never completes, so nothing ever
  /// clears the flag and only a restart helps.
  static const Duration defaultDialTimeout = Duration(seconds: 10);

  final Duration _dialTimeout;

  Future<void> _onConnect(Connect _, Emitter<PtConnectionState> emit) async {
    if (isClosed) return;
    _started = true;
    _closing = false;
    _ensureWatchdog();
    if (_offline) {
      // No dial, no timeout, no battery spent proving reachability.
      emit(const ConnectionOffline());
      return;
    }
    if (_dialInFlight) return;
    _cancelBackoff();
    _listenToStream();
    emit(const ConnectionConnecting());
    await _dialSafely(emit);
  }

  void _onDisconnect(Disconnect event, Emitter<PtConnectionState> emit) {
    _closing = true;
    // A resumable disconnect leaves `_started` untouched: that flag is what
    // `AppForegrounded` checks before dialling, and a background suspend must
    // not clear it or the return path has nothing to resume.
    if (!event.resumeOnForeground) {
      _started = false;
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
    }
    _socketUp = false;
    _connectedAtMs = null;
    _attempt = 0;
    // Cancelling invalidates any in-flight backoff, so a queued `BackoffElapsed`
    // cannot dial after the user asked for silence.
    _cancelBackoff();
    _stopHeartbeat();
    _cancelStreamSubscriptions();
    _resubscribedGeneration = -1;
    AppLogger.clearSession();
    AppLogger.info(
      LogEvents.wsDisconnected,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.reason: event.reason,
      },
    );
    unawaited(_guard(() => _stream.disconnect(reason: event.reason)));
    emit(const ConnectionDisconnected());
  }

  void _onReconnectNow(ReconnectNow _, Emitter<PtConnectionState> emit) {
    _cancelBackoff();
    _started = true;
    if (_offline) {
      emit(const ConnectionOffline());
      return;
    }
    if (isClosed) return;
    add(const Connect());
  }

  void _onAppBackgrounded(AppBackgrounded _, Emitter<PtConnectionState> emit) {
    _backgrounded = true;
    _stopHeartbeat();
    AppLogger.info(
      _msgLifecycle,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.reason: 'app_backgrounded',
      },
    );
    // Nothing is emitted: the socket is kept on purpose for the lifecycle
    // observer's timeout, so claiming `disconnected` would be a lie and claiming
    // a fresh live state would be premature.
  }

  void _onAppForegrounded(AppForegrounded _, Emitter<PtConnectionState> emit) {
    _backgrounded = false;
    if (!_started) return;
    if (_socketUp) {
      _startHeartbeat();
      emit(_connectedState());
      return;
    }
    if (_offline) {
      emit(const ConnectionOffline());
      return;
    }
    if (isClosed) return;
    add(const Connect());
  }

  void _onInternetStatusChanged(
    InternetStatusChanged event,
    Emitter<PtConnectionState> emit,
  ) {
    if (event.status == InternetStatus.disconnected) {
      _offline = true;
      // The route is gone, so the socket is gone with it, whatever the OS still
      // believes about the TCP connection. Clearing `_socketUp` is what lets the
      // recovery branch below take the dial path when reachability returns
      // instead of reporting a socket that no longer carries traffic.
      _socketUp = false;
      _connectedAtMs = null;
      _cancelBackoff();
      _stopHeartbeat();
      unawaited(_guard(() => _stream.disconnect(reason: 'offline')));
      emit(const ConnectionOffline());
      return;
    }
    final bool wasOffline = _offline;
    _offline = false;
    if (_socketUp) {
      // Reachability is not liveness: the socket is left alone and the resumed
      // heartbeat discovers a dead one within one pulse.
      _startHeartbeat();
      emit(_connectedState());
      return;
    }
    if (!_started || _closing || _backgrounded || !wasOffline) return;
    // After an offline episode the schedule restarts from its base.
    _attempt = 0;
    _policy.reset();
    emit(
      ConnectionReconnecting(
        attempt: 1,
        nextAttemptIn: Duration.zero,
        previous: _lastStatus,
      ),
    );
    if (isClosed) return;
    add(const Connect());
  }

  /// The backstop: if the bloc wants a connection and nothing is pending, try.
  ///
  /// Every guard here answers "is a retry already on its way, or is retrying
  /// pointless right now". When none of them holds, the app has been left in a
  /// state that nothing will leave on its own, and a dial is the only way out.
  ///
  /// `_offline` is cleared before dialling even though the gate forbids dialling
  /// while offline: the gate re-reads cached reachability on every attempt, so a
  /// refused dial costs a counter and one WARN — and if the flag outlived the
  /// condition that set it, this is what recovers. Without that, a status event
  /// that never arrived would pin the app offline indefinitely, which is exactly
  /// what a watchdog exists to prevent.
  void _onWatchdogFired(
    ReconnectWatchdogFired _,
    Emitter<PtConnectionState> emit,
  ) {
    if (isClosed) return;
    if (!_started || _closing) return;
    if (_socketUp) return;
    if (_backoffTimer != null) return;
    // Deliberately not gated on `_backgrounded`. That flag is cleared only by an
    // `AppForegrounded` event, so one missed lifecycle signal would disable this
    // backstop along with every other recovery path — leaving an app that is on
    // screen, online, and permanently offline. A dial is cheap and the gate
    // refuses it when there really is no route, so the watchdog prefers trying.
    _offline = false;
    add(const Connect());
  }

  /// Starts the watchdog once; it runs for as long as the session does.
  void _ensureWatchdog() {
    if (_watchdogTimer != null || isClosed) return;
    _watchdogTimer = Timer.periodic(watchdogInterval, (_) {
      if (isClosed) return;
      add(const ReconnectWatchdogFired());
    });
  }

  void _onBackoffElapsed(
    BackoffElapsed event,
    Emitter<PtConnectionState> emit,
  ) {
    if (event.attemptId != _currentAttemptId) {
      // A superseded attempt: the id moved on, so this timer must not open a
      // second socket.
      AppLogger.debug(
        _msgBackoffIgnored,
        fields: <String, Object?>{
          LogFields.component: LogComponents.transport,
          LogFields.count: event.attemptId,
        },
      );
      return;
    }
    // Consume the id before dialling: a duplicate delivery of this same event
    // must not open a second socket.
    _cancelBackoff();
    if (!_started || _offline || _closing || _backgrounded) return;
    if (isClosed) return;
    add(const Connect());
  }

  /// Attaches to the repository, cancelling any previous attachment first.
  void _listenToStream() {
    _cancelStreamSubscriptions();
    _messagesSub = _stream.messages.listen(
      (ServerMessage message) => add(SocketMessageReceived(message)),
      onError: (Object error, StackTrace stackTrace) =>
          _contain('messages_stream', error, stackTrace),
    );
    _failuresSub = _stream.failures.listen(
      (AppFailure failure) => add(TransportFailureReported(failure)),
      onError: (Object error, StackTrace stackTrace) =>
          _contain('failures_stream', error, stackTrace),
    );
    _statusSub = _stream.statusStream.listen(
      (ConnectionStatus status) => add(SocketStatusReported(status)),
      onError: (Object error, StackTrace stackTrace) =>
          _contain('status_stream', error, stackTrace),
    );
  }

  void _handleSocketMessage(
    SocketMessageReceived event,
    Emitter<PtConnectionState> emit,
  ) {
    _onMessage(event.message, emit);
  }

  void _handleTransportFailure(
    TransportFailureReported event,
    Emitter<PtConnectionState> emit,
  ) {
    _onFailure(event.failure, emit);
  }

  void _handleSocketStatus(
    SocketStatusReported event,
    Emitter<PtConnectionState> emit,
  ) {
    _onStatus(event.status, emit);
  }

  void _onStatus(ConnectionStatus status, Emitter<PtConnectionState> emit) {
    if (isClosed) return;
    final ConnectionStatus previous = _lastStatus;
    _lastStatus = status;
    if (status == ConnectionStatus.connected) {
      _onSocketUp(emit);
      return;
    }
    if (status == ConnectionStatus.disconnected) {
      _onSocketDown(
        reason: 'status_disconnected',
        previous: previous,
        emit: emit,
      );
    }
    // `connecting`/`reconnecting` are the transport narrating its own retry; the
    // bloc's timer owns the schedule, so neither arms a second attempt.
  }

  void _onFailure(AppFailure failure, Emitter<PtConnectionState> emit) {
    if (isClosed) return;
    AppLogger.warn(
      LogEvents.wsDisconnected,
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        if (failure.code != null) LogFields.errorCode: failure.code,
        LogFields.reason: 'failure_reported',
      },
    );
    if (failure is OfflineFailure) {
      // The transport's offline gate refused the dial, which mirrors what the
      // connectivity layer reports; no retry may be armed while offline.
      _offline = true;
      _cancelBackoff();
      _stopHeartbeat();
      emit(const ConnectionOffline());
      return;
    }
    _onSocketDown(
      reason: failure.code ?? 'failure_reported',
      previous: _lastStatus,
      emit: emit,
    );
  }

  void _onMessage(ServerMessage message, Emitter<PtConnectionState> emit) {
    if (isClosed) return;
    // Only the frames that describe *this socket* are read here.
    if (message is WelcomeMessage) {
      _onWelcome(message, emit);
      return;
    }
    if (message is PongMessage) {
      _onPong(message, emit);
      return;
    }
    if (message is HealthMessage) {
      _onHealth(message, emit);
      return;
    }
    if (message is GoodbyeMessage) {
      _onSocketDown(reason: 'goodbye', previous: _lastStatus, emit: emit);
      return;
    }
    if (message is ErrorMessage && message.fatal) {
      _onSocketDown(reason: 'fatal_error', previous: _lastStatus, emit: emit);
    }
  }

  void _onWelcome(WelcomeMessage welcome, Emitter<PtConnectionState> emit) {
    AppLogger.setSession(
      sessionId: welcome.sessionId,
      shortId: welcome.shortId,
    );
    // The announced cadence is honoured, but one longer than the backend's
    // missing-report window cannot be: the tier machine would classify every
    // report as overdue and hold the client at MINIMAL however good its link is.
    final Duration announced = Duration(milliseconds: welcome.heartbeatMs);
    if (announced > Duration.zero && announced <= _maxHeartbeatInterval) {
      _heartbeatInterval = announced;
    }
    if (!_socketUp) return;
    _startHeartbeat();
    emit(_connectedState());
    unawaited(_resubscribe());
  }

  void _onPong(PongMessage pong, Emitter<PtConnectionState> emit) {
    final RttSample? sample = _rtt.onPong(pong);
    if (sample == null) return;
    _rttMs = sample.rttMs.round();
    final double jitterMs = _jitter.add(sample.rttMs);
    // A pong that arrived while reachability says offline is stale evidence; the
    // offline state stands until the connectivity stream clears it.
    if (_socketUp && !_offline) emit(_connectedState());
    _maybeReportHealth(jitterMs);
  }

  void _onHealth(HealthMessage message, Emitter<PtConnectionState> emit) {
    final DeliveryTier reported = message.health.tier;
    if (reported == _tier) return;
    _tier = reported;
    AppLogger.info(
      _msgTierObserved,
      fields: <String, Object?>{
        LogFields.component: LogComponents.tier,
        LogFields.tier: reported.wire,
        LogFields.reason: message.health.reason,
      },
    );
    if (_socketUp && !_offline) emit(_connectedState());
  }

  void _onSocketUp(Emitter<PtConnectionState> emit) {
    _cancelBackoff();
    _closing = false;
    // A live socket is proof of reachability, so an earlier reading is stale.
    _offline = false;
    _socketUp = true;
    _connectedAtMs = _clock.monotonicMs();
    _socketGeneration++;
    _resetHealthRegime();
    AppLogger.info(
      LogEvents.wsConnected,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.count: _socketGeneration,
      },
    );
    _startHeartbeat();
    emit(_connectedState());
    unawaited(_resubscribe());
  }

  void _onSocketDown({
    required String reason,
    required ConnectionStatus previous,
    required Emitter<PtConnectionState> emit,
  }) {
    if (!_started || _offline || _closing) return;
    if (_backoffTimer != null) return; // One timer only.

    _socketUp = false;
    _stopHeartbeat();

    if (_backgrounded) {
      // Android throttles the radio for backgrounded apps, so retrying here would
      // spend battery on a screen nobody is looking at. Report the freeze and let
      // `AppForegrounded` reconnect.
      _connectedAtMs = null;
      emit(const ConnectionStale(reason: 'socket_down_while_backgrounded'));
      return;
    }

    final int? upSinceMs = _connectedAtMs;
    _connectedAtMs = null;
    if (upSinceMs != null) {
      final Duration connectedFor = Duration(
        milliseconds: _clock.monotonicMs() - upSinceMs,
      );
      if (_policy.isStableEnoughToReset(connectedFor)) {
        _attempt = 0; // A stable connection resets the schedule.
        _policy.reset();
      }
    }

    _attempt++;
    _currentAttemptId++;
    final Duration delay = _policy.delayFor(_attempt);
    final int attemptId = _currentAttemptId;
    _backoffTimer = Timer(delay, () {
      _backoffTimer = null;
      if (isClosed) return;
      add(BackoffElapsed(attemptId));
    });
    _metrics.increment(MetricNames.wsReconnectsTotal);
    AppLogger.warn(
      LogEvents.wsReconnectScheduled,
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        LogFields.reason: reason,
        LogFields.count: _attempt,
        LogFields.durationMs: delay.inMilliseconds,
      },
    );
    emit(
      ConnectionReconnecting(
        attempt: _attempt,
        nextAttemptIn: delay,
        previous: previous,
      ),
    );
  }

  /// Re-sends the subscription, at most once per socket.
  Future<void> _resubscribe() async {
    if (_resubscribedGeneration == _socketGeneration) return;
    _resubscribedGeneration = _socketGeneration;
    // The repository holds the subscription in force, so a reconnect restores
    // the market the user switched to rather than the one the app started on.
    final SubscriptionSpec spec = _stream.currentSubscription ?? _subscription;
    await _guard(() => _stream.subscribe(spec));
    AppLogger.info(
      _msgSubscribed,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.symbol: spec.symbol,
        LogFields.interval: spec.interval.wire,
      },
    );
  }

  /// The connected state, read from the repository's cached `welcome`.
  ConnectionConnected _connectedState() {
    final WelcomeMessage? welcome = _safeWelcome();
    return ConnectionConnected(
      rttMs: _rttMs,
      sessionId: welcome?.sessionId ?? '',
      shortId: welcome?.shortId ?? '',
      epoch: welcome?.epoch ?? 0,
      tier: _tier,
    );
  }

  WelcomeMessage? _safeWelcome() {
    try {
      return _stream.welcome;
    } on Object catch (error, stackTrace) {
      _contain('welcome_read', error, stackTrace);
      return null;
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat(); // Cancel before arming: one heartbeat timer, always.
    if (!_socketUp) return;
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, _onHeartbeatTick);
  }

  void _onHeartbeatTick(Timer _) {
    if (isClosed || _backgrounded || !_socketUp) return;
    // Expiry is derived from the clock rather than a per-pulse timer so the timer
    // count stays constant.
    final int expired = _rtt.expirePending();
    if (expired > 0) {
      // Unanswered past the pulse timeout. A socket that has gone quiet is only
      // observable here: the transport reports a peer close, and a disappeared
      // network sends none.
      add(const HeartbeatMissed());
      return;
    }
    unawaited(_sendSafely(_rtt.nextPing()));
  }

  void _onHeartbeatMissed(HeartbeatMissed _, Emitter<PtConnectionState> emit) {
    if (!_socketUp || _closing || _offline) return;
    _onSocketDown(reason: 'pong_timeout', previous: _lastStatus, emit: emit);
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Sends a `latency_report`, throttled to one every two seconds.
  void _maybeReportHealth(double jitterMs) {
    final int nowMs = _clock.monotonicMs();
    if (nowMs - _lastReportAtMs < _reportIntervalMs) return;
    _lastReportAtMs = nowMs;
    unawaited(
      _sendSafely(
        LatencyReportMessage(
          rttMs: _rtt.averageRttMs,
          jitterMs: jitterMs,
          samples: _jitter.sampleCount,
          clientTimeMs: _clock.now().millisecondsSinceEpoch,
          window: _jitterWindow,
          missedPongs: _rtt.missedPongs,
          cappedSamples: _jitter.cappedCount,
        ),
      ),
    );
  }

  /// Clears the RTT window and its jitter and logs the reset, so
  /// "why did the latency readout jump" is answerable from the log alone.
  void _resetHealthRegime() {
    _rtt.reset();
    _jitter.reset();
    _rttMs = 0;
    _lastReportAtMs = _clock.monotonicMs() - _reportIntervalMs;
    AppLogger.info(
      _msgHeartbeat,
      fields: <String, Object?>{
        LogFields.component: LogComponents.metrics,
        LogFields.reason: 'rtt_regime_reset',
      },
    );
  }

  Future<void> _dialSafely(Emitter<PtConnectionState> emit) async {
    _dialInFlight = true;
    try {
      await _stream.connect().timeout(_dialTimeout);
    } on TimeoutException {
      // Release the slot and let the normal retry path take over. `finally`
      // below clears the flag, so the next attempt is a real attempt.
      _contain(
        'dial_timeout',
        TimeoutException('dial timed out'),
        StackTrace.current,
      );
      _onSocketDown(reason: 'dial_timeout', previous: _lastStatus, emit: emit);
    } on Object catch (error, stackTrace) {
      _contain('dial', error, stackTrace);
      _onSocketDown(reason: 'dial_failed', previous: _lastStatus, emit: emit);
    } finally {
      _dialInFlight = false;
    }
  }

  Future<void> _sendSafely(ClientMessage message) =>
      _guard(() => _stream.send(message));

  /// Runs a repository call and turns a thrown error into a log record, which is
  /// what keeps an exception out of the widget tree.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      _contain('repository_call', error, stackTrace);
    }
  }

  void _contain(String reason, Object error, StackTrace stackTrace) {
    AppLogger.error(
      _msgStreamCallFailed,
      fields: <String, Object?>{
        LogFields.component: LogComponents.transport,
        LogFields.reason: reason,
      },
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Cancels the pending backoff timer, if any.
  ///
  /// The attempt id moves on with every cancellation, so a timer that already
  /// fired and queued its [BackoffElapsed] is superseded even when it is
  /// delivered after the cancellation — which is what makes "at most one
  /// reconnect timer" true in the presence of event-queue interleaving.
  void _cancelBackoff() {
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _currentAttemptId++;
  }

  void _cancelStreamSubscriptions() {
    unawaited(_messagesSub?.cancel());
    unawaited(_failuresSub?.cancel());
    unawaited(_statusSub?.cancel());
    _messagesSub = null;
    _failuresSub = null;
    _statusSub = null;
  }

  /// Releases the timers and subscriptions this bloc owns.
  ///
  /// A doc comment rather than an implementation note because this override is
  /// part of the bloc's public contract: closing it must leave nothing behind.
  @override
  Future<void> close() async {
    // No timer and no subscription outlives the bloc. The socket itself is
    // closed by [Disconnect] or by the repository's owner; this bloc releases
    // only what it created.
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _cancelBackoff();
    _stopHeartbeat();
    _cancelStreamSubscriptions();
    return super.close();
  }
}
