// Package market owns the canonical market state. It is the only package that
// writes trades, order-book levels, candles and the rolling summary, and it has
// no knowledge of sessions, tiers, HTTP or the database.
package market

import (
	"fmt"
	"math/rand/v2"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// OrderBook is the canonical book for one symbol.
//
// Levels are kept in sorted slices rather than a tree: at 100 levels the whole
// structure is a few kilobytes and fits in cache, top-of-book updates are
// in-place writes, and level churn shifts at most 100 elements. A level whose
// quantity reaches zero is removed, so iteration never sees empty levels.
type OrderBook struct {
	symbol    domain.Symbol
	maxLevels int
	window    int

	epoch    uint64
	updateID uint64

	bids []domain.Level // strictly descending price
	asks []domain.Level // strictly ascending price
}

// NewOrderBook creates an empty book. window is how many levels per side are
// published to subscribers; it is deliberately smaller than maxLevels so the
// top of the book stays correct while levels churn just outside the window.
func NewOrderBook(sym domain.Symbol, maxLevels, window int) *OrderBook {
	if maxLevels < 15 {
		maxLevels = 100
	}
	if window < 10 || window > maxLevels {
		window = 15
		if window > maxLevels {
			window = maxLevels
		}
	}
	return &OrderBook{
		symbol:    sym,
		maxLevels: maxLevels,
		window:    window,
		bids:      make([]domain.Level, 0, maxLevels),
		asks:      make([]domain.Level, 0, maxLevels),
	}
}

// Window returns how many levels per side are published.
func (b *OrderBook) Window() int { return b.window }

// Epoch returns the reset generation this book belongs to.
func (b *OrderBook) Epoch() uint64 { return b.epoch }

// UpdateID returns the id of the last applied mutation.
func (b *OrderBook) UpdateID() uint64 { return b.updateID }

// Install replaces the whole book with a snapshot, which is how a session
// bootstrap and an engine reset both work. The snapshot's own sequence numbers
// become the new baseline.
func (b *OrderBook) Install(epoch, updateID uint64, bids, asks []domain.Level) error {
	if len(bids) == 0 || len(asks) == 0 {
		return domain.ErrEmptyBook
	}
	if bids[0].Price.Cmp(asks[0].Price) >= 0 {
		return fmt.Errorf("%w: best bid %d >= best ask %d",
			domain.ErrCrossedBook, bids[0].Price, asks[0].Price)
	}
	b.epoch = epoch
	b.updateID = updateID
	b.bids = trimTo(append([]domain.Level(nil), bids...), b.maxLevels)
	b.asks = trimTo(append([]domain.Level(nil), asks...), b.maxLevels)
	return nil
}

// Snapshot returns a deep copy safely usable by another goroutine.
func (b *OrderBook) Snapshot(at time.Time) domain.OrderBookSnapshot {
	return domain.OrderBookSnapshot{
		Symbol:     b.symbol.ID,
		Epoch:      b.epoch,
		UpdateID:   b.updateID,
		Bids:       append([]domain.Level(nil), b.bids...),
		Asks:       append([]domain.Level(nil), b.asks...),
		ServerTime: at.UTC(),
	}
}

// TopN returns copies of the best n levels per side.
func (b *OrderBook) TopN(n int) (bids, asks []domain.Level) {
	return copyLevels(b.bids, n), copyLevels(b.asks, n)
}

// BestBid returns the highest bid.
func (b *OrderBook) BestBid() (domain.Level, bool) {
	if len(b.bids) == 0 {
		return domain.Level{}, false
	}
	return b.bids[0], true
}

// BestAsk returns the lowest ask.
func (b *OrderBook) BestAsk() (domain.Level, bool) {
	if len(b.asks) == 0 {
		return domain.Level{}, false
	}
	return b.asks[0], true
}

// Spread returns bestAsk-bestBid.
func (b *OrderBook) Spread() (domain.Price, bool) {
	bid, okB := b.BestBid()
	ask, okA := b.BestAsk()
	if !okA || !okB {
		return 0, false
	}
	return ask.Price.Sub(bid.Price), true
}

// Depth returns the number of levels per side.
func (b *OrderBook) Depth() (bids, asks int) { return len(b.bids), len(b.asks) }

// ApplyTrade makes a trade consume resting liquidity at the touch and replenishes
// depth at the far end, so the book reacts to trading instead of merely
// jittering. The whole effect is one update id, because an update id identifies a
// state transition rather than a level.
func (b *OrderBook) ApplyTrade(t domain.Trade, rng *rand.Rand) *Mutation {
	if len(b.bids) == 0 || len(b.asks) == 0 {
		return nil
	}
	changed := make(map[int64]domain.Level, 4)

	consume := func(side []domain.Level, buy bool) []domain.Level {
		level := side[0]
		remaining := level.Quantity.Sub(t.Quantity)
		if remaining.IsPositive() {
			side[0].Quantity = remaining
			changed[int64(level.Price)] = side[0]
			return side
		}
		// The level is exhausted: drop it and add a new one at the far end so
		// the book keeps its configured depth.
		changed[int64(level.Price)] = domain.Level{Price: level.Price, Quantity: 0}
		side = side[1:]

		var far domain.Price
		if buy {
			far = side[len(side)-1].Price.Add(domain.Price(1 + rng.IntN(2)))
		} else {
			far = side[len(side)-1].Price.Sub(domain.Price(1 + rng.IntN(2)))
		}
		if far <= 0 {
			far = domain.Price(1)
		}
		fresh := domain.Level{Price: far, Quantity: replenishQuantity(b.symbol, rng)}
		if buy {
			side = append(side, fresh)
		} else {
			side = insertDescending(side, fresh)
		}
		changed[int64(fresh.Price)] = fresh
		return side
	}

	switch t.Side {
	case domain.SideBuy:
		b.asks = consume(b.asks, true)
	default:
		b.bids = consume(b.bids, false)
	}

	if err := b.checkOrdering(); err != nil {
		// A crossed book is an invariant violation. Report it rather than
		// serving a book the client cannot reason about.
		return &Mutation{Epoch: b.epoch, FirstUpdate: b.updateID, LastUpdate: b.updateID, Err: err}
	}

	b.updateID++
	return b.mutation(changed, t.Timestamp)
}

// Refresh mutates a few randomly chosen levels exactly as an exchange's depth
// stream churns outside the touch, and re-centres the ladder when it has drifted.
// One call produces one update id.
func (b *OrderBook) Refresh(rng *rand.Rand, mid domain.Price, at time.Time) *Mutation {
	if len(b.bids) == 0 || len(b.asks) == 0 {
		return b.Recenter(mid, at)
	}
	if b.needsRecenter(mid) {
		return b.Recenter(mid, at)
	}

	changed := make(map[int64]domain.Level, 8)
	touched := 1 + rng.IntN(3)
	for range touched {
		b.mutateRandomLevel(rng, &changed, true)
	}
	touched = 1 + rng.IntN(3)
	for range touched {
		b.mutateRandomLevel(rng, &changed, false)
	}
	b.replenish(rng, &changed)

	if err := b.checkOrdering(); err != nil {
		return &Mutation{Epoch: b.epoch, FirstUpdate: b.updateID, LastUpdate: b.updateID, Err: err}
	}
	b.updateID++
	return b.mutation(changed, at)
}

// needsRecenter reports whether the ladder has drifted far enough from the mid that
// it no longer describes the current market.
//
// This matters because levels only ever leave the book at the touch and are added
// at the far end. After a sustained move and a partial retrace the two sides end up
// stranded on either side of the price, producing an implausible spread and a book
// that no longer reacts to the market. A real book tracks the price, so ours does
// too.
func (b *OrderBook) needsRecenter(mid domain.Price) bool {
	if mid <= 0 {
		return false
	}
	if len(b.bids) < b.maxLevels*3/4 || len(b.asks) < b.maxLevels*3/4 {
		return true
	}
	spread := b.asks[0].Price.Sub(b.bids[0].Price)
	tolerance := domain.Price(6 * b.maxLevels / 100)
	if tolerance < 6 {
		tolerance = 6
	}
	return spread > tolerance || b.bids[0].Price.Cmp(mid) > 0 || b.asks[0].Price.Cmp(mid) < 0
}

// Recenter rebuilds the ladder symmetrically around the mid, preserving the existing
// size distribution so the depth profile stays realistic, and restoring the
// configured number of levels per side.
func (b *OrderBook) Recenter(mid domain.Price, at time.Time) *Mutation {
	if mid <= 0 {
		return nil
	}
	changed := make(map[int64]domain.Level, 2*b.maxLevels)

	// Capture the previous window so deletions can be reported to sessions.
	for _, lvl := range b.bids {
		changed[int64(lvl.Price)] = domain.Level{Price: lvl.Price, Quantity: 0}
	}
	for _, lvl := range b.asks {
		changed[int64(lvl.Price)] = domain.Level{Price: lvl.Price, Quantity: 0}
	}

	half := domain.Price(1 + (int64(mid) % 2))
	bestBid := domain.Price(int64(mid) - int64(half))
	bestAsk := domain.Price(int64(mid) + int64(half))
	if bestBid <= 0 {
		bestBid = 1
	}
	if bestAsk <= bestBid {
		bestAsk = bestBid + 1
	}

	// Level spacing widens with depth. A book whose levels are all one tick apart
	// would describe a market only a few dollars deep, which does not look like a
	// real BTC book on the depth ladder.
	bids := make([]domain.Level, 0, b.maxLevels)
	asks := make([]domain.Level, 0, b.maxLevels)
	bidPrice, askPrice := bestBid, bestAsk
	for i := range b.maxLevels {
		if i > 0 {
			step := domain.Price(1 + i/20)
			bidPrice -= step
			askPrice += step
		}
		if bidPrice <= 0 {
			bidPrice = domain.Price(1)
		}
		bids = append(bids, domain.Level{Price: bidPrice, Quantity: b.sizeAt(i, true)})
		asks = append(asks, domain.Level{Price: askPrice, Quantity: b.sizeAt(i, false)})
	}
	b.bids = bids
	b.asks = asks

	for _, lvl := range bids {
		changed[int64(lvl.Price)] = lvl
	}
	for _, lvl := range asks {
		changed[int64(lvl.Price)] = lvl
	}

	if err := b.checkOrdering(); err != nil {
		return &Mutation{Epoch: b.epoch, FirstUpdate: b.updateID, LastUpdate: b.updateID, Err: err}
	}
	b.updateID++
	return b.mutation(changed, at)
}

// sizeAt returns the resting size for the level at the given depth. Deeper levels
// carry more size, which is what a real book looks like.
func (b *OrderBook) sizeAt(depth int, bid bool) domain.Qty {
	// Reuse the existing quantity when the ladder is only being re-priced, so a
	// recentre does not look like the whole book was replaced.
	side := b.bids
	if !bid {
		side = b.asks
	}
	if depth < len(side) {
		return side[depth].Quantity
	}
	base := 0.02 + float64(depth)*0.004
	scaled := int64(base * float64(b.symbol.QtyScale))
	if scaled < 1 {
		scaled = 1
	}
	return domain.Qty(scaled)
}

// replenish restores levels that churn removed, so the configured depth is
// maintained instead of bleeding away over a long session.
func (b *OrderBook) replenish(rng *rand.Rand, changed *map[int64]domain.Level) {
	for len(b.bids) < b.maxLevels {
		last := b.bids[len(b.bids)-1].Price
		price := last.Sub(domain.Price(1 + rng.IntN(2)))
		if price <= 0 {
			break
		}
		level := domain.Level{Price: price, Quantity: replenishQuantity(b.symbol, rng)}
		b.bids = append(b.bids, level)
		(*changed)[int64(price)] = level
	}
	for len(b.asks) < b.maxLevels {
		last := b.asks[len(b.asks)-1].Price
		price := last.Add(domain.Price(1 + rng.IntN(2)))
		level := domain.Level{Price: price, Quantity: replenishQuantity(b.symbol, rng)}
		b.asks = append(b.asks, level)
		(*changed)[int64(price)] = level
	}
}

// ApplyDelta applies a provider-supplied delta with an explicit range. The
// sequence rules match the ones clients apply to us, so the same reasoning and
// the same tests cover both boundaries.
func (b *OrderBook) ApplyDelta(epoch, first, last uint64, bids, asks []domain.Level, at time.Time) (*Mutation, error) {
	if epoch != b.epoch {
		return nil, fmt.Errorf("%w: delta epoch %d, book epoch %d", domain.ErrStaleUpdate, epoch, b.epoch)
	}
	if last <= b.updateID {
		return nil, fmt.Errorf("%w: delta %d..%d already applied at %d",
			domain.ErrStaleUpdate, first, last, b.updateID)
	}
	if first > b.updateID+1 {
		return nil, fmt.Errorf("%w: delta starts at %d, book is at %d",
			domain.ErrBookGap, first, b.updateID)
	}

	changed := make(map[int64]domain.Level, len(bids)+len(asks))
	for _, lvl := range bids {
		b.bids = applyLevel(b.bids, lvl, true, b.maxLevels, &changed)
	}
	for _, lvl := range asks {
		b.asks = applyLevel(b.asks, lvl, false, b.maxLevels, &changed)
	}
	if err := b.checkOrdering(); err != nil {
		return nil, err
	}
	b.updateID = last
	return b.mutationRange(changed, first, last, at), nil
}

func (b *OrderBook) mutateRandomLevel(rng *rand.Rand, changed *map[int64]domain.Level, bid bool) {
	side := b.bids
	if !bid {
		side = b.asks
	}
	if len(side) == 0 {
		return
	}
	// Bias toward the top of the book, where real churn happens.
	idx := int(float64(len(side)) * rng.Float64() * rng.Float64())
	if idx >= len(side) {
		idx = len(side) - 1
	}
	level := side[idx]

	if rng.Float64() < 0.08 && len(side) > 20 {
		side = append(side[:idx], side[idx+1:]...)
		(*changed)[int64(level.Price)] = domain.Level{Price: level.Price, Quantity: 0}
	} else {
		factor := 0.5 + rng.Float64()*1.5
		q := domain.Qty(float64(level.Quantity) * factor)
		if q < 1 {
			q = 1
		}
		level.Quantity = q
		side[idx] = level
		(*changed)[int64(level.Price)] = level
	}

	if bid {
		b.bids = side
	} else {
		b.asks = side
	}
}

func (b *OrderBook) mutation(changed map[int64]domain.Level, at time.Time) *Mutation {
	return b.mutationRange(changed, b.updateID, b.updateID, at)
}

func (b *OrderBook) mutationRange(changed map[int64]domain.Level, first, last uint64, at time.Time) *Mutation {
	m := &Mutation{
		Symbol:      b.symbol.ID,
		Epoch:       b.epoch,
		FirstUpdate: first,
		LastUpdate:  last,
		At:          at.UTC(),
	}
	m.Bids, m.Asks = b.windowLocked()
	return m
}

// windowLocked returns copies of the published window. The copies are what make
// a published window safe to share: subscribers never observe the engine's own
// slices, and a deletion is derived by the delivery layer as "present in the
// previous window, absent from this one".
func (b *OrderBook) windowLocked() (bids, asks []domain.Level) {
	return copyLevels(b.bids, b.window), copyLevels(b.asks, b.window)
}

func (b *OrderBook) checkOrdering() error {
	for i := 1; i < len(b.bids); i++ {
		if b.bids[i-1].Price.Cmp(b.bids[i].Price) <= 0 {
			return fmt.Errorf("%w: bids not strictly descending at %d", domain.ErrCrossedBook, i)
		}
	}
	for i := 1; i < len(b.asks); i++ {
		if b.asks[i-1].Price.Cmp(b.asks[i].Price) >= 0 {
			return fmt.Errorf("%w: asks not strictly ascending at %d", domain.ErrCrossedBook, i)
		}
	}
	if len(b.bids) > 0 && len(b.asks) > 0 && b.bids[0].Price.Cmp(b.asks[0].Price) >= 0 {
		return fmt.Errorf("%w: best bid %d >= best ask %d",
			domain.ErrCrossedBook, b.bids[0].Price, b.asks[0].Price)
	}
	return nil
}

// Mutation describes one canonical book state transition.
type Mutation struct {
	Symbol      string
	Epoch       uint64
	FirstUpdate uint64
	LastUpdate  uint64
	Bids        []domain.Level
	Asks        []domain.Level
	At          time.Time
	Err         error
}

// BookWindow is the slice of the book published to subscribers. The slices are
// owned by the publisher and must be treated as read-only by consumers.
type BookWindow struct {
	Symbol      string
	Epoch       uint64
	UpdateID    uint64
	Bids        []domain.Level
	Asks        []domain.Level
	At          time.Time
	Description string
}

// --- level helpers ----------------------------------------------------------

func copyLevels(src []domain.Level, n int) []domain.Level {
	if n <= 0 || n > len(src) {
		n = len(src)
	}
	return append([]domain.Level(nil), src[:n]...)
}

func trimTo(levels []domain.Level, maxLevels int) []domain.Level {
	if len(levels) <= maxLevels {
		return levels
	}
	return levels[:maxLevels]
}

func insertDescending(levels []domain.Level, lvl domain.Level) []domain.Level {
	idx := len(levels)
	for i, existing := range levels {
		if lvl.Price.Cmp(existing.Price) > 0 {
			idx = i
			break
		}
	}
	levels = append(levels, domain.Level{})
	copy(levels[idx+1:], levels[idx:])
	levels[idx] = lvl
	return levels
}

func insertAscending(levels []domain.Level, lvl domain.Level) []domain.Level {
	idx := len(levels)
	for i, existing := range levels {
		if lvl.Price.Cmp(existing.Price) < 0 {
			idx = i
			break
		}
	}
	levels = append(levels, domain.Level{})
	copy(levels[idx+1:], levels[idx:])
	levels[idx] = lvl
	return levels
}

// applyLevel sets or deletes one level, keeping the slice sorted and capped.
func applyLevel(levels []domain.Level, lvl domain.Level, bid bool, maxLevels int, changed *map[int64]domain.Level) []domain.Level {
	if lvl.Quantity.IsZero() {
		for i, existing := range levels {
			if existing.Price == lvl.Price {
				levels = append(levels[:i], levels[i+1:]...)
				break
			}
		}
		(*changed)[int64(lvl.Price)] = domain.Level{Price: lvl.Price, Quantity: 0}
		return levels
	}

	for i, existing := range levels {
		if existing.Price == lvl.Price {
			levels[i] = lvl
			(*changed)[int64(lvl.Price)] = lvl
			return levels
		}
	}

	if bid {
		levels = insertDescending(levels, lvl)
	} else {
		levels = insertAscending(levels, lvl)
	}
	(*changed)[int64(lvl.Price)] = lvl
	if len(levels) > maxLevels {
		levels = levels[:maxLevels]
	}
	return levels
}

// replenishQuantity sizes a freshly added level.
func replenishQuantity(sym domain.Symbol, rng *rand.Rand) domain.Qty {
	base := 0.02 + rng.Float64()*0.6
	scaled := int64(base * float64(sym.QtyScale))
	if scaled < 1 {
		scaled = 1
	}
	return domain.Qty(scaled)
}
