package market

import (
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// summaryBuckets is the ring size: one bucket per minute of the 24h window. Per
// second buckets would be 60x larger for no gain, because the ring exists only to
// expire old data.
const summaryBuckets = 24 * 60

// Summary24h maintains a rolling 24-hour view of the market.
//
// Volume is a running sum with subtraction on expiry, so it is O(1). High and low
// are cached and only recomputed when the bucket that expires actually held the
// extreme, which keeps the common case O(1) while staying exact. The open is the
// first bucket still inside the window.
type Summary24h struct {
	symbol  domain.Symbol
	buckets []summaryBucket
	volume  domain.Qty
	high    domain.Price
	low     domain.Price
	open    domain.Price
	last    domain.Price
	trades  int64
	openAt  int64

	// count is how many buckets are currently inside the window. It is the
	// authority for HasData: an empty window must never report a stale extreme.
	count int
	// newestMinute is the most recent minute folded in. It drives expiry, so a
	// bucket that falls out of the window is dropped even when nothing lands on
	// its ring slot.
	newestMinute int64
}

type summaryBucket struct {
	set    bool
	minute int64
	volume domain.Qty
	high   domain.Price
	low    domain.Price
	open   domain.Price
	close  domain.Price
	trades int64
}

// NewSummary24h creates an empty summary.
func NewSummary24h(sym domain.Symbol) *Summary24h {
	return &Summary24h{symbol: sym, buckets: make([]summaryBucket, summaryBuckets)}
}

// Apply folds a trade into the window.
func (s *Summary24h) Apply(t domain.Trade) {
	minute := t.Timestamp.UTC().Truncate(time.Minute).Unix() / 60
	s.advance(minute)

	idx := bucketIndex(minute)
	b := &s.buckets[idx]

	// A collision means the slot still holds a bucket from exactly 24h ago.
	if b.set && b.minute != minute {
		s.expire(b)
	}

	if !b.set {
		b.set = true
		b.minute = minute
		b.open = t.Price
		b.high = t.Price
		b.low = t.Price
		b.close = t.Price
		b.trades = 0
		s.count++
		if s.count == 1 || minute < s.openAt {
			s.openAt = minute
			s.open = t.Price
		}
	} else {
		if t.Price.Cmp(b.high) > 0 {
			b.high = t.Price
		}
		if t.Price.Cmp(b.low) < 0 {
			b.low = t.Price
		}
		b.close = t.Price
	}

	b.volume = b.volume.Add(t.Quantity)
	b.trades++

	s.volume = s.volume.Add(t.Quantity)
	s.trades++

	if s.count == 1 && b.trades == 1 {
		s.high, s.low, s.open = t.Price, t.Price, t.Price
	} else {
		if t.Price.Cmp(s.high) > 0 {
			s.high = t.Price
		}
		if t.Price.Cmp(s.low) < 0 {
			s.low = t.Price
		}
	}
	s.last = t.Price
	if minute > s.newestMinute {
		s.newestMinute = minute
	}
}

// advance expires every bucket that has fallen outside the 24h window. The walk
// is bounded: a gap of a full window or more clears everything in one step rather
// than iterating over an unbounded number of missing minutes.
func (s *Summary24h) advance(minute int64) {
	if s.count == 0 {
		s.newestMinute = minute
		return
	}
	if minute <= s.newestMinute {
		return
	}
	gap := minute - s.newestMinute
	if gap >= summaryBuckets {
		s.clear()
		s.newestMinute = minute
		return
	}
	oldest := minute - summaryBuckets + 1
	for m := s.newestMinute + 1; m <= minute; m++ {
		b := &s.buckets[bucketIndex(m)]
		if b.set && b.minute < oldest {
			s.expire(b)
		}
	}
	s.newestMinute = minute
}

// expire removes a bucket from the window. Volume and trade counts are
// subtracted; the cached high/low/open are recomputed only when the expiring
// bucket actually held them.
func (s *Summary24h) expire(b *summaryBucket) {
	s.volume = s.volume.Sub(b.volume)
	s.trades -= b.trades
	s.count--

	heldHigh := b.high == s.high
	heldLow := b.low == s.low
	heldOpen := b.minute == s.openAt
	*b = summaryBucket{}

	if s.count == 0 {
		s.high, s.low, s.open = 0, 0, 0
		s.openAt = 0
		return
	}
	if heldHigh {
		s.recomputeHigh()
	}
	if heldLow {
		s.recomputeLow()
	}
	if heldOpen {
		s.recomputeOpen()
	}
}

func (s *Summary24h) clear() {
	for i := range s.buckets {
		s.buckets[i] = summaryBucket{}
	}
	s.volume = 0
	s.trades = 0
	s.count = 0
	s.high = 0
	s.low = 0
	s.open = 0
	s.openAt = 0
}

func bucketIndex(minute int64) int {
	return int(((minute % summaryBuckets) + summaryBuckets) % summaryBuckets)
}

func (s *Summary24h) recomputeHigh() {
	found := false
	for i := range s.buckets {
		b := &s.buckets[i]
		if !b.set {
			continue
		}
		if !found || b.high.Cmp(s.high) > 0 {
			s.high = b.high
			found = true
		}
	}
}

func (s *Summary24h) recomputeLow() {
	found := false
	for i := range s.buckets {
		b := &s.buckets[i]
		if !b.set {
			continue
		}
		if !found || b.low.Cmp(s.low) < 0 {
			s.low = b.low
			found = true
		}
	}
}

func (s *Summary24h) recomputeOpen() {
	first := int64(0)
	found := false
	for i := range s.buckets {
		b := &s.buckets[i]
		if !b.set {
			continue
		}
		if !found || b.minute < first {
			first = b.minute
			s.open = b.open
			s.openAt = b.minute
			found = true
		}
	}
}

// Snapshot renders the current window.
func (s *Summary24h) Snapshot(at time.Time) domain.MarketSummary {
	change := domain.Price(0)
	changeBP := int64(0)
	if s.count > 0 && s.open != 0 {
		change = s.last.Sub(s.open)
		if bp, err := domain.ChangeBasisPoints(s.open, s.last); err == nil {
			changeBP = bp
		}
	}
	return domain.MarketSummary{
		Symbol:    s.symbol.ID,
		Last:      s.last,
		Open24h:   s.open,
		High24h:   s.high,
		Low24h:    s.low,
		Volume24h: s.volume,
		Change:    change,
		ChangeBP:  changeBP,
		Trades24h: s.trades,
		UpdatedAt: at.UTC(),
	}
}

// HasData reports whether any trade is inside the window.
func (s *Summary24h) HasData() bool { return s.count > 0 }

// Reset clears the window, for a market reset.
func (s *Summary24h) Reset() {
	s.clear()
	s.last = 0
	s.newestMinute = 0
}
