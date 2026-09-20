package domain

import (
	"fmt"
	"time"
)

// DeliveryTier is the per-connection delivery class. It affects only how often
// state is delivered, never what the state is.
type DeliveryTier string

const (
	TierFull     DeliveryTier = "FULL"
	TierDegraded DeliveryTier = "DEGRADED"
	TierMinimal  DeliveryTier = "MINIMAL"
)

func ParseTier(v string) (DeliveryTier, error) {
	switch DeliveryTier(v) {
	case TierFull:
		return TierFull, nil
	case TierDegraded:
		return TierDegraded, nil
	case TierMinimal:
		return TierMinimal, nil
	default:
		return "", fmt.Errorf("domain: unknown delivery tier %q", v)
	}
}

// Rank orders tiers from best to worst so the machine can move one step at a time.
func (t DeliveryTier) Rank() int {
	switch t {
	case TierFull:
		return 2
	case TierDegraded:
		return 1
	case TierMinimal:
		return 0
	default:
		return -1
	}
}

// TierReason explains why the last transition happened. It is persisted and
// surfaced in the diagnostics UI.
type TierReason string

const (
	ReasonGoodHealth        TierReason = "GOOD_HEALTH"
	ReasonHighRTT           TierReason = "HIGH_RTT"
	ReasonHighJitter        TierReason = "HIGH_JITTER"
	ReasonMissingReports    TierReason = "MISSING_REPORTS"
	ReasonForcedOverride    TierReason = "FORCED_OVERRIDE"
	ReasonRecovery          TierReason = "RECOVERY"
	ReasonInitialAssignment TierReason = "INITIAL"
)

// HealthBand is the classification of a single health report.
type HealthBand uint8

const (
	BandGood HealthBand = iota
	BandDegraded
	BandMinimal
)

func (b HealthBand) String() string {
	switch b {
	case BandGood:
		return "GOOD"
	case BandDegraded:
		return "DEGRADED_BAND"
	default:
		return "MINIMAL_BAND"
	}
}

// HealthReport is a client-measured transport sample. The client owns the
// measurement because it owns the round trip; the backend owns the decision.
type HealthReport struct {
	RTTMs        float64   `json:"rttMs"`
	JitterMs     float64   `json:"jitterMs"`
	Samples      int       `json:"samples"`
	ClientTimeMs int64     `json:"clientTimeMs"`
	ReceivedAt   time.Time `json:"-"`
}

// TierTransition records one tier change with enough context to explain it later.
type TierTransition struct {
	SessionID string       `json:"sessionId"`
	From      DeliveryTier `json:"fromTier"`
	To        DeliveryTier `json:"toTier"`
	Reason    TierReason   `json:"reason"`
	Streak    int          `json:"streak"`
	RTTMs     float64      `json:"rttMs"`
	JitterMs  float64      `json:"jitterMs"`
	Override  string       `json:"override"`
	At        time.Time    `json:"at"`
	Changed   bool         `json:"changed"`
}
