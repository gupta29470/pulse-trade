import 'dart:convert';
import 'dart:io';

import 'package:pulse_trade_frontend/core/cache/cache_directory.dart';
import 'package:pulse_trade_frontend/core/cache/cache_store.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/logging/app_logger.dart';
import 'package:pulse_trade_frontend/core/logging/log_fields.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';

/// The file cache tier.
///
/// Holds what is too large for a preferences file: candle series per interval,
/// the order-book snapshot, recent trades, the market summary and the watchlist
/// roster. One JSON envelope per key, `{"v","at","ttlMs","payload"}`, at
/// `<cacheDirectory>/pulsetrade/<sanitised key>.json`.
///
/// Capped at `maxBytes` (8 MB) and `maxEntries` (20 files) with LRU eviction, so
/// a long-lived install cannot fill the cache directory. "Least recently used"
/// is tracked in memory and seeded from each file's modification time at
/// [open], the best available proxy for an access this process did not observe.
///
/// Every filesystem call is wrapped in `try`/`catch (Object)`: a missing
/// directory, an unreadable file or a failed write degrades to a miss or a
/// no-op with one WARN. This tier is never a correctness dependency.
final class FileCacheStore implements CacheStore {
  FileCacheStore._({
    required this._directory,
    required this._metrics,
    required this._clock,
    required this._schemaVersion,
    required this._maxBytes,
    required this._maxEntries,
  });

  /// Subdirectory of the platform cache directory that this app owns.
  static const String subdirectory = 'pulsetrade';

  /// Extension of every envelope file.
  static const String extension = '.json';

  /// Resolves the cache directory and returns a ready store.
  ///
  /// Falls back from the application cache directory to the temporary
  /// directory; if neither resolves, the returned store is a
  /// deliberate no-op, so a platform without a usable cache directory still
  /// runs instead of crashing at startup.
  static Future<FileCacheStore> open({
    OnDeviceMetrics? metrics,
    Clock? clock,
    int schemaVersion = kCacheSchemaVersion,
    int maxBytes = 8 * 1024 * 1024,
    int maxEntries = 20,
  }) async {
    final Clock resolvedClock = clock ?? SystemClock();
    // A store that cannot touch the filesystem: reads miss, writes do nothing.
    FileCacheStore noop() => FileCacheStore._(
      directory: null,
      metrics: metrics,
      clock: resolvedClock,
      schemaVersion: schemaVersion,
      maxBytes: maxBytes,
      maxEntries: maxEntries,
    );

    final Directory? base = await _resolveBaseDirectory();
    if (base == null) {
      AppLogger.warn(_eventDirectoryUnavailable, fields: _fields(null));
      return noop();
    }

    final Directory directory = Directory(_join(base.path, subdirectory));
    try {
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
    } on Object catch (error) {
      AppLogger.warn(_eventDirectoryUnavailable, fields: _errorFields(error));
      return noop();
    }

    final FileCacheStore store = FileCacheStore._(
      directory: directory,
      metrics: metrics,
      clock: resolvedClock,
      schemaVersion: schemaVersion,
      maxBytes: maxBytes,
      maxEntries: maxEntries,
    );
    store._seedLastAccess();
    return store;
  }

  static const String _eventReadFailed = 'cache_file_read_failed';
  static const String _eventCorrupt = 'cache_entry_corrupt';
  static const String _eventVersionMismatch = 'cache_schema_mismatch';
  static const String _eventDecodeFailed = 'cache_decode_failed';
  static const String _eventDeleteFailed = 'cache_file_delete_failed';
  static const String _eventDirectoryFallback = 'cache_directory_fallback';
  static const String _eventDirectoryUnavailable =
      'cache_directory_unavailable';

  static const String _fieldVersion = 'v';
  static const String _fieldWrittenAt = 'at';
  static const String _fieldTtlMs = 'ttlMs';
  static const String _fieldPayload = 'payload';

  /// Characters a key may keep in a file name; everything else becomes `_`, so
  /// `candles:BTCUSDT:1m` becomes `candles_BTCUSDT_1m`. The key builders in
  /// `MarketCacheRepository` never produce two keys that collide here.
  static final RegExp _illegal = RegExp(r'[^A-Za-z0-9._-]');

  final Directory? _directory;
  final OnDeviceMetrics? _metrics;
  final Clock _clock;
  final int _schemaVersion;
  final int _maxBytes;
  final int _maxEntries;

  /// Sanitised file stem -> last read or write instant, in UTC.
  final Map<String, DateTime> _lastAccess = <String, DateTime>{};

  /// Sanitised file stem -> logical key, for keys touched this process. Files
  /// seeded from disk are only known by their stem, so eviction falls back to
  /// the stem in the log record.
  final Map<String, String> _logicalKeys = <String, String>{};

  int _evictions = 0;
  int _hits = 0;
  int _misses = 0;
  int _writes = 0;
  int _writeFailures = 0;

  static Map<String, Object?> _errorFields(Object error) => <String, Object?>{
    LogFields.component: LogComponents.cache,
    LogFields.error: error.toString(),
  };

  static Map<String, Object?> _fields(String? key) => <String, Object?>{
    LogFields.component: LogComponents.cache,
    LogFields.cacheKey: ?key,
  };

  static Map<String, Object?> _keyedErrorFields(String key, Object error) =>
      <String, Object?>{
        LogFields.component: LogComponents.cache,
        LogFields.cacheKey: key,
        LogFields.error: error.toString(),
      };

  @override
  Future<CacheEntry<T>?> read<T>(
    String key,
    T Function(Map<String, dynamic>) decode,
  ) async {
    final Directory? directory = _directory;
    if (directory == null) {
      _countMiss();
      return null;
    }

    final File file = _fileFor(directory, key);
    final String raw;
    try {
      if (!await file.exists()) {
        _countMiss();
        return null;
      }
      raw = await file.readAsString();
    } on Object catch (error) {
      AppLogger.warn(_eventReadFailed, fields: _keyedErrorFields(key, error));
      _countMiss();
      return null;
    }

    _touch(key);

    final _CacheEnvelope? envelope = _decodeEnvelope(_tryDecodeJson(raw));
    if (envelope == null) {
      AppLogger.debug(_eventCorrupt, fields: _fields(key));
      await _deleteFile(file);
      _countMiss();
      return null;
    }

    if (envelope.schemaVersion != _schemaVersion) {
      AppLogger.debug(
        _eventVersionMismatch,
        fields: <String, Object?>{
          ..._fields(key),
          LogFields.count: envelope.schemaVersion,
        },
      );
      await _deleteFile(file);
      _countMiss();
      return null;
    }

    final T payload;
    try {
      payload = decode(envelope.payload);
    } on Object catch (error) {
      AppLogger.debug(
        _eventDecodeFailed,
        fields: _keyedErrorFields(key, error),
      );
      await _deleteFile(file);
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
    final Directory? directory = _directory;
    if (directory == null) return;

    try {
      final Map<String, dynamic> payload = encode(value);
      final String raw = jsonEncode(<String, Object?>{
        _fieldVersion: _schemaVersion,
        _fieldWrittenAt: _clock.now().toUtc().toIso8601String(),
        _fieldTtlMs: ttl.inMilliseconds,
        _fieldPayload: payload,
      });
      await _fileFor(directory, key).writeAsString(raw, flush: false);
      _touch(key);
      _writes++;
      _metrics?.increment(MetricNames.cacheWritesTotal);
      await _evictIfNeeded(directory);
    } on Object catch (error) {
      _writeFailures++;
      _metrics?.increment(MetricNames.cacheWriteFailuresTotal);
      AppLogger.warn(
        LogEvents.cacheWriteFailed,
        fields: _keyedErrorFields(key, error),
      );
    }
  }

  @override
  Future<void> invalidate(String key) async {
    final Directory? directory = _directory;
    if (directory == null) return;
    _lastAccess.remove(_sanitise(key));
    _logicalKeys.remove(_sanitise(key));
    await _deleteFile(_fileFor(directory, key));
  }

  @override
  Future<void> clear() async {
    final Directory? directory = _directory;
    if (directory == null) return;
    for (final _CacheFile file in await _scan(directory)) {
      await _deleteFile(file.file);
    }
    _lastAccess.clear();
    _logicalKeys.clear();
  }

  @override
  Future<CacheStats> stats() async {
    final Directory? directory = _directory;
    final List<_CacheFile> files = directory == null
        ? const <_CacheFile>[]
        : await _scan(directory);
    var bytes = 0;
    for (final _CacheFile file in files) {
      bytes += file.bytes;
    }
    return CacheStats(
      entries: files.length,
      bytes: bytes,
      hits: _metrics?.value(MetricNames.cacheHitsTotal) ?? _hits,
      misses: _metrics?.value(MetricNames.cacheMissesTotal) ?? _misses,
      writes: _metrics?.value(MetricNames.cacheWritesTotal) ?? _writes,
      writeFailures:
          _metrics?.value(MetricNames.cacheWriteFailuresTotal) ??
          _writeFailures,
      evictions: _evictions,
    );
  }

  /// Records that [key] was just read or written, so eviction can rank it.
  void _touch(String key) {
    final String stem = _sanitise(key);
    _lastAccess[stem] = _clock.now().toUtc();
    _logicalKeys[stem] = key;
  }

  void _countMiss() {
    _misses++;
    _metrics?.increment(MetricNames.cacheMissesTotal);
  }

  /// Resolves where the tier lives: the platform cache directory, else the
  /// temporary directory, else nowhere.
  static Future<Directory?> _resolveBaseDirectory() async {
    try {
      final String? cachePath = await CacheDirectory.applicationCache();
      if (cachePath != null) return Directory(cachePath);
    } on Object catch (error) {
      AppLogger.warn(_eventDirectoryFallback, fields: _errorFields(error));
    }
    try {
      final String? temporaryPath = await CacheDirectory.temporary();
      if (temporaryPath != null) return Directory(temporaryPath);
    } on Object catch (error) {
      AppLogger.warn(_eventDirectoryUnavailable, fields: _errorFields(error));
      return null;
    }
    return null;
  }

  /// Seeds the LRU table from files already on disk.
  ///
  /// Modification time is used rather than access time because not every
  /// platform updates `atime`.
  void _seedLastAccess() {
    final Directory? directory = _directory;
    if (directory == null) return;
    try {
      for (final FileSystemEntity entity in directory.listSync()) {
        if (entity is! File) continue;
        final String? stem = _stemOf(entity.path);
        if (stem == null) continue;
        _lastAccess[stem] = entity.statSync().modified.toUtc();
      }
    } on Object catch (error) {
      AppLogger.debug(_eventReadFailed, fields: _errorFields(error));
    }
  }

  /// Deletes entries until both the byte cap and the entry cap are satisfied,
  /// oldest access first. `index` always advances, so a file that refuses to
  /// delete cannot spin the loop.
  Future<void> _evictIfNeeded(Directory directory) async {
    final List<_CacheFile> files = await _scan(directory);
    var remainingBytes = 0;
    for (final _CacheFile file in files) {
      remainingBytes += file.bytes;
    }
    if (remainingBytes <= _maxBytes && files.length <= _maxEntries) return;

    files.sort(
      (_CacheFile a, _CacheFile b) => a.lastAccess.compareTo(b.lastAccess),
    );
    var remainingEntries = files.length;
    var index = 0;
    while ((remainingBytes > _maxBytes || remainingEntries > _maxEntries) &&
        index < files.length) {
      final _CacheFile victim = files[index];
      index++;
      try {
        await victim.file.delete();
        _evictions++;
        remainingBytes -= victim.bytes;
        remainingEntries--;
        _lastAccess.remove(victim.stem);
        final String? logical = _logicalKeys.remove(victim.stem);
        AppLogger.warn(
          LogEvents.cacheEvicted,
          fields: <String, Object?>{
            LogFields.component: LogComponents.cache,
            LogFields.cacheKey: logical ?? victim.stem,
            LogFields.count: _evictions,
          },
        );
      } on Object catch (error) {
        AppLogger.warn(
          _eventDeleteFailed,
          fields: _keyedErrorFields(victim.stem, error),
        );
      }
    }
  }

  /// Lists the envelope files with their size and last-known access instant.
  Future<List<_CacheFile>> _scan(Directory directory) async {
    final List<_CacheFile> out = <_CacheFile>[];
    try {
      final List<FileSystemEntity> entities = await directory.list().toList();
      for (final FileSystemEntity entity in entities) {
        if (entity is! File) continue;
        final String? stem = _stemOf(entity.path);
        if (stem == null) continue;
        final FileStat stat = await entity.stat();
        out.add(
          _CacheFile(
            file: entity,
            stem: stem,
            bytes: stat.size,
            lastAccess: _lastAccess[stem] ?? stat.modified.toUtc(),
          ),
        );
      }
    } on Object catch (error) {
      AppLogger.debug(_eventReadFailed, fields: _errorFields(error));
    }
    return out;
  }

  /// Deletes [file]; a failure is a WARN, never an exception, because the cache
  /// owns nothing the app needs.
  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object catch (error) {
      AppLogger.warn(_eventDeleteFailed, fields: _errorFields(error));
    }
  }

  /// The file that backs [key].
  File _fileFor(Directory directory, String key) =>
      File(_join(directory.path, '${_sanitise(key)}$extension'));

  /// Strips directory and [extension] from [path], returning `null` for a file
  /// this store does not own.
  String? _stemOf(String path) {
    final String name = path.split(Platform.pathSeparator).last;
    if (!name.endsWith(extension)) return null;
    return name.substring(0, name.length - extension.length);
  }
}

/// Maps a logical cache key onto a legal file name.
String _sanitise(String key) => key.replaceAll(FileCacheStore._illegal, '_');

/// Joins with the platform separator so the same code works on Windows.
String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

/// `jsonDecode` throws on malformed text; a corrupt envelope must become a
/// miss, so the conversion is confined to this helper.
Object? _tryDecodeJson(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

/// Validates every envelope field before it is trusted.
_CacheEnvelope? _decodeEnvelope(Object? decoded) {
  if (decoded is! Map<String, Object?>) return null;

  final Object? version = decoded[FileCacheStore._fieldVersion];
  final Object? writtenAt = decoded[FileCacheStore._fieldWrittenAt];
  final Object? ttlMs = decoded[FileCacheStore._fieldTtlMs];
  final Object? payload = decoded[FileCacheStore._fieldPayload];
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

/// One decoded envelope; private because the shape is a tier detail.
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

/// One envelope file on disk, as eviction ranks it.
final class _CacheFile {
  const _CacheFile({
    required this.file,
    required this.stem,
    required this.bytes,
    required this.lastAccess,
  });

  final File file;
  final String stem;
  final int bytes;
  final DateTime lastAccess;
}
