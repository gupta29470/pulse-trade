/// Wall-clock and monotonic time, behind one interface.
///
/// Everything that measures a duration (RTT, reconnect backoff, cache TTL,
/// debounce) takes a [Clock] so tests can advance time explicitly and so no
/// production code path needs `DateTime.now`.
abstract interface class Clock {
  /// Current wall-clock instant, always in UTC.
  DateTime now();

  /// Milliseconds from an arbitrary but strictly monotonic origin.
  ///
  /// RTT must use this: a wall-clock jump (NTP, timezone change, the emulator's
  /// ~2 s skew) must never be able to corrupt a latency sample.
  int monotonicMs();
}

/// The production [Clock]: wall time from the system, monotonic time from a
/// [Stopwatch] that is started once and never reset.
final class SystemClock implements Clock {
  /// Starts the monotonic stopwatch immediately.
  SystemClock() {
    _stopwatch.start();
  }

  final Stopwatch _stopwatch = Stopwatch();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  int monotonicMs() => _stopwatch.elapsedMilliseconds;
}

/// A [Clock] whose time only moves when a test moves it.
///
/// Kept in `lib/` rather than `test/` because widget and integration harnesses
/// also need it, and because a shared implementation keeps test setup small.
final class FakeClock implements Clock {
  /// Creates a clock at [start] with a monotonic origin of zero.
  FakeClock({DateTime? start, int monotonicStartMs = 0})
    : _now = start ?? DateTime.utc(2026, 9, 17, 12, 41, 3),
      _monotonicMs = monotonicStartMs;

  DateTime _now;
  int _monotonicMs;

  @override
  DateTime now() => _now;

  @override
  int monotonicMs() => _monotonicMs;

  /// Advances both the wall clock and the monotonic clock.
  void advance(Duration duration) {
    _now = _now.add(duration);
    _monotonicMs += duration.inMilliseconds;
  }
}
