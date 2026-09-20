package metrics_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// TestSmokeDrivesEveryRecorderMethod is the production wiring check: it opens the
// store the way cmd/server does, hands it one record of every kind the engine,
// delivery and debug layers produce, flushes, and reads each query surface. A
// method whose column list or scan order is wrong fails here rather than in a
// live session.
func TestSmokeDrivesEveryRecorderMethod(t *testing.T) {
	ctx := context.Background()
	dsn := filepath.Join(t.TempDir(), "smoke.db")
	store, err := metrics.Open(ctx, metrics.Config{
		Enabled:           true,
		Driver:            metrics.DriverSQLite,
		DSN:               dsn,
		QueueCapacity:     128,
		BatchSize:         16,
		FlushInterval:     25 * time.Millisecond,
		RetentionEnabled:  true,
		RetentionLatency:  time.Hour,
		RetentionEvents:   time.Hour,
		RetentionSessions: time.Hour,
		PruneInterval:     time.Hour,
		PruneBatch:        100,
	}, testLogger(t))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = store.Close(ctx) }()

	now := time.Now().UTC()
	disconnected := now.Add(30 * time.Second)
	rec := store.Recorder()

	rec.RecordSessionStart(observability.SessionRow{
		SessionID: "sess-smoke", DeviceID: "dev", ClientVersion: "1.0.0", Platform: "android",
		RemoteAddr: "127.0.0.1:1", Symbol: testSymbol, Interval: "1m",
		ConnectedAt: now, InitialTier: "FULL",
	})
	rec.RecordLatency(observability.LatencySample{
		SessionID: "sess-smoke", Seq: 1, RTTMs: 74.25, JitterMs: 12.5, Samples: 10,
		ServerTime: now, Capped: true, MissedPong: true,
	})
	rec.RecordHealthReport(observability.HealthReportRow{
		SessionID: "sess-smoke", ReceivedAt: now, RTTMs: 74.25, JitterMs: 12.5,
		AgeSinceLastMs: 240, Band: "GOOD",
	})
	rec.RecordTierTransition(observability.TierTransitionRow{
		SessionID: "sess-smoke", At: now, From: "FULL", To: "DEGRADED", Reason: "HIGH_RTT",
		RTTMs: 175.2, JitterMs: 19.4, Streak: 3,
	})
	rec.RecordDeliveryWindow(observability.DeliveryWindow{
		SessionID: "sess-smoke", WindowStart: now, WindowMs: 5000, Tier: "FULL", TargetRate: 10,
		CandleUpdates: 4, TradeMessages: 9, BookDeltas: 12, HealthMessages: 1,
		Coalesced: 2, Suppressed: 1, BytesSent: 4096, EffectiveRate: 5.2,
	})
	rec.RecordBookEvent(observability.BookSyncEvent{
		At: now, SessionID: "sess-smoke", Scope: observability.ScopeSession,
		Event: observability.BookEventRecoveryStarted, Epoch: 1, FromUpdateID: 10,
		ToUpdateID: 20, GapSize: 3, DurationMs: 12, Attempt: 1,
	})
	rec.RecordProtocolEvent(observability.ProtocolEvent{
		At: now, SessionID: "sess-smoke", Kind: observability.ProtocolMalformedFrame,
		Detail: "bad json", Count: 2,
	})
	rec.RecordEngineEvent(observability.EngineEvent{
		Event: "WARMUP_COMPLETE", Epoch: 1, EventIndex: 100, UpdateID: 5, TradeID: 1_000_000,
		Detail: "events=100", DurationMs: 42, At: now,
	})
	rec.RecordCandleClose(mustCandle(t, now.Truncate(time.Minute)))
	rec.RecordFaultInjection(observability.FaultInjectionRow{
		At: now, SessionID: "sess-smoke", Fault: "DROP_DELTA", Parameters: `{"rate":0.1}`, Applied: true,
	})
	rec.RecordSessionEnd(observability.SessionRow{
		SessionID: "sess-smoke", DisconnectedAt: &disconnected, DisconnectReason: "client_closed",
		FinalTier: "DEGRADED", UptimeMs: 30_000, MessagesSent: 12, MessagesReceived: 4,
		BytesSent: 2048, ProtocolErrors: 1,
	})

	if err := store.Flush(ctx); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	if got := store.QueueDepth(); got != 0 {
		t.Fatalf("QueueDepth() = %d after Flush, want 0", got)
	}
	if got := store.Dropped(); got != 0 {
		t.Fatalf("Dropped() = %d, want 0", got)
	}
	health := store.Health()
	if health.Status != metrics.StatusOK {
		t.Fatalf("Health().Status = %q (%d write failures), want ok", health.Status, health.WriteFailures)
	}
	if health.RowsWritten < 11 {
		t.Fatalf("Health().RowsWritten = %d, want at least the 11 records queued", health.RowsWritten)
	}
	if health.SchemaVersion < 1 {
		t.Fatalf("Health().SchemaVersion = %d, want at least 1", health.SchemaVersion)
	}

	summary, err := store.Querier().Summary(ctx, time.Hour)
	if err != nil {
		t.Fatalf("Summary: %v", err)
	}
	if summary.LatencySamples != 1 || summary.TotalSessions != 1 || summary.ActiveSessions != 0 {
		t.Fatalf("summary = %+v, want 1 latency sample, 1 total session, 0 active", summary)
	}
	if summary.RTT.Samples != 1 || summary.RTT.MinMs != 74.25 || summary.RTT.MaxMs != 74.25 {
		t.Fatalf("summary RTT = %+v, want the exact sample", summary.RTT)
	}
	if summary.CandlesClosed != 1 {
		t.Fatalf("summary candles=%d, want 1", summary.CandlesClosed)
	}
	if summary.Counters[observability.CounterMetricsDropped] != 0 {
		t.Fatalf("summary dropped = %d, want 0", summary.Counters[observability.CounterMetricsDropped])
	}

	buckets, err := store.Querier().LatencyBuckets(ctx, "sess-smoke", now.Add(-time.Hour), now.Add(time.Hour), time.Minute)
	if err != nil {
		t.Fatalf("LatencyBuckets: %v", err)
	}
	if len(buckets) != 1 || buckets[0].AvgJitterMs != 12.5 {
		t.Fatalf("buckets = %+v, want one bucket with jitter 12.5", buckets)
	}

	transitions, err := store.Querier().TierTransitions(ctx, now.Add(-time.Hour), now.Add(time.Hour), 10)
	if err != nil {
		t.Fatalf("TierTransitions: %v", err)
	}
	if len(transitions) != 1 || transitions[0].Reason != "HIGH_RTT" || transitions[0].Streak != 3 {
		t.Fatalf("transitions = %+v, want the recorded HIGH_RTT row", transitions)
	}

	sessions, err := store.Querier().Sessions(ctx, 10)
	if err != nil {
		t.Fatalf("Sessions: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("sessions = %d, want 1", len(sessions))
	}
	if sessions[0].FinalTier != "DEGRADED" || sessions[0].DisconnectedAt == nil {
		t.Fatalf("session = %+v, want the closed row", sessions[0])
	}

	windows, err := store.Querier().DeliveryWindows(ctx, "sess-smoke", now.Add(-time.Hour), now.Add(time.Hour), 10)
	if err != nil {
		t.Fatalf("DeliveryWindows: %v", err)
	}
	if len(windows) != 1 || windows[0].EffectiveRate != 5.2 || windows[0].Coalesced != 2 {
		t.Fatalf("windows = %+v, want the recorded window", windows)
	}

	// The SQLite driver's own pruning must accept the store's retention config.
	if got := store.RowsPruned(); got != 0 {
		t.Fatalf("RowsPruned() = %d before any prune, want 0", got)
	}
}

// Compile-time proof of the interfaces the rest of the system depends on. The
// engine declares market.Recorder itself, so the assertion lives here rather than
// in the metrics package: importing market from metrics would invert the
// dependency rule.
var (
	_ metrics.Recorder = (*metrics.Store)(nil)
	_ metrics.Querier  = (*metrics.Store)(nil)
	_ market.Recorder  = (*metrics.Store)(nil)
)
