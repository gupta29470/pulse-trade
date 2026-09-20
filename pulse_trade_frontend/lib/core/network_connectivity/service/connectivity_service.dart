import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/utils/network_constants.dart';
import 'package:pulse_trade_frontend/core/network_connectivity/utils/network_quality.dart';
import 'package:rxdart/rxdart.dart';

// Re-exported so a consumer of this module speaks one vocabulary for
// reachability instead of also importing the plugin.
export 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart'
    show InternetStatus;

/// Log field key holding the raw probe status (`connected` / `disconnected`).
///
/// [LogFields] carries the canonical app-wide vocabulary and has no
/// connectivity-status key; rather than invent a global field, the one key this
/// module needs lives next to its only writer.
const String _internetStatusField = 'internetStatus';

/// The single source of *internet reachability*.
///
/// This layer answers one question only: can this device reach the internet? It
/// says nothing about the backend socket or market liveness — those are separate
/// layers and must never be collapsed into one boolean.
///
/// Semantics carried over from the reference module deliberately: two
/// independent probes with `useDefaultOptions: false` so one dead endpoint
/// cannot fake an outage; `null` (UNKNOWN) until the first probe answers;
/// a debounce before a disconnect is published and no disconnect published
/// while backgrounded; status consumed as a stream, never polled at build time.
class ConnectivityService with WidgetsBindingObserver {
  /// Creates the service.
  ///
  /// [clock] is the time source for latency; tests inject a `FakeClock` so a
  /// sample is deterministic and no production path needs `DateTime.now()`.
  ///
  /// [_disconnectDebounce] overrides the disconnect debounce so a test can
  /// exercise it without waiting out the production interval.
  ConnectivityService({
    Clock? clock,
    this._disconnectDebounce = NetworkMonitoringConfig.disconnectDebounce,
  }) : _clock = clock ?? SystemClock();

  final Clock _clock;
  final Duration _disconnectDebounce;

  /// Last published status; `null` means UNKNOWN.
  InternetStatus? _internetStatus;

  /// Whether a probe is in flight right now.
  bool _isChecking = false;

  /// Whether the app is backgrounded; disconnect readings are dropped while
  /// true.
  bool _isPaused = false;

  /// Whether [dispose] already ran. Every later event is dropped, so a probe
  /// completing after disposal cannot touch a closed controller.
  bool _isDisposed = false;

  /// Whether the lifecycle observer was actually registered, so [dispose] does
  /// not need the binding in a test that never initialized the service.
  bool _observerAttached = false;

  /// Publishes the status. A `BehaviorSubject` rather than a plain broadcast
  /// controller: a page that subscribes late receives the current status
  /// immediately instead of rendering UNKNOWN until the next transition.
  final BehaviorSubject<InternetStatus?> _internetStatusController =
      BehaviorSubject<InternetStatus?>();

  /// Subscription to the checker's own status stream.
  StreamSubscription<InternetStatus>? _statusSubscription;

  /// Pending disconnect verdict.
  Timer? _disconnectDebounceTimer;

  /// The checker built by [initializeConnectionChecker]; `null` before
  /// initialization and after disposal.
  InternetConnection? _internetConnection;

  /// The last published status, or `null` while still UNKNOWN.
  ///
  /// `null` is a real state, not a synonym for offline: the first probe may not
  /// have completed and the UI must not claim offline before it has.
  InternetStatus? get internetStatus => _internetStatus;

  /// Status transitions, starting with the initial `null` (UNKNOWN).
  ///
  /// This is the only correct input for UI building.
  Stream<InternetStatus?> get internetStatusStream =>
      _internetStatusController.stream;

  /// Whether a probe is in flight right now.
  bool get isChecking => _isChecking;

  /// Whether the probe is suspended because the app is backgrounded.
  bool get isPaused => _isPaused;

  /// Whether the last published status is `connected`.
  ///
  /// NOTE: Do not use this for UI building — the UI is stream-driven
  /// ([internetStatusStream]), so it can never render a stale boolean. This
  /// getter is for non-widget call sites, such as an offline gate that must
  /// decide synchronously whether to attempt a call.
  bool get isInternetConnectionAvailable =>
      _internetStatus == InternetStatus.connected;

  /// Registers the lifecycle observer, publishes UNKNOWN, builds the checker
  /// and subscribes to its status stream.
  ///
  /// UNKNOWN is published before the first probe so no listener mistakes "no
  /// event yet" for offline; the subscription is attached after that probe so
  /// the first result is published once, not twice. A second call would build a
  /// second checker and leak the first subscription, so it is guarded.
  Future<void> initializeConnectionChecker() async {
    if (_isDisposed || _internetConnection != null) return;

    WidgetsBinding.instance.addObserver(this);
    _observerAttached = true;

    _logTransition('unknown_until_first_check');
    _internetStatusController.add(null);

    final connection = InternetConnection.createInstance(
      customCheckOptions: <InternetCheckOption>[
        InternetCheckOption(
          uri: Uri.parse(NetworkCheckEndpoints.primaryNetworkCheckUrl),
          timeout: NetworkMonitoringConfig.qualityCheckTimeout,
        ),
        InternetCheckOption(
          uri: Uri.parse(NetworkCheckEndpoints.secondaryQualityCheckEndpoint),
          timeout: NetworkMonitoringConfig.qualityCheckTimeout,
        ),
      ],
      useDefaultOptions: false,
      checkInterval: NetworkMonitoringConfig.checkInterval,
    );
    _internetConnection = connection;

    await checkConnection();

    // The service can be disposed while the first probe is in flight.
    if (_isDisposed) return;

    _statusSubscription = connection.onStatusChange.listen(
      _handleConnectionChange,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error(
          LogEvents.connectivityChanged,
          fields: <String, Object?>{
            LogFields.component: LogComponents.connectivity,
            LogFields.reason: 'status_stream_error',
          },
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        _logTransition('status_stream_closed');
      },
    );
  }

  /// Runs one probe now and publishes the result through the normal path, so a
  /// disconnect still waits out the debounce.
  ///
  /// Returns whether the internet answered. While a probe is already in flight
  /// this returns the last known answer rather than starting a second one, so a
  /// resume plus a manual retry cannot double the traffic.
  Future<bool> checkConnection() async {
    final connection = _internetConnection;
    // Before initialization, and after disposal, there is nothing to probe;
    // report what is already known rather than inventing a status.
    if (connection == null) return isInternetConnectionAvailable;
    if (_isChecking) return isInternetConnectionAvailable;

    _isChecking = true;
    try {
      final hasConnection = await connection.hasInternetAccess;
      _handleConnectionChange(
        hasConnection ? InternetStatus.connected : InternetStatus.disconnected,
      );
      return hasConnection;
    } on Object catch (error, stackTrace) {
      // The package swallows per-probe failures, so this is effectively
      // unreachable; it stays because a thrown probe must degrade to "no
      // answer" instead of escaping into the caller.
      AppLogger.error(
        LogEvents.connectivityChanged,
        fields: <String, Object?>{
          LogFields.component: LogComponents.connectivity,
          LogFields.reason: 'probe_failed',
        },
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    } finally {
      _isChecking = false;
    }
  }

  /// Measures the reachability round trip and maps it to a quality tier.
  ///
  /// Returns `unknown` when nothing answers. The measurement uses
  /// [Clock.monotonicMs] and never wall time, so a clock jump cannot corrupt a
  /// sample. The result is a diagnostics readout only, never a tier input, which
  /// is why it is not logged as a connectivity transition.
  Future<NetworkQuality> getNetworkQuality() async {
    final connection = _internetConnection;
    if (connection == null) return NetworkQuality.unknown;

    final startedAtMs = _clock.monotonicMs();
    final hasConnection = await connection.hasInternetAccess;
    final latencyMs = _clock.monotonicMs() - startedAtMs;

    if (!hasConnection) return NetworkQuality.unknown;
    return qualityFromLatencyMs(latencyMs);
  }

  /// Maps a measured latency to a quality tier, using
  /// [NetworkQualityThreshold].
  ///
  /// Public so Diagnostics and tests can classify a known sample without
  /// running a probe.
  NetworkQuality qualityFromLatencyMs(int latencyMs) {
    if (latencyMs < NetworkQualityThreshold.excellentThreshold) {
      return NetworkQuality.excellent;
    }
    if (latencyMs < NetworkQualityThreshold.goodThreshold) {
      return NetworkQuality.good;
    }
    if (latencyMs < NetworkQualityThreshold.fairThreshold) {
      return NetworkQuality.fair;
    }
    return NetworkQuality.poor;
  }

  /// Suspends trust in probe results while the app is backgrounded.
  ///
  /// Android throttles network access for backgrounded apps, so a disconnect
  /// reading taken there would show OFFLINE for a healthy connection.
  void setConnectionCheckPaused() {
    if (_isPaused) return;
    _isPaused = true;
    _logTransition('checks_paused');
  }

  /// Clears [isPaused] and immediately re-probes.
  ///
  /// Time passed while backgrounded, so the published status may already be
  /// wrong; waiting for the next scheduled probe would leave it stale for up to
  /// a full interval.
  void setConnectionResumedAndCheckConnection() {
    _isPaused = false;
    _logTransition('checks_resumed');
    unawaited(checkConnection());
  }

  /// Releases every resource this service owns. Safe to call more than once.
  ///
  /// Cancels the pending verdict, detaches the observer, cancels the checker
  /// subscription and closes the status controller, so no timer or listener
  /// outlives its screen.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    _disconnectDebounceTimer?.cancel();
    _disconnectDebounceTimer = null;

    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAttached = false;
    }

    unawaited(_statusSubscription?.cancel());
    _statusSubscription = null;
    _internetConnection = null;

    // Closing a controller whose listeners have not yet cancelled is deliberate:
    // the listeners are owned by their consumers (a bloc disposes its own
    // subscription before this service). Awaiting that close, or awaiting a
    // listener's `cancel()` after this point, would deadlock — the close future
    // waits for the listeners and the cancel future waits for the close — so
    // dispose is synchronous and the close is fire-and-forget.
    unawaited(_internetStatusController.close());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      setConnectionCheckPaused();
    } else if (state == AppLifecycleState.resumed) {
      setConnectionResumedAndCheckConnection();
    }
  }

  /// Feeds a status through the exact path the checker's stream uses —
  /// debounce, pause rule and dedupe included.
  ///
  /// A test cannot make the package's own stream emit on demand; driving the
  /// real handling path keeps a debounce test honest instead of testing a copy
  /// of the logic.
  @visibleForTesting
  void emitStatusForTest(InternetStatus status) =>
      _handleConnectionChange(status);

  /// Applies the pause and debounce rules, then publishes.
  void _handleConnectionChange(InternetStatus status) {
    if (_isDisposed) return;

    // Any fresh reading supersedes a pending verdict: a `connected` during the
    // debounce cancels the disconnect instead of racing it.
    _disconnectDebounceTimer?.cancel();
    _disconnectDebounceTimer = null;

    if (_isPaused && status == InternetStatus.disconnected) {
      _logTransition('disconnect_ignored_while_paused');
      return;
    }

    if (status == InternetStatus.disconnected) {
      _logTransition('disconnect_debounced', debounce: _disconnectDebounce);
      _disconnectDebounceTimer = Timer(_disconnectDebounce, () {
        _disconnectDebounceTimer = null;
        // The app may have been backgrounded during the debounce, which would
        // make this verdict a product of a throttled probe.
        if (_isPaused) {
          _logTransition('debounced_disconnect_ignored_while_paused');
          return;
        }
        _emitStatus(InternetStatus.disconnected);
      });
      return;
    }

    _emitStatus(status);
  }

  /// Publishes [status] if it differs from the last published one.
  void _emitStatus(InternetStatus status) {
    if (_isDisposed) return;
    // Re-publishing a status the UI already holds would rebuild every listener
    // for nothing.
    if (_internetStatus == status) return;

    _internetStatus = status;
    _logTransition(
      status == InternetStatus.connected
          ? 'internet_connected'
          : 'internet_disconnected',
      status: status,
    );
    _internetStatusController.add(status);
  }

  /// Writes one structured connectivity record.
  ///
  /// Every record uses the same event slug and `component`, so the module can
  /// be filtered with `component=connectivity`; `reason`
  /// distinguishes the transitions.
  void _logTransition(
    String reason, {
    InternetStatus? status,
    Duration? debounce,
  }) {
    AppLogger.info(
      LogEvents.connectivityChanged,
      fields: <String, Object?>{
        LogFields.component: LogComponents.connectivity,
        LogFields.reason: reason,
        if (status != null) _internetStatusField: status.name,
        if (debounce != null) LogFields.durationMs: debounce.inMilliseconds,
      },
    );
  }
}
