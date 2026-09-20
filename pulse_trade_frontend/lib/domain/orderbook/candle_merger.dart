import 'package:pulse_trade_frontend/domain/entities/candle.dart';

/// The candle merge table, implemented as a pure function.
///
/// Identity is `(interval, startTime)`. Nothing here is ever appended blindly:
/// every case either replaces, ignores with a counter, or inserts at the correct
/// sorted position, because a duplicated bucket would silently corrupt the chart
/// and the OHLCV it derives.
final class CandleMerger {
  /// Creates a merger that keeps at most [retention] candles per series.
  CandleMerger({this.retention = 500});

  /// Maximum candles retained; the oldest are dropped once the series grows.
  final int retention;

  int _ignoredCount = 0;
  int _replacedCount = 0;
  int _appendedCount = 0;

  /// Candles ignored because they were duplicates, stale, or immutable.
  int get ignoredCount => _ignoredCount;

  /// Candles that replaced an existing bucket.
  int get replacedCount => _replacedCount;

  /// Candles that extended the series.
  int get appendedCount => _appendedCount;

  /// Merges [incoming] into [existing] and returns the new series.
  ///
  /// [existing] must be ascending by `startTime`; the returned list is too. The
  /// input list is never mutated, so a bloc can hold an immutable state and
  /// publish a new one.
  List<Candle> merge(List<Candle> existing, Candle incoming) {
    if (existing.isEmpty) {
      _appendedCount++;
      return _trimmed(<Candle>[incoming]);
    }

    final Candle last = existing.last;
    if (incoming.interval == last.interval &&
        incoming.startTime.isAfter(last.startTime)) {
      final List<Candle> next = List<Candle>.of(existing);
      // A newer bucket finalises the previous one: a client that missed the
      // `candle_closed` frame still ends up with an immutable previous bucket.
      if (!last.closed) {
        next[next.length - 1] = last.copyWith(closed: true);
      }
      next.add(incoming);
      _appendedCount++;
      return _trimmed(next);
    }

    final int index = _indexOfIdentity(existing, incoming);
    if (index < 0) {
      // Not present. An older bucket than everything we hold is outside the
      // retained window (or arrives out of order) and is ignored rather than
      // inserted in the middle of a series the chart has already drawn.
      if (incoming.startTime.isBefore(existing.first.startTime)) {
        _ignoredCount++;
        return existing;
      }
      return _trimmed(_insertSorted(existing, incoming));
    }

    final Candle current = existing[index];
    if (current.closed) {
      // Canonical closed candles are immutable: neither another
      // close nor a late active update may rewrite them.
      _ignoredCount++;
      return existing;
    }
    if (!incoming.closed && incoming.sourceSequence <= current.sourceSequence) {
      // Lower or equal sequence: nothing new to say about this bucket.
      _ignoredCount++;
      return existing;
    }

    final List<Candle> next = List<Candle>.of(existing);
    next[index] = incoming;
    _replacedCount++;
    return next;
  }

  /// Merges a whole history response into [existing].
  ///
  /// History is the one case where an **older** bucket is legitimate: a page of
  /// 500 candles legitimately reaches back before the live series. Overlapping
  /// buckets are deduplicated by identity, preferring the higher
  /// `sourceSequence`, which is the last row of the table. Live candles win
  /// over an equally-sequenced history row because they carry the same value.
  List<Candle> mergeHistory(List<Candle> existing, Iterable<Candle> history) {
    final Map<String, Candle> byIdentity = <String, Candle>{};
    for (final Candle candle in existing) {
      byIdentity[_identityKey(candle)] = candle;
    }
    for (final Candle candle in history) {
      final String key = _identityKey(candle);
      final Candle? current = byIdentity[key];
      if (current == null) {
        byIdentity[key] = candle;
        _appendedCount++;
        continue;
      }
      if (current.closed ||
          (!candle.closed && candle.sourceSequence <= current.sourceSequence)) {
        _ignoredCount++;
        continue;
      }
      byIdentity[key] = candle;
      _replacedCount++;
    }

    final List<Candle> merged = byIdentity.values.toList()
      ..sort((Candle a, Candle b) => a.startTime.compareTo(b.startTime));
    return _trimmed(merged);
  }

  /// True when [candle] belongs to the same bucket as [other].
  static bool sameIdentity(Candle candle, Candle other) =>
      candle.interval == other.interval && candle.startTime == other.startTime;

  static String _identityKey(Candle candle) =>
      '${candle.interval.wire}@${candle.startTime.toUtc().toIso8601String()}';

  int _indexOfIdentity(List<Candle> list, Candle incoming) {
    var low = 0;
    var high = list.length - 1;
    while (low <= high) {
      final int mid = low + ((high - low) >> 1);
      final Candle candidate = list[mid];
      final int byTime = candidate.startTime.compareTo(incoming.startTime);
      if (byTime == 0) {
        return candidate.interval == incoming.interval ? mid : -1;
      }
      if (byTime < 0) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  List<Candle> _insertSorted(List<Candle> list, Candle incoming) {
    var index = list.length;
    for (var i = 0; i < list.length; i++) {
      if (list[i].startTime.isAfter(incoming.startTime)) {
        index = i;
        break;
      }
    }
    final List<Candle> next = List<Candle>.of(list);
    next.insert(index, incoming);
    _appendedCount++;
    return next;
  }

  List<Candle> _trimmed(List<Candle> list) {
    if (list.length <= retention) return list;
    return list.sublist(list.length - retention);
  }
}
