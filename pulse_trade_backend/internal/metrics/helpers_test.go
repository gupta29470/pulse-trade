package metrics_test

import (
	"context"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"

	// The drivers register themselves; importing them here is what makes
	// metrics.Open("sqlite") and metrics.Open("memory") work.
	_ "github.com/pulsetrade/pulse-trade-backend/internal/metrics/memory"
	_ "github.com/pulsetrade/pulse-trade-backend/internal/metrics/sqlite"
)

// testSymbol must exist in the domain registry: candle rows are stored as exact
// decimal strings produced by the symbol's formatters.
const testSymbol = "BTCUSDT"

// newTestStore builds a store on the requested driver with a fast flush interval and
// a tiny queue where the test needs one.
func newTestStore(t *testing.T, cfg metrics.Config) *metrics.Store {
	t.Helper()
	cfg.Enabled = true
	if cfg.QueueCapacity == 0 {
		cfg.QueueCapacity = 64
	}
	if cfg.BatchSize == 0 {
		cfg.BatchSize = 8
	}
	if cfg.FlushInterval == 0 {
		// Long enough that a test which forgets Flush sees a failure rather than
		// a race, short enough that shutdown never waits on it.
		cfg.FlushInterval = 50 * time.Millisecond
	}
	if cfg.Driver == metrics.DriverSQLite && cfg.DSN == "" {
		cfg.DSN = t.TempDir() + "/metrics.db"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	store, err := metrics.Open(ctx, cfg, testLogger(t))
	if err != nil {
		t.Fatalf("Open(%s): %v", cfg.Driver, err)
	}
	t.Cleanup(func() {
		closeCtx, closeCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer closeCancel()
		if err := store.Close(closeCtx); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return store
}

// testLogger captures log output at error level. The store's warn records are
// asserted through its counters instead: a rate-limited WARN is deliberately not
// something a test can depend on.
func testLogger(t *testing.T) *observability.Logger {
	t.Helper()
	return observability.New("error", "test", false, &discardWriter{t: t})
}

// discardWriter keeps log output out of the test's stdout while still making a
// failure readable by attaching it to the test's log.
type discardWriter struct{ t *testing.T }

func (d *discardWriter) Write(p []byte) (int, error) {
	d.t.Logf("%s", string(p))
	return len(p), nil
}

// drivers returns the drivers every cross-driver guarantee is tested against.
func drivers() []string { return []string{metrics.DriverMemory, metrics.DriverSQLite} }

// sampleLatency is the exact-value fixture the latency assertions are built on.
var sampleLatency = observability.LatencySample{
	SessionID:  "sess-exact",
	Seq:        1,
	RTTMs:      74.25,
	JitterMs:   12.5,
	Samples:    10,
	ServerTime: time.Date(2026, 9, 17, 12, 41, 3, 235_000_000, time.UTC),
}

// seedSession writes the session row that latency_samples references. The SQLite
// schema enforces the foreign key, so this is required for both drivers to behave
// identically.
func seedSession(store *metrics.Store, sessionID string, at time.Time) {
	store.RecordSessionStart(observability.SessionRow{
		SessionID:   sessionID,
		DeviceID:    "device-1",
		Symbol:      testSymbol,
		Interval:    "1m",
		ConnectedAt: at,
		InitialTier: "FULL",
	})
}

// mustCandle builds a candle whose values exercise both decimal scales: a
// two-digit price and an eight-digit quantity.
func mustCandle(t *testing.T, start time.Time) domain.Candle {
	t.Helper()
	if _, err := domain.Lookup(testSymbol); err != nil {
		t.Fatalf("domain.Lookup(%s): %v", testSymbol, err)
	}
	return domain.Candle{
		Symbol:     testSymbol,
		Interval:   domain.Interval1m,
		StartTime:  start,
		Open:       domain.Price(6742135),
		High:       domain.Price(6749900),
		Low:        domain.Price(6730001),
		Close:      domain.Price(6745000),
		Volume:     domain.Qty(18400000),
		TradeCount: 42,
	}
}
