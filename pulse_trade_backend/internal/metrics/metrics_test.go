package metrics_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/metrics/sqlite"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// TestOpenDisabledStoreIsInert covers the "metrics off" contract: the rest of the
// system must keep working, so every write is a no-op, every read is empty, and
// health says so explicitly rather than reporting a healthy store that is not
// storing anything.
func TestOpenDisabledStoreIsInert(t *testing.T) {
	store, err := metrics.Open(context.Background(), metrics.Config{Enabled: false, Driver: metrics.DriverSQLite, DSN: "/nonexistent/metrics.db"}, testLogger(t))
	if err != nil {
		t.Fatalf("Open(disabled): %v", err)
	}
	defer func() { _ = store.Close(context.Background()) }()

	// These must not panic even though no database exists.
	store.Recorder().RecordLatency(sampleLatency)
	store.Recorder().RecordSessionStart(observability.SessionRow{SessionID: "x"})
	store.Recorder().RecordCandleClose(mustCandle(t, time.Now().UTC()))

	if got := store.Health().Status; got != metrics.StatusDisabled {
		t.Fatalf("Health().Status = %q, want %q", got, metrics.StatusDisabled)
	}
	if got := store.Health().Driver; got != metrics.DriverSQLite {
		t.Fatalf("Health().Driver = %q, want %q", got, metrics.DriverSQLite)
	}
	if got := store.Dropped(); got != 0 {
		t.Fatalf("Dropped() = %d, want 0 for a disabled store", got)
	}

	summary, err := store.Querier().Summary(context.Background(), time.Hour)
	if err != nil {
		t.Fatalf("Summary(disabled): %v", err)
	}
	if summary.LatencySamples != 0 || summary.TotalSessions != 0 {
		t.Fatalf("disabled summary should be empty, got %+v", summary)
	}
	buckets, err := store.Querier().LatencyBuckets(context.Background(), "", time.Time{}, time.Time{}, time.Second)
	if err != nil {
		t.Fatalf("LatencyBuckets(disabled): %v", err)
	}
	if len(buckets) != 0 {
		t.Fatalf("disabled LatencyBuckets returned %d buckets, want 0", len(buckets))
	}
	if err := store.Flush(context.Background()); err != nil {
		t.Fatalf("Flush(disabled): %v", err)
	}
}

// TestOpenRejectsUnknownDriver proves a configuration mistake fails at startup
// rather than silently degrading into a store that records nothing.
func TestOpenRejectsUnknownDriver(t *testing.T) {
	_, err := metrics.Open(context.Background(), metrics.Config{Enabled: true, Driver: "postgres", DSN: "x"}, testLogger(t))
	if err == nil {
		t.Fatal("Open with an unregistered driver should fail")
	}
	_, err = metrics.Open(context.Background(), metrics.Config{Enabled: true, Driver: metrics.DriverSQLite}, testLogger(t))
	if err == nil {
		t.Fatal("Open(sqlite) without a DSN should fail")
	}
}

// TestRecordNeverBlocks proves the queue is bounded, overflow drops the
// oldest record, the drop is counted, and no producer ever waits.
func TestRecordNeverBlocks(t *testing.T) {
	dsn := filepath.Join(t.TempDir(), "overflow.db")
	store, err := metrics.Open(context.Background(), metrics.Config{
		Enabled: true, Driver: metrics.DriverSQLite, DSN: dsn,
		QueueCapacity: 32,
		BatchSize:     8,
		// A long interval keeps the writer from draining during the burst.
		FlushInterval: time.Hour,
	}, testLogger(t))
	if err != nil {
		t.Fatalf("Open(sqlite): %v", err)
	}
	defer func() { _ = store.Close(context.Background()) }()

	const burst = 10 * 32
	start := time.Now()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < burst; i++ {
			store.Recorder().RecordEngineEvent(observability.EngineEvent{
				Event: "PAUSE",
				At:    time.Now().UTC(),
			})
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("RecordEngineEvent blocked: a producer waited on the metrics store")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("recording %d records took %s; the producer path is not non-blocking", burst, elapsed)
	}
	if got := store.Dropped(); got == 0 {
		t.Fatal("Dropped() = 0 after a burst of 10x capacity, want > 0")
	}
	// Recording must keep working after overflow.
	store.Recorder().RecordEngineEvent(observability.EngineEvent{Event: "RESUME", At: time.Now().UTC()})
	if got := store.Health().Status; got != metrics.StatusOK {
		t.Fatalf("Health().Status = %q, want %q: overflow is not a write failure", got, metrics.StatusOK)
	}
}

// TestWriteFailureDegradesWithoutBlocking proves a store whose database
// starts failing is reported as degraded, counts the failures, and keeps accepting
// records without blocking or panicking.
func TestWriteFailureDegradesWithoutBlocking(t *testing.T) {
	dsn := filepath.Join(t.TempDir(), "degrade.db")
	store, err := metrics.Open(context.Background(), metrics.Config{
		Enabled: true, Driver: metrics.DriverSQLite, DSN: dsn,
		QueueCapacity: 64, BatchSize: 8, FlushInterval: 10 * time.Millisecond,
	}, testLogger(t))
	if err != nil {
		t.Fatalf("Open(sqlite): %v", err)
	}
	defer func() { _ = store.Close(context.Background()) }()
	ctx := context.Background()

	store.Recorder().RecordEngineEvent(observability.EngineEvent{Event: "START", At: time.Now().UTC()})
	if err := store.Flush(ctx); err != nil {
		t.Fatalf("Flush on a healthy store: %v", err)
	}
	if got := store.Health().Status; got != metrics.StatusOK {
		t.Fatalf("Health().Status = %q before the failure, want %q", got, metrics.StatusOK)
	}

	// Break the writer's target table on a second connection to the same file.
	breaker, err := sqlite.Open(ctx, dsn)
	if err != nil {
		t.Fatalf("sqlite.Open(breaker): %v", err)
	}
	defer func() { _ = breaker.Close() }()
	if err := breaker.ForceWriteFailureForTest(ctx, "engine_events"); err != nil {
		t.Fatalf("ForceWriteFailureForTest: %v", err)
	}

	start := time.Now()
	for i := 0; i < 256; i++ {
		store.Recorder().RecordEngineEvent(observability.EngineEvent{
			Event: "BURST_START", Detail: "post-failure record", At: time.Now().UTC(),
		})
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("recording into a failing store took %s; it must not block", elapsed)
	}
	if err := store.Flush(ctx); err != nil {
		t.Logf("Flush surfaced the write failure: %v", err)
	}

	health := store.Health()
	if health.Status != metrics.StatusDegraded {
		t.Fatalf("Health().Status = %q, want %q after failed writes", health.Status, metrics.StatusDegraded)
	}
	if health.WriteFailures == 0 {
		t.Fatal("Health().WriteFailures = 0, want > 0")
	}

	// The store must still accept records after failing, without blocking.
	producerStart := time.Now()
	for i := 0; i < 512; i++ {
		store.Recorder().RecordSessionStart(observability.SessionRow{
			SessionID: "sess-after-failure", Symbol: testSymbol, Interval: "1m",
			ConnectedAt: time.Now().UTC(), InitialTier: "FULL",
		})
	}
	if elapsed := time.Since(producerStart); elapsed > 2*time.Second {
		t.Fatalf("recording after degradation took %s; it must not block", elapsed)
	}
	if err := store.Flush(ctx); err != nil {
		t.Logf("Flush after degradation: %v", err)
	}
}

// TestCloseDrainsQueue proves records queued immediately before Close are
// not lost.
//
// The two drivers prove it differently, and the test asserts the stronger form
// each one can offer: the durable driver is reopened and the rows are read back
// from the file, while the synchronous driver is inspected before Close because
// its writes are already durable by then.
func TestCloseDrainsQueue(t *testing.T) {
	const rows = 100
	base := sampleLatency.ServerTime

	t.Run(metrics.DriverSQLite, func(t *testing.T) {
		dsn := filepath.Join(t.TempDir(), "close.db")
		store, err := metrics.Open(context.Background(), metrics.Config{
			Enabled: true, Driver: metrics.DriverSQLite, DSN: dsn,
			QueueCapacity: 512, BatchSize: 8, FlushInterval: time.Hour,
		}, testLogger(t))
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		seedSession(store, "sess-close", base)
		for i := 0; i < rows; i++ {
			store.Recorder().RecordLatency(observability.LatencySample{
				SessionID: "sess-close", Seq: int64(i), RTTMs: 10 + float64(i), JitterMs: 1,
				Samples: 10, ServerTime: base.Add(time.Duration(i) * time.Millisecond),
			})
		}

		// Close must drain without the caller flushing first.
		if err := store.Close(context.Background()); err != nil {
			t.Fatalf("Close: %v", err)
		}
		if got := store.Dropped(); got != 0 {
			t.Fatalf("Dropped() = %d, want 0: Close lost queued records", got)
		}

		// Reopening the same file is the durable proof: the rows are on disk.
		repo, err := sqlite.Open(context.Background(), dsn)
		if err != nil {
			t.Fatalf("reopen: %v", err)
		}
		defer func() { _ = repo.Close() }()
		n, err := repo.CountRowsForTest(context.Background(), "latency_samples")
		if err != nil {
			t.Fatalf("count latency_samples: %v", err)
		}
		if n != rows {
			t.Fatalf("database holds %d latency rows after Close, want %d", n, rows)
		}
	})

	t.Run(metrics.DriverMemory, func(t *testing.T) {
		store, err := metrics.Open(context.Background(), metrics.Config{
			Enabled: true, Driver: metrics.DriverMemory,
			QueueCapacity: 512, BatchSize: 8, FlushInterval: time.Hour,
		}, testLogger(t))
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		seedSession(store, "sess-close", base)
		for i := 0; i < rows; i++ {
			store.Recorder().RecordLatency(observability.LatencySample{
				SessionID: "sess-close", Seq: int64(i), RTTMs: 10 + float64(i), JitterMs: 1,
				Samples: 10, ServerTime: base.Add(time.Duration(i) * time.Millisecond),
			})
		}
		// Nothing may be lost. The writer may already have committed part of the
		// burst (which is fine), so the invariant is that queued plus written
		// covers every record and nothing was dropped.
		if got := store.Dropped(); got != 0 {
			t.Fatalf("Dropped() = %d before Close, want 0", got)
		}
		if err := store.Close(context.Background()); err != nil {
			t.Fatalf("Close: %v", err)
		}
		if got := store.Health().RowsWritten; got < rows {
			t.Fatalf("RowsWritten = %d after Close, want >= %d", got, rows)
		}
		if got := store.Dropped(); got != 0 {
			t.Fatalf("Dropped() = %d after Close, want 0", got)
		}
	})
}

// TestSummaryComputesRealAggregates proves count, min, avg, p95 and max
// are computed from the values, not estimated.
func TestSummaryComputesRealAggregates(t *testing.T) {
	for _, driver := range drivers() {
		t.Run(driver, func(t *testing.T) {
			store := newTestStore(t, metrics.Config{Driver: driver, QueueCapacity: 1024, FlushInterval: time.Hour})
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Second)
			seedSession(store, "sess-summary", now.Add(-time.Minute))

			// 1..100 ms, so every statistic has a value that can be recomputed.
			// By hand: min 1, max 100, avg 50.5, p95 95.
			for i := 1; i <= 100; i++ {
				store.Recorder().RecordLatency(observability.LatencySample{
					SessionID:  "sess-summary",
					Seq:        int64(i),
					RTTMs:      float64(i),
					JitterMs:   2,
					Samples:    10,
					ServerTime: now.Add(-time.Duration(i) * time.Millisecond),
				})
			}
			store.Recorder().RecordTierTransition(observability.TierTransitionRow{
				SessionID: "sess-summary", At: now.Add(-time.Second),
				From: "FULL", To: "DEGRADED", Reason: "HIGH_RTT",
			})
			store.Recorder().RecordProtocolEvent(observability.ProtocolEvent{
				At: now.Add(-time.Second), SessionID: "sess-summary",
				Kind: observability.ProtocolMalformedFrame, Count: 3,
			})
			store.Recorder().RecordBookEvent(observability.BookSyncEvent{
				At: now.Add(-time.Second), Scope: observability.ScopeSession,
				SessionID: "sess-summary", Event: observability.BookEventGapDetected, GapSize: 4,
			})
			store.Recorder().RecordBookEvent(observability.BookSyncEvent{
				At: now.Add(-time.Second), Scope: observability.ScopeSession,
				SessionID: "sess-summary", Event: observability.BookEventRecoveryStarted,
			})
			if err := store.Flush(ctx); err != nil {
				t.Fatalf("Flush: %v", err)
			}

			summary, err := store.Querier().Summary(ctx, time.Hour)
			if err != nil {
				t.Fatalf("Summary: %v", err)
			}
			if summary.RTT.Samples != 100 {
				t.Fatalf("RTT.Samples = %d, want 100", summary.RTT.Samples)
			}
			if summary.RTT.MinMs != 1 {
				t.Fatalf("RTT.MinMs = %v, want 1", summary.RTT.MinMs)
			}
			if summary.RTT.MaxMs != 100 {
				t.Fatalf("RTT.MaxMs = %v, want 100", summary.RTT.MaxMs)
			}
			if summary.RTT.AvgMs != 50.5 {
				t.Fatalf("RTT.AvgMs = %v, want 50.5", summary.RTT.AvgMs)
			}
			if summary.RTT.P95Ms != 95 {
				t.Fatalf("RTT.P95Ms = %v, want 95 (nearest rank)", summary.RTT.P95Ms)
			}
			if summary.JitterMs != 2 {
				t.Fatalf("JitterMs = %v, want 2", summary.JitterMs)
			}
			if summary.ActiveSessions != 1 || summary.TotalSessions != 1 {
				t.Fatalf("sessions: active=%d total=%d, want 1/1", summary.ActiveSessions, summary.TotalSessions)
			}
			if summary.TierDistribution["FULL"] != 1 {
				t.Fatalf("TierDistribution = %v, want FULL:1", summary.TierDistribution)
			}
			if summary.TierTransitions != 1 {
				t.Fatalf("TierTransitions = %d, want 1", summary.TierTransitions)
			}
			if summary.MalformedMessages != 3 {
				t.Fatalf("MalformedMessages = %d, want 3 (the event's count)", summary.MalformedMessages)
			}
			if summary.BookGapsDetected != 1 || summary.BookRecoveries != 1 {
				t.Fatalf("book counters: gaps=%d recoveries=%d, want 1/1",
					summary.BookGapsDetected, summary.BookRecoveries)
			}
			if summary.LatencySamples != 100 {
				t.Fatalf("LatencySamples = %d, want 100", summary.LatencySamples)
			}
			if summary.Counters[observability.CounterMetricsDropped] != store.Dropped() {
				t.Fatalf("summary dropped counter %d != Dropped() %d",
					summary.Counters[observability.CounterMetricsDropped], store.Dropped())
			}
		})
	}
}

// TestLatencyBucketsGroupByTime proves bucketing places samples in the right
// windows and keeps the per-bucket statistics separate.
func TestLatencyBucketsGroupByTime(t *testing.T) {
	for _, driver := range drivers() {
		t.Run(driver, func(t *testing.T) {
			store := newTestStore(t, metrics.Config{Driver: driver})
			ctx := context.Background()
			base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
			seedSession(store, "sess-buckets", base)

			// Three samples in bucket 0 (12:00:00-12:00:05), two in bucket 1.
			for i, rtt := range []float64{10, 20, 30} {
				store.Recorder().RecordLatency(observability.LatencySample{
					SessionID: "sess-buckets", Seq: int64(i), RTTMs: rtt, JitterMs: 1,
					Samples: 10, ServerTime: base.Add(time.Duration(i) * time.Second),
				})
			}
			for i, rtt := range []float64{100, 200} {
				store.Recorder().RecordLatency(observability.LatencySample{
					SessionID: "sess-buckets", Seq: int64(10 + i), RTTMs: rtt, JitterMs: 1,
					Samples: 10, ServerTime: base.Add(5*time.Second + time.Duration(i)*time.Second),
				})
			}
			// A sample for another session must not leak into this series.
			seedSession(store, "sess-other", base)
			store.Recorder().RecordLatency(observability.LatencySample{
				SessionID: "sess-other", Seq: 1, RTTMs: 9999, JitterMs: 1,
				Samples: 10, ServerTime: base.Add(time.Second),
			})
			if err := store.Flush(ctx); err != nil {
				t.Fatalf("Flush: %v", err)
			}

			buckets, err := store.Querier().LatencyBuckets(ctx, "sess-buckets", base, base.Add(time.Minute), 5*time.Second)
			if err != nil {
				t.Fatalf("LatencyBuckets: %v", err)
			}
			if len(buckets) != 2 {
				t.Fatalf("got %d buckets, want 2: %+v", len(buckets), buckets)
			}
			if buckets[0].Count != 3 || buckets[0].MinMs != 10 || buckets[0].MaxMs != 30 || buckets[0].AvgMs != 20 {
				t.Fatalf("bucket 0 = %+v, want count 3 min 10 max 30 avg 20", buckets[0])
			}
			if buckets[1].Count != 2 || buckets[1].MinMs != 100 || buckets[1].MaxMs != 200 || buckets[1].AvgMs != 150 {
				t.Fatalf("bucket 1 = %+v, want count 2 min 100 max 200 avg 150", buckets[1])
			}
			if !buckets[1].Start.Equal(base.Add(5 * time.Second)) {
				t.Fatalf("bucket 1 start = %s, want %s", buckets[1].Start, base.Add(5*time.Second))
			}
		})
	}
}

// TestSessionLifecycleRoundTrips proves start/end produce one row with the close
// half applied, which is what the diagnostics session list reads.
func TestSessionLifecycleRoundTrips(t *testing.T) {
	for _, driver := range drivers() {
		t.Run(driver, func(t *testing.T) {
			store := newTestStore(t, metrics.Config{Driver: driver})
			ctx := context.Background()
			connectedAt := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
			disconnectedAt := connectedAt.Add(42 * time.Second)

			store.Recorder().RecordSessionStart(observability.SessionRow{
				SessionID: "sess-life", DeviceID: "dev-9", ClientVersion: "1.0.0", Platform: "android",
				RemoteAddr: "10.0.0.5:5555", Symbol: testSymbol, Interval: "1m",
				ConnectedAt: connectedAt, InitialTier: "FULL",
			})
			store.Recorder().RecordSessionEnd(observability.SessionRow{
				SessionID: "sess-life", DisconnectedAt: &disconnectedAt, DisconnectReason: "client_closed",
				FinalTier: "DEGRADED", UptimeMs: 42_000, MessagesSent: 17, MessagesReceived: 3,
				BytesSent: 4096, ProtocolErrors: 1,
			})
			if err := store.Flush(ctx); err != nil {
				t.Fatalf("Flush: %v", err)
			}

			rows, err := store.Querier().Sessions(ctx, 10)
			if err != nil {
				t.Fatalf("Sessions: %v", err)
			}
			if len(rows) != 1 {
				t.Fatalf("got %d session rows, want 1", len(rows))
			}
			got := rows[0]
			if got.SessionID != "sess-life" || got.DeviceID != "dev-9" || got.Platform != "android" {
				t.Fatalf("session identity lost: %+v", got)
			}
			if got.DisconnectedAt == nil || !got.DisconnectedAt.Equal(disconnectedAt) {
				t.Fatalf("DisconnectedAt = %v, want %s", got.DisconnectedAt, disconnectedAt)
			}
			if got.DisconnectReason != "client_closed" || got.FinalTier != "DEGRADED" {
				t.Fatalf("close fields lost: %+v", got)
			}
			if got.MessagesSent != 17 || got.BytesSent != 4096 || got.ProtocolErrors != 1 {
				t.Fatalf("session counters lost: %+v", got)
			}
			if !got.ConnectedAt.Equal(connectedAt) {
				t.Fatalf("ConnectedAt = %s, want %s", got.ConnectedAt, connectedAt)
			}
		})
	}
}

// TestCandleCloseStoresExactDecimalStrings proves the audit trail keeps prices as
// exact decimal text produced by the symbol's formatters, not as floats. It drives
// the repository directly so the assertion is about the stored text.
func TestCandleCloseStoresExactDecimalStrings(t *testing.T) {
	ctx := context.Background()
	repo, err := sqlite.Open(ctx, filepath.Join(t.TempDir(), "candles.db"))
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer func() { _ = repo.Close() }()

	candle := mustCandle(t, time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC))
	sym, err := domain.Lookup(testSymbol)
	if err != nil {
		t.Fatalf("domain.Lookup: %v", err)
	}
	closedAt := candle.StartTime.Add(time.Minute)
	if err := repo.WriteBatch(ctx, metrics.Batch{
		CandleClose: []metrics.CandleCloseRow{{
			Symbol:     candle.Symbol,
			Interval:   string(candle.Interval),
			StartTime:  candle.StartTime,
			Open:       sym.FormatPrice(candle.Open),
			High:       sym.FormatPrice(candle.High),
			Low:        sym.FormatPrice(candle.Low),
			Close:      sym.FormatPrice(candle.Close),
			Volume:     sym.FormatQty(candle.Volume),
			TradeCount: int64(candle.TradeCount),
			ClosedAt:   closedAt,
			Epoch:      1,
		}},
	}); err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}

	var (
		open, high, low, closeStr, volume string
		interval, symbol                  string
		startTime                         string
		tradeCount                        int64
	)
	if err := repo.QueryRowForTest(ctx,
		`SELECT symbol, interval, start_time, open, high, low, close, volume, trade_count FROM candle_closes`,
		&symbol, &interval, &startTime, &open, &high, &low, &closeStr, &volume, &tradeCount,
	); err != nil {
		t.Fatalf("read candle_closes: %v", err)
	}

	if symbol != candle.Symbol || interval != string(candle.Interval) {
		t.Fatalf("candle identity = %s/%s, want %s/%s", symbol, interval, candle.Symbol, candle.Interval)
	}
	// The driver normalises a whole-second RFC3339 value by dropping the ".000",
	// which changes the TEXT but not the instant. The value that matters is that
	// the timestamp is UTC and unchanged.
	parsedStart, err := time.Parse(time.RFC3339, startTime)
	if err != nil {
		t.Fatalf("start_time = %q, which is not RFC3339: %v", startTime, err)
	}
	if !parsedStart.Equal(candle.StartTime) {
		t.Fatalf("start_time = %s, want %s", parsedStart, candle.StartTime)
	}
	if open != sym.FormatPrice(candle.Open) || closeStr != sym.FormatPrice(candle.Close) {
		t.Fatalf("open/close = %s/%s, want %s/%s", open, closeStr, sym.FormatPrice(candle.Open), sym.FormatPrice(candle.Close))
	}
	if high != sym.FormatPrice(candle.High) || low != sym.FormatPrice(candle.Low) {
		t.Fatalf("high/low = %s/%s, want %s/%s", high, low, sym.FormatPrice(candle.High), sym.FormatPrice(candle.Low))
	}
	if volume != sym.FormatQty(candle.Volume) {
		t.Fatalf("volume = %s, want %s", volume, sym.FormatQty(candle.Volume))
	}
	if tradeCount != int64(candle.TradeCount) {
		t.Fatalf("trade_count = %d, want %d", tradeCount, candle.TradeCount)
	}
	if open != "67421.35" || volume != "0.18400000" {
		t.Fatalf("decimal rendering = %s/%s, want 67421.35/0.18400000", open, volume)
	}
}

// TestRetentionPrunesOldRows proves retention removes old rows in
// bounded batches and leaves recent rows alone.
func TestRetentionPrunesOldRows(t *testing.T) {
	ctx := context.Background()
	repo, err := sqlite.Open(ctx, filepath.Join(t.TempDir(), "retention.db"))
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	defer func() { _ = repo.Close() }()

	now := time.Now().UTC().Truncate(time.Second)
	oldSession := observability.SessionRow{
		SessionID: "sess-old", Symbol: testSymbol, Interval: "1m",
		ConnectedAt: now.Add(-4 * time.Hour), InitialTier: "FULL",
	}
	// Write the fixture rows through the repository so the prune test is about
	// pruning alone.
	const oldRows, newRows = 5, 3
	var seed []observability.LatencySample
	for i := 0; i < oldRows; i++ {
		seed = append(seed, observability.LatencySample{
			SessionID: "sess-old", Seq: int64(i), RTTMs: 5, JitterMs: 1, Samples: 4,
			ServerTime: now.Add(-2 * time.Hour).Add(time.Duration(i) * time.Millisecond),
		})
	}
	for i := 0; i < newRows; i++ {
		seed = append(seed, observability.LatencySample{
			SessionID: "sess-old", Seq: int64(oldRows + i), RTTMs: 5, JitterMs: 1, Samples: 4,
			ServerTime: now.Add(-time.Minute).Add(time.Duration(i) * time.Millisecond),
		})
	}
	if err := repo.WriteBatch(ctx, metrics.Batch{
		Sessions: []metrics.SessionWrite{{Row: oldSession}},
		Latency:  seed,
	}); err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}

	ret := sqlite.Retention{Enabled: true, Latency: time.Hour, Events: time.Hour, Sessions: time.Hour}
	result, err := repo.Prune(ctx, now, ret, 2) // batch of 2 forces the batching loop to iterate
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	if result.Total == 0 {
		t.Fatal("Prune removed nothing, want the old rows deleted")
	}
	if got := result.Rows["latency_samples"]; got != oldRows {
		t.Fatalf("pruned %d latency rows, want %d", got, oldRows)
	}

	remaining, err := repo.CountRowsForTest(ctx, "latency_samples")
	if err != nil {
		t.Fatalf("count latency_samples: %v", err)
	}
	if remaining != newRows {
		t.Fatalf("kept %d rows, want %d (retention deleted too much)", remaining, newRows)
	}

	// A disabled retention must not delete anything.
	before, err := repo.CountRowsForTest(ctx, "latency_samples")
	if err != nil {
		t.Fatalf("count latency_samples: %v", err)
	}
	if _, err := repo.Prune(ctx, now, sqlite.Retention{Enabled: false}, 2); err != nil {
		t.Fatalf("Prune(disabled): %v", err)
	}
	after, err := repo.CountRowsForTest(ctx, "latency_samples")
	if err != nil {
		t.Fatalf("count latency_samples: %v", err)
	}
	if after != before {
		t.Fatalf("disabled retention deleted rows: %d -> %d", before, after)
	}

	// The old session is pruned too: retention keys sessions on disconnect time,
	// and a row with no disconnect is never removed.
	if _, err := repo.Prune(ctx, now, ret, 2); err != nil {
		t.Fatalf("Prune(second pass): %v", err)
	}
	sessions, err := repo.CountRowsForTest(ctx, "sessions")
	if err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if sessions != 1 {
		t.Fatalf("sessions = %d, want 1: an in-flight session must never be pruned", sessions)
	}
}

// TestRetentionRunsOnItsOwnTimer proves the store actually schedules retention:
// a record older than the configured window disappears without any test calling
// Prune, and the pruned-row counter reports it.
func TestRetentionRunsOnItsOwnTimer(t *testing.T) {
	ctx := context.Background()
	dsn := filepath.Join(t.TempDir(), "auto-prune.db")
	store, err := metrics.Open(ctx, metrics.Config{
		Enabled: true, Driver: metrics.DriverSQLite, DSN: dsn,
		QueueCapacity: 128, BatchSize: 8, FlushInterval: 10 * time.Millisecond,
		RetentionEnabled:  true,
		RetentionLatency:  time.Hour,
		RetentionEvents:   time.Hour,
		RetentionSessions: time.Hour,
		PruneInterval:     25 * time.Millisecond,
		PruneBatch:        50,
	}, testLogger(t))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = store.Close(ctx) }()

	now := time.Now().UTC()
	seedSession(store, "sess-old", now.Add(-3*time.Hour))
	store.Recorder().RecordLatency(observability.LatencySample{
		SessionID: "sess-old", Seq: 1, RTTMs: 5, JitterMs: 1, Samples: 4,
		ServerTime: now.Add(-2 * time.Hour),
	})
	if err := store.Flush(ctx); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	if got := store.RowsPruned(); got != 0 {
		t.Fatalf("RowsPruned() = %d before the timer fires, want 0", got)
	}

	// Bounded polling, no sleeps: the pruning timer is the only thing that can
	// change the counter.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if store.RowsPruned() > 0 {
			break
		}
		select {
		case <-time.After(10 * time.Millisecond):
		}
	}
	if got := store.RowsPruned(); got == 0 {
		t.Fatal("RowsPruned() = 0 after the prune interval elapsed, want > 0")
	}

	buckets, err := store.Querier().LatencyBuckets(ctx, "sess-old", now.Add(-24*time.Hour), now.Add(time.Hour), time.Hour)
	if err != nil {
		t.Fatalf("LatencyBuckets: %v", err)
	}
	if len(buckets) != 0 {
		t.Fatalf("old latency rows survived retention: %+v", buckets)
	}
}

// TestOpenCreatesMissingParentDirectory covers the default configuration: the
// shipped DSN is ./data/pulsetrade.db and a fresh checkout has no data directory,
// so the store creates it rather than making the default a startup failure.
func TestOpenCreatesMissingParentDirectory(t *testing.T) {
	base := t.TempDir()
	dsn := filepath.Join(base, "nested", "deeper", "metrics.db")
	if _, err := os.Stat(filepath.Dir(dsn)); !os.IsNotExist(err) {
		t.Fatalf("precondition: %s should not exist", filepath.Dir(dsn))
	}
	store, err := metrics.Open(context.Background(), metrics.Config{
		Enabled: true, Driver: metrics.DriverSQLite, DSN: dsn,
	}, testLogger(t))
	if err != nil {
		t.Fatalf("Open with a missing parent directory: %v", err)
	}
	defer func() { _ = store.Close(context.Background()) }()
	if store.Health().SchemaVersion < 1 {
		t.Fatalf("SchemaVersion = %d, want at least 1", store.Health().SchemaVersion)
	}
	if _, err := os.Stat(dsn); err != nil {
		t.Fatalf("database file was not created: %v", err)
	}
}
