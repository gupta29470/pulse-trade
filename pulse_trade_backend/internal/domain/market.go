package domain

import (
	"fmt"
	"time"
)

// Side is the aggressor side of a trade: which resting side it consumed.
type Side uint8

const (
	SideUnknown Side = 0
	SideBuy     Side = 1 // buyer was the aggressor
	SideSell    Side = 2 // seller was the aggressor
)

func (s Side) String() string {
	switch s {
	case SideBuy:
		return "BUY"
	case SideSell:
		return "SELL"
	default:
		return "UNKNOWN"
	}
}

func ParseSide(v string) (Side, error) {
	switch v {
	case "BUY":
		return SideBuy, nil
	case "SELL":
		return SideSell, nil
	default:
		return SideUnknown, fmt.Errorf("domain: unknown trade side %q", v)
	}
}

// Trade is one executed trade on the canonical stream. ID is the ordering
// identity and is unique for the lifetime of the process, including across an
// engine reset: duplicate detection and the database audit trail both rely on it.
type Trade struct {
	ID        uint64    `json:"tradeId"`
	Symbol    string    `json:"symbol"`
	Timestamp time.Time `json:"timestamp"`
	Price     Price     `json:"-"`
	Quantity  Qty       `json:"-"`
	Side      Side      `json:"-"`
}

// Level is one price level. A Quantity of zero means "delete this level" when it
// appears in a delta.
type Level struct {
	Price    Price `json:"-"`
	Quantity Qty   `json:"-"`
}

// OrderBookSnapshot is a complete, self-consistent view of the top of the book
// at one instant. Epoch changes on an engine reset and lets a client discard a
// book it can no longer trust.
type OrderBookSnapshot struct {
	Symbol     string    `json:"symbol"`
	Epoch      uint64    `json:"epoch"`
	UpdateID   uint64    `json:"updateId"`
	Bids       []Level   `json:"-"`
	Asks       []Level   `json:"-"`
	ServerTime time.Time `json:"serverTime"`
}

// BestBid returns the highest bid, or false when the book has no bids.
func (s OrderBookSnapshot) BestBid() (Level, bool) {
	if len(s.Bids) == 0 {
		return Level{}, false
	}
	return s.Bids[0], true
}

// BestAsk returns the lowest ask, or false when the book has no asks.
func (s OrderBookSnapshot) BestAsk() (Level, bool) {
	if len(s.Asks) == 0 {
		return Level{}, false
	}
	return s.Asks[0], true
}

// Spread returns bestAsk-bestBid. It reports false when either side is empty.
func (s OrderBookSnapshot) Spread() (Price, bool) {
	b, okB := s.BestBid()
	a, okA := s.BestAsk()
	if !okA || !okB {
		return 0, false
	}
	return a.Price.Sub(b.Price), true
}

// Validate asserts the invariants a served snapshot must satisfy.
func (s OrderBookSnapshot) Validate() error {
	if len(s.Bids) == 0 || len(s.Asks) == 0 {
		return ErrEmptyBook
	}
	bestBid, bestAsk := s.Bids[0].Price, s.Asks[0].Price
	if bestBid.Cmp(bestAsk) >= 0 {
		return fmt.Errorf("%w: bid %d >= ask %d", ErrCrossedBook, bestBid, bestAsk)
	}
	for i := 1; i < len(s.Bids); i++ {
		if s.Bids[i-1].Price.Cmp(s.Bids[i].Price) <= 0 {
			return fmt.Errorf("%w: bids not strictly descending at %d", ErrCrossedBook, i)
		}
	}
	for i := 1; i < len(s.Asks); i++ {
		if s.Asks[i-1].Price.Cmp(s.Asks[i].Price) >= 0 {
			return fmt.Errorf("%w: asks not strictly ascending at %d", ErrCrossedBook, i)
		}
	}
	return nil
}

// MarketSummary is the rolling 24h view of one market. It is computed once
// by that market's engine and served to every client, so the app never derives it.
type MarketSummary struct {
	Symbol    string    `json:"symbol"`
	Last      Price     `json:"-"`
	Open24h   Price     `json:"-"`
	High24h   Price     `json:"-"`
	Low24h    Price     `json:"-"`
	Volume24h Qty       `json:"-"`
	Change    Price     `json:"-"`
	ChangeBP  int64     `json:"changeBasisPoints"`
	Trades24h int64     `json:"trades24h"`
	UpdatedAt time.Time `json:"updatedAt"`
}
