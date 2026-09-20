/// The payload-shape generation of every cache entry.
///
/// Bumped when a payload shape changes; a mismatch deletes the entry and
/// reports a miss, so an old build can never feed a new decoder something it
/// was not written for. It lives outside the store classes because both tiers
/// must agree on it.
///
/// `2`: candles carry `closed`, the flag that marks a finished bucket. A
/// version `1` entry has no such flag, and supplying a default would report a
/// bucket state the writer never observed, so those entries are discarded.
const int kCacheSchemaVersion = 2;

/// One immutable cache entry: the value plus the metadata that decides whether
/// it may still be shown as fresh.
///
/// TTL is data, not a filter: [isStaleAt] answers the
/// question, and the caller decides to keep rendering the value with a `STALE`
/// tag rather than hide it.
final class CacheEntry<T> {
  /// Creates an entry. [writtenAt] is the instant the payload was produced in
  /// UTC, so age arithmetic never crosses a timezone.
  const CacheEntry({
    required this.key,
    required this.schemaVersion,
    required this.writtenAt,
    required this.ttl,
    required this.payload,
  });

  /// The logical key the entry was stored under, e.g. `candles:BTCUSDT:1m`.
  final String key;

  /// The payload generation the entry was written with.
  final int schemaVersion;

  /// When the payload was produced.
  final DateTime writtenAt;

  /// How long the payload stays fresh after [writtenAt].
  final Duration ttl;

  /// The decoded value.
  final T payload;

  /// True when the entry is past its TTL at [now].
  ///
  /// Strictly greater: an entry written exactly [ttl] ago is still fresh, so a
  /// 5-minute candle cache is not marked stale one tick early.
  bool isStaleAt(DateTime now) => now.difference(writtenAt) > ttl;

  /// How long ago the entry was written, relative to [now].
  ///
  /// Negative when [now] precedes [writtenAt], which happens if the device
  /// clock moved backwards; the caller renders that as "as of" now rather than
  /// inventing a negative age.
  Duration ageAt(DateTime now) => now.difference(writtenAt);

  /// Copy with a different [payload], keeping the metadata.
  ///
  /// Used when a payload is re-encoded without being refetched; a rewritten
  /// payload keeps its original [writtenAt] so it does not fake freshness.
  CacheEntry<T> copyWith({
    String? key,
    int? schemaVersion,
    DateTime? writtenAt,
    Duration? ttl,
    T? payload,
  }) {
    return CacheEntry<T>(
      key: key ?? this.key,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      writtenAt: writtenAt ?? this.writtenAt,
      ttl: ttl ?? this.ttl,
      payload: payload ?? this.payload,
    );
  }
}

/// A point-in-time measurement of a cache tier, for the Diagnostics screen and
/// its `Copy diagnostics JSON` document.
///
/// Counters are cumulative for the process; [entries] and [bytes] are gauges
/// read at the moment [CacheStore.stats] was called.
final class CacheStats {
  /// Creates a measurement. Every field is required so a new counter cannot be
  /// forgotten at a construction site.
  const CacheStats({
    required this.entries,
    required this.bytes,
    required this.hits,
    required this.misses,
    required this.writes,
    required this.writeFailures,
    required this.evictions,
  });

  /// The all-zero measurement, used when a store cannot be opened at all.
  static const CacheStats empty = CacheStats._empty();

  const CacheStats._empty()
    : entries = 0,
      bytes = 0,
      hits = 0,
      misses = 0,
      writes = 0,
      writeFailures = 0,
      evictions = 0;

  /// Number of entries currently stored.
  final int entries;

  /// Total payload bytes currently stored.
  final int bytes;

  /// Reads that produced a usable entry.
  final int hits;

  /// Reads that produced nothing (absent, corrupt or superseded version).
  final int misses;

  /// Writes that completed.
  final int writes;

  /// Writes that failed and were swallowed with one WARN.
  final int writeFailures;

  /// Entries removed to stay inside a size or count limit.
  final int evictions;

  /// A JSON-safe view. Counters are numbers, never pre-formatted strings, so
  /// `jq` can aggregate them.
  Map<String, Object?> toJson() => <String, Object?>{
    'entries': entries,
    'bytes': bytes,
    'hits': hits,
    'misses': misses,
    'writes': writes,
    'writeFailures': writeFailures,
    'evictions': evictions,
  };
}

/// The storage contract shared by the two cache tiers.
///
/// Implementations differ only in where bytes land; the entry contract, the
/// corruption rules and the non-throwing reads are identical, which is what
/// lets `MarketCacheRepository` swap tiers without knowing which one it holds.
abstract interface class CacheStore {
  /// Reads and decodes the entry under [key].
  ///
  /// **Non-throwing**: a missing entry, a version mismatch, a corrupt envelope
  /// or a [decode] failure all degrade to `null` (a miss) and increment
  /// `cache_misses_total`. Cache is an optimisation, never
  /// a correctness dependency, so no read path may raise into the UI.
  ///
  /// The returned entry carries its [CacheEntry.writtenAt] and
  /// [CacheEntry.ttl]; a stale entry is still returned, because TTL expiry
  /// marks data `STALE` rather than dropping it.
  Future<CacheEntry<T>?> read<T>(
    String key,
    T Function(Map<String, dynamic>) decode,
  );

  /// Encodes [value] with [encode] and stores it under [key] with [ttl].
  ///
  /// **Non-throwing**: an encoding or platform failure logs one WARN,
  /// increments `cache_write_failures_total`, and live state is unaffected.
  /// Callers on the delivery path invoke this with `unawaited` so a write never
  /// sits on the critical path.
  Future<void> write<T>(
    String key,
    T value, {
    required Duration ttl,
    required Map<String, dynamic> Function(T) encode,
  });

  /// Deletes the entry under [key], if any.
  Future<void> invalidate(String key);

  /// Deletes every entry this store owns.
  Future<void> clear();

  /// Measures the store: entry count, bytes and cumulative counters.
  Future<CacheStats> stats();
}
