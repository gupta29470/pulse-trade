package market

import "github.com/pulsetrade/pulse-trade-backend/internal/domain"

// TradeRing is a fixed-size ring of the most recent trades. It allocates once and
// never grows, so a long session has a constant memory footprint.
type TradeRing struct {
	buf   []domain.Trade
	head  int
	count int
}

// NewTradeRing creates a ring with the given capacity.
func NewTradeRing(capacity int) *TradeRing {
	if capacity < 1 {
		capacity = 200
	}
	return &TradeRing{buf: make([]domain.Trade, capacity)}
}

// Push appends a trade, overwriting the oldest entry when full.
func (r *TradeRing) Push(t domain.Trade) {
	r.buf[r.head] = t
	r.head = (r.head + 1) % len(r.buf)
	if r.count < len(r.buf) {
		r.count++
	}
}

// Len returns how many trades are retained.
func (r *TradeRing) Len() int { return r.count }

// Recent returns up to limit trades, newest first.
func (r *TradeRing) Recent(limit int) []domain.Trade {
	if limit <= 0 || limit > r.count {
		limit = r.count
	}
	out := make([]domain.Trade, 0, limit)
	for i := range limit {
		idx := (r.head - 1 - i + len(r.buf)*2) % len(r.buf)
		out = append(out, r.buf[idx])
	}
	return out
}

// Last returns the most recent trade.
func (r *TradeRing) Last() (domain.Trade, bool) {
	if r.count == 0 {
		return domain.Trade{}, false
	}
	idx := (r.head - 1 + len(r.buf)) % len(r.buf)
	return r.buf[idx], true
}

// Reset clears the ring.
func (r *TradeRing) Reset() {
	r.head = 0
	r.count = 0
}
