import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/error/app_failure.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/networking/market_api.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_override.dart';
import 'package:pulse_trade_frontend/domain/entities/delivery_tier.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/repositories/market_stream_repository.dart';
import 'package:pulse_trade_frontend/features/debug/debug_console_state.dart';

/// One raw debug REST call, injected by the composition root.
///
/// `MarketApi` deliberately exposes no debug routes — they exist behind
/// `ENABLE_DEBUG_CONTROLS` and must never leak into the domain-facing client.
/// The console therefore receives the *transport function*
/// instead of a second API class: the parent wires it to a small Dio adapter
/// that returns the decoded JSON object, and the cubit stays free of `dio`,
/// which is what lets it be unit-tested with a fake that records paths and
/// query values.
///
/// [method] is part of the contract because the console needs both verbs: the
/// session list is a `GET`, while every fault and generator control is a `POST`. The
/// adapter used to hard-code `POST`, so the list answered `405 METHOD_NOT_ALLOWED`,
/// the console showed no sessions, and its fault controls could never be enabled.
typedef DebugRequest =
    Future<Map<String, Object?>> Function(
      String path, {
      Map<String, String>? query,
      Object? body,
      String method,
    });

/// How many book deltas a gap fault skips, and how long a stale-snapshot fault holds
/// writes. Both are large enough to be unmistakable on the client and small enough
/// that the session recovers on its own, which is what makes them demonstrable.
const int bookGapSkipCount = 3;
const int malformedFrameCount = 1;
const int staleSnapshotHoldMs = 4000;

/// The JSON body that injects [fault].
///
/// The backend serves **one** faults endpoint per session
/// (`POST /api/v1/debug/sessions/{id}/faults`) and takes every knob as a field of its
/// body, so a fault maps onto a field rather than onto a path. Each field name here
/// is one the backend decodes, and the mapping is deliberately a pure function: the
/// console addressed one path per fault for a while, so all six buttons answered 404,
/// and a test can now pin the field names without standing up the cubit.
Map<String, Object?> faultBodyFor(DebugFault fault) => switch (fault) {
  // A real sequence gap: the client must notice the range jump, resnapshot and resume.
  DebugFault.bookGap => <String, Object?>{'skipBookDeltas': bookGapSkipCount},
  // The same range sent twice, which an idempotent client must ignore.
  DebugFault.duplicateDelta => <String, Object?>{'duplicateDelta': true},
  // Two ranges in reverse order, which must be rejected rather than applied.
  DebugFault.outOfOrderDelta => <String, Object?>{'reverseDeltas': true},
  // Frames the client cannot parse, which must not take the socket down.
  DebugFault.malformed => <String, Object?>{
    'malformedFrames': malformedFrameCount,
  },
  // Writes held back, so the book ages past its staleness window while the socket stays up.
  DebugFault.staleSnapshot => <String, Object?>{
    'holdWritesMs': staleSnapshotHoldMs,
  },
  // No candle_closed, so a client that assumes broadcasts will diverge.
  DebugFault.intervalMismatch => <String, Object?>{'skipCandleClosed': true},
};

/// The protocol faults the backend can inject per session.
///
/// The slug is the exact path segment the backend matches, so a rename here is a
/// compile-time change at every call site and a silent 404 is impossible; the
/// label is the copy the console button shows.
enum DebugFault {
  /// Skip book mutations so the client must detect a range gap.
  bookGap('book-gap', 'Book gap'),

  /// Repeat the previous delta range so the client must ignore it idempotently.
  duplicateDelta('duplicate-delta', 'Duplicate delta'),

  /// Send two delta ranges in reverse order.
  outOfOrderDelta('out-of-order-delta', 'Out-of-order delta'),

  /// Send invalid JSON, an unknown type, a bad timestamp, and so on.
  malformed('malformed', 'Malformed message'),

  /// Reply to a snapshot request with an older update id.
  staleSnapshot('stale-snapshot', 'Stale snapshot'),

  /// Emit a candle update for an interval this session never subscribed to.
  intervalMismatch('interval-mismatch', 'Interval mismatch');

  /// Binds the wire slug and the button label.
  const DebugFault(this.slug, this.label);

  /// The exact path segment (`/faults/<slug>`) the backend validates.
  final String slug;

  /// Human-readable button label.
  final String label;
}

/// Drives the debug console screen.
///
/// Every action follows the same contract: mark the console busy, perform the
/// call, then **always** refresh the session list and the log tail and publish
/// one line of feedback. The refresh is not optional polish — the screen requires
/// the resulting *client-side reaction* to be visible, and the reaction arrives
/// in the log ring buffer and the session list, not in the HTTP response.
///
/// **Nothing throws out of this cubit.** A debug action that fails is data: it
/// becomes [DebugConsoleState.lastError] and one structured ERROR record, so a
/// fault injection that 404s does not take down the screen that is meant to
/// report it.
final class DebugConsoleCubit extends Cubit<DebugConsoleState> {
  /// Creates the cubit.
  ///
  /// [_api] is the offline-gated public REST client, used only to confirm the
  /// metrics-store fault through `/health` — the one place where the point
  /// of a fault is a *public* surface degrading. [_metrics] supplies the on-device
  /// counters shown next to the log tail.
  DebugConsoleCubit({
    required this._api,
    required this._stream,
    required this._metrics,
    Clock? clock,
    required this._debugRequest,
  }) : _clock = clock ?? SystemClock(),
       super(DebugConsoleState.initial);

  /// The debug REST prefix (`/api/v1/debug`).
  static const String _debugPrefix = '/api/v1/debug';

  /// How many log records the tail shows. The ring buffer holds 500; a console
  /// tail is for eyeballing a fault's aftermath, not for reading a day of logs.
  static const int logTailLength = 50;

  final MarketApi _api;
  final MarketStreamRepository _stream;
  final OnDeviceMetrics _metrics;
  final Clock _clock;
  final DebugRequest _debugRequest;

  /// The on-device counters, for the "client-side reaction" readout.
  ///
  /// A live read rather than a snapshot in state: counters change on paths the
  /// console does not drive, so a copied value would be stale exactly when a
  /// tester is looking for the effect of a fault.
  Map<String, int> get counters => _metrics.snapshot();

  /// The last [logTailLength] records, oldest first, as single-line JSON input.
  List<Map<String, Object?>> get logTail {
    final List<Map<String, Object?>> records = state.logRecords;
    if (records.length <= logTailLength) return records;
    return records.sublist(records.length - logTailLength);
  }

  /// Loads `GET /api/v1/debug/sessions` into the state.
  Future<void> loadSessions() async {
    if (isClosed) return;
    _safeEmit(state.copyWith(isBusy: true, lastResult: null, lastError: null));
    try {
      final List<DebugSessionInfo> sessions = await _fetchSessions();
      _safeEmit(
        state.copyWith(
          isBusy: false,
          sessions: sessions,
          lastResult: '${sessions.length} live session(s)',
          logRecords: AppLogger.records,
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'debug_action_failed',
        fields: <String, Object?>{
          LogFields.component: LogComponents.session,
          LogFields.event: 'load_sessions',
        },
        error: error,
        stackTrace: stackTrace,
      );
      _safeEmit(
        state.copyWith(
          isBusy: false,
          lastError: _describe(error),
          logRecords: AppLogger.records,
        ),
      );
    }
  }

  /// Stops the engine's trade generation.
  Future<void> pauseGenerator() => _generatorAction(
    path: 'pause',
    success: 'Generator paused — the client must show a paused market',
  );

  /// Resumes generation after [pauseGenerator].
  Future<void> resumeGenerator() =>
      _generatorAction(path: 'resume', success: 'Generator resumed');

  /// Resets the epoch, re-warms the engine and broadcasts a fresh snapshot.
  Future<void> resetGenerator() => _generatorAction(
    path: 'reset',
    success: 'Market reset — the client must resynchronise',
  );

  /// Forces a volatility burst for [seconds].
  Future<void> burstGenerator({int seconds = 5}) =>
      _runAction('generator_burst', () async {
        await _debugRequest(
          '$_debugPrefix/generator/burst',
          method: 'POST',
          query: <String, String>{'seconds': '$seconds'},
        );
        return 'Volatility burst requested for ${seconds}s';
      });

  /// Serves empty candle arrays for the next few history requests.
  Future<void> emptyHistory() => _generatorAction(
    path: 'empty-history',
    success: 'Empty-history mode armed',
  );

  /// Closes one session's socket with a shutdown-style goodbye.
  Future<void> dropSession(String id) => _runAction('session_drop', () async {
    await _debugRequest(
      '$_debugPrefix/sessions/${_encode(id)}/drop',
      method: 'POST',
    );
    return 'Drop requested for ${shortIdOf(id)}';
  });

  /// Adds [ms] of artificial write delay to one session.
  ///
  /// Delay is a knob on the faults body rather than a route of its own: the backend
  /// serves one faults endpoint per session and takes the knobs as JSON fields, so a
  /// separate `/lag` path answered 404.
  Future<void> lagSession(String id, int ms) =>
      _runAction('session_lag', () async {
        await _debugRequest(
          '$_debugPrefix/sessions/${_encode(id)}/faults',
          method: 'POST',
          body: <String, Object?>{'writeDelayMs': ms},
        );
        return 'Lag ${ms}ms requested for ${shortIdOf(id)}';
      });

  /// Randomises one session's write delay by up to [ms].
  Future<void> jitterSession(String id, int ms) =>
      _runAction('session_jitter', () async {
        await _debugRequest(
          '$_debugPrefix/sessions/${_encode(id)}/faults',
          method: 'POST',
          body: <String, Object?>{'writeJitterMs': ms},
        );
        return 'Jitter ${ms}ms requested for ${shortIdOf(id)}';
      });

  /// Pins or releases the delivery tier over the socket.
  Future<void> forceTier(DeliveryOverride override) =>
      _runAction('force_tier', () async {
        await _stream.send(TierOverrideMessage(tier: override.wire));
        _safeEmit(state.copyWith(tierOverride: override));
        return 'Tier override sent: ${override.wire}';
      });

  /// Injects one protocol fault into [sessionId].
  ///
  /// The backend serves one faults endpoint per session and takes every knob as a
  /// field of its JSON body, so a fault is a body rather than a path. The console
  /// used to address one path per fault, which the backend never served, so each of
  /// these buttons answered 404 — the mapping is [faultBodyFor] and is unit-tested
  /// against the field names the backend decodes.
  Future<void> injectFault(String sessionId, DebugFault fault) =>
      _runAction('inject_${_snake(fault.slug)}', () async {
        await _debugRequest(
          '$_debugPrefix/sessions/${_encode(sessionId)}/faults',
          method: 'POST',
          body: faultBodyFor(fault),
        );
        return '${fault.label} injected into ${shortIdOf(sessionId)}';
      });

  /// Makes the metrics store fail or recovers it.
  ///
  /// The follow-up `GET /api/v1/health` is the whole point of the control: the
  /// fault is only interesting if delivery continues while the public health
  /// surface degrades, so the result line reports the backend's own verdict
  /// instead of a 200 from the debug route.
  Future<void> setMetricsStoreFailure(bool fail) =>
      _runAction('metrics_store_failure', () async {
        await _debugRequest(
          '$_debugPrefix/metrics/fail',
          method: 'POST',
          query: <String, String>{'on': fail ? 'true' : 'false'},
        );
        final String storeState = fail ? 'failing' : 'restored';
        try {
          final HealthSnapshot health = await _api.getDetailedHealth();
          final String store = health.metricsStatus ?? 'unknown';
          return 'Metrics store $storeState · /health ${health.status} · '
              'store $store';
        } catch (error) {
          return 'Metrics store $storeState · health probe failed: '
              '${_describe(error)}';
        }
      });

  /// Closes this session's socket through the debug path.
  Future<void> dropConnection() => _runAction('drop_connection', () async {
    await _stream.disconnect(reason: 'debug');
    return 'Socket closed — the client must show STALE and reconnect';
  });

  /// Runs a generator control, which needs no query parameters.
  Future<void> _generatorAction({
    required String path,
    required String success,
  }) => _runAction('generator_${_snake(path)}', () async {
    await _debugRequest('$_debugPrefix/generator/$path', method: 'POST');
    return success;
  });

  /// The shared action envelope: busy, run, refresh, publish one feedback line.
  Future<void> _runAction(
    String label,
    Future<String> Function() action,
  ) async {
    if (isClosed) return;
    _safeEmit(state.copyWith(isBusy: true, lastResult: null, lastError: null));

    String? result;
    String? failure;
    try {
      result = await action();
    } catch (error, stackTrace) {
      failure = _describe(error);
      AppLogger.error(
        'debug_action_failed',
        fields: <String, Object?>{
          LogFields.component: LogComponents.session,
          LogFields.event: label,
        },
        error: error,
        stackTrace: stackTrace,
      );
    }

    // Refresh regardless of outcome: a failed action's aftermath (no session
    // list change, one ERROR record) is exactly what the console must show.
    List<DebugSessionInfo> sessions = state.sessions;
    try {
      sessions = await _fetchSessions();
    } catch (error) {
      failure ??= 'Session refresh failed: ${_describe(error)}';
    }

    if (isClosed) return;
    _safeEmit(
      state.copyWith(
        isBusy: false,
        sessions: sessions,
        lastResult: result,
        lastError: failure,
        logRecords: AppLogger.records,
      ),
    );
  }

  /// Fetches and parses the live session list.
  Future<List<DebugSessionInfo>> _fetchSessions() async {
    final Map<String, Object?> response = await _debugRequest(
      '$_debugPrefix/sessions',
      method: 'GET',
    );
    return _parseSessions(response);
  }

  /// Parses the session list from the several shapes a debug adapter may return.
  ///
  /// Defensive by design: this is a debug read against a route the parent wires
  /// by hand, so `{sessions: […]}` and `{items: […]}` are both accepted, a
  /// single session object is treated as a list of one, and an entry without an
  /// id is skipped rather than rendered as a blank row.
  List<DebugSessionInfo> _parseSessions(Map<String, Object?> response) {
    final Object? raw =
        response['sessions'] ?? response['items'] ?? response['data'];
    final List<DebugSessionInfo> out = <DebugSessionInfo>[];
    if (raw is List<Object?>) {
      for (final Object? entry in raw) {
        final DebugSessionInfo? session = _parseSession(entry);
        if (session != null) out.add(session);
      }
      return out;
    }
    final DebugSessionInfo? single = _parseSession(response);
    if (single != null) out.add(single);
    return out;
  }

  /// Parses one session object, returning `null` when it has no usable id.
  DebugSessionInfo? _parseSession(Object? entry) {
    if (entry is! Map<Object?, Object?>) return null;
    final String id = _stringOf(entry['sessionId'] ?? entry['id']);
    if (id.isEmpty) return null;

    final DateTime connectedAt = _dateOf(
      entry['connectedAt'] ?? entry['connected_at'],
    );
    final int reportedUptime = _intOf(entry['uptimeMs']);
    final int inferredUptime = connectedAt.millisecondsSinceEpoch == 0
        ? 0
        : _clock.now().difference(connectedAt).inMilliseconds;

    return DebugSessionInfo(
      id: id,
      shortId: _stringOf(entry['shortId'], fallback: shortIdOf(id)),
      tier:
          DeliveryTier.tryParse(_stringOf(entry['tier'])) ?? DeliveryTier.full,
      overrideTier:
          DeliveryOverride.tryParse(_stringOf(entry['override'])) ??
          DeliveryOverride.automatic,
      rttMs: _doubleOf(entry['rttMs']),
      jitterMs: _doubleOf(entry['jitterMs']),
      uptimeMs: reportedUptime > 0
          ? reportedUptime
          : (inferredUptime > 0 ? inferredUptime : 0),
      connectedAt: connectedAt,
      symbol: _stringOf(entry['symbol'], fallback: '—'),
    );
  }

  /// The six-character display id, matching the diagnostics readout.
  static String shortIdOf(String id) =>
      id.length <= 6 ? id : id.substring(0, 6);

  /// Turns a wire slug (`book-gap`) into a snake_case log event suffix.
  ///
  /// Extracted so the event slug is built in one place and a call site cannot
  /// emit a log record whose `event` value disagrees with the naming rule.
  static String _snake(String slug) => slug.replaceAll('-', '_');

  /// Percent-encodes a path segment so a session id cannot alter the route.
  static String _encode(String segment) => Uri.encodeComponent(segment);

  /// Emits unless the cubit was closed while an async operation was in flight.
  void _safeEmit(DebugConsoleState next) {
    if (isClosed) return;
    emit(next);
  }

  /// One line of user-facing failure copy for any thrown object.
  static String _describe(Object error) {
    if (error is AppFailure) {
      final String? code = error.code;
      return code == null ? error.message : '${error.message} ($code)';
    }
    return '$error';
  }

  /// Reads a string, or [fallback] when the value is missing or another type.
  static String _stringOf(Object? value, {String fallback = ''}) =>
      value is String ? value : fallback;

  /// Reads an integer from a JSON number or a decimal string.
  static int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// Reads a double from a JSON number or a decimal string.
  static double _doubleOf(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  /// Parses an ISO-8601 string or an epoch-millisecond number as UTC.
  static DateTime _dateOf(Object? value) {
    if (value is String) {
      final DateTime? parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
}
