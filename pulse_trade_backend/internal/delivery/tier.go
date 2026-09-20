// Package delivery turns canonical market events into per-connection delivery. It
// owns session state, the delivery tier of each connection, coalescing, scheduling
// and the socket write path. It never writes canonical market state.
package delivery

import (
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// Thresholds is the tunable part of the tier policy. It travels to the client in
// the welcome frame so the app can display the backend's real numbers instead of
// keeping its own copy.
type Thresholds struct {
	FullMaxRTTMs       float64
	FullMaxJitterMs    float64
	MinimalMinRTTMs    float64
	MinimalMinJitterMs float64
	DegradeStreak      int
	RecoverStreak      int
	ReportHold         time.Duration
	ReportDegrade      time.Duration
}

// Policy decides how a health sample maps onto a band and a tier. It is an
// interface so thresholds can be tuned per environment and swapped in tests
// without touching the state machine that uses them.
type Policy interface {
	Classify(rttMs, jitterMs float64) domain.HealthBand
	Thresholds() Thresholds
	TargetRate(tier domain.DeliveryTier) float64
	FlushInterval(tier domain.DeliveryTier) time.Duration
}

// DefaultPolicy implements the documented thresholds: FULL below 150ms/50ms,
// MINIMAL at or above 500ms/150ms, DEGRADED in between.
type DefaultPolicy struct {
	thresholds Thresholds
	rates      map[domain.DeliveryTier]float64
}

// NewDefaultPolicy builds the production policy.
func NewDefaultPolicy(t Thresholds, fullRate, degradedRate, minimalRate float64) *DefaultPolicy {
	return &DefaultPolicy{
		thresholds: t,
		rates: map[domain.DeliveryTier]float64{
			domain.TierFull:     fullRate,
			domain.TierDegraded: degradedRate,
			domain.TierMinimal:  minimalRate,
		},
	}
}

// Classify maps one sample onto a health band.
//
// The bands are deliberately ordered from best to worst and use "or" rather than
// "and" for the bad conditions: a connection with low latency but wild jitter is
// not a good connection.
func (p *DefaultPolicy) Classify(rttMs, jitterMs float64) domain.HealthBand {
	switch {
	case rttMs >= p.thresholds.MinimalMinRTTMs || jitterMs >= p.thresholds.MinimalMinJitterMs:
		return domain.BandMinimal
	case rttMs >= p.thresholds.FullMaxRTTMs || jitterMs >= p.thresholds.FullMaxJitterMs:
		return domain.BandDegraded
	default:
		return domain.BandGood
	}
}

// Thresholds returns the configured thresholds.
func (p *DefaultPolicy) Thresholds() Thresholds { return p.thresholds }

// TargetRate returns the tier's chart-update ceiling per second. The actual rate
// can be lower when the market is quiet; inventing events to hit a target would
// make the data a lie.
func (p *DefaultPolicy) TargetRate(tier domain.DeliveryTier) float64 {
	if rate, ok := p.rates[tier]; ok && rate > 0 {
		return rate
	}
	return 1
}

// FlushInterval is the inverse of the target rate: how long the delivery loop
// waits between flushes at this tier.
func (p *DefaultPolicy) FlushInterval(tier domain.DeliveryTier) time.Duration {
	rate := p.TargetRate(tier)
	return time.Duration(float64(time.Second) / rate)
}

// TierMachine is the adaptive delivery state machine.
//
// It is pure: no clock, no channels, no I/O, no logging. That is what makes the
// hysteresis rules exhaustively testable, and it keeps the decision separate from
// the side effects a transition causes (retuning the scheduler, notifying the
// client, persisting the row).
type TierMachine struct {
	policy Policy

	// autoTier is what the automatic rules currently produce. It keeps evolving
	// while an override is active, so clearing the override lands on a tier that
	// reflects the recent health samples rather than a stale one.
	autoTier domain.DeliveryTier
	// tier is the effective tier, which equals autoTier unless overridden.
	tier     domain.DeliveryTier
	override *domain.DeliveryTier

	goodStreak     int // consecutive GOOD reports
	badStreak      int // consecutive DEGRADED_BAND-or-worse reports
	minimalStreak  int // consecutive MINIMAL_BAND reports
	recoveryStreak int // consecutive reports better than MINIMAL_BAND

	// watchdogApplied tracks whether this silence episode has already been acted
	// on. Without it, re-evaluating the same report age would walk the tier down
	// one step per evaluation, which is not what "degrade one tier" means.
	watchdogApplied bool

	reason domain.TierReason
}

// NewTierMachine starts every connection at FULL, which is the honest default: the
// client has not reported anything yet, and the first reports arrive within two
// seconds.
func NewTierMachine(policy Policy) *TierMachine {
	return &TierMachine{
		policy:   policy,
		autoTier: domain.TierFull,
		tier:     domain.TierFull,
		reason:   domain.ReasonInitialAssignment,
	}
}

// Tier returns the effective delivery tier.
func (m *TierMachine) Tier() domain.DeliveryTier { return m.tier }

// AutoTier returns the tier the automatic rules would choose.
func (m *TierMachine) AutoTier() domain.DeliveryTier { return m.autoTier }

// Override returns the forced tier, if any.
func (m *TierMachine) Override() *domain.DeliveryTier { return m.override }

// Reason returns the reason for the current tier.
func (m *TierMachine) Reason() domain.TierReason { return m.reason }

// Streak returns the streak behind the current tier, for diagnostics and for the
// persisted transition row. Reporting the wrong counter would make the hysteresis
// behaviour impossible to explain after the fact.
func (m *TierMachine) Streak() int {
	switch m.reason {
	case domain.ReasonHighRTT, domain.ReasonHighJitter:
		if m.autoTier == domain.TierMinimal {
			return m.minimalStreak
		}
		return m.badStreak
	case domain.ReasonGoodHealth:
		return m.goodStreak
	case domain.ReasonRecovery:
		return m.recoveryStreak
	default:
		return 0
	}
}

// Observe applies one health report.
//
// Transition rules (asymmetric on purpose: degrade quickly, recover slowly):
//
//	FULL -> DEGRADED after DegradeStreak consecutive reports at DEGRADED_BAND or worse
//	DEGRADED -> MINIMAL after DegradeStreak consecutive MINIMAL_BAND reports
//	DEGRADED -> FULL after RecoverStreak consecutive GOOD reports
//	MINIMAL -> DEGRADED after RecoverStreak consecutive reports better than MINIMAL_BAND
//	MINIMAL -> FULL never directly; recovery passes through DEGRADED
func (m *TierMachine) Observe(rep domain.HealthReport, at time.Time) domain.TierTransition {
	band := m.policy.Classify(rep.RTTMs, rep.JitterMs)
	m.updateStreaks(band)
	// A report of any quality ends the current silence episode.
	m.watchdogApplied = false

	next := m.autoTier
	reason := m.reason

	switch m.autoTier {
	case domain.TierFull:
		if m.badStreak >= m.policy.Thresholds().DegradeStreak {
			next = domain.TierDegraded
			reason = bandReason(band)
		}
	case domain.TierDegraded:
		switch {
		case m.minimalStreak >= m.policy.Thresholds().DegradeStreak:
			next = domain.TierMinimal
			reason = bandReason(band)
		case m.goodStreak >= m.policy.Thresholds().RecoverStreak:
			next = domain.TierFull
			reason = domain.ReasonGoodHealth
		}
	case domain.TierMinimal:
		if m.recoveryStreak >= m.policy.Thresholds().RecoverStreak {
			next = domain.TierDegraded
			reason = domain.ReasonRecovery
		}
	}

	changed := next != m.autoTier
	m.autoTier = next
	m.reason = reason

	// The observation always feeds the automatic machine, even while an override is
	// active: an override changes delivery, not the health assessment.
	if m.override != nil {
		return domain.TierTransition{
			From: m.tier, To: m.tier, Reason: domain.ReasonForcedOverride,
			Streak: m.Streak(), RTTMs: rep.RTTMs, JitterMs: rep.JitterMs,
			At: at, Changed: false,
		}
	}
	return m.applyAuto(at, rep, changed)
}

// OnMissingReports applies the watchdog rule for a report that never arrived.
//
// A client that stops reporting is not treated as healthy by default: silence for
// 5-10s drops one tier, and beyond 10s the connection is MINIMAL. Because this path
// bypasses the streaks, it can only ever degrade; coming back up still requires the
// full recovery streak, so a client that flaps its reports cannot oscillate.
func (m *TierMachine) OnMissingReports(age time.Duration, at time.Time) domain.TierTransition {
	thresholds := m.policy.Thresholds()

	var target domain.DeliveryTier
	switch {
	case age >= thresholds.ReportDegrade:
		target = domain.TierMinimal
		m.watchdogApplied = true
	case age >= thresholds.ReportHold && !m.watchdogApplied:
		target = oneStepDown(m.autoTier)
		m.watchdogApplied = true
	default:
		return domain.TierTransition{From: m.tier, To: m.tier, Reason: m.reason, At: at, Changed: false}
	}

	if target == m.autoTier {
		// Idempotent: re-evaluating the same age must not produce another transition.
		return domain.TierTransition{From: m.tier, To: m.tier, Reason: m.reason, At: at, Changed: false}
	}

	m.autoTier = target
	m.reason = domain.ReasonMissingReports
	m.resetStreaks()

	if m.override != nil {
		return domain.TierTransition{From: m.tier, To: m.tier, Reason: domain.ReasonForcedOverride, At: at, Changed: false}
	}

	previous := m.tier
	m.tier = target
	return domain.TierTransition{From: previous, To: target, Reason: domain.ReasonMissingReports, At: at, Changed: previous != target}
}

// Force pins the connection to a tier. It is a debug control, so the reason is
// always FORCED_OVERRIDE and the automatic state keeps evolving underneath.
func (m *TierMachine) Force(tier domain.DeliveryTier, at time.Time) domain.TierTransition {
	forced := tier
	m.override = &forced
	previous := m.tier
	m.tier = tier
	m.reason = domain.ReasonForcedOverride
	return domain.TierTransition{From: previous, To: tier, Reason: domain.ReasonForcedOverride, At: at, Changed: previous != tier}
}

// ClearOverride returns to the automatic tier.
func (m *TierMachine) ClearOverride(at time.Time) domain.TierTransition {
	if m.override == nil {
		return domain.TierTransition{From: m.tier, To: m.tier, Reason: m.reason, At: at, Changed: false}
	}
	m.override = nil
	previous := m.tier
	m.tier = m.autoTier
	m.reason = domain.ReasonRecovery
	return domain.TierTransition{From: previous, To: m.tier, Reason: domain.ReasonRecovery, At: at, Changed: previous != m.tier}
}

// OnReconnect resets the health-driven state. A new socket is a new network
// regime; inheriting the previous connection's streaks would be misleading.
func (m *TierMachine) OnReconnect(at time.Time) domain.TierTransition {
	previous := m.tier
	m.override = nil
	m.autoTier = domain.TierFull
	m.tier = domain.TierFull
	m.reason = domain.ReasonInitialAssignment
	m.resetStreaks()
	return domain.TierTransition{From: previous, To: m.tier, Reason: domain.ReasonInitialAssignment, At: at, Changed: previous != m.tier}
}

func (m *TierMachine) updateStreaks(band domain.HealthBand) {
	if band == domain.BandGood {
		m.goodStreak++
	} else {
		m.goodStreak = 0
	}
	if band == domain.BandMinimal {
		m.minimalStreak++
	} else {
		m.minimalStreak = 0
	}
	if band >= domain.BandDegraded {
		m.badStreak++
	} else {
		m.badStreak = 0
	}
	if band != domain.BandMinimal {
		m.recoveryStreak++
	} else {
		m.recoveryStreak = 0
	}
	// Cap the counters: past the longest threshold they carry no information, and
	// an unbounded counter would be a (very slow) leak in a long-lived session.
	const cap = 16
	m.goodStreak = min(m.goodStreak, cap)
	m.badStreak = min(m.badStreak, cap)
	m.minimalStreak = min(m.minimalStreak, cap)
	m.recoveryStreak = min(m.recoveryStreak, cap)
}

func (m *TierMachine) resetStreaks() {
	m.goodStreak, m.badStreak, m.minimalStreak, m.recoveryStreak = 0, 0, 0, 0
}

func (m *TierMachine) applyAuto(at time.Time, rep domain.HealthReport, changed bool) domain.TierTransition {
	previous := m.tier
	m.tier = m.autoTier
	return domain.TierTransition{
		From:     previous,
		To:       m.tier,
		Reason:   m.reason,
		Streak:   m.Streak(),
		RTTMs:    rep.RTTMs,
		JitterMs: rep.JitterMs,
		At:       at,
		Changed:  changed && previous != m.tier,
	}
}

func bandReason(band domain.HealthBand) domain.TierReason {
	if band == domain.BandMinimal {
		return domain.ReasonHighJitter
	}
	return domain.ReasonHighRTT
}

func oneStepDown(tier domain.DeliveryTier) domain.DeliveryTier {
	switch tier {
	case domain.TierFull:
		return domain.TierDegraded
	default:
		return domain.TierMinimal
	}
}

// --- health tracking --------------------------------------------------------

// HealthSnapshot is the transport health currently known for a session.
type HealthSnapshot struct {
	HasReport    bool
	RTTMs        float64
	JitterMs     float64
	Samples      int
	LastReportAt time.Time
	Age          time.Duration
	MissedPongs  int
	Capped       int
	TotalReports int64
}

// HealthTracker stores the client's reported transport health.
//
// The client owns the measurement because it owns the round trip; the backend
// owns the decision. The tracker therefore accepts values and never second-guesses
// them beyond the plausibility checks the protocol already applied.
type HealthTracker struct {
	policy Policy

	hasReport    bool
	rttMs        float64
	jitterMs     float64
	samples      int
	lastReportAt time.Time
	missedPongs  int
	capped       int
	totalReports int64
}

// NewHealthTracker creates an empty tracker.
func NewHealthTracker(policy Policy) *HealthTracker {
	return &HealthTracker{policy: policy}
}

// Ingest records one health report.
func (h *HealthTracker) Ingest(rep domain.HealthReport) {
	h.hasReport = true
	h.rttMs = rep.RTTMs
	h.jitterMs = rep.JitterMs
	h.samples = rep.Samples
	h.lastReportAt = rep.ReceivedAt
	h.totalReports++
}

// Snapshot renders the current health relative to now.
func (h *HealthTracker) Snapshot(now time.Time) HealthSnapshot {
	snap := HealthSnapshot{
		HasReport:    h.hasReport,
		RTTMs:        h.rttMs,
		JitterMs:     h.jitterMs,
		Samples:      h.samples,
		LastReportAt: h.lastReportAt,
		MissedPongs:  h.missedPongs,
		Capped:       h.capped,
		TotalReports: h.totalReports,
	}
	if h.hasReport {
		snap.Age = now.Sub(h.lastReportAt)
		if snap.Age < 0 {
			snap.Age = 0
		}
	}
	return snap
}

// Band classifies the current health, or reports GOOD when nothing has been
// observed yet. The zero-report case never reaches the tier machine, because the
// watchdog degrades on silence long before that matters.
func (h *HealthTracker) Band() domain.HealthBand {
	if !h.hasReport {
		return domain.BandGood
	}
	return h.policy.Classify(h.rttMs, h.jitterMs)
}
