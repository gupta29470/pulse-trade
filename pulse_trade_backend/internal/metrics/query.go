package metrics

import (
	"context"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// Query bounds. A metrics read is capped at 1000 rows and a 24-hour range; these
// constants are the store-side floor of that contract. Reads share the single
// write connection, so an unbounded read is a write-path stall, not just a slow
// response.
const (
	maxQueryRows      = 1000
	maxQueryRange     = 24 * time.Hour
	defaultBucketSize = 5 * time.Second
	maxLatencySamples = 200_000
)

// The five methods below are the same reads exposed on the Querier value. They
// exist so *Store can be handed to a consumer that declares its own reader
// interface (the HTTP layer does exactly that); the wrapper type keeps the
// documented Querier surface explicit.

// Summary computes the metrics summary over a window.
func (s *Store) Summary(ctx context.Context, window time.Duration) (observability.MetricsSummary, error) {
	return (*querier)(s).Summary(ctx, window)
}

// LatencyBuckets returns the bucketed latency series.
func (s *Store) LatencyBuckets(ctx context.Context, sessionID string, from, to time.Time, bucket time.Duration) ([]observability.LatencyBucket, error) {
	return (*querier)(s).LatencyBuckets(ctx, sessionID, from, to, bucket)
}

// TierTransitions returns tier changes, newest first.
func (s *Store) TierTransitions(ctx context.Context, from, to time.Time, limit int) ([]observability.TierTransitionRow, error) {
	return (*querier)(s).TierTransitions(ctx, from, to, limit)
}

// Sessions returns session lifecycle rows, newest first.
func (s *Store) Sessions(ctx context.Context, limit int) ([]observability.SessionRow, error) {
	return (*querier)(s).Sessions(ctx, limit)
}

// DeliveryWindows returns delivered-versus-target windows, newest first.
func (s *Store) DeliveryWindows(ctx context.Context, sessionID string, from, to time.Time, limit int) ([]observability.DeliveryWindow, error) {
	return (*querier)(s).DeliveryWindows(ctx, sessionID, from, to, limit)
}

// querier adapts the store to the read interface. It is a distinct type rather
// than methods on Store so the read path cannot accidentally use write-side
// helpers, and so Querier returns something that only reads.
type querier Store

// Summary computes the metrics summary over the given window. A non-positive
// window means the default fifteen minutes.
func (q *querier) Summary(ctx context.Context, window time.Duration) (observability.MetricsSummary, error) {
	s := (*Store)(q)
	out := observability.MetricsSummary{
		GeneratedAt:      time.Now().UTC(),
		TierDistribution: map[string]int{},
		Counters:         map[string]int64{},
	}
	if !s.cfg.Enabled || s.repo == nil {
		// A disabled store answers with an empty but valid summary so the
		// diagnostics screen renders zeroes instead of an error.
		return out, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if window <= 0 {
		window = defaultQueryWindow
	}
	now := time.Now().UTC()
	from := now.Add(-window)

	stats, err := s.repo.SummaryStats(ctx, from, now)
	if err != nil {
		return out, err
	}
	counters, err := s.repo.EngineEventCounters(ctx, from, now)
	if err != nil {
		return out, err
	}
	samples, err := s.repo.LatencySamples(ctx, LatencyQuery{From: from, To: now, Limit: maxLatencySamples})
	if err != nil {
		return out, err
	}

	out.UptimeMs = time.Since(s.opened).Milliseconds()
	out.ActiveSessions = int(stats.ActiveSessions)
	out.TotalSessions = stats.TotalSessions
	out.TierDistribution = stats.TierDistribution
	if out.TierDistribution == nil {
		out.TierDistribution = map[string]int{}
	}
	out.RTT = rttStats(samples)
	out.JitterMs = meanJitter(samples)
	out.Reconnects = stats.Reconnects
	out.BookRecoveries = stats.BookRecoveries
	out.BookGapsDetected = stats.BookGapsDetected
	out.MalformedMessages = stats.MalformedMessages
	out.DuplicateDeltas = stats.DuplicateDeltas
	out.StaleDeltas = stats.StaleDeltas
	out.OutOfOrderTrades = stats.OutOfOrderTrades
	out.TierTransitions = stats.TierTransitions
	out.CandlesClosed = stats.CandleCloses
	out.CandleInvariantViolations = counters.InvariantViolations
	out.LatencySamples = stats.LatencySamples
	out.DeliveryWindows = stats.DeliveryWindows

	// The store's own counters belong in the summary: the question
	// "did the metrics system lose anything" is answered here, next to the
	// numbers that loss would have affected.
	out.Counters[observability.CounterMetricsDropped] = s.dropped.Load()
	out.Counters[observability.CounterMetricsWriteFailures] = s.writeFailures.Load()
	out.Counters[observability.CounterMetricsRowsWritten] = s.rowsWritten.Load()
	out.Counters[observability.CounterMetricsPrunedRows] = s.prunedRows.Load()
	out.Counters[observability.CounterEngineEventsTotal] = counters.Total
	out.Counters[observability.CounterTierTransitionsTotal] = stats.TierTransitions
	out.Counters[observability.CounterMalformedMessages] = stats.MalformedMessages
	out.Counters[observability.CounterCandlesClosedTotal] = stats.CandleCloses
	out.Counters[observability.CounterBookRecoveriesTotal] = stats.BookRecoveries
	out.Counters[observability.CounterBookGapsTotal] = stats.BookGapsDetected
	return out, nil
}

// LatencyBuckets returns the bucketed latency series the diagnostics chart draws.
func (q *querier) LatencyBuckets(ctx context.Context, sessionID string, from, to time.Time, bucket time.Duration) ([]observability.LatencyBucket, error) {
	s := (*Store)(q)
	if !s.cfg.Enabled || s.repo == nil {
		return nil, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if bucket <= 0 {
		bucket = defaultBucketSize
	}
	from, to = clampRange(from, to)
	if !to.After(from) {
		return nil, nil
	}
	samples, err := s.repo.LatencySamples(ctx, LatencyQuery{
		SessionID: sessionID,
		From:      from,
		To:        to,
		Limit:     maxLatencySamples,
	})
	if err != nil {
		return nil, err
	}
	return bucketLatency(samples, from, bucket), nil
}

// TierTransitions returns tier changes, newest first.
func (q *querier) TierTransitions(ctx context.Context, from, to time.Time, limit int) ([]observability.TierTransitionRow, error) {
	s := (*Store)(q)
	if !s.cfg.Enabled || s.repo == nil {
		return nil, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if from.IsZero() && to.IsZero() {
		to = time.Now().UTC()
		from = to.Add(-maxQueryRange)
	} else {
		from, to = clampRange(from, to)
	}
	return s.repo.TierTransitions(ctx, from, to, limitOr(limit, 100, maxQueryRows))
}

// Sessions returns session lifecycle rows, newest first.
func (q *querier) Sessions(ctx context.Context, limit int) ([]observability.SessionRow, error) {
	s := (*Store)(q)
	if !s.cfg.Enabled || s.repo == nil {
		return nil, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	return s.repo.Sessions(ctx, limitOr(limit, 100, maxQueryRows))
}

// DeliveryWindows returns delivered-versus-target windows, newest first.
func (q *querier) DeliveryWindows(ctx context.Context, sessionID string, from, to time.Time, limit int) ([]observability.DeliveryWindow, error) {
	s := (*Store)(q)
	if !s.cfg.Enabled || s.repo == nil {
		return nil, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if from.IsZero() && to.IsZero() {
		to = time.Now().UTC()
		from = to.Add(-maxQueryRange)
	} else {
		from, to = clampRange(from, to)
	}
	return s.repo.DeliveryWindows(ctx, sessionID, from, to, limitOr(limit, 100, maxQueryRows))
}

// meanJitter returns the mean absolute jitter over the sample set.
func meanJitter(samples []observability.LatencySample) float64 {
	if len(samples) == 0 {
		return 0
	}
	var sum float64
	for _, s := range samples {
		sum += s.JitterMs
	}
	return sum / float64(len(samples))
}

// clampRange applies the query range ceiling. A caller asking for "everything"
// gets the largest range the store will serve rather than an unbounded scan.
func clampRange(from, to time.Time) (time.Time, time.Time) {
	now := time.Now().UTC()
	if to.IsZero() {
		to = now
	}
	if from.IsZero() {
		from = to.Add(-maxQueryRange)
	}
	if to.Sub(from) > maxQueryRange {
		from = to.Add(-maxQueryRange)
	}
	return from.UTC(), to.UTC()
}
