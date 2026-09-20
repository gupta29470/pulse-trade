import 'dart:convert';

import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/storage/app_storage.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';

/// The `shared_preferences` cache tier.
///
/// Holds the small, frequently-read metadata that the tiered store routes here —
/// the market roster. **Contract: the whole tier stays at or below 64 KB.** That
/// is why payloads live in the file tier instead — a preferences file is
/// rewritten as a whole by the platform, so a multi-kilobyte candle series here
/// would make every unrelated write expensive.
///
/// Each entry is one JSON string under `cache.prefs.<key>` in the envelope
/// shape:
///
/// ```json
/// {"v":1,"at":"2026-09-17T12:41:03.240Z","ttlMs":300000,"payload":{...}}
/// ```
///
/// Reads never throw: a missing value, a corrupt envelope, a schema-version
/// mismatch or a decoder failure deletes the entry and reports a miss. A
/// **stale** entry is still returned, because TTL expiry marks data `STALE`
/// and never hides it.
final class PrefsCacheStore implements CacheStore {
  /// Creates the tier over an already-open [AppStorage].
  ///
  /// [clock] defaults to the system clock so production wiring only has to pass
  /// a storage handle, while a test can inject a [FakeClock] to make
  /// [CacheEntry.writtenAt] deterministic.
  PrefsCacheStore({
    required this._storage,
    this._metrics,
    Clock? clock,
    this._schemaVersion = kCacheSchemaVersion,
  }) : _clock = clock ?? SystemClock();

  /// Logical key prefix inside the preferences namespace.
  ///
  /// Combined with the namespace, the physical key is
  /// `pulsetrade.v1.cache.prefs.<key>`.
  static const String keyPrefix = 'cache.prefs.';

  final AppStorage _storage;
  final OnDeviceMetrics? _metrics;
  final Clock _clock;
  final int _schemaVersion;

  // Fallbacks used only when no metric registry was injected, so `stats` is
  // still meaningful in a unit test that constructs the tier bare.
  int _hits = 0;
  int _misses = 0;
  int _writes = 0;
  int _writeFailures = 0;

  @override
  Future<CacheEntry<T>?> read<T>(
    String key,
    T Function(Map<String, dynamic>) decode,
  ) async {
    final String? raw = _storage.readString('$keyPrefix$key');
    if (raw == null) {
      _countMiss();
      return null;
    }

    final _CacheEnvelope? envelope = _decodeEnvelope(_tryDecodeJson(raw));
    if (envelope == null) {
      AppLogger.debug(
        _eventCorrupt,
        fields: <String, Object?>{
          LogFields.component: LogComponents.cache,
          LogFields.cacheKey: key,
        },
      );
      await _discard(key);
      _countMiss();
      return null;
    }

    if (envelope.schemaVersion != _schemaVersion) {
      AppLogger.debug(
        _eventVersionMismatch,
        fields: <String, Object?>{
          LogFields.component: LogComponents.cache,
          LogFields.cacheKey: key,
          LogFields.count: envelope.schemaVersion,
        },
      );
      await _discard(key);
      _countMiss();
      return null;
    }

    final T payload;
    try {
      payload = decode(envelope.payload);
    } on Object catch (error) {
      AppLogger.debug(
        _eventDecodeFailed,
        fields: <String, Object?>{
          LogFields.component: LogComponents.cache,
          LogFields.cacheKey: key,
          LogFields.error: error.toString(),
        },
      );
      await _discard(key);
      _countMiss();
      return null;
    }

    _hits++;
    _metrics?.increment(MetricNames.cacheHitsTotal);
    return CacheEntry<T>(
      key: key,
      schemaVersion: envelope.schemaVersion,
      writtenAt: envelope.writtenAt,
      ttl: envelope.ttl,
      payload: payload,
    );
  }

  @override
  Future<void> write<T>(
    String key,
    T value, {
    required Duration ttl,
    required Map<String, dynamic> Function(T) encode,
  }) async {
    try {
      final Map<String, dynamic> payload = encode(value);
      final String raw = jsonEncode(<String, Object?>{
        _fieldVersion: _schemaVersion,
        _fieldWrittenAt: _clock.now().toUtc().toIso8601String(),
        _fieldTtlMs: ttl.inMilliseconds,
        _fieldPayload: payload,
      });
      await _storage.writeString('$keyPrefix$key', raw);
      _writes++;
      _metrics?.increment(MetricNames.cacheWritesTotal);
    } on Object catch (error) {
      _writeFailures++;
      _metrics?.increment(MetricNames.cacheWriteFailuresTotal);
      AppLogger.warn(
        LogEvents.cacheWriteFailed,
        fields: <String, Object?>{
          LogFields.component: LogComponents.cache,
          LogFields.cacheKey: key,
          LogFields.error: error.toString(),
        },
      );
    }
  }

  @override
  Future<void> invalidate(String key) async {
    await _discard(key);
  }

  @override
  Future<void> clear() async {
    for (final String key in _cacheKeys()) {
      await _discard(key);
    }
  }

  @override
  Future<CacheStats> stats() async {
    final List<String> keys = _cacheKeys();
    var bytes = 0;
    for (final String key in keys) {
      final String? raw = _storage.readString('$keyPrefix$key');
      if (raw != null) bytes += utf8.encode(raw).length;
    }
    return CacheStats(
      entries: keys.length,
      bytes: bytes,
      hits: _metrics?.value(MetricNames.cacheHitsTotal) ?? _hits,
      misses: _metrics?.value(MetricNames.cacheMissesTotal) ?? _misses,
      writes: _metrics?.value(MetricNames.cacheWritesTotal) ?? _writes,
      writeFailures:
          _metrics?.value(MetricNames.cacheWriteFailuresTotal) ??
          _writeFailures,
      evictions: 0,
    );
  }

  /// Cache keys owned by this tier, without the base key prefix.
  List<String> _cacheKeys() {
    final List<String> out = <String>[];
    for (final String key in _storage.keys()) {
      if (key.startsWith(keyPrefix)) {
        out.add(key.substring(keyPrefix.length));
      }
    }
    return out;
  }

  void _countMiss() {
    _misses++;
    _metrics?.increment(MetricNames.cacheMissesTotal);
  }

  /// Deletes one entry; a delete failure is logged but never rethrown, because
  /// the cache owns nothing the rest of the app needs.
  Future<void> _discard(String key) async {
    try {
      await _storage.remove('$keyPrefix$key');
    } on Object catch (error) {
      AppLogger.warn(
        _eventDeleteFailed,
        fields: <String, Object?>{
          LogFields.component: LogComponents.cache,
          LogFields.cacheKey: key,
          LogFields.error: error.toString(),
        },
      );
    }
  }

  static const String _fieldVersion = 'v';
  static const String _fieldWrittenAt = 'at';
  static const String _fieldTtlMs = 'ttlMs';
  static const String _fieldPayload = 'payload';

  static const String _eventCorrupt = 'cache_entry_corrupt';
  static const String _eventVersionMismatch = 'cache_schema_mismatch';
  static const String _eventDecodeFailed = 'cache_decode_failed';
  static const String _eventDeleteFailed = 'cache_delete_failed';
}

/// One decoded envelope. Kept private: the envelope shape is an implementation
/// detail of the tier, not part of the [CacheStore] contract.
final class _CacheEnvelope {
  const _CacheEnvelope({
    required this.schemaVersion,
    required this.writtenAt,
    required this.ttl,
    required this.payload,
  });

  final int schemaVersion;
  final DateTime writtenAt;
  final Duration ttl;
  final Map<String, Object?> payload;
}

/// `jsonDecode` throws on malformed text; the read contract is a silent miss,
/// so the conversion is confined to this one helper.
Object? _tryDecodeJson(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

/// Validates every field before it is trusted, so a truncated or hand-edited
/// value becomes a miss rather than a type error deeper in the app.
_CacheEnvelope? _decodeEnvelope(Object? decoded) {
  if (decoded is! Map<String, Object?>) return null;

  final Object? version = decoded[PrefsCacheStore._fieldVersion];
  final Object? writtenAt = decoded[PrefsCacheStore._fieldWrittenAt];
  final Object? ttlMs = decoded[PrefsCacheStore._fieldTtlMs];
  final Object? payload = decoded[PrefsCacheStore._fieldPayload];
  if (version is! int ||
      writtenAt is! String ||
      ttlMs is! int ||
      payload is! Map<String, Object?>) {
    return null;
  }

  final DateTime? parsedAt = DateTime.tryParse(writtenAt);
  if (parsedAt == null) return null;

  return _CacheEnvelope(
    schemaVersion: version,
    writtenAt: parsedAt.toUtc(),
    ttl: Duration(milliseconds: ttlMs),
    payload: payload,
  );
}
