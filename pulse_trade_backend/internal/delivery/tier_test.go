package delivery_test

import (
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/delivery"
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

func testPolicy() *delivery.DefaultPolicy {
	return delivery.NewDefaultPolicy(delivery.Thresholds{
		FullMaxRTTMs:       150,
		FullMaxJitterMs:    50,
		MinimalMinRTTMs:    500,
		MinimalMinJitterMs: 150,
		DegradeStreak:      3,
		RecoverStreak:      5,
		ReportHold:         5 * time.Second,
		ReportDegrade:      10 * time.Second,
	}, 10, 2, 0.5)
}

func healthy(rtt, jitter float64, at time.Time) domain.HealthReport {
	return domain.HealthReport{RTTMs: rtt, JitterMs: jitter, Samples: 10, ReceivedAt: at}
}

// The tier machine changes tier with hysteresis.
//
// The point of the test is the shape of the response, not the exact thresholds: a
// single noisy sample must not move the tier, degrading must be quicker than
// recovering, and MINIMAL must never jump straight back to FULL.
func TestTierMachine_HysteresisTimeline(t *testing.T) {
	t.Parallel()
	clock := time.Date(2026, 9, 17, 12, 41, 3, 0, time.UTC)
	machine := delivery.NewTierMachine(testPolicy())

	if got := machine.Tier(); got != domain.TierFull {
		t.Fatalf("initial tier = %s, want FULL", got)
	}

	// One healthy report, then two unhealthy ones: still FULL, because the degrade
	// streak needs three consecutive bad reports.
	machine.Observe(healthy(80, 12, clock), clock)
	if tr := machine.Observe(healthy(210, 30, clock), clock); tr.Changed {
		t.Fatalf("a single bad report changed the tier to %s", tr.To)
	}
	if tr := machine.Observe(healthy(190, 22, clock), clock); tr.Changed {
		t.Fatalf("two bad reports changed the tier to %s", tr.To)
	}
	if got := machine.Tier(); got != domain.TierFull {
		t.Fatalf("after two bad reports tier = %s, want FULL", got)
	}

	// The third consecutive bad report degrades.
	tr := machine.Observe(healthy(175, 19, clock), clock)
	if !tr.Changed || tr.To != domain.TierDegraded {
		t.Fatalf("third bad report: changed=%v to=%s, want DEGRADED", tr.Changed, tr.To)
	}
	if tr.Reason == "" || tr.Streak == 0 {
		t.Fatalf("transition should carry a reason and the streak: %+v", tr)
	}

	// Four healthy reports are not enough to recover.
	for range 4 {
		if tr := machine.Observe(healthy(90, 15, clock), clock); tr.Changed {
			t.Fatalf("recovered after fewer than five good reports: %+v", tr)
		}
	}
	if got := machine.Tier(); got != domain.TierDegraded {
		t.Fatalf("after four good reports tier = %s, want DEGRADED", got)
	}

	// The fifth recovers.
	tr = machine.Observe(healthy(88, 14, clock), clock)
	if !tr.Changed || tr.To != domain.TierFull {
		t.Fatalf("fifth good report: changed=%v to=%s, want FULL", tr.Changed, tr.To)
	}
	if tr.Reason != domain.ReasonGoodHealth {
		t.Fatalf("recovery reason = %s, want GOOD_HEALTH", tr.Reason)
	}
}

func TestTierMachine_SingleNoisySampleDoesNotOscillate(t *testing.T) {
	t.Parallel()
	clock := time.Date(2026, 9, 17, 12, 41, 3, 0, time.UTC)
	machine := delivery.NewTierMachine(testPolicy())

	// Settle into DEGRADED.
	for range 3 {
		machine.Observe(healthy(200, 20, clock), clock)
	}
	if machine.Tier() != domain.TierDegraded {
		t.Fatalf("setup failed: tier = %s", machine.Tier())
	}

	// Alternate good and bad reports forever; the tier must stay put, because
	// neither streak ever reaches its threshold.
	for i := range 20 {
		rtt := 90.0
		if i%2 == 1 {
			rtt = 200
		}
		if tr := machine.Observe(healthy(rtt, 10, clock), clock); tr.Changed {
			t.Fatalf("oscillated on iteration %d: %+v", i, tr)
		}
	}
	if got := machine.Tier(); got != domain.TierDegraded {
		t.Fatalf("tier = %s after alternating reports, want DEGRADED", got)
	}
}

func TestTierMachine_DegradedToMinimalAndBack(t *testing.T) {
	t.Parallel()
	clock := time.Date(2026, 9, 17, 12, 41, 3, 0, time.UTC)
	machine := delivery.NewTierMachine(testPolicy())

	for range 3 {
		machine.Observe(healthy(200, 20, clock), clock)
	}

	// Three minimal-band reports take it to MINIMAL.
	for i := range 3 {
		tr := machine.Observe(healthy(600, 20, clock), clock)
		if i < 2 && tr.Changed {
			t.Fatalf("moved to MINIMAL too early on report %d", i+1)
		}
	}
	if got := machine.Tier(); got != domain.TierMinimal {
		t.Fatalf("tier = %s, want MINIMAL", got)
	}

	// MINIMAL never jumps to FULL: after five reports that are better than
	// minimal-band but still degraded, the tier becomes DEGRADED, not FULL.
	for range 5 {
		machine.Observe(healthy(300, 60, clock), clock)
	}
	if got := machine.Tier(); got != domain.TierDegraded {
		t.Fatalf("tier = %s after recovery from MINIMAL, want DEGRADED", got)
	}

	// Only then can five good reports reach FULL.
	for range 5 {
		machine.Observe(healthy(80, 10, clock), clock)
	}
	if got := machine.Tier(); got != domain.TierFull {
		t.Fatalf("tier = %s, want FULL", got)
	}
}

func TestTierMachine_MinimalToDegradedRequiresFiveReports(t *testing.T) {
	t.Parallel()
	clock := time.Date(2026, 9, 17, 12, 41, 3, 0, time.UTC)
	machine := delivery.NewTierMachine(testPolicy())

	// Go straight to MINIMAL.
	for range 3 {
		machine.Observe(healthy(200, 20, clock), clock)
	}
	for range 3 {
		machine.Observe(healthy(600, 20, clock), clock)
	}
	if machine.Tier() != domain.TierMinimal {
		t.Fatalf("setup failed: %s", machine.Tier())
	}

	// Four good reports are not enough.
	for i := range 4 {
		if tr := machine.Observe(healthy(80, 10, clock), clock); tr.Changed {
			t.Fatalf("recovered from MINIMAL after %d reports", i+1)
		}
	}
	tr := machine.Observe(healthy(80, 10, clock), clock)
	if !tr.Changed || tr.To != domain.TierDegraded {
		t.Fatalf("fifth good report: %+v, want DEGRADED", tr)
	}
	if tr.Reason != domain.ReasonRecovery {
		t.Fatalf("reason = %s, want RECOVERY", tr.Reason)
	}
}

// The watchdog degrades a connection that stops reporting.
func TestTierMachine_MissingReportFallback(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 17, 12, 41, 3, 0, time.UTC)
	policy := testPolicy()

	t.Run("holds below the hold threshold", func(t *testing.T) {
		machine := delivery.NewTierMachine(policy)
		if tr := machine.OnMissingReports(2*time.Second, now); tr.Changed {
			t.Fatalf("tier changed after 2s of silence: %+v", tr)
		}
		if machine.Tier() != domain.TierFull {
			t.Fatalf("tier = %s, want FULL", machine.Tier())
		}
	})

	t.Run("drops exactly one tier between hold and degrade", func(t *testing.T) {
		machine := delivery.NewTierMachine(policy)
		tr := machine.OnMissingReports(6*time.Second, now)
		if !tr.Changed || tr.To != domain.TierDegraded {
			t.Fatalf("6s of silence: %+v, want DEGRADED", tr)
		}
		if tr.Reason != domain.ReasonMissingReports {
			t.Fatalf("reason = %s, want MISSING_REPORTS", tr.Reason)
		}
		// A second evaluation at the same age must not move it again.
		if tr := machine.OnMissingReports(6*time.Second, now); tr.Changed {
			t.Fatalf("watchdog is not idempotent: %+v", tr)
		}
	})

	t.Run("reaches minimal beyond the degrade threshold", func(t *testing.T) {
		machine := delivery.NewTierMachine(policy)
		machine.OnMissingReports(6*time.Second, now)
		tr := machine.OnMissingReports(11*time.Second, now)
		if !tr.Changed || tr.To != domain.TierMinimal {
			t.Fatalf("11s of silence: %+v, want MINIMAL", tr)
		}
	})

	t.Run("a fresh report does not jump minimal to full", func(t *testing.T) {
		machine := delivery.NewTierMachine(policy)
		machine.OnMissingReports(11*time.Second, now)
		if machine.Tier() != domain.TierMinimal {
			t.Fatalf("setup failed: %s", machine.Tier())
		}
		for i := range 5 {
			tr := machine.Observe(healthy(70, 8, now), now)
			if tr.Changed && tr.To == domain.TierFull {
				t.Fatalf("jumped straight to FULL after %d reports", i+1)
			}
		}
		if machine.Tier() != domain.TierDegraded {
			t.Fatalf("tier = %s, want DEGRADED after recovery from a missing-report fallback", machine.Tier())
		}
	})

	t.Run("a flapping client cannot oscillate the tier", func(t *testing.T) {
		machine := delivery.NewTierMachine(policy)
		// Silence, one report, silence, one report... the recovery streak resets
		// each time the watchdog degrades, so the tier can only settle downwards.
		for range 6 {
			machine.OnMissingReports(6*time.Second, now)
			machine.Observe(healthy(70, 8, now), now)
		}
		if got := machine.Tier(); got == domain.TierFull {
			t.Fatalf("tier = %s; a flapping client should not be treated as healthy", got)
		}
	})
}

func TestTierMachine_OverrideAffectsDeliveryOnly(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 17, 12, 41, 3, 0, time.UTC)
	machine := delivery.NewTierMachine(testPolicy())

	tr := machine.Force(domain.TierMinimal, now)
	if !tr.Changed || machine.Tier() != domain.TierMinimal {
		t.Fatalf("force failed: %+v tier=%s", tr, machine.Tier())
	}
	if tr.Reason != domain.ReasonForcedOverride {
		t.Fatalf("reason = %s, want FORCED_OVERRIDE", tr.Reason)
	}

	// Reports still feed the automatic machine, but the effective tier stays pinned.
	for range 5 {
		if tr := machine.Observe(healthy(70, 8, now), now); tr.Changed {
			t.Fatalf("an override should suppress automatic transitions: %+v", tr)
		}
	}
	if machine.Tier() != domain.TierMinimal {
		t.Fatalf("tier = %s, want MINIMAL while overridden", machine.Tier())
	}
	if machine.AutoTier() != domain.TierFull {
		t.Fatalf("auto tier = %s, want FULL (the healthy reports were still observed)", machine.AutoTier())
	}

	// Clearing the override lands on the automatic tier.
	tr = machine.ClearOverride(now)
	if !tr.Changed || machine.Tier() != domain.TierFull {
		t.Fatalf("clear override: %+v tier=%s", tr, machine.Tier())
	}
}

func TestTierMachine_ReconnectResetsHealthState(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 9, 17, 12, 41, 3, 0, time.UTC)
	machine := delivery.NewTierMachine(testPolicy())
	for range 3 {
		machine.Observe(healthy(600, 200, now), now)
	}
	machine.Force(domain.TierMinimal, now)

	tr := machine.OnReconnect(now)
	if !tr.Changed || tr.To != domain.TierFull {
		t.Fatalf("reconnect: %+v, want FULL", tr)
	}
	if machine.Override() != nil {
		t.Fatal("a per-connection override must not survive a reconnect")
	}
}

func TestDefaultPolicy_Classify(t *testing.T) {
	t.Parallel()
	policy := testPolicy()
	cases := []struct {
		rtt, jitter float64
		want        domain.HealthBand
	}{
		{50, 10, domain.BandGood},
		{149, 49, domain.BandGood},
		{150, 10, domain.BandDegraded},
		{100, 50, domain.BandDegraded},
		{499, 100, domain.BandDegraded},
		{500, 10, domain.BandMinimal},
		{100, 150, domain.BandMinimal},
		{900, 400, domain.BandMinimal},
	}
	for _, tc := range cases {
		if got := policy.Classify(tc.rtt, tc.jitter); got != tc.want {
			t.Fatalf("Classify(%v, %v) = %s, want %s", tc.rtt, tc.jitter, got, tc.want)
		}
	}
}

func TestDefaultPolicy_RatesAndIntervals(t *testing.T) {
	t.Parallel()
	policy := testPolicy()
	if got := policy.TargetRate(domain.TierFull); got != 10 {
		t.Fatalf("full rate = %v, want 10", got)
	}
	if got := policy.FlushInterval(domain.TierFull); got != 100*time.Millisecond {
		t.Fatalf("full flush interval = %s, want 100ms", got)
	}
	if got := policy.FlushInterval(domain.TierMinimal); got != 2*time.Second {
		t.Fatalf("minimal flush interval = %s, want 2s", got)
	}
}
