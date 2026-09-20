package market

import (
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// CandleAggregator folds trades into one interval's candles.
//
// Apply takes a trade and nothing else — no session, no tier, no clock. That is
// the structural reason a throttled client cannot alter candle values: the type
// has no way to observe a tier.
type CandleAggregator struct {
	symbol   domain.Symbol
	interval domain.Interval
	depth    int

	active    domain.Candle
	hasActive bool

	// closed is a ring of finished candles in ascending time order. The oldest
	// entry is overwritten once depth is reached.
	closed  []domain.Candle
	head    int
	closedN int

	lateTrades uint64
}

// NewCandleAggregator builds an aggregator for one interval with a bounded
// history ring.
func NewCandleAggregator(sym domain.Symbol, iv domain.Interval, depth int) *CandleAggregator {
	if depth <= 0 {
		depth = iv.HistoryDepth()
	}
	return &CandleAggregator{
		symbol:   sym,
		interval: iv,
		depth:    depth,
		closed:   make([]domain.Candle, depth),
	}
}

// Interval returns the interval this aggregator serves.
func (a *CandleAggregator) Interval() domain.Interval { return a.interval }

// LateTrades returns how many trades were rejected for arriving in a closed bucket.
func (a *CandleAggregator) LateTrades() uint64 { return a.lateTrades }

// Apply folds a trade into the aggregation.
//
// It reports whether the active candle changed and, when a bucket rolled over,
// the candle that just closed. Closed candles are immutable: a trade that
// belongs to an already-closed bucket is counted and dropped rather than
// rewriting history, because rewritten history would make cross-tier equality
// impossible to prove.
func (a *CandleAggregator) Apply(t domain.Trade) (changed bool, closed *domain.Candle) {
	if t.Symbol != a.symbol.ID {
		return false, nil
	}
	bucket := a.interval.BucketStart(t.Timestamp)

	switch {
	case !a.hasActive:
		a.active = domain.NewCandle(a.symbol.ID, a.interval, t)
		a.hasActive = true
		return true, nil

	case bucket.Equal(a.active.StartTime):
		a.active.Apply(t)
		return true, nil

	case bucket.After(a.active.StartTime):
		finished := a.active
		a.pushClosed(finished)
		a.active = domain.NewCandle(a.symbol.ID, a.interval, t)
		a.hasActive = true
		return true, &finished

	default:
		// A trade older than the active bucket: the bucket is already closed.
		a.lateTrades++
		return false, nil
	}
}

// Active returns the in-progress candle.
func (a *CandleAggregator) Active() (domain.Candle, bool) { return a.active, a.hasActive }

// LastClosed returns the most recently closed candle.
func (a *CandleAggregator) LastClosed() (domain.Candle, bool) {
	if a.closedN == 0 {
		return domain.Candle{}, false
	}
	return a.closed[a.idx(a.closedN-1)], true
}

// History returns up to limit closed candles in ascending time order. The active
// candle is deliberately excluded so a caller cannot mistake an in-progress
// bucket for a completed one.
func (a *CandleAggregator) History(limit int) []domain.Candle {
	if limit <= 0 || limit > a.closedN {
		limit = a.closedN
	}
	out := make([]domain.Candle, 0, limit)
	for i := a.closedN - limit; i < a.closedN; i++ {
		out = append(out, a.closed[a.idx(i)])
	}
	return out
}

// HistoryWithActive returns closed candles plus the in-progress candle. This is
// what the REST history endpoint serves, because a chart needs the active bucket
// to draw the live candle.
func (a *CandleAggregator) HistoryWithActive(limit int) []domain.Candle {
	if limit <= 0 {
		limit = a.closedN + 1
	}
	room := limit
	if a.hasActive {
		room--
	}
	if room > a.closedN {
		room = a.closedN
	}
	out := make([]domain.Candle, 0, room+1)
	for i := a.closedN - room; i < a.closedN; i++ {
		out = append(out, a.closed[a.idx(i)])
	}
	if a.hasActive {
		out = append(out, a.active)
	}
	return out
}

// ClosedCount returns how many candles are retained.
func (a *CandleAggregator) ClosedCount() int { return a.closedN }

// Reset clears all state, for a market reset.
func (a *CandleAggregator) Reset() {
	a.hasActive = false
	a.active = domain.Candle{}
	a.head = 0
	a.closedN = 0
	a.lateTrades = 0
}

func (a *CandleAggregator) pushClosed(c domain.Candle) {
	a.closed[a.head] = c
	a.head = (a.head + 1) % a.depth
	if a.closedN < a.depth {
		a.closedN++
	}
}

// idx maps a logical index (0 = oldest) onto the ring.
func (a *CandleAggregator) idx(logical int) int {
	start := 0
	if a.closedN == a.depth {
		start = a.head
	}
	return (start + logical) % a.depth
}
