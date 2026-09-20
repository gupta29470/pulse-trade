import 'package:flutter/material.dart';
import 'package:pulse_trade_frontend/app/theme/app_colors.dart';
import 'package:pulse_trade_frontend/core/telemetry/on_device_metrics.dart';
import 'package:pulse_trade_frontend/domain/entities/health_snapshot.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_records.dart';
import 'package:pulse_trade_frontend/domain/entities/metrics_snapshot.dart';
import 'package:pulse_trade_frontend/features/diagnostics/diagnostics_state.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/diagnostics_section.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/diagnostics_sections.dart';
import 'package:pulse_trade_frontend/features/diagnostics/widgets/gauge_readout.dart';

/// Round trip, from the backend's aggregates plus the live series.
///
/// Aggregates come from `/metrics/summary` and the headline value from the
/// newest latency bucket. The two are deliberately shown together: a summary
/// alone hides that the *current* window is worse than the average, which is the
/// only thing a reviewer watching a degradation demo cares about.
class RoundTripSection extends StatelessWidget {
  /// Creates the section.
  const RoundTripSection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final MetricsSnapshot? metrics = state.metrics;
    final LatencyBucket? latest = state.latestBucket;
    final RttStats? rtt = metrics?.rtt;
    final bool hasSummary = rtt != null && rtt.samples > 0;
    final bool hasSeries = state.latency.isNotEmpty;

    if (!hasSummary && !hasSeries) {
      return const DiagnosticsCard(
        child: DiagnosticsSection(
          title: 'Round Trip',
          rows: <DiagnosticRow>[
            DiagnosticRow('RTT', 'waiting for the first metrics response'),
          ],
        ),
      );
    }

    // The backend computed the percentile, so its aggregate wins where the two
    // disagree; the series only supplies the current reading.
    final double value = latest?.avgMs ?? rtt?.avgMs ?? 0;
    final double min = hasSummary ? rtt.minMs : _minOf(state.latency);
    final double max = hasSummary ? rtt.maxMs : _maxOf(state.latency);
    final double average = rtt?.avgMs ?? value;

    return DiagnosticsCard(
      child: GaugeReadout(
        title: 'Round Trip',
        value: value,
        min: min,
        max: max,
        average: average,
        p95: hasSummary ? rtt.p95Ms : null,
        sampleCount: hasSummary ? rtt.samples : _sumCounts(state.latency),
      ),
    );
  }
}

/// Jitter: the current value, its spread, and the window contract.
///
/// The window size, the heartbeat cadence and the outlier cap are *documented
/// constants* of the heartbeat protocol, not measurements, so they are
/// printed as text rather than derived — a diagnostics screen that recomputed
/// the window from whatever samples happened to arrive would report a different
/// contract than the one the system implements.
class JitterSection extends StatelessWidget {
  /// Creates the section.
  const JitterSection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final List<double> series = <double>[
      for (final LatencyBucket bucket in state.latency) bucket.avgJitterMs,
    ];
    final double reported = state.delivery?.jitterMs ?? 0;
    final double value = series.isEmpty ? reported : series.last;
    final double average = state.metrics?.jitterMsMean ?? reported;

    return DiagnosticsCard(
      child: GaugeReadout(
        title: 'Jitter · window 10 · heartbeat 2 s · cap 3× median',
        value: value,
        min: series.isEmpty ? 0 : series.reduce((a, b) => a < b ? a : b),
        max: series.isEmpty ? 0 : series.reduce((a, b) => a > b ? a : b),
        average: average,
        deviation: _deviation(series, average),
        sampleCount: series.length,
      ),
    );
  }
}

/// Feed and L2 health: the local book's own synchronisation view.
class FeedHealthSection extends StatelessWidget {
  /// Creates the section.
  const FeedHealthSection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final Map<String, int> counters = state.counters;
    return DiagnosticsCard(
      child: DiagnosticsSection(
        title: 'Feed & L2 Health',
        trailing: state.bookState.name.toUpperCase(),
        rows: <DiagnosticRow>[
          DiagnosticRow(
            'Order Book State',
            state.bookState.name.toUpperCase(),
            valueColor: DiagnosticsFormat.forBookState(state.bookState),
          ),
          DiagnosticRow(
            'Epoch / Update ID',
            '${state.bookEpoch} / ${DiagnosticsFormat.thousands(state.bookAppliedUpdateId)}',
          ),
          DiagnosticRow(
            'Last Applied Range',
            // An en dash, not a hyphen: this is a range, and the compact form is
            // what makes it readable at a glance.
            state.lastAppliedLastUpdateId == 0
                ? DiagnosticsFormat.unknown
                : '${state.lastAppliedFirstUpdateId}'
                      '–${state.lastAppliedLastUpdateId}',
          ),
          DiagnosticRow(
            'Gap Detected',
            state.gapCount > 0 ? 'YES · ${state.gapCount}' : 'NO',
            valueColor: state.gapCount > 0 ? AppColors.bear : AppColors.bull,
          ),
          DiagnosticRow('Resync Recoveries', '${state.recoveryCount}'),
          DiagnosticRow('Duplicate Deltas', '${state.duplicateCount}'),
          DiagnosticRow('Stale Deltas', '${state.staleCount}'),
          DiagnosticRow(
            'Out-of-order Trades',
            '${counters[MetricNames.outOfOrderTradesTotal] ?? 0}',
          ),
          DiagnosticRow(
            'Malformed Messages',
            '${counters[MetricNames.malformedMessagesTotal] ?? 0}',
          ),
        ],
      ),
    );
  }
}

/// Candles: interval, history depth, and the pending-request flag.
class CandleSection extends StatelessWidget {
  /// Creates the section.
  const CandleSection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final Map<String, int> counters = state.counters;
    final SessionRecord? session = state.sessions.isEmpty
        ? null
        : state.sessions.first;
    final int historyRequests = counters[MetricNames.historyRequestsTotal] ?? 0;
    final int staleHistory =
        counters[MetricNames.staleHistoryResponsesTotal] ?? 0;
    final int pending = historyRequests - staleHistory;
    final LatencyBucket? latest = state.latestBucket;

    return DiagnosticsCard(
      child: DiagnosticsSection(
        title: 'Candles',
        rows: <DiagnosticRow>[
          DiagnosticRow(
            'Interval',
            session?.interval ?? DiagnosticsFormat.unknown,
          ),
          DiagnosticRow(
            'History Loaded',
            DiagnosticsFormat.cacheValue(state.cacheStats, 'candles'),
          ),
          DiagnosticRow(
            'Active Candle',
            latest == null
                ? DiagnosticsFormat.unknown
                : DiagnosticsFormat.clock(latest.end),
          ),
          DiagnosticRow(
            'Pending History Req',
            // Only claimable once the client has actually issued a history
            // request; before that the honest answer is "unknown", not "NO".
            historyRequests == 0
                ? DiagnosticsFormat.unknown
                : (pending > 0 ? 'YES · $pending' : 'NO'),
          ),
        ],
      ),
    );
  }
}

/// Recovery: reconnects and book rebuilds, the two ways the client self-heals.
class RecoverySection extends StatelessWidget {
  /// Creates the section.
  const RecoverySection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final Map<String, int> counters = state.counters;
    final int reconnects = counters[MetricNames.wsReconnectsTotal] ?? 0;
    final int? age = state.delivery?.lastReportAgeMs;
    final MetricsSnapshot? metrics = state.metrics;

    return DiagnosticsCard(
      child: DiagnosticsSection(
        title: 'Recovery',
        rows: <DiagnosticRow>[
          DiagnosticRow(
            'Reconnects',
            state.hasData ? '$reconnects' : DiagnosticsFormat.unknown,
          ),
          DiagnosticRow('Book recoveries', '${state.recoveryCount}'),
          DiagnosticRow(
            'Backend book recoveries',
            metrics == null
                ? DiagnosticsFormat.unknown
                : '${metrics.bookRecoveries}',
          ),
          DiagnosticRow(
            'Last health report age',
            age == null
                ? DiagnosticsFormat.unknown
                : DiagnosticsFormat.seconds(age),
          ),
        ],
      ),
    );
  }
}

/// Persistence: the metrics store, and the samples behind the aggregates.
class PersistenceSection extends StatelessWidget {
  /// Creates the section.
  const PersistenceSection({super.key, required this.state});

  /// The readout being rendered.
  final DiagnosticsState state;

  @override
  Widget build(BuildContext context) {
    final HealthSnapshot? health = state.health;
    final MetricsSnapshot? metrics = state.metrics;
    final int samples = metrics?.latencySamples ?? _sumCounts(state.latency);
    final int transitions = state.tierTransitions.isNotEmpty
        ? state.tierTransitions.length
        : (metrics?.tierTransitions ?? 0);

    final String store = health == null
        ? DiagnosticsFormat.unknown
        : '${health.metricsDriver ?? DiagnosticsFormat.unknown} · '
              '${health.metricsStatus ?? DiagnosticsFormat.unknown} · '
              'queue ${health.metricsQueueDepth ?? 0} · '
              'dropped ${health.metricsDroppedTotal ?? 0}';

    return DiagnosticsCard(
      child: DiagnosticsSection(
        title: 'Persistence',
        rows: <DiagnosticRow>[
          DiagnosticRow('Metrics Store', store),
          DiagnosticRow(
            'Latency Samples',
            samples == 0
                ? '0'
                : '${DiagnosticsFormat.thousands(samples)} (window 15 min)',
          ),
          DiagnosticRow('Tier Transitions', '$transitions'),
          DiagnosticRow(
            'Delivery Windows',
            '${state.deliveryWindows.length} (window 15 min)',
          ),
        ],
      ),
    );
  }
}

double _minOf(List<LatencyBucket> buckets) {
  if (buckets.isEmpty) return 0;
  double out = buckets.first.minMs;
  for (final LatencyBucket bucket in buckets) {
    if (bucket.minMs < out) out = bucket.minMs;
  }
  return out;
}

double _maxOf(List<LatencyBucket> buckets) {
  if (buckets.isEmpty) return 0;
  double out = buckets.first.maxMs;
  for (final LatencyBucket bucket in buckets) {
    if (bucket.maxMs > out) out = bucket.maxMs;
  }
  return out;
}

int _sumCounts(List<LatencyBucket> buckets) {
  int total = 0;
  for (final LatencyBucket bucket in buckets) {
    total += bucket.count;
  }
  return total;
}

/// Mean absolute deviation of [series] around [mean].
///
/// Labelled `Dev`, not `σ`: the backend reports a mean jitter and no standard
/// deviation, so this is a derived indicator and must not be presented as a
/// number the server computed. An empty series yields zero rather than NaN.
double _deviation(List<double> series, double mean) {
  if (series.isEmpty) return 0;
  double total = 0;
  for (final double sample in series) {
    total += (sample - mean).abs();
  }
  return total / series.length;
}
