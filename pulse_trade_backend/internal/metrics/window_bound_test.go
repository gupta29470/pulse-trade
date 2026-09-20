package metrics_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// TestWindowBoundsAreInclusiveOnBothDrivers pins the meaning of a query window.
//
// Timestamps are stored at **millisecond** precision (`encodeTime` truncates), so
// a window end of `T` covers every row whose instant is at or before `T`. A
// half-open upper bound (`at < T`) silently drops the millisecond that `T` falls
// in — precisely the millisecond a caller asking for "up to now" cares about, and
// the one the newest recorded sample sits in.
//
// Both drivers have to agree here: the in-memory driver compares
// `!at.After(to)`, and a driver that disagreed would make the diagnostics screen
// disagree with itself depending on `METRICS_DRIVER`.
func TestWindowBoundsAreInclusiveOnBothDrivers(t *testing.T) {
	drivers := []string{metrics.DriverSQLite, metrics.DriverMemory}

	for _, driver := range drivers {
		t.Run(driver, func(t *testing.T) {
			ctx := context.Background()
			config := metrics.Config{
				Enabled:       true,
				Driver:        driver,
				QueueCapacity: 32,
				BatchSize:     8,
				FlushInterval: 10 * time.Millisecond,
			}
			if driver == metrics.DriverSQLite {
				config.DSN = filepath.Join(t.TempDir(), "window.db")
			}
			store, err := metrics.Open(ctx, config, testLogger(t))
			if err != nil {
				t.Fatalf("Open(%s): %v", driver, err)
			}
			defer func() { _ = store.Close(ctx) }()

			// A time already at the stored precision, so "the row's instant" and
			// "the encoded row's instant" are the same value by construction.
			at := time.Now().UTC().Truncate(time.Millisecond)
			store.Recorder().RecordTierTransition(observability.TierTransitionRow{
				SessionID: "sess-bound",
				At:        at,
				From:      "FULL",
				To:        "DEGRADED",
				Reason:    "HIGH_RTT",
			})
			if err := store.Flush(ctx); err != nil {
				t.Fatalf("Flush: %v", err)
			}

			cases := []struct {
				name string
				from time.Time
				to   time.Time
			}{
				{"row exactly at the window end", at.Add(-time.Hour), at},
				{"row exactly at the window start", at, at.Add(time.Hour)},
				{"row is the whole window", at, at},
				{"row inside the window", at.Add(-time.Minute), at.Add(time.Minute)},
			}
			for _, testCase := range cases {
				rows, err := store.Querier().TierTransitions(ctx, testCase.from, testCase.to, 10)
				if err != nil {
					t.Fatalf("%s: TierTransitions: %v", testCase.name, err)
				}
				if len(rows) != 1 {
					t.Errorf("%s [%s]: got %d rows, want 1; a window's bounds include the row written at them",
						testCase.name, driver, len(rows))
				}
			}

			// The same boundary through the aggregate path the frontend reads.
			stats, err := store.Querier().Summary(ctx, time.Hour)
			if err != nil {
				t.Fatalf("Summary: %v", err)
			}
			if stats.TierTransitions != 1 {
				t.Errorf("[%s] Summary.TierTransitions = %d, want 1", driver, stats.TierTransitions)
			}
		})
	}
}
