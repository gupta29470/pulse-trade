import 'dart:math';

/// The reconnect backoff schedule, jittered so simultaneous clients cannot
/// retry in lockstep.
///
/// **The sequence.** [defaultSchedule] is `1s, 2s, 4s, 8s, 16s, 30s`, and every
/// attempt after the sixth reuses the last value, so the schedule is bounded,
/// a long outage costs one attempt every 30 s rather than one per doubling.
///
/// **The jitter.** Each delay is multiplied by a factor drawn uniformly from
/// `[0.8, 1.2]`, i.e. the returned value is the base delay ±20 %, with a floor of
/// one millisecond so a tiny custom schedule cannot produce a zero or negative
/// duration. Jitter exists so a fleet of clients that lost the same server does
/// not come back in lockstep; the bound is what makes the schedule still
/// recognisable in a log (`1s, 2s, 4s…` plus-or-minus a fifth).
///
/// **Determinism.** Injecting a seeded `Random` makes the whole jitter sequence
/// reproducible, which is what the reconnect test asserts: the same seed must
/// produce the same delays on every run, so a failing reconnect test is
/// debuggable.
///
/// **Reset.** `delayFor` is a pure function of the attempt index, so there is no
/// schedule cursor to clear. [reset] exists to return the *jitter* generator to
/// its initial state after a connection has proven stable, and is a documented
/// no-op when the caller injected its own generator — that generator belongs to
/// the caller, and silently replacing a seeded instance would break the very
/// determinism this class promises.
final class ReconnectPolicy {
  /// Creates a policy.
  ///
  /// When [random] is null the policy creates and owns a generator seeded from
  /// the platform's entropy source, and remembers that seed so [reset] can
  /// replay the same sequence. [schedule] defaults to [defaultSchedule]; it must
  /// not be empty, because an empty schedule would make [delayFor] undefined.
  factory ReconnectPolicy({Random? random, List<Duration>? schedule}) {
    final List<Duration> normalized = _normalize(schedule);
    final Random? injected = random;
    if (injected != null) {
      return ReconnectPolicy._(
        random: injected,
        seed: null,
        schedule: normalized,
      );
    }
    final int seed = Random().nextInt(_seedBound);
    return ReconnectPolicy._(
      random: Random(seed),
      seed: seed,
      schedule: normalized,
    );
  }

  ReconnectPolicy._({
    required this._random,
    required this._seed,
    required this._schedule,
  });

  /// `1s, 2s, 4s, 8s, 16s, 30s`; the last entry repeats for every later attempt.
  static const List<Duration> defaultSchedule = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// How long a connection must survive before the next outage starts at the
  /// first entry of the schedule again ("reset after 30 s stable").
  static const Duration stableAfter = Duration(seconds: 30);

  /// The jitter bound, as a fraction of the base delay: ±20 %.
  static const double jitterFraction = 0.2;

  /// Upper bound (exclusive) for the self-managed seed. Small enough for a
  /// 32-bit-safe `Random`, large enough that two policies do not collide.
  static const int _seedBound = 1 << 31;

  final List<Duration> _schedule;
  final int? _seed;
  Random _random;

  /// The jittered delay for 1-based [attempt].
  ///
  /// An attempt below one is treated as the first attempt rather than throwing:
  /// a caller that has not yet counted an attempt is asking for the first delay,
  /// and turning that into an exception would push a programming mistake into a
  /// reconnect path that must never throw.
  Duration delayFor(int attempt) {
    final List<Duration> schedule = _schedule;
    final int index = attempt < 1 ? 0 : attempt - 1;
    final Duration base =
        schedule[index < schedule.length ? index : schedule.length - 1];

    // `nextDouble()` is in [0, 1), so the factor lands in [0.8, 1.2).
    final double factor = 1 + (_random.nextDouble() * 2 - 1) * jitterFraction;
    final int jitteredMs = (base.inMilliseconds * factor).round();
    return Duration(milliseconds: jitteredMs < 1 ? 1 : jitteredMs);
  }

  /// Whether a connection that lasted [connectedFor] was stable enough that the
  /// next outage should start from the base delay.
  bool isStableEnoughToReset(Duration connectedFor) =>
      connectedFor >= stableAfter;

  /// Returns the owned jitter generator to its initial seed.
  ///
  /// A no-op when the caller injected the generator (see the class comment).
  void reset() {
    final int? seed = _seed;
    if (seed != null) {
      _random = Random(seed);
    }
  }

  /// Validates and freezes the schedule.
  static List<Duration> _normalize(List<Duration>? schedule) {
    if (schedule == null) return defaultSchedule;
    if (schedule.isEmpty) {
      throw ArgumentError.value(schedule, 'schedule', 'must not be empty');
    }
    return List<Duration>.unmodifiable(schedule);
  }
}
