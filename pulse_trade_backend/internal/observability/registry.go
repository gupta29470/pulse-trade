package observability

import (
	"sort"
	"sync"
	"sync/atomic"
)

// Counter names. They are referenced by the diagnostics endpoints and by the
// README's troubleshooting section.
const (
	CounterWSConnectionsTotal   = "ws_connections_total"
	CounterWSConnectionsActive  = "ws_connections_active"
	CounterWSDisconnectsTotal   = "ws_disconnects_total"
	CounterWSMessagesInTotal    = "ws_messages_in_total"
	CounterWSMessagesOutTotal   = "ws_messages_out_total"
	CounterWSBytesOutTotal      = "ws_bytes_out_total"
	CounterWSReconnectsTotal    = "ws_reconnects_total"
	CounterHealthReportsTotal   = "health_reports_total"
	CounterMissedPongsTotal     = "missed_pongs_total"
	CounterTierTransitionsTotal = "tier_transitions_total"
	CounterBookRecoveriesTotal  = "orderbook_recoveries_total"
	CounterBookGapsTotal        = "orderbook_gaps_total"
	CounterBookDuplicateDeltas  = "orderbook_duplicate_deltas_total"
	CounterBookStaleDeltas      = "orderbook_stale_deltas_total"
	CounterBookCoalescedTotal   = "orderbook_coalesced_total"
	CounterCandlesClosedTotal   = "candles_closed_total"
	CounterCandleViolations     = "candle_invariant_violations_total"
	CounterMalformedMessages    = "malformed_messages_total"
	CounterValidationFailures   = "validation_failures_total"
	CounterOutOfOrderTrades     = "out_of_order_trades_total"
	CounterDuplicateTrades      = "duplicate_trades_total"
	CounterUnknownMessages      = "unknown_messages_total"
	CounterMetricsRowsWritten   = "metrics_rows_written_total"
	CounterMetricsDropped       = "metrics_dropped_total"
	CounterMetricsWriteFailures = "metrics_write_failures_total"
	CounterMetricsPrunedRows    = "metrics_pruned_rows_total"
	CounterEngineEventsTotal    = "engine_events_total"
	CounterSlowConsumersTotal   = "slow_consumers_total"
	CounterRateLimitedTotal     = "rate_limited_total"
	CounterProviderFaultsTotal  = "provider_faults_total"
)

// Gauge names.
const (
	GaugeEngineEventIndex  = "engine_event_index"
	GaugeEngineUpdateID    = "engine_update_id"
	GaugeEngineEpoch       = "engine_epoch"
	GaugeSessionsActive    = "sessions_active"
	GaugeMetricsQueueDepth = "metrics_queue_depth"
	GaugeBusSubscribers    = "bus_subscribers"
)

// Registry holds process counters and gauges.
//
// It is intentionally tiny: counters are monotonic totals, gauges are last-value
// observations, and the snapshot is a flat map so it can be exported straight into
// the metrics summary without an adapter.
type Registry struct {
	mu       sync.RWMutex
	counters map[string]*atomic.Int64
	gauges   map[string]*atomic.Int64
}

// NewRegistry creates an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		counters: make(map[string]*atomic.Int64),
		gauges:   make(map[string]*atomic.Int64),
	}
}

func (r *Registry) counter(name string) *atomic.Int64 {
	r.mu.RLock()
	c, ok := r.counters[name]
	r.mu.RUnlock()
	if ok {
		return c
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if c, ok := r.counters[name]; ok {
		return c
	}
	c = &atomic.Int64{}
	r.counters[name] = c
	return c
}

func (r *Registry) gauge(name string) *atomic.Int64 {
	r.mu.RLock()
	g, ok := r.gauges[name]
	r.mu.RUnlock()
	if ok {
		return g
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if g, ok := r.gauges[name]; ok {
		return g
	}
	g = &atomic.Int64{}
	r.gauges[name] = g
	return g
}

// Inc increments a counter by one.
func (r *Registry) Inc(name string) { r.counter(name).Add(1) }

// Add increments a counter by n.
func (r *Registry) Add(name string, n int64) {
	if n == 0 {
		return
	}
	r.counter(name).Add(n)
}

// SetGauge records a gauge value.
func (r *Registry) SetGauge(name string, v int64) { r.gauge(name).Store(v) }

// Counter reads a counter's current value.
func (r *Registry) Counter(name string) int64 { return r.counter(name).Load() }

// Gauge reads a gauge's current value.
func (r *Registry) Gauge(name string) int64 { return r.gauge(name).Load() }

// Snapshot returns every counter and gauge. Gauges are prefixed so a consumer can
// tell the two apart without a schema.
func (r *Registry) Snapshot() map[string]int64 {
	r.mu.RLock()
	defer r.mu.RUnlock()

	out := make(map[string]int64, len(r.counters)+len(r.gauges))
	for name, c := range r.counters {
		out[name] = c.Load()
	}
	for name, g := range r.gauges {
		out["gauge."+name] = g.Load()
	}
	return out
}

// CounterNames returns the registered counter names, sorted.
func (r *Registry) CounterNames() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	names := make([]string, 0, len(r.counters))
	for name := range r.counters {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
