package protocol

import (
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// LevelJSON is a price/quantity pair rendered as exact decimal strings. Strings,
// not numbers, so a JavaScript or Dart client cannot round a price on the way in.
type LevelJSON [2]string

// Levels converts domain levels for the wire. A zero quantity is preserved: it is
// how a delta says "delete this level".
func Levels(sym domain.Symbol, levels []domain.Level) []LevelJSON {
	out := make([]LevelJSON, 0, len(levels))
	for _, l := range levels {
		out = append(out, LevelJSON{sym.FormatPrice(l.Price), sym.FormatQty(l.Quantity)})
	}
	return out
}

// WelcomePayload is the first frame a client receives. It carries the engine epoch
// so a client that reconnects to a reset market learns that immediately instead of
// waiting for a sequence mismatch.
type WelcomePayload struct {
	SessionID      string             `json:"sessionId"`
	ShortID        string             `json:"shortId"`
	Symbol         string             `json:"symbol"`
	Epoch          uint64             `json:"epoch"`
	EngineState    string             `json:"engineState"`
	ServerTime     string             `json:"serverTime"`
	ProtocolMin    int                `json:"protocolMin"`
	ProtocolMax    int                `json:"protocolMax"`
	Intervals      []string           `json:"intervals"`
	Channels       []string           `json:"channels"`
	HeartbeatMs    int                `json:"heartbeatMs"`
	TierRates      map[string]float64 `json:"tierRatesPerSec"`
	TierThresholds TierThresholds     `json:"tierThresholds"`
}

// TierThresholds lets the app display the backend's actual thresholds instead of
// hardcoding its own copy of them.
type TierThresholds struct {
	FullMaxRTTMs       float64 `json:"fullMaxRttMs"`
	FullMaxJitterMs    float64 `json:"fullMaxJitterMs"`
	MinimalMinRTTMs    float64 `json:"minimalMinRttMs"`
	MinimalMinJitterMs float64 `json:"minimalMinJitterMs"`
	DegradeStreak      int     `json:"degradeStreak"`
	RecoverStreak      int     `json:"recoverStreak"`
	ReportHoldMs       int64   `json:"reportHoldMs"`
	ReportDegradeMs    int64   `json:"reportDegradeMs"`
}

// SubscribedPayload acknowledges a subscription.
type SubscribedPayload struct {
	Symbol   string   `json:"symbol"`
	Interval string   `json:"interval"`
	Channels []string `json:"channels"`
	Epoch    uint64   `json:"epoch"`
}

// UnsubscribedPayload acknowledges a channel removal.
type UnsubscribedPayload struct {
	Channels []string `json:"channels"`
}

// PongPayload echoes the client's pulse so the client can compute RTT locally.
// The server time is informational only: RTT is never derived from it, so clock
// skew between the device and the backend cannot corrupt the measurement.
type PongPayload struct {
	ID           int64 `json:"id"`
	ClientTimeMs int64 `json:"clientTimeMs"`
	ServerTimeMs int64 `json:"serverTimeMs"`
}

// PingPayload is the server-side keepalive. It is not used for RTT.
type PingPayload struct {
	ID int64 `json:"id"`
}

// MarketStatusPayload tells clients whether the engine is trading.
type MarketStatusPayload struct {
	State   string `json:"state"`
	Epoch   uint64 `json:"epoch"`
	Message string `json:"message"`
	At      string `json:"at"`
}

// OrderBookSnapshotPayload is the full book. The REST endpoint returns this object
// without the envelope.
type OrderBookSnapshotPayload struct {
	Symbol     string      `json:"symbol"`
	Epoch      uint64      `json:"epoch"`
	UpdateID   uint64      `json:"updateId"`
	Bids       []LevelJSON `json:"bids"`
	Asks       []LevelJSON `json:"asks"`
	ServerTime string      `json:"serverTime"`
}

// OrderBookDeltaPayload carries a contiguous range of engine update ids.
//
// The range is what makes per-tier coalescing safe: a client can always prove
// continuity with first <= lastApplied+1 <= last, even when several engine updates
// were merged into one message.
type OrderBookDeltaPayload struct {
	Symbol        string      `json:"symbol"`
	Epoch         uint64      `json:"epoch"`
	FirstUpdateID uint64      `json:"firstUpdateId"`
	LastUpdateID  uint64      `json:"lastUpdateId"`
	Bids          []LevelJSON `json:"bids"`
	Asks          []LevelJSON `json:"asks"`
}

// TradePayload is one executed trade.
type TradePayload struct {
	TradeID   uint64 `json:"tradeId"`
	Symbol    string `json:"symbol"`
	Timestamp string `json:"timestamp"`
	Price     string `json:"price"`
	Quantity  string `json:"quantity"`
	Side      string `json:"side"`
}

// TradeBatchPayload is used by the degraded and minimal tiers. Compaction is
// surfaced to the client rather than hidden: the app shows how many intermediate
// trades it did not receive.
type TradeBatchPayload struct {
	Symbol       string         `json:"symbol"`
	Trades       []TradePayload `json:"trades"`
	Compacted    bool           `json:"compacted"`
	OmittedCount int            `json:"omittedCount"`
}

// CandlePayload is one OHLCV bucket as exact decimal strings.
type CandlePayload struct {
	StartTime      string `json:"startTime"`
	Open           string `json:"open"`
	High           string `json:"high"`
	Low            string `json:"low"`
	Close          string `json:"close"`
	Volume         string `json:"volume"`
	TradeCount     int    `json:"tradeCount"`
	SourceSequence uint64 `json:"sourceSequence"`
	// Active marks the bucket that is still forming, so the payload is
	// self-describing on every transport.
	//
	// It exists because REST history *includes* the in-progress bucket. Without
	// this field a client can only assume the whole response is finalised, and a
	// client that made that assumption treats the newest bucket as immutable and
	// discards every live update for it — a chart that never ticks. The
	// WebSocket update frame already said "active" on the envelope; saying it on
	// the candle too means REST, a live update and a close describe the same
	// object the same way.
	Active bool `json:"active"`
}

// CandleUpdatePayload carries the complete active candle, not a diff, so a client
// that misses intermediate updates still ends up with a correct candle.
type CandleUpdatePayload struct {
	Symbol         string        `json:"symbol"`
	Interval       string        `json:"interval"`
	Candle         CandlePayload `json:"candle"`
	SourceSequence uint64        `json:"sourceSequence"`
	Active         bool          `json:"active"`
}

// CandleClosedPayload is the final candle. It is never coalesced away, because a
// client that misses it cannot finalise the bucket.
type CandleClosedPayload struct {
	Symbol   string        `json:"symbol"`
	Interval string        `json:"interval"`
	Candle   CandlePayload `json:"candle"`
	Epoch    uint64        `json:"epoch"`
}

// MarketSummaryPayload is the rolling 24h view.
type MarketSummaryPayload struct {
	Symbol            string `json:"symbol"`
	Last              string `json:"last"`
	Open24h           string `json:"open24h"`
	High24h           string `json:"high24h"`
	Low24h            string `json:"low24h"`
	Volume24h         string `json:"volume24h"`
	Change            string `json:"change"`
	ChangeBasisPoints int64  `json:"changeBasisPoints"`
	Trades24h         int64  `json:"trades24h"`
	UpdatedAt         string `json:"updatedAt"`
}

// HealthPayload is the app's single source of truth for delivery state. The app
// renders what the backend reports; it never infers a tier.
type HealthPayload struct {
	Tier                string  `json:"tier"`
	Override            string  `json:"override"`
	Reason              string  `json:"reason"`
	TargetRatePerSec    float64 `json:"targetRatePerSec"`
	EffectiveRatePerSec float64 `json:"effectiveRatePerSec"`
	RTTMs               float64 `json:"rttMs"`
	JitterMs            float64 `json:"jitterMs"`
	LastReportAgeMs     int64   `json:"lastReportAgeMs"`
	UptimeMs            int64   `json:"uptimeMs"`
	BookEpoch           uint64  `json:"bookEpoch"`
	BookUpdateID        uint64  `json:"bookUpdateId"`
	CoalescedCount      int64   `json:"coalescedCount"`
	SuppressedCount     int64   `json:"suppressedCount"`
	QueuedMessages      int     `json:"queuedMessages"`
	DroppedMessages     int64   `json:"droppedMessages"`
}

// ErrorPayload carries a typed error to the client.
type ErrorPayload struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Fatal     bool   `json:"fatal"`
	RequestID string `json:"requestId,omitempty"`
}

// GoodbyePayload is sent during a graceful shutdown so the client can reconnect
// deliberately instead of discovering a dead socket.
type GoodbyePayload struct {
	Reason string `json:"reason"`
}

// --- constructors -----------------------------------------------------------

// TradePayloadFrom renders one trade.
func TradePayloadFrom(sym domain.Symbol, t domain.Trade) TradePayload {
	return TradePayload{
		TradeID:   t.ID,
		Symbol:    t.Symbol,
		Timestamp: FormatTime(t.Timestamp),
		Price:     sym.FormatPrice(t.Price),
		Quantity:  sym.FormatQty(t.Quantity),
		Side:      t.Side.String(),
	}
}

// CandlePayloadFrom renders one candle. [active] states whether this bucket is
// still forming: REST history ends with the active bucket, a `candle_update`
// frame *is* it, and a `candle_closed` frame is final. The caller always knows,
// so it is a parameter rather than a guess made here.
func CandlePayloadFrom(sym domain.Symbol, c domain.Candle, active bool) CandlePayload {
	return CandlePayload{
		StartTime:      FormatTime(c.StartTime),
		Open:           sym.FormatPrice(c.Open),
		High:           sym.FormatPrice(c.High),
		Low:            sym.FormatPrice(c.Low),
		Close:          sym.FormatPrice(c.Close),
		Volume:         sym.FormatQty(c.Volume),
		TradeCount:     c.TradeCount,
		SourceSequence: c.SourceSequence,
		Active:         active,
	}
}

// SummaryPayloadFrom renders the rolling summary.
func SummaryPayloadFrom(sym domain.Symbol, s domain.MarketSummary) MarketSummaryPayload {
	return MarketSummaryPayload{
		Symbol:            s.Symbol,
		Last:              sym.FormatPrice(s.Last),
		Open24h:           sym.FormatPrice(s.Open24h),
		High24h:           sym.FormatPrice(s.High24h),
		Low24h:            sym.FormatPrice(s.Low24h),
		Volume24h:         sym.FormatQty(s.Volume24h),
		Change:            sym.FormatPrice(s.Change),
		ChangeBasisPoints: s.ChangeBP,
		Trades24h:         s.Trades24h,
		UpdatedAt:         FormatTime(s.UpdatedAt),
	}
}

// ErrorPayloadFrom converts a typed protocol error for the wire.
func ErrorPayloadFrom(err *Error) ErrorPayload {
	if err == nil {
		return ErrorPayload{Code: CodeInternal, Message: "unknown error"}
	}
	return ErrorPayload{Code: err.Code, Message: err.Message, Fatal: err.Fatal, RequestID: err.RequestID}
}

// SnapshotPayloadFrom renders a book snapshot.
func SnapshotPayloadFrom(sym domain.Symbol, s domain.OrderBookSnapshot) OrderBookSnapshotPayload {
	return OrderBookSnapshotPayload{
		Symbol:     s.Symbol,
		Epoch:      s.Epoch,
		UpdateID:   s.UpdateID,
		Bids:       Levels(sym, s.Bids),
		Asks:       Levels(sym, s.Asks),
		ServerTime: FormatTime(s.ServerTime),
	}
}

// DeltaPayloadFrom renders a coalesced book delta range.
func DeltaPayloadFrom(sym domain.Symbol, epoch, first, last uint64, bids, asks []domain.Level) OrderBookDeltaPayload {
	return OrderBookDeltaPayload{
		Symbol:        sym.ID,
		Epoch:         epoch,
		FirstUpdateID: first,
		LastUpdateID:  last,
		Bids:          Levels(sym, bids),
		Asks:          Levels(sym, asks),
	}
}

// HealthInterval is how often a health frame is emitted while connected.
const HealthInterval = 500 * time.Millisecond

// ServerHeartbeatInterval is the idle keepalive cadence: the server's own ping,
// which proves the socket is writable and refreshes the peer's read deadline.
const ServerHeartbeatInterval = 30 * time.Second

// ClientHeartbeatInterval is the cadence the client measures round-trip time at,
// and the value the `welcome` frame announces. It is separate from
// [ServerHeartbeatInterval] on purpose: a 30 s measurement cadence would leave
// the tier machine seeing no reports for longer than its own missing-report
// window, so every client would be degraded to MINIMAL however good its link is.
const ClientHeartbeatInterval = 2 * time.Second
