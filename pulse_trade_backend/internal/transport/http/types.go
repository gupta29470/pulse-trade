package http

import (
	"context"
	"sync"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// MetricsQuerier is the read side of the metrics store. It is declared here, by the
// consumer, so the transport layer does not depend on a storage implementation.
type MetricsQuerier interface {
	Summary(ctx context.Context, window time.Duration) (observability.MetricsSummary, error)
	LatencyBuckets(ctx context.Context, sessionID string, from, to time.Time, bucket time.Duration) ([]observability.LatencyBucket, error)
	TierTransitions(ctx context.Context, from, to time.Time, limit int) ([]observability.TierTransitionRow, error)
	Sessions(ctx context.Context, limit int) ([]observability.SessionRow, error)
	DeliveryWindows(ctx context.Context, sessionID string, from, to time.Time, limit int) ([]observability.DeliveryWindow, error)
}

// DebugState holds debug-only switches that the handlers consult. Keeping them in
// one place means a release build simply never constructs it.
type DebugState struct {
	mu             sync.RWMutex
	emptyHistory   bool
	metricsFailure bool
}

// NewDebugState creates an empty debug state.
func NewDebugState() *DebugState { return &DebugState{} }

// SetEmptyHistory makes the candle endpoints return no history, which is how the
// app's empty-history state is demonstrated.
func (d *DebugState) SetEmptyHistory(on bool) {
	d.mu.Lock()
	d.emptyHistory = on
	d.mu.Unlock()
}

// EmptyHistory reports whether history is being suppressed.
func (d *DebugState) EmptyHistory() bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.emptyHistory
}

// SetMetricsFailure makes the metrics store fail writes, to prove delivery
// continues and /health reports the store as degraded.
func (d *DebugState) SetMetricsFailure(on bool) {
	d.mu.Lock()
	d.metricsFailure = on
	d.mu.Unlock()
}

// MetricsFailure reports whether metrics writes are being forced to fail.
func (d *DebugState) MetricsFailure() bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.metricsFailure
}
