/// Where a piece of data came from, so the UI can label it honestly.
enum DataProvenance {
  /// Fresh from the backend in this session.
  live,

  /// Read from disk and still inside its TTL.
  cached,

  /// Read from disk but past its TTL. Still rendered, never presented as live.
  stale,
}

/// A value together with its provenance and the time it was written.
///
/// Cache is never promoted to live: the transition out of [DataProvenance.cached]
/// or [DataProvenance.stale] requires fresh data from the backend.
/// Carrying the provenance on the value is what lets the market screen attach a
/// `CACHED · as of HH:MM:SS` tag without guessing from the state machine.
final class Sourced<T> {
  /// Creates a sourced value.
  const Sourced({required this.value, required this.provenance, this.asOf});

  /// A fresh value straight from the backend.
  factory Sourced.live(T value, {DateTime? asOf}) =>
      Sourced<T>(value: value, provenance: DataProvenance.live, asOf: asOf);

  /// A value read from disk. [writtenAt] is the cache entry's write time.
  factory Sourced.fromCache(
    T value, {
    required DateTime writtenAt,
    required bool stale,
  }) => Sourced<T>(
    value: value,
    provenance: stale ? DataProvenance.stale : DataProvenance.cached,
    asOf: writtenAt,
  );

  /// The payload.
  final T value;

  /// Where the payload came from.
  final DataProvenance provenance;

  /// When the payload was produced. `null` only for a [DataProvenance.live]
  /// value that arrived without a server timestamp.
  final DateTime? asOf;

  /// True when the payload came from the backend in this session.
  bool get isLive => provenance == DataProvenance.live;

  /// True when the payload came from disk, fresh or stale.
  bool get isFromCache => provenance != DataProvenance.live;

  /// True when the payload came from disk and is past its TTL.
  bool get isStale => provenance == DataProvenance.stale;

  /// The same provenance applied to a transformed payload.
  Sourced<R> map<R>(R Function(T value) transform) =>
      Sourced<R>(value: transform(value), provenance: provenance, asOf: asOf);

  @override
  bool operator ==(Object other) =>
      other is Sourced<T> &&
      other.value == value &&
      other.provenance == provenance &&
      other.asOf == asOf;

  @override
  int get hashCode => Object.hash(value, provenance, asOf);

  @override
  String toString() => 'Sourced(${provenance.name}, $value, asOf: $asOf)';
}
