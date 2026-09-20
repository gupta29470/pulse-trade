package delivery

import (
	"sort"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// Coalescer holds one session's undelivered state.
//
// Every value it keeps is the newest complete value rather than a partial update:
// the newest active candle per interval, the newest book window, and a bounded
// batch of trades. That is what makes discarding an intermediate update safe - the
// client is never left with half an update, so a dropped message costs a frame of
// animation and never correctness.
//
// The book is handled differently from the rest. Instead of dropping superseded
// changes, the coalescer diffs the newest window against what the client was last
// told, and emits one contiguous range covering everything that changed. The client
// can therefore still prove sequence continuity, which is the property that matters
// for a book and does not matter for a chart.
type Coalescer struct {
	symbol domain.Symbol

	// Current engine window, keyed by price in scaled units.
	bids map[int64]domain.Level
	asks map[int64]domain.Level
	// What the client's book currently reflects.
	sentBids map[int64]domain.Level
	sentAsks map[int64]domain.Level

	epoch         uint64
	updateID      uint64
	clientApplied uint64
	bookDirty     bool
	needsSnapshot bool

	candles map[domain.Interval]domain.Candle
	trades  []domain.Trade
	omitted int

	coalesced  int64
	suppressed int64
}

// NewCoalescer creates an empty coalescer for one symbol.
func NewCoalescer(symbol domain.Symbol) *Coalescer {
	return &Coalescer{
		symbol:   symbol,
		bids:     make(map[int64]domain.Level),
		asks:     make(map[int64]domain.Level),
		sentBids: make(map[int64]domain.Level),
		sentAsks: make(map[int64]domain.Level),
		candles:  make(map[domain.Interval]domain.Candle),
	}
}

// OnBookWindow records the newest engine window.
//
// It must be called with the complete published window, not a diff: the coalescer
// derives deletions by comparing the new window against what the client holds.
func (c *Coalescer) OnBookWindow(epoch, updateID uint64, bids, asks []domain.Level) {
	if epoch != c.epoch {
		// A reset invalidates the client's book: it must resynchronise rather than
		// apply a delta against levels from a previous epoch.
		c.epoch = epoch
		c.needsSnapshot = true
		c.bookDirty = true
		c.sentBids = make(map[int64]domain.Level)
		c.sentAsks = make(map[int64]domain.Level)
		c.clientApplied = 0
	}
	// The engine publishes the complete window, so it replaces the previous one
	// rather than merging into it. Merging would keep a level the engine has
	// stopped publishing forever, and the client's depth ladder would drift out of
	// sync with the engine's.
	replaceLevels(c.bids, levelMap(bids))
	replaceLevels(c.asks, levelMap(asks))
	if updateID > c.updateID {
		c.updateID = updateID
	}
	c.bookDirty = true
}

// OnCandle records the newest active candle for its interval. Only the newest
// matters: a candle carries complete OHLCV, so an older value has no information
// the newer one lacks.
func (c *Coalescer) OnCandle(candle domain.Candle) {
	if previous, ok := c.candles[candle.Interval]; ok && previous.SourceSequence >= candle.SourceSequence && previous.StartTime.Equal(candle.StartTime) {
		return
	}
	c.candles[candle.Interval] = candle
}

// OnTrade appends a trade to the pending batch, counting trades that were folded
// into a batch rather than sent individually.
func (c *Coalescer) OnTrade(t domain.Trade, maxBatch int) {
	if maxBatch > 0 && len(c.trades) >= maxBatch {
		// Keep the newest trades rather than the oldest: the price the UI shows is
		// the current one, so an old trade is the least valuable thing to send.
		c.trades = append(c.trades[1:], t)
		c.omitted++
		c.coalesced++
		return
	}
	c.trades = append(c.trades, t)
}

// TakeBookDelta returns the contiguous range the client should apply next.
//
// The range always starts at clientApplied+1, so the client can verify continuity
// even when several engine updates were merged. A level is included when it differs
// from what the client was told, and a level the client has but the engine no longer
// publishes inside the window is sent with quantity zero to delete it. That is how
// the client's window stays exactly the engine's window even when levels enter and
// leave the tracked range.
func (c *Coalescer) TakeBookDelta() (epoch, first, last uint64, bids, asks []domain.Level, ok bool) {
	if !c.bookDirty || c.needsSnapshot {
		return 0, 0, 0, nil, nil, false
	}
	if c.updateID <= c.clientApplied {
		c.bookDirty = false
		return 0, 0, 0, nil, nil, false
	}

	bids = diffLevels(c.bids, c.sentBids)
	asks = diffLevels(c.asks, c.sentAsks)

	if len(bids) == 0 && len(asks) == 0 {
		// Nothing changed, so nothing is sent - and the client's applied sequence
		// must NOT advance. The client only advances when it receives a message, so
		// silently moving our idea of its position forward would make the next real
		// delta look like a gap and trigger a pointless resynchronisation.
		c.bookDirty = false
		return 0, 0, 0, nil, nil, false
	}

	first = c.clientApplied + 1
	last = c.updateID
	replaceLevels(c.sentBids, c.bids)
	replaceLevels(c.sentAsks, c.asks)
	c.clientApplied = c.updateID
	c.bookDirty = false

	sortLevels(bids, true)
	sortLevels(asks, false)
	return c.epoch, first, last, bids, asks, true
}

// TakeCandle returns the newest active candle for an interval.
func (c *Coalescer) TakeCandle(iv domain.Interval) (domain.Candle, bool) {
	candle, ok := c.candles[iv]
	if !ok {
		return domain.Candle{}, false
	}
	delete(c.candles, iv)
	return candle, true
}

// TakeTrades returns the pending trades and how many older trades the batch
// limit discarded. The caller decides whether to send them individually or
// compacted.
func (c *Coalescer) TakeTrades() (trades []domain.Trade, omitted int, ok bool) {
	if len(c.trades) == 0 {
		return nil, c.omitted, false
	}
	trades = c.trades
	omitted = c.omitted
	c.trades = nil
	c.omitted = 0
	return trades, omitted, true
}

// NeedsSnapshot reports whether the client must be resynchronised before any
// further delta can be sent, which happens after an epoch change.
func (c *Coalescer) NeedsSnapshot() bool { return c.needsSnapshot }

// SnapshotSent marks a snapshot as delivered: the client's book now equals the
// engine window at updateID, so deltas continue from there.
func (c *Coalescer) SnapshotSent(epoch, updateID uint64) {
	c.epoch = epoch
	c.updateID = updateID
	c.clientApplied = updateID
	c.needsSnapshot = false
	c.bookDirty = false
	replaceLevels(c.sentBids, c.bids)
	replaceLevels(c.sentAsks, c.asks)
}

// InjectGap makes the next delta start past what the client can legally apply,
// which is how a missing order-book update is demonstrated. The client's book is
// left untouched, so it must detect the discontinuity and request a snapshot.
func (c *Coalescer) InjectGap() uint64 {
	previous := c.clientApplied
	c.clientApplied = c.updateID
	c.bookDirty = true
	return c.updateID - previous
}

// Reset clears everything for a new epoch.
func (c *Coalescer) Reset() {
	c.bids = make(map[int64]domain.Level)
	c.asks = make(map[int64]domain.Level)
	c.sentBids = make(map[int64]domain.Level)
	c.sentAsks = make(map[int64]domain.Level)
	c.candles = make(map[domain.Interval]domain.Candle)
	c.trades = nil
	c.omitted = 0
	c.bookDirty = false
	c.needsSnapshot = true
	c.clientApplied = 0
	c.updateID = 0
}

// PendingCounts reports how much state is waiting, for the health payload.
func (c *Coalescer) PendingCounts() (candles, trades, bookLevels int) {
	bookLevels = len(c.bids) + len(c.asks)
	return len(c.candles), len(c.trades), bookLevels
}

// Stats returns the coalescing counters since the last read.
func (c *Coalescer) Stats() (coalesced, suppressed int64) {
	coalesced, suppressed = c.coalesced, c.suppressed
	c.coalesced, c.suppressed = 0, 0
	return coalesced, suppressed
}

// levelMap indexes a window by price for diffing.
func levelMap(levels []domain.Level) map[int64]domain.Level {
	out := make(map[int64]domain.Level, len(levels))
	for _, l := range levels {
		out[int64(l.Price)] = l
	}
	return out
}

func replaceLevels(dst, src map[int64]domain.Level) {
	for k := range dst {
		delete(dst, k)
	}
	for k, v := range src {
		dst[k] = v
	}
}

// mergeLevels is used only where the caller has a genuine partial update, such as
// squashing several engine windows into the newest before publishing one delta.
func mergeLevels(dst map[int64]domain.Level, levels []domain.Level) {
	for _, l := range levels {
		dst[int64(l.Price)] = l
	}
}

// diffLevels returns the levels the client must be told about: changed values, new
// levels, and deletions (quantity zero) for levels it still holds.
func diffLevels(current, sent map[int64]domain.Level) []domain.Level {
	out := make([]domain.Level, 0, len(current))
	for price, level := range current {
		if previous, ok := sent[price]; !ok || previous.Quantity != level.Quantity {
			out = append(out, level)
		}
	}
	for price := range sent {
		if _, ok := current[price]; !ok {
			out = append(out, domain.Level{Price: domain.Price(price), Quantity: 0})
		}
	}
	return out
}

func sortLevels(levels []domain.Level, descending bool) {
	sort.Slice(levels, func(i, j int) bool {
		if descending {
			return levels[i].Price > levels[j].Price
		}
		return levels[i].Price < levels[j].Price
	})
}
