import 'dart:collection';

import 'package:equatable/equatable.dart';
import 'package:pulse_trade_frontend/core/clock/clock.dart';
import 'package:pulse_trade_frontend/core/networking/client_message.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/messages/server_message.dart'
    hide PingMessage;

/// One completed round-trip measurement.
final class RttSample extends Equatable {
  /// Creates a sample.
  const RttSample({
    required this.pulseId,
    required this.rttMs,
    required this.sentAtMonoMs,
    required this.receivedAtMonoMs,
    required this.serverTimeMs,
  });

  /// The pulse id that was echoed back.
  final int pulseId;

  /// `receivedAtMonoMs - sentAtMonoMs`, on the monotonic clock.
  final double rttMs;

  /// Monotonic send time.
  final int sentAtMonoMs;

  /// Monotonic receive time.
  final int receivedAtMonoMs;

  /// The server's own clock at the moment it replied. Recorded for the skew
  /// readout; never used to compute [rttMs].
  final int serverTimeMs;

  @override
  List<Object?> get props => <Object?>[
    pulseId,
    rttMs,
    sentAtMonoMs,
    receivedAtMonoMs,
    serverTimeMs,
  ];

  @override
  String toString() => 'RttSample(#$pulseId, ${rttMs.toStringAsFixed(1)}ms)';
}

/// Turns `ping`/`pong` exchanges into RTT samples using only the **monotonic**
/// clock.
///
/// A wall-clock jump — NTP correction, timezone change, the emulator's measured
/// ~2 s skew against external time sources — must never be able to corrupt a
/// latency sample, and the backend's `serverTimeMs` is never subtracted for the
/// same reason.
///
/// A pulse that is not answered inside [timeout] (4 s) is a missed sample: it is
/// counted, excluded from the jitter window, and treated as a health-report gap.
final class RttCalculator {
  /// Creates a calculator.
  RttCalculator({
    required this._clock,
    this.timeout = const Duration(seconds: 4),
    this.historyLimit = 100,
    OnDeviceMetrics? metrics,
  }) : _metrics = metrics ?? OnDeviceMetrics();

  /// How long a pulse may stay unanswered before it counts as missed.
  final Duration timeout;

  /// How many completed samples are retained for the diagnostics readout.
  final int historyLimit;

  final Clock _clock;
  final OnDeviceMetrics _metrics;

  final Map<int, int> _pending = <int, int>{};
  final ListQueue<RttSample> _samples = ListQueue<RttSample>();

  int _nextPulseId = 0;
  int _missedPongs = 0;

  /// Builds the next `ping` frame and records its send time.
  PingMessage nextPing() {
    _nextPulseId++;
    final int sentAt = _clock.monotonicMs();
    _pending[_nextPulseId] = sentAt;
    return PingMessage(id: _nextPulseId, clientTimeMs: sentAt);
  }

  /// Completes the pulse [pong] answers.
  ///
  /// Returns the sample, or `null` when the pong is unknown, duplicated,
  /// arrived after [timeout] — in which case it is counted as missed instead.
  RttSample? onPong(PongMessage pong) {
    final int? sentAt = _pending.remove(pong.id);
    if (sentAt == null) return null;

    final int receivedAt = _clock.monotonicMs();
    final int elapsed = receivedAt - sentAt;
    if (elapsed < 0 || elapsed > timeout.inMilliseconds) {
      _recordMissed();
      return null;
    }

    final RttSample sample = RttSample(
      pulseId: pong.id,
      rttMs: elapsed.toDouble(),
      sentAtMonoMs: sentAt,
      receivedAtMonoMs: receivedAt,
      serverTimeMs: pong.serverTimeMs,
    );
    _samples.addLast(sample);
    while (_samples.length > historyLimit) {
      _samples.removeFirst();
    }
    return sample;
  }

  /// Removes pulses older than [timeout] and returns how many expired.
  ///
  /// A timer calls this; deriving the count from the clock rather than from a
  /// per-pulse timer keeps the timer count constant.
  int expirePending() {
    final int now = _clock.monotonicMs();
    final List<int> expired = <int>[];
    for (final MapEntry<int, int> entry in _pending.entries) {
      if (now - entry.value > timeout.inMilliseconds) expired.add(entry.key);
    }
    for (final int id in expired) {
      _pending.remove(id);
      _recordMissed();
    }
    return expired.length;
  }

  /// How many pulses are still awaiting a pong.
  int get pendingCount => _pending.length;

  /// Completed samples, oldest first.
  List<RttSample> get samples => List<RttSample>.unmodifiable(_samples);

  /// Pulses that were never answered inside [timeout].
  int get missedPongs => _missedPongs;

  /// The most recent RTT, or zero before the first sample.
  double get latestRttMs => _samples.isEmpty ? 0 : _samples.last.rttMs;

  /// Mean RTT over the retained history.
  double get averageRttMs {
    if (_samples.isEmpty) return 0;
    var total = 0.0;
    for (final RttSample sample in _samples) {
      total += sample.rttMs;
    }
    return total / _samples.length;
  }

  /// Minimum RTT over the retained history.
  double get minRttMs {
    if (_samples.isEmpty) return 0;
    var best = double.maxFinite;
    for (final RttSample sample in _samples) {
      if (sample.rttMs < best) best = sample.rttMs;
    }
    return best;
  }

  /// Maximum RTT over the retained history.
  double get maxRttMs {
    if (_samples.isEmpty) return 0;
    var worst = 0.0;
    for (final RttSample sample in _samples) {
      if (sample.rttMs > worst) worst = sample.rttMs;
    }
    return worst;
  }

  /// Clears pending pulses and history.
  ///
  /// Called on every reconnect: a new network regime must not inherit stale
  /// jitter, and the reset itself is recorded as a metrics event.
  void reset() {
    _pending.clear();
    _samples.clear();
  }

  void _recordMissed() {
    _missedPongs++;
    _metrics.increment(MetricNames.missedPongsTotal);
  }
}
