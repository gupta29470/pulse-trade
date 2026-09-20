import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';

/// Severity of a log record, ordered so a minimum level is a simple comparison.
enum LogLevel {
  /// Per-event protocol detail. Off unless explicitly enabled.
  debug,

  /// Lifecycle: connect, subscribe, recovery, tier change.
  info,

  /// Anomalous but handled: malformed frame, gap, stale response.
  warn,

  /// Broken invariant or failed dependency.
  error,
}

/// The single structured logger.
///
/// Every record is one JSON object with the canonical fields, emitted through
/// `dart:developer` `log` so it shows up in the observability tools without
/// stdout noise. `print` is banned by lint and never used here. A bounded ring
/// buffer keeps the last [ringCapacity] records so `Copy diagnostics JSON` can
/// export them verbatim without touching the file system.
abstract final class AppLogger {
  const AppLogger._();

  /// The service name carried on every record.
  static const String serviceName = 'pulsetrade-frontend';

  /// The build version carried on every record.
  static const String version = '0.1.0';

  /// Maximum retained records. A log console is not a data store.
  static const int ringCapacity = 500;

  /// Name passed to `dart:developer` so records can be filtered by tooling.
  static const String developerName = 'pulsetrade';

  /// Time source. Injectable so tests get deterministic `time` fields, and so
  /// this file remains the only logger that needs a wall clock.
  static Clock clock = SystemClock();

  /// Records below this level are dropped before they reach the ring buffer.
  static LogLevel minLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;

  static final ListQueue<Map<String, Object?>> _records =
      ListQueue<Map<String, Object?>>();

  static String? _sessionId;
  static String? _shortId;
  static String? _component;

  /// The retained log records, oldest first.
  static List<Map<String, Object?>> get records =>
      List<Map<String, Object?>>.unmodifiable(_records);

  /// Attaches the session scope to every subsequent record.
  static void setSession({required String sessionId, required String shortId}) {
    _sessionId = sessionId;
    _shortId = shortId;
  }

  /// Clears the session scope on disconnect.
  static void clearSession() {
    _sessionId = null;
    _shortId = null;
  }

  /// Sets a default `component` for call sites that would otherwise repeat it.
  static void setComponent(String component) {
    _component = component;
  }

  /// Empties the ring buffer. Used between tests so records do not leak.
  static void clear() {
    _records.clear();
  }

  /// Serializes the ring buffer as a JSON array, for `Copy diagnostics JSON`.
  static String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(_records.toList());

  /// Logs per-event protocol detail.
  static void debug(String msg, {Map<String, Object?> fields = const {}}) =>
      _emit(LogLevel.debug, msg, fields);

  /// Logs a lifecycle event.
  static void info(String msg, {Map<String, Object?> fields = const {}}) =>
      _emit(LogLevel.info, msg, fields);

  /// Logs an anomalous but handled condition.
  static void warn(String msg, {Map<String, Object?> fields = const {}}) =>
      _emit(LogLevel.warn, msg, fields);

  /// Logs a broken invariant or a failed dependency.
  static void error(
    String msg, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) {
    final merged = <String, Object?>{
      if (error != null) LogFields.error: error.toString(),
      ...fields,
    };
    _emit(LogLevel.error, msg, merged, stackTrace: stackTrace);
  }

  static void _emit(
    LogLevel level,
    String msg,
    Map<String, Object?> fields, {
    StackTrace? stackTrace,
  }) {
    if (level.index < minLevel.index) return;

    final record = <String, Object?>{
      LogFields.time: _formatTime(clock.now()),
      LogFields.level: level.name.toUpperCase(),
      LogFields.msg: msg,
      LogFields.service: serviceName,
      LogFields.version: version,
      if (_sessionId != null) LogFields.sessionId: _sessionId,
      if (_shortId != null) LogFields.shortId: _shortId,
      LogFields.component: fields[LogFields.component] ?? _component ?? 'app',
      for (final MapEntry<String, Object?> entry in fields.entries)
        if (entry.key != LogFields.component &&
            !LogFields.redacted.contains(entry.key))
          entry.key: entry.value,
    };

    _records.addLast(record);
    while (_records.length > ringCapacity) {
      _records.removeFirst();
    }

    developer.log(
      jsonEncode(record),
      name: developerName,
      level: _developerLevel(level),
      error: fields[LogFields.error],
      stackTrace: stackTrace,
    );
  }

  static int _developerLevel(LogLevel level) => switch (level) {
    LogLevel.debug => 500,
    LogLevel.info => 800,
    LogLevel.warn => 900,
    LogLevel.error => 1000,
  };

  /// RFC3339 with milliseconds, UTC — the exact format the backend emits, so a
  /// reviewer can diff the two streams with `jq`.
  static String _formatTime(DateTime value) {
    final utc = value.toUtc();
    final iso = utc.toIso8601String();
    // `toIso8601String` emits microseconds on the VM; the wire contract is
    // millisecond precision, so it is truncated rather than rounded.
    final dot = iso.indexOf('.');
    if (dot < 0) return iso;
    final fraction = iso.substring(dot + 1).replaceAll('Z', '');
    return '${iso.substring(0, dot)}.${fraction.padRight(3, '0').substring(0, 3)}Z';
  }
}
