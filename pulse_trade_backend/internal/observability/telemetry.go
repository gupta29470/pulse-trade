// Package observability provides structured JSON logging, an in-process metric
// registry, and the telemetry payload types that the engine and the delivery
// layer hand to the metrics store. It holds no business logic.
package observability

import "time"

// EngineEvent is one notable engine lifecycle event.
type EngineEvent struct {
	Event      string
	Epoch      uint64
	EventIndex uint64
	UpdateID   uint64
	TradeID    uint64
	Detail     string
	DurationMs int64
	At         time.Time
}

// LatencySample is one client-reported round-trip measurement. Every sample is
// persisted: the tier machine's input must be auditable after the fact.
type LatencySample struct {
	SessionID    string
	Seq          int64
	RTTMs        float64
	JitterMs     float64
	Samples      int
	ClientTimeMs int64
	ServerTime   time.Time
	Capped       bool
	MissedPong   bool
}

// HealthReportRow is a raw health report as received, before policy is applied.
type HealthReportRow struct {
	SessionID      string
	ReceivedAt     time.Time
	RTTMs          float64
	JitterMs       float64
	AgeSinceLastMs int64
	Band           string
}

// TierTransitionRow records one tier change with enough context to explain it.
type TierTransitionRow struct {
	SessionID string
	At        time.Time
	From      string
	To        string
	Reason    string
	RTTMs     float64
	JitterMs  float64
	Streak    int
	Override  string
}

// DeliveryWindow is one five-second delivery summary per session. It is what makes
// "target rate versus effective rate" observable rather than asserted.
type DeliveryWindow struct {
	SessionID      string
	WindowStart    time.Time
	WindowMs       int64
	Tier           string
	TargetRate     float64
	EffectiveRate  float64
	CandleUpdates  int64
	TradeMessages  int64
	BookDeltas     int64
	HealthMessages int64
	Coalesced      int64
	Suppressed     int64
	BytesSent      int64
}

// Book sync event scopes.
const (
	ScopeEngine  = "ENGINE"
	ScopeSession = "SESSION"
)

// Book sync event names.
const (
	BookEventSnapshotApplied = "SNAPSHOT_APPLIED"
	BookEventGapDetected     = "GAP_DETECTED"
	BookEventRecoveryStarted = "RECOVERY_STARTED"
	BookEventRecoveryDone    = "RECOVERY_COMPLETE"
	BookEventRecoveryFailed  = "RECOVERY_FAILED"
	BookEventEpochChanged    = "EPOCH_CHANGED"
	BookEventCoalesced       = "COALESCED"
	BookEventStaleDelta      = "STALE_DELTA"
	BookEventDuplicateDelta  = "DUPLICATE_DELTA"
)

// BookSyncEvent records one order-book synchronization event.
type BookSyncEvent struct {
	At           time.Time
	SessionID    string
	Scope        string
	Event        string
	Epoch        uint64
	FromUpdateID uint64
	ToUpdateID   uint64
	GapSize      int64
	DurationMs   int64
	Attempt      int
}

// Protocol anomaly kinds.
const (
	ProtocolMalformedFrame   = "MALFORMED_FRAME"
	ProtocolUnknownType      = "UNKNOWN_TYPE"
	ProtocolValidationFailed = "VALIDATION_FAILED"
	ProtocolRateLimited      = "RATE_LIMITED"
	ProtocolDuplicateDelta   = "DUPLICATE_DELTA"
	ProtocolStaleDelta       = "STALE_DELTA"
	ProtocolOutOfOrderTrade  = "OUT_OF_ORDER_TRADE"
	ProtocolMissedPong       = "MISSED_PONG"
	ProtocolSlowConsumer     = "SLOW_CONSUMER"
	ProtocolInternal         = "INTERNAL"
)

// ProtocolEvent records an anomaly observed on one connection.
type ProtocolEvent struct {
	At        time.Time
	SessionID string
	Kind      string
	Detail    string
	Count     int64
}

// SessionRow is the lifecycle record of one connection.
type SessionRow struct {
	SessionID        string
	DeviceID         string
	ClientVersion    string
	Platform         string
	RemoteAddr       string
	Symbol           string
	Interval         string
	ConnectedAt      time.Time
	DisconnectedAt   *time.Time
	DisconnectReason string
	InitialTier      string
	FinalTier        string
	OverrideTier     string
	UptimeMs         int64
	MessagesSent     int64
	MessagesReceived int64
	BytesSent        int64
	ProtocolErrors   int64
}

// FaultInjectionRow records a deliberately injected fault.
type FaultInjectionRow struct {
	At         time.Time
	SessionID  string
	Fault      string
	Parameters string
	Applied    bool
}

// MetricsSummary is the shape served by GET /api/v1/metrics/summary.
type MetricsSummary struct {
	GeneratedAt               time.Time        `json:"generatedAt"`
	UptimeMs                  int64            `json:"uptimeMs"`
	ActiveSessions            int              `json:"activeSessions"`
	TotalSessions             int64            `json:"totalSessions"`
	TierDistribution          map[string]int   `json:"tierDistribution"`
	RTT                       RTTStats         `json:"rtt"`
	JitterMs                  float64          `json:"jitterMsMean"`
	Reconnects                int64            `json:"reconnects"`
	BookRecoveries            int64            `json:"bookRecoveries"`
	BookGapsDetected          int64            `json:"bookGapsDetected"`
	MalformedMessages         int64            `json:"malformedMessages"`
	DuplicateDeltas           int64            `json:"duplicateDeltas"`
	StaleDeltas               int64            `json:"staleDeltas"`
	OutOfOrderTrades          int64            `json:"outOfOrderTrades"`
	TierTransitions           int64            `json:"tierTransitions"`
	CandlesClosed             int64            `json:"candlesClosed"`
	CandleInvariantViolations int64            `json:"candleInvariantViolations"`
	LatencySamples            int64            `json:"latencySamples"`
	DeliveryWindows           int64            `json:"deliveryWindows"`
	Counters                  map[string]int64 `json:"counters"`
}

// RTTStats is a percentile summary over a time window.
type RTTStats struct {
	Samples int64   `json:"samples"`
	MinMs   float64 `json:"minMs"`
	AvgMs   float64 `json:"avgMs"`
	P95Ms   float64 `json:"p95Ms"`
	MaxMs   float64 `json:"maxMs"`
}

// LatencyBucket is one aggregated point of the latency time series.
type LatencyBucket struct {
	Start       time.Time `json:"start"`
	End         time.Time `json:"end"`
	Count       int64     `json:"count"`
	MinMs       float64   `json:"minMs"`
	AvgMs       float64   `json:"avgMs"`
	P95Ms       float64   `json:"p95Ms"`
	MaxMs       float64   `json:"maxMs"`
	AvgJitterMs float64   `json:"avgJitterMs"`
}
