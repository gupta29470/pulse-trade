// Package exchange defines the upstream market-data boundary.
//
// The engine consumes a MarketDataProvider and knows nothing about where the
// events come from. Two implementations exist for this build: a deterministic
// synthetic generator (the running market) and a fixture replay provider used by
// tests and controlled demonstrations. A fault-injection decorator can wrap
// either one without the engine noticing.
package exchange

import (
	"context"
	"errors"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// EventType discriminates normalised upstream events.
type EventType uint8

const (
	EventTrade EventType = iota + 1
	EventBookDelta
	EventHeartbeat
	EventFault
)

func (t EventType) String() string {
	switch t {
	case EventTrade:
		return "trade"
	case EventBookDelta:
		return "book_delta"
	case EventHeartbeat:
		return "heartbeat"
	case EventFault:
		return "fault"
	default:
		return "unknown"
	}
}

// MarketEvent is one normalised upstream event.
type MarketEvent interface {
	EventType() EventType
	At() time.Time
}

// TradeEvent carries one executed trade.
type TradeEvent struct {
	Trade domain.Trade
}

func (e TradeEvent) EventType() EventType { return EventTrade }
func (e TradeEvent) At() time.Time        { return e.Trade.Timestamp }

// BookDeltaEvent carries an upstream book mutation with its own sequence range.
// The synthetic provider does not emit these (the canonical book is derived from
// trades inside the engine), but a provider that already maintains a book can,
// and the engine applies them when they arrive.
type BookDeltaEvent struct {
	Symbol      string
	Epoch       uint64
	FirstUpdate uint64
	LastUpdate  uint64
	Bids        []domain.Level
	Asks        []domain.Level
	Timestamp   time.Time
}

func (e BookDeltaEvent) EventType() EventType { return EventBookDelta }
func (e BookDeltaEvent) At() time.Time        { return e.Timestamp }

// HeartbeatEvent lets a provider signal liveness without market data.
type HeartbeatEvent struct {
	Timestamp time.Time
}

func (e HeartbeatEvent) EventType() EventType { return EventHeartbeat }
func (e HeartbeatEvent) At() time.Time        { return e.Timestamp }

// FaultEvent marks a deliberately injected anomaly so the engine and the logs
// can distinguish an injected fault from a real one.
type FaultEvent struct {
	Kind        string
	Description string
	Timestamp   time.Time
}

func (e FaultEvent) EventType() EventType { return EventFault }
func (e FaultEvent) At() time.Time        { return e.Timestamp }

// MarketDataProvider is the upstream contract the engine consumes.
//
// It is deliberately two methods. The engine needs a bootstrap snapshot and a
// stream of normalised events, and nothing else: candle history and recent
// trades are derived from the trade stream inside the engine (which is what
// makes candle values independent of any delivery tier). Providers that do have
// upstream REST history expose it through the optional capability interfaces
// below rather than forcing every provider to stub methods it cannot implement.
type MarketDataProvider interface {
	// Snapshot returns the state the canonical book is bootstrapped from.
	Snapshot(ctx context.Context, symbol string) (domain.OrderBookSnapshot, error)
	// Stream returns normalised events. The channel is closed when ctx ends.
	Stream(ctx context.Context, symbol string) (<-chan MarketEvent, error)
}

// HistoryProvider is an optional capability for providers that can serve
// historical candles directly from upstream.
type HistoryProvider interface {
	HistoricalCandles(ctx context.Context, symbol string, iv domain.Interval, limit int) ([]domain.Candle, error)
}

// RecentTradesProvider is an optional capability for providers that keep a
// recent-trade tape upstream.
type RecentTradesProvider interface {
	RecentTrades(ctx context.Context, symbol string, limit int) ([]domain.Trade, error)
}

// Pace controls how quickly the synthetic provider emits events.
type Pace uint8

const (
	// PaceRealtime emits on a wall-clock cadence and timestamps with the clock.
	PaceRealtime Pace = iota
	// PaceFast emits as fast as the consumer drains and advances a virtual
	// timeline. It exists for warmup, which must fill history without waiting
	// for it, and for tests.
	PaceFast
)

func (p Pace) String() string {
	if p == PaceFast {
		return "fast"
	}
	return "realtime"
}

// PaceController is implemented by providers that can be switched between
// warmup and live. The engine uses it once, between the two phases.
type PaceController interface {
	SetPace(pace Pace)
	Pace() Pace
}

// Pauser is implemented by providers whose generation can be stopped and
// resumed without tearing down the stream (debug control).
type Pauser interface {
	Pause()
	Resume()
	Paused() bool
}

// Burster is implemented by providers that can force a volatility burst.
type Burster interface {
	ForceBurst(d time.Duration)
}

// Errors returned by providers.
var (
	ErrStreamClosed     = errors.New("exchange: event stream closed")
	ErrUnsupported      = errors.New("exchange: provider does not support this capability")
	ErrSymbolMismatch   = errors.New("exchange: provider is configured for a different symbol")
	ErrInvalidFixture   = errors.New("exchange: invalid replay fixture")
	ErrAlreadyStreaming = errors.New("exchange: a stream is already active")
)
