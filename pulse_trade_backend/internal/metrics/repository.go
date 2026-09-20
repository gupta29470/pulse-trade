package metrics

import (
	"context"
	"sort"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// defaultQueryWindow is the aggregate window used by Summary when the caller
// does not name one. Fifteen minutes is the window the diagnostics screen charts,
// so the summary and the chart agree on what "recent" means.
const defaultQueryWindow = 15 * time.Minute

// SummaryStats is the cheap, index-friendly part of the metrics summary: row
// counts per table and per enum kind. RTT and jitter aggregates are computed
// separately because they need the sample values themselves.
type SummaryStats struct {
	TotalSessions    int64
	ActiveSessions   int64
	TierDistribution map[string]int

	LatencySamples  int64
	DeliveryWindows int64
	CandleCloses    int64
	TierTransitions int64
	EngineEvents    int64

	Reconnects       int64
	CandleInvariants int64

	MalformedMessages int64
	DuplicateDeltas   int64
	StaleDeltas       int64
	OutOfOrderTrades  int64
	BookRecoveries    int64
	BookGapsDetected  int64
}

// Batch is one transaction's worth of records. It exists so the writer builds the
// whole batch off the lock and the repository only has to persist it.
type Batch struct {
	Latency     []observability.LatencySample
	Health      []observability.HealthReportRow
	Tiers       []observability.TierTransitionRow
	Delivery    []observability.DeliveryWindow
	BookEvents  []observability.BookSyncEvent
	Protocol    []observability.ProtocolEvent
	Sessions    []SessionWrite
	EngineEvts  []observability.EngineEvent
	CandleClose []CandleCloseRow
	Faults      []observability.FaultInjectionRow
}

// Len returns how many rows the batch will write. It is the writer's accounting
// unit: RowsWritten is incremented by exactly this number after a commit.
func (b Batch) Len() int {
	return len(b.Latency) + len(b.Health) + len(b.Tiers) + len(b.Delivery) +
		len(b.BookEvents) + len(b.Protocol) + len(b.Sessions) + len(b.EngineEvts) +
		len(b.CandleClose) + len(b.Faults)
}

// SessionWrite is one session row mutation. The store distinguishes "start" from
// "end" before batching because one is an upsert and the other an update.
type SessionWrite struct {
	Row observability.SessionRow
	End bool
}

// EngineEventCounters counts engine events by name, which is how the summary
// answers "were there invariant violations" without scanning every row.
type EngineEventCounters struct {
	Total               int64
	InvariantViolations int64
}

// CandleCloseRow is a candle close with its prices already rendered as exact
// decimal strings. Rendering happens in the store, not in the driver, so both
// drivers store the same strings and neither needs the symbol registry.
type CandleCloseRow struct {
	Symbol     string
	Interval   string
	StartTime  time.Time
	Open       string
	High       string
	Low        string
	Close      string
	Volume     string
	TradeCount int64
	ClosedAt   time.Time
	Epoch      uint64
}

// LatencyQuery selects raw latency samples. It is the input to every latency
// aggregate, so bucketing and percentile maths live in exactly one place.
type LatencyQuery struct {
	SessionID string
	From      time.Time
	To        time.Time
	Limit     int
}

// Repository is the driver contract behind the store. One implementation owns
// one backing database; the store never talks to SQL directly.
type Repository interface {
	// WriteBatch persists every record in one transaction. A partial write is a
	// failure: the caller counts it and moves on rather than retrying rows
	// individually, because metrics are best-effort by design.
	WriteBatch(ctx context.Context, b Batch) error

	// UpsertSession inserts or refreshes a session's lifecycle row.
	UpsertSession(ctx context.Context, row observability.SessionRow) error

	// EndSession closes a session row. Ending an unknown session is not an
	// error: a session row may have been dropped with its batch.
	EndSession(ctx context.Context, row observability.SessionRow) error

	// SummaryStats returns the windowed row counts behind MetricsSummary.
	SummaryStats(ctx context.Context, from, to time.Time) (SummaryStats, error)

	// LatencySamples returns raw samples in ascending server-time order.
	LatencySamples(ctx context.Context, q LatencyQuery) ([]observability.LatencySample, error)

	// EngineEventCounters counts engine events in a window.
	EngineEventCounters(ctx context.Context, from, to time.Time) (EngineEventCounters, error)

	// TierTransitions returns transitions in descending time order.
	TierTransitions(ctx context.Context, from, to time.Time, limit int) ([]observability.TierTransitionRow, error)

	// Sessions returns lifecycle rows, most recent connection first.
	Sessions(ctx context.Context, limit int) ([]observability.SessionRow, error)

	// DeliveryWindows returns delivery windows in descending time order.
	DeliveryWindows(ctx context.Context, sessionID string, from, to time.Time, limit int) ([]observability.DeliveryWindow, error)

	// Ping reports whether the backing store is reachable.
	Ping(ctx context.Context) error

	// SchemaVersion returns the highest applied migration version, or 0 when the
	// driver does not migrate (the in-memory driver).
	SchemaVersion() int

	// Close releases the backing store.
	Close() error
}

// latencyAggregate accumulates one bucket (or one whole query) of latency
// samples. It keeps every value so p95 is a real percentile rather than an
// estimate; the sample counts involved are small because every query is bounded.
type latencyAggregate struct {
	values []float64
	jitter []float64
	sum    float64
	jitSum float64
	min    float64
	max    float64
}

func (a *latencyAggregate) add(rtt, jitterMs float64) {
	if len(a.values) == 0 {
		a.min, a.max = rtt, rtt
	} else {
		if rtt < a.min {
			a.min = rtt
		}
		if rtt > a.max {
			a.max = rtt
		}
	}
	a.values = append(a.values, rtt)
	a.jitter = append(a.jitter, jitterMs)
	a.sum += rtt
	a.jitSum += jitterMs
}

func (a *latencyAggregate) count() int64 { return int64(len(a.values)) }

func (a *latencyAggregate) avg() float64 {
	if len(a.values) == 0 {
		return 0
	}
	return a.sum / float64(len(a.values))
}

func (a *latencyAggregate) avgJitter() float64 {
	if len(a.jitter) == 0 {
		return 0
	}
	return a.jitSum / float64(len(a.jitter))
}

// p95 returns the nearest-rank 95th percentile. Nearest rank is used rather than
// linear interpolation because the value reported to a client must be a value the
// system actually observed.
func (a *latencyAggregate) p95() float64 {
	if len(a.values) == 0 {
		return 0
	}
	sorted := append([]float64(nil), a.values...)
	sort.Float64s(sorted)
	rank := (95*len(sorted) + 99) / 100
	if rank < 1 {
		rank = 1
	}
	return sorted[rank-1]
}

// rttStats folds raw samples into the summary's percentile block.
func rttStats(samples []observability.LatencySample) observability.RTTStats {
	if len(samples) == 0 {
		return observability.RTTStats{}
	}
	var agg latencyAggregate
	for _, s := range samples {
		agg.add(s.RTTMs, s.JitterMs)
	}
	return observability.RTTStats{
		Samples: agg.count(),
		MinMs:   agg.min,
		AvgMs:   agg.avg(),
		P95Ms:   agg.p95(),
		MaxMs:   agg.max,
	}
}

// bucketLatency groups samples into fixed-width buckets starting at the first
// bucket boundary at or before from. Bucket boundaries are derived from the
// caller's range, not from wall-clock now, so a test gets identical bounds across
// both drivers and across repeated calls.
func bucketLatency(samples []observability.LatencySample, from time.Time, bucket time.Duration) []observability.LatencyBucket {
	if bucket <= 0 || len(samples) == 0 {
		return nil
	}
	start := from.UTC().Truncate(bucket)
	byStart := make(map[time.Time]*latencyAggregate, len(samples))
	for _, s := range samples {
		at := s.ServerTime.UTC()
		offset := at.Sub(start)
		if offset < 0 {
			// A sample before the range start is impossible for a well-formed
			// query; anchoring it to the first bucket is friendlier than dropping
			// it, and the caller can see the count is off by looking at Start.
			offset = 0
		}
		key := start.Add((offset / bucket) * bucket)
		agg, ok := byStart[key]
		if !ok {
			agg = &latencyAggregate{}
			byStart[key] = agg
		}
		agg.add(s.RTTMs, s.JitterMs)
	}

	starts := make([]time.Time, 0, len(byStart))
	for k := range byStart {
		starts = append(starts, k)
	}
	sort.Slice(starts, func(i, j int) bool { return starts[i].Before(starts[j]) })

	out := make([]observability.LatencyBucket, 0, len(starts))
	for _, s := range starts {
		agg := byStart[s]
		out = append(out, observability.LatencyBucket{
			Start:       s,
			End:         s.Add(bucket),
			Count:       agg.count(),
			MinMs:       agg.min,
			AvgMs:       agg.avg(),
			P95Ms:       agg.p95(),
			MaxMs:       agg.max,
			AvgJitterMs: agg.avgJitter(),
		})
	}
	return out
}

// limitOr applies a default and a hard ceiling to a caller-supplied limit.
// Unbounded queries are the one way a metrics read could stall the writer, so
// every list query is capped here rather than at each call site.
func limitOr(limit, def, max int) int {
	if limit <= 0 {
		return def
	}
	if limit > max {
		return max
	}
	return limit
}
