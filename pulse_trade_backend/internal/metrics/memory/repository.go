// Package memory is the in-memory metrics driver. It applies every batch
// synchronously, which is what makes unit tests deterministic: a record is
// queryable as soon as Record* returns, with no flush or polling needed.
package memory

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// Repository is a bounded-by-nothing, process-local metrics store. It is not for
// production: it exists so the store's contract can be tested without SQL.
type Repository struct {
	mu sync.RWMutex

	latency     []observability.LatencySample
	health      []observability.HealthReportRow
	tiers       []observability.TierTransitionRow
	delivery    []observability.DeliveryWindow
	bookEvents  []observability.BookSyncEvent
	protocol    []observability.ProtocolEvent
	engineEvts  []observability.EngineEvent
	candleClose []metrics.CandleCloseRow
	faults      []observability.FaultInjectionRow
	sessions    map[string]observability.SessionRow
	sessionAt   []string

	// writerOpts is the store's writer configuration, kept so WriterOptions can
	// return it with this driver plugged in.
	writerOpts metrics.WriterOptions
}

// NewRepository creates an empty in-memory store.
func NewRepository() *Repository {
	return &Repository{sessions: map[string]observability.SessionRow{}}
}

// WriteBatch appends every record. The driver keeps insertion order so a test can
// assert on ordering as well as on content.
func (r *Repository) WriteBatch(_ context.Context, b metrics.Batch) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.latency = append(r.latency, b.Latency...)
	r.health = append(r.health, b.Health...)
	r.tiers = append(r.tiers, b.Tiers...)
	r.delivery = append(r.delivery, b.Delivery...)
	r.bookEvents = append(r.bookEvents, b.BookEvents...)
	r.protocol = append(r.protocol, b.Protocol...)
	r.engineEvts = append(r.engineEvts, b.EngineEvts...)
	r.candleClose = append(r.candleClose, b.CandleClose...)
	r.faults = append(r.faults, b.Faults...)
	for _, s := range b.Sessions {
		// A "start" record is an upsert and an "end" record only fills in the
		// closing columns, exactly like the SQL driver's INSERT versus UPDATE.
		// Treating both as upserts would erase the identity of an already-written
		// session row when a connection closes inside the same batch.
		if s.End {
			r.endSessionLocked(s.Row)
			continue
		}
		r.putSessionLocked(s.Row)
	}
	return nil
}

// UpsertSession inserts or refreshes one session row.
func (r *Repository) UpsertSession(_ context.Context, row observability.SessionRow) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.putSessionLocked(row)
	return nil
}

func (r *Repository) putSessionLocked(row observability.SessionRow) {
	if _, ok := r.sessions[row.SessionID]; !ok {
		r.sessionAt = append(r.sessionAt, row.SessionID)
	}
	r.sessions[row.SessionID] = row
}

// EndSession closes one session row. Ending an unknown session is a no-op, which
// mirrors the SQL driver's UPDATE semantics.
func (r *Repository) EndSession(_ context.Context, row observability.SessionRow) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.endSessionLocked(row)
	return nil
}

// endSessionLocked applies the closing half of a session row. Ending an unknown
// session is a no-op, mirroring an UPDATE that matched no row.
func (r *Repository) endSessionLocked(row observability.SessionRow) {
	existing, ok := r.sessions[row.SessionID]
	if !ok {
		return
	}
	if row.DisconnectedAt != nil {
		existing.DisconnectedAt = row.DisconnectedAt
	}
	if row.DisconnectReason != "" {
		existing.DisconnectReason = row.DisconnectReason
	}
	if row.FinalTier != "" {
		existing.FinalTier = row.FinalTier
	}
	if row.OverrideTier != "" {
		existing.OverrideTier = row.OverrideTier
	}
	existing.UptimeMs = row.UptimeMs
	existing.MessagesSent = row.MessagesSent
	existing.MessagesReceived = row.MessagesReceived
	existing.BytesSent = row.BytesSent
	existing.ProtocolErrors = row.ProtocolErrors
	r.sessions[row.SessionID] = existing
}

// SummaryStats counts the windowed rows the summary needs.
func (r *Repository) SummaryStats(_ context.Context, from, to time.Time) (metrics.SummaryStats, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	stats := metrics.SummaryStats{
		TotalSessions:    int64(len(r.sessionAt)),
		TierDistribution: map[string]int{},
		LatencySamples:   int64(len(r.latency)),
		DeliveryWindows:  int64(len(r.delivery)),
	}
	for _, id := range r.sessionAt {
		row := r.sessions[id]
		if row.DisconnectedAt == nil {
			stats.ActiveSessions++
		}
		if tier := row.FinalTier; tier != "" {
			stats.TierDistribution[tier]++
		} else if row.InitialTier != "" {
			stats.TierDistribution[row.InitialTier]++
		}
	}
	for _, ev := range r.engineEvts {
		if inWindow(ev.At, from, to) {
			stats.EngineEvents++
		}
	}
	for _, tr := range r.tiers {
		if inWindow(tr.At, from, to) {
			stats.TierTransitions++
		}
	}
	for _, c := range r.candleClose {
		if inWindow(c.ClosedAt, from, to) {
			stats.CandleCloses++
		}
	}
	for _, p := range r.protocol {
		if !inWindow(p.At, from, to) {
			continue
		}
		switch p.Kind {
		case observability.ProtocolMalformedFrame:
			stats.MalformedMessages += countOrOne(p.Count)
		case observability.ProtocolDuplicateDelta:
			stats.DuplicateDeltas += countOrOne(p.Count)
		case observability.ProtocolStaleDelta:
			stats.StaleDeltas += countOrOne(p.Count)
		case observability.ProtocolOutOfOrderTrade:
			stats.OutOfOrderTrades += countOrOne(p.Count)
		}
	}
	for _, b := range r.bookEvents {
		if !inWindow(b.At, from, to) {
			continue
		}
		switch b.Event {
		case observability.BookEventRecoveryStarted:
			stats.BookRecoveries++
		case observability.BookEventGapDetected:
			stats.BookGapsDetected++
		}
	}
	for _, s := range r.sessionAt {
		row := r.sessions[s]
		if row.DisconnectReason == "client_reconnect" || row.DisconnectReason == "reconnect" {
			stats.Reconnects++
		}
	}
	return stats, nil
}

func countOrOne(v int64) int64 {
	if v <= 0 {
		return 1
	}
	return v
}

func inWindow(at, from, to time.Time) bool {
	if at.IsZero() {
		return false
	}
	if !from.IsZero() && at.Before(from) {
		return false
	}
	if !to.IsZero() && at.After(to) {
		return false
	}
	return true
}

// LatencySamples returns raw samples in ascending server-time order.
func (r *Repository) LatencySamples(_ context.Context, q metrics.LatencyQuery) ([]observability.LatencySample, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]observability.LatencySample, 0, len(r.latency))
	for _, s := range r.latency {
		if q.SessionID != "" && s.SessionID != q.SessionID {
			continue
		}
		if !inWindow(s.ServerTime, q.From, q.To) {
			continue
		}
		out = append(out, s)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ServerTime.Before(out[j].ServerTime) })
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, nil
}

// EngineEventCounters counts engine events in a window.
func (r *Repository) EngineEventCounters(_ context.Context, from, to time.Time) (metrics.EngineEventCounters, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var c metrics.EngineEventCounters
	for _, ev := range r.engineEvts {
		if !inWindow(ev.At, from, to) {
			continue
		}
		c.Total++
		if ev.Event == "INVARIANT_VIOLATION" {
			c.InvariantViolations++
		}
	}
	return c, nil
}

// TierTransitions returns transitions in descending time order.
func (r *Repository) TierTransitions(_ context.Context, from, to time.Time, limit int) ([]observability.TierTransitionRow, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]observability.TierTransitionRow, 0, len(r.tiers))
	for _, tr := range r.tiers {
		if !inWindow(tr.At, from, to) {
			continue
		}
		out = append(out, tr)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// Sessions returns lifecycle rows, most recent connection first.
func (r *Repository) Sessions(_ context.Context, limit int) ([]observability.SessionRow, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]observability.SessionRow, 0, len(r.sessionAt))
	for _, id := range r.sessionAt {
		out = append(out, r.sessions[id])
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ConnectedAt.After(out[j].ConnectedAt) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// DeliveryWindows returns delivery windows in descending time order.
func (r *Repository) DeliveryWindows(_ context.Context, sessionID string, from, to time.Time, limit int) ([]observability.DeliveryWindow, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]observability.DeliveryWindow, 0, len(r.delivery))
	for _, w := range r.delivery {
		if sessionID != "" && w.SessionID != sessionID {
			continue
		}
		if !inWindow(w.WindowStart, from, to) {
			continue
		}
		out = append(out, w)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].WindowStart.After(out[j].WindowStart) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// Ping always succeeds: the store is the process.
func (r *Repository) Ping(context.Context) error { return nil }

// SchemaVersion is 0 because the in-memory driver has no schema.
func (r *Repository) SchemaVersion() int { return 0 }

// ConfigureWriter records the store's writer configuration. The in-memory driver
// writes every batch synchronously, so every callback still applies — the store's
// counters and its flush-latency signal do not depend on which driver is behind
// them, and a test that asserts on RowsWritten must see the same numbers.
func (r *Repository) ConfigureWriter(opts metrics.WriterOptions) {
	r.mu.Lock()
	r.writerOpts = opts
	r.mu.Unlock()
}

// WriterOptions returns the store's configuration with this driver plugged in.
// Batching stays enabled so the store's policy (BatchSize, FlushInterval) is
// exercised identically across drivers.
func (r *Repository) WriterOptions() metrics.WriterOptions {
	r.mu.RLock()
	opts := r.writerOpts
	r.mu.RUnlock()
	opts.Repository = r
	// Retention is not applied: an in-memory store holds one test's rows, and
	// dropping them by age would make assertions flaky.
	opts.Retention = metrics.Retention{Enabled: false}
	return opts
}

// init registers the driver so metrics.Open can select it by name without the
// parent package importing this one.
func init() {
	metrics.RegisterDriver("memory", func(context.Context, metrics.Config, *observability.Logger) (metrics.Repository, error) {
		return NewRepository(), nil
	})
}

// Close releases the collected rows so a long test run does not hold them.
func (r *Repository) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.latency, r.health, r.tiers, r.delivery = nil, nil, nil, nil
	r.bookEvents, r.protocol, r.engineEvts, r.candleClose = nil, nil, nil, nil
	r.faults, r.sessionAt = nil, nil
	r.sessions = map[string]observability.SessionRow{}
	return nil
}

// compile-time proof that the driver satisfies the store's contract.
var _ metrics.Repository = (*Repository)(nil)
