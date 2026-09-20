import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';

/// Implements the background policy.
///
/// On `paused`/`inactive` the heartbeats must stop **immediately** (a socket
/// left pinging in the background burns the user's battery and radio), but the
/// socket itself is kept for [backgroundTimeout] because a glance at another
/// app should not cost a reconnect. Only when the timeout fires is the socket
/// closed and the market marked `STALE`.
///
/// This class owns no socket state: it calls the three supplied callbacks so
/// the composition root can decide what "stop pings", "close now" and "come
/// back" mean. Exactly one timer exists at any time: every transition
/// cancels before it arms.
final class AppLifecycleObserver with WidgetsBindingObserver {
  /// Creates the observer.
  ///
  /// [_onBackgrounded] is invoked immediately on the first background
  /// transition, [_onBackgroundTimeout] once the timeout elapses while still
  /// backgrounded, and [_onForegrounded] on every resume. A resume always calls
  /// [_onForegrounded] — even when the socket survived — because the caller may
  /// still have to restart the connectivity probe; [socketClosedWhileBackgrounded]
  /// is how it learns whether a reconnect and snapshot sync are needed.
  AppLifecycleObserver({
    required this._onBackgrounded,
    required this._onBackgroundTimeout,
    required this._onForegrounded,
    Clock? clock,
    this._backgroundTimeout = const Duration(seconds: 30),
  }) : _clock = clock ?? SystemClock();

  static const String _msgBackgrounded = 'app_backgrounded';
  static const String _msgForegrounded = 'app_foregrounded';
  static const String _msgBackgroundTimeout = 'app_background_timeout';
  static const String _msgBackgroundTimerDisabled =
      'app_background_timer_disabled';
  static const String _msgTimeoutChanged = 'app_background_timeout_changed';
  static const String _msgObserverAttached = 'app_lifecycle_observer_attached';
  static const String _msgObserverRemoved = 'app_lifecycle_observer_removed';

  static const String _reasonSocketSurvived = 'socket_survived';
  static const String _reasonSocketClosed = 'socket_closed';

  final VoidCallback _onBackgrounded;
  final VoidCallback _onBackgroundTimeout;
  final VoidCallback _onForegrounded;
  final Clock _clock;

  Duration _backgroundTimeout;
  Timer? _timer;
  bool _attached = false;
  bool _backgrounded = false;
  bool _socketClosedWhileBackgrounded = false;
  int _backgroundedAtMs = 0;

  /// Whether the app is currently considered backgrounded.
  ///
  /// True from the first `paused`/`inactive`/`hidden` transition until the next
  /// `resumed`, including the period after the timeout has fired.
  bool get isBackgrounded => _backgrounded;

  /// Whether the background timer fired during the most recent background
  /// episode, i.e. the socket was closed and `resumed` therefore needs a full
  /// reconnect → resubscribe → snapshot sync.
  ///
  /// Cleared when the next background episode begins, so it always describes
  /// the episode that just ended.
  bool get socketClosedWhileBackgrounded => _socketClosedWhileBackgrounded;

  /// How long the socket is kept alive after backgrounding.
  ///
  /// `Duration.zero` (or negative) means "never close": no timer is armed at
  /// all. The value is a setting, so it can change while the app runs.
  Duration get backgroundTimeout => _backgroundTimeout;

  /// Changes [backgroundTimeout] and re-arms the timer if the app is currently
  /// backgrounded and the previous timer has not already fired.
  ///
  /// Re-arming starts a fresh window from now, so a timeout change extends the
  /// current window instead of cutting it short and closing the socket early.
  void setBackgroundTimeout(Duration value) {
    if (value == _backgroundTimeout) return;
    _backgroundTimeout = value;
    if (_backgrounded && !_socketClosedWhileBackgrounded) {
      _startBackgroundTimer();
    }
    AppLogger.info(
      _msgTimeoutChanged,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.durationMs: value.inMilliseconds,
      },
    );
  }

  /// Registers this observer with [WidgetsBinding].
  ///
  /// The Flutter binding must already be initialized (`main` calls
  /// `WidgetsFlutterBinding.ensureInitialized` before bootstrap). Idempotent,
  /// so a hot reload or a double bootstrap cannot register twice and deliver
  /// every lifecycle event to two live observers.
  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    AppLogger.info(
      _msgObserverAttached,
      fields: <String, Object?>{LogFields.component: LogComponents.session},
    );
  }

  /// Removes the observer and cancels the pending timer.
  ///
  /// Called from the composition root's teardown; after this the instance is
  /// inert, so a late platform event cannot call into a disposed graph.
  void dispose() {
    if (_attached) {
      WidgetsBinding.instance.removeObserver(this);
      _attached = false;
    }
    _cancelTimer();
    _backgrounded = false;
    AppLogger.info(
      _msgObserverRemoved,
      fields: <String, Object?>{LogFields.component: LogComponents.session},
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `hidden` precedes `paused` on the platforms that report it.
    // `detached` means the engine is going away; both are "not in the
    // foreground", so heartbeats stop on the first of them. Every enumerator is
    // listed so a future lifecycle state forces a decision here instead of
    // silently defaulting to one branch.
    final bool backgrounded = switch (state) {
      AppLifecycleState.inactive ||
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => true,
      AppLifecycleState.resumed => false,
    };

    if (backgrounded) {
      _handleBackgrounded();
    } else {
      _handleForegrounded();
    }
  }

  void _handleBackgrounded() {
    if (_backgrounded) return;
    _backgrounded = true;
    _socketClosedWhileBackgrounded = false;
    _backgroundedAtMs = _clock.monotonicMs();

    // Heartbeats stop now; the socket close is the timer's decision.
    _onBackgrounded();
    AppLogger.info(
      _msgBackgrounded,
      fields: <String, Object?>{LogFields.component: LogComponents.session},
    );

    _startBackgroundTimer();
  }

  void _handleForegrounded() {
    // `resumed` is also delivered once at startup, before any background
    // transition; there is nothing to resume then.
    if (!_backgrounded) return;

    final bool socketClosed = _socketClosedWhileBackgrounded;
    _cancelTimer();
    _backgrounded = false;
    _onForegrounded();
    AppLogger.info(
      _msgForegrounded,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.durationMs: _clock.monotonicMs() - _backgroundedAtMs,
        LogFields.reason: socketClosed
            ? _reasonSocketClosed
            : _reasonSocketSurvived,
      },
    );
  }

  /// Arms the single background timer, unless the policy is "never close".
  void _startBackgroundTimer() {
    _cancelTimer();
    final Duration timeout = _backgroundTimeout;
    if (timeout <= Duration.zero) {
      AppLogger.info(
        _msgBackgroundTimerDisabled,
        fields: <String, Object?>{LogFields.component: LogComponents.session},
      );
      return;
    }
    _timer = Timer(timeout, _onBackgroundTimerFired);
  }

  void _onBackgroundTimerFired() {
    _timer = null;
    _socketClosedWhileBackgrounded = true;
    _onBackgroundTimeout();
    AppLogger.info(
      _msgBackgroundTimeout,
      fields: <String, Object?>{
        LogFields.component: LogComponents.session,
        LogFields.durationMs: _backgroundTimeout.inMilliseconds,
        LogFields.reason: _reasonSocketClosed,
      },
    );
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
