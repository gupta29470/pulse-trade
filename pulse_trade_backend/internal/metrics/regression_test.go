package metrics_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// A quiet server records a handful of rows and never fills a batch. These cases
// pin the store's guarantees under a quiet server: a record written before a
// flush is visible to a reader afterwards, and a partial batch is committed
// rather than left waiting for company.
func TestPeriodicFlushCommitsAPartialBatch(t *testing.T) {
	t.Parallel()

	store, err := metrics.Open(context.Background(), metrics.Config{
		Enabled:       true,
		Driver:        "sqlite",
		DSN:           filepath.Join(t.TempDir(), "quiet.db"),
		QueueCapacity: 256,
		BatchSize:     128, // deliberately far above the number of rows recorded
		FlushInterval: 40 * time.Millisecond,
	}, observability.New("debug", "test", true, nil))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = store.Close(ctx)
	})

	now := time.Now().UTC()
	store.Recorder().RecordLatency(observability.LatencySample{
		SessionID: "sess_quiet", Seq: 1, RTTMs: 74.25, JitterMs: 12.5,
		Samples: 10, ServerTime: now,
	})

	// Wait for the timer to fire on its own; no Flush call anywhere in this test.
	deadline := time.Now().Add(3 * time.Second)
	var seen int64
	for time.Now().Before(deadline) {
		buckets, err := store.Querier().LatencyBuckets(context.Background(),
			"sess_quiet", now.Add(-time.Minute), now.Add(time.Minute), time.Second)
		if err != nil {
			t.Fatalf("query: %v", err)
		}
		for _, b := range buckets {
			seen += b.Count
		}
		if seen > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if seen == 0 {
		h := store.Health()
		t.Fatalf("the periodic flush never committed the pending sample: health=%+v dropped=%d",
			h, store.Dropped())
	}
	if got := store.Health().RowsWritten; got == 0 {
		t.Fatal("rows were committed but the store reports RowsWritten == 0")
	}
	if dropped := store.Dropped(); dropped != 0 {
		t.Fatalf("unexpected drops: %d", dropped)
	}
}

// The same behaviour on the in-memory driver, which isolates a batching fault from
// a SQLite visibility fault.
func TestPeriodicFlushCommitsOnTheMemoryDriver(t *testing.T) {
	t.Parallel()

	store, err := metrics.Open(context.Background(), metrics.Config{
		Enabled:       true,
		Driver:        "memory",
		QueueCapacity: 256,
		BatchSize:     128,
		FlushInterval: 40 * time.Millisecond,
	}, observability.New("error", "test", false, nil))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = store.Close(ctx)
	})

	now := time.Now().UTC()
	store.Recorder().RecordLatency(observability.LatencySample{
		SessionID: "sess_mem", Seq: 1, RTTMs: 74.25, JitterMs: 12.5,
		Samples: 10, ServerTime: now,
	})

	deadline := time.Now().Add(2 * time.Second)
	var seen int64
	for time.Now().Before(deadline) {
		buckets, err := store.Querier().LatencyBuckets(context.Background(),
			"sess_mem", now.Add(-time.Minute), now.Add(time.Minute), time.Second)
		if err != nil {
			t.Fatalf("query: %v", err)
		}
		for _, b := range buckets {
			seen += b.Count
		}
		if seen > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if seen == 0 {
		t.Fatalf("memory driver never committed the pending sample: health=%+v", store.Health())
	}
}
