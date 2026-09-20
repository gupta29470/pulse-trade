package delivery_test

import (
	"context"
	"fmt"
	"sort"
	"testing"

	"github.com/pulsetrade/pulse-trade-backend/internal/delivery"
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// clientBook is a reference implementation of the sequence rules the app applies.
// Keeping it in the test package means server-side coalescing is checked against the
// contract the client actually implements, not against a restatement of the
// server's own behaviour.
type clientBook struct {
	epoch       uint64
	applied     uint64
	bids        map[domain.Price]domain.Qty
	asks        map[domain.Price]domain.Qty
	gaps        int
	staleDeltas int
	deltas      int
}

func newClientBook() *clientBook {
	return &clientBook{bids: map[domain.Price]domain.Qty{}, asks: map[domain.Price]domain.Qty{}}
}

func (c *clientBook) applySnapshot(epoch, updateID uint64, bids, asks []domain.Level) {
	c.epoch = epoch
	c.applied = updateID
	c.bids = map[domain.Price]domain.Qty{}
	c.asks = map[domain.Price]domain.Qty{}
	mergeLevels(c.bids, bids)
	mergeLevels(c.asks, asks)
}

func mergeLevels(dst map[domain.Price]domain.Qty, levels []domain.Level) {
	for _, l := range levels {
		if l.Quantity == 0 {
			delete(dst, l.Price)
			continue
		}
		dst[l.Price] = l.Quantity
	}
}

// applyDelta enforces the documented rules: an epoch mismatch or a range that starts
// beyond applied+1 is a gap, a range ending at or before applied is stale, and an
// overlapping range is applied in full.
func (c *clientBook) applyDelta(epoch, first, last uint64, bids, asks []domain.Level) {
	if epoch != c.epoch {
		c.gaps++
		return
	}
	if last <= c.applied {
		c.staleDeltas++
		return
	}
	if first > c.applied+1 {
		c.gaps++
		return
	}
	mergeLevels(c.bids, bids)
	mergeLevels(c.asks, asks)
	c.applied = last
	c.deltas++
}

func (c *clientBook) topBids(n int) []domain.Level { return topN(c.bids, n, true) }
func (c *clientBook) topAsks(n int) []domain.Level { return topN(c.asks, n, false) }

func topN(book map[domain.Price]domain.Qty, n int, descending bool) []domain.Level {
	levels := make([]domain.Level, 0, len(book))
	for price, qty := range book {
		levels = append(levels, domain.Level{Price: price, Quantity: qty})
	}
	sort.Slice(levels, func(i, j int) bool {
		if descending {
			return levels[i].Price > levels[j].Price
		}
		return levels[i].Price < levels[j].Price
	})
	if n > len(levels) {
		n = len(levels)
	}
	return levels[:n]
}

// engineWindow builds a plausible engine window for step i.
//
// Every step changes quantities inside the window, and every fifth step the whole
// ladder shifts by one tick. That combination matters: it guarantees each step
// produces an observable change (so the sequential path always has a delta to send)
// and it exercises both an arriving level and a level leaving the tracked window.
type engineWindow struct{}

func newEngineWindow() *engineWindow { return &engineWindow{} }

func (w *engineWindow) step(i int) ([]domain.Level, []domain.Level) {
	const base = domain.Price(6_742_000)
	shift := domain.Price(i / 5)

	bids := make([]domain.Level, 0, 15)
	asks := make([]domain.Level, 0, 15)
	for k := range 15 {
		bids = append(bids, domain.Level{
			Price:    base + shift - domain.Price(k),
			Quantity: domain.Qty(1_000_000 + int64(k)*1_000 + int64(i%5)*17),
		})
		asks = append(asks, domain.Level{
			Price:    base + shift + 100 + domain.Price(k),
			Quantity: domain.Qty(900_000 + int64(k)*1_000 + int64(i%7)*23),
		})
	}
	return bids, asks
}

// A coalesced range must equal sequential application.
//
// The server may merge several engine updates into one message, because a throttled
// client cannot receive every intermediate state. This test proves merging is
// lossless: the client that received one coalesced range ends up with exactly the
// book of a client that received every individual update.
func TestCoalescer_CoalescedRangeEqualsSequentialApplication(t *testing.T) {
	t.Parallel()
	const updates = 40

	sequential := delivery.NewCoalescer(domain.BTCUSDT)
	coalesced := delivery.NewCoalescer(domain.BTCUSDT)
	sequential.SnapshotSent(1, 0)
	coalesced.SnapshotSent(1, 0)

	clientSequential := newClientBook()
	clientCoalesced := newClientBook()
	clientSequential.applySnapshot(1, 0, nil, nil)
	clientCoalesced.applySnapshot(1, 0, nil, nil)

	window := newEngineWindow()
	for i := 1; i <= updates; i++ {
		bids, asks := window.step(i)

		// Client A: every update flushed as its own delta.
		sequential.OnBookWindow(1, uint64(i), bids, asks)
		if ok := takeAndApply(sequential, clientSequential); !ok {
			t.Fatalf("update %d produced no delta on the sequential path", i)
		}

		// Client B: the same updates, but never flushed until the end.
		coalesced.OnBookWindow(1, uint64(i), bids, asks)
	}
	if ok := takeAndApply(coalesced, clientCoalesced); !ok {
		t.Fatal("the coalesced path produced no delta")
	}

	if clientSequential.gaps != 0 {
		t.Fatalf("sequential client saw %d gaps", clientSequential.gaps)
	}
	if clientCoalesced.gaps != 0 {
		t.Fatalf("coalesced client saw %d gaps; a merged range must remain applicable", clientCoalesced.gaps)
	}
	if clientSequential.applied != updates {
		t.Fatalf("sequential client applied %d, want %d", clientSequential.applied, updates)
	}
	if clientCoalesced.applied != updates {
		t.Fatalf("coalesced client applied %d, want %d", clientCoalesced.applied, updates)
	}
	// The coalesced path is only interesting if it really did merge.
	if clientCoalesced.deltas >= clientSequential.deltas {
		t.Fatalf("coalescing did not reduce message count: %d vs %d",
			clientCoalesced.deltas, clientSequential.deltas)
	}
	assertSameBook(t, clientSequential, clientCoalesced)
}

func takeAndApply(c *delivery.Coalescer, client *clientBook) bool {
	epoch, first, last, bids, asks, ok := c.TakeBookDelta()
	if !ok {
		return false
	}
	client.applyDelta(epoch, first, last, bids, asks)
	return true
}

func assertSameBook(t *testing.T, a, b *clientBook) {
	t.Helper()
	if a.applied != b.applied {
		t.Fatalf("applied sequence differs: %d vs %d", a.applied, b.applied)
	}
	compare := func(label string, left, right []domain.Level) {
		if len(left) != len(right) {
			t.Fatalf("%s length differs: %d vs %d", label, len(left), len(right))
		}
		for i := range left {
			if left[i].Price != right[i].Price || left[i].Quantity != right[i].Quantity {
				t.Fatalf("%s level %d differs: %d@%d vs %d@%d",
					label, i, left[i].Quantity, left[i].Price, right[i].Quantity, right[i].Price)
			}
		}
	}
	compare("bids", a.topBids(15), b.topBids(15))
	compare("asks", a.topAsks(15), b.topAsks(15))
}

// A level that leaves the tracked window must be deleted on the client, otherwise
// the client's tenth level would be a price the engine no longer publishes.
func TestCoalescer_EmitsDeletionForLevelLeavingWindow(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	coalescer.SnapshotSent(1, 10)

	client := newClientBook()
	client.applySnapshot(1, 10, nil, nil)

	// Three bid levels published.
	coalescer.OnBookWindow(1, 11,
		[]domain.Level{
			{Price: 6_742_000, Quantity: 100},
			{Price: 6_741_999, Quantity: 200},
			{Price: 6_741_998, Quantity: 300},
		},
		[]domain.Level{{Price: 6_742_001, Quantity: 400}},
	)
	if ok := takeAndApply(coalescer, client); !ok {
		t.Fatal("expected a delta for the first window")
	}
	if len(client.topBids(10)) != 3 {
		t.Fatalf("client holds %d bid levels, want 3", len(client.topBids(10)))
	}

	// The deepest level drops out of the engine window.
	coalescer.OnBookWindow(1, 12,
		[]domain.Level{
			{Price: 6_742_000, Quantity: 100},
			{Price: 6_741_999, Quantity: 200},
		},
		[]domain.Level{{Price: 6_742_001, Quantity: 400}},
	)
	if ok := takeAndApply(coalescer, client); !ok {
		t.Fatal("expected a deletion delta")
	}

	for _, level := range client.topBids(10) {
		if level.Price == 6_741_998 {
			t.Fatal("a level that left the engine window is still present on the client")
		}
	}
	if len(client.topBids(10)) != 2 {
		t.Fatalf("client holds %d bid levels, want 2", len(client.topBids(10)))
	}
}

func TestCoalescer_EpochChangeRequiresSnapshot(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	coalescer.SnapshotSent(1, 50)

	coalescer.OnBookWindow(2, 1,
		[]domain.Level{{Price: 100, Quantity: 1}},
		[]domain.Level{{Price: 101, Quantity: 1}})
	if !coalescer.NeedsSnapshot() {
		t.Fatal("an epoch change must force a fresh snapshot")
	}
	if _, _, _, _, _, ok := coalescer.TakeBookDelta(); ok {
		t.Fatal("no delta may be sent before the client has resynchronised")
	}

	coalescer.SnapshotSent(2, 1)
	coalescer.OnBookWindow(2, 2,
		[]domain.Level{{Price: 100, Quantity: 5}},
		[]domain.Level{{Price: 101, Quantity: 6}})
	epoch, first, last, _, _, ok := coalescer.TakeBookDelta()
	if !ok {
		t.Fatal("expected a delta after the snapshot")
	}
	if epoch != 2 || first != 2 || last != 2 {
		t.Fatalf("range = epoch %d %d..%d, want epoch 2 range 2..2", epoch, first, last)
	}
}

// A window that repeats without changing anything produces no message, yet the next
// real change must still be contiguous for the client.
func TestCoalescer_EmptyDiffKeepsRangesContiguous(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	bids := []domain.Level{{Price: 6_742_000, Quantity: 100}}
	asks := []domain.Level{{Price: 6_742_100, Quantity: 100}}
	coalescer.SnapshotSent(1, 10)

	client := newClientBook()
	client.applySnapshot(1, 10, bids, asks)

	// Update 11 restates the window. A snapshot cannot tell the coalescer which
	// levels the client actually received, so the first delta after a snapshot
	// restates the whole window rather than assuming anything.
	coalescer.OnBookWindow(1, 11, bids, asks)
	if ok := takeAndApply(coalescer, client); !ok {
		t.Fatal("the first window after a snapshot should produce a delta")
	}

	// Update 12 repeats the window, so there is nothing to send.
	coalescer.OnBookWindow(1, 12, bids, asks)
	if _, _, _, _, _, ok := coalescer.TakeBookDelta(); ok {
		t.Fatal("an unchanged window should not produce a delta")
	}

	coalescer.OnBookWindow(1, 13, []domain.Level{{Price: 6_742_000, Quantity: 250}}, asks)
	epoch, first, last, outBids, outAsks, ok := coalescer.TakeBookDelta()
	if !ok {
		t.Fatal("expected a delta for the changed level")
	}
	if first != 12 || last != 13 {
		t.Fatalf("range = %d..%d, want 12..13", first, last)
	}

	client.applyDelta(epoch, first, last, outBids, outAsks)
	if client.gaps != 0 {
		t.Fatalf("the client reported %d gaps for a contiguous range", client.gaps)
	}
	if got := client.bids[6_742_000]; got != 250 {
		t.Fatalf("client bid quantity = %d, want 250", got)
	}
	if client.applied != 13 {
		t.Fatalf("client applied = %d, want 13", client.applied)
	}
}

// InjectGap is the mechanism behind the "missing order-book update" demonstration:
// the next delta must start past what the client can legally apply.
func TestCoalescer_InjectedGapForcesClientRecovery(t *testing.T) {
	t.Parallel()
	asks := []domain.Level{{Price: 6_742_100, Quantity: 100}}
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	coalescer.SnapshotSent(1, 1)

	client := newClientBook()
	client.applySnapshot(1, 1, []domain.Level{{Price: 6_742_000, Quantity: 100}}, asks)

	coalescer.OnBookWindow(1, 2, []domain.Level{{Price: 6_742_000, Quantity: 110}}, asks)
	coalescer.OnBookWindow(1, 3, []domain.Level{{Price: 6_742_000, Quantity: 120}}, asks)
	coalescer.OnBookWindow(1, 4, []domain.Level{{Price: 6_742_000, Quantity: 130}}, asks)

	if skipped := coalescer.InjectGap(); skipped != 3 {
		t.Fatalf("injected gap covered %d update ids, want 3", skipped)
	}
	if _, _, _, _, _, ok := coalescer.TakeBookDelta(); ok {
		t.Fatal("no delta should be emitted for an already-applied range")
	}

	coalescer.OnBookWindow(1, 5, []domain.Level{{Price: 6_742_000, Quantity: 140}}, asks)
	epoch, first, last, outBids, outAsks, ok := coalescer.TakeBookDelta()
	if !ok {
		t.Fatal("expected a delta after the skipped range")
	}
	if first <= client.applied+1 {
		t.Fatalf("range starts at %d, which the client could apply; the gap was not injected", first)
	}

	client.applyDelta(epoch, first, last, outBids, outAsks)
	if client.gaps != 1 {
		t.Fatalf("client detected %d gaps, want exactly 1", client.gaps)
	}
	if client.applied != 1 {
		t.Fatalf("client applied = %d; a discontiguous delta must not be applied", client.applied)
	}
}

func TestCoalescer_DuplicateRangeIsInert(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	coalescer.SnapshotSent(1, 1)
	coalescer.OnBookWindow(1, 2,
		[]domain.Level{{Price: 100, Quantity: 5}},
		[]domain.Level{{Price: 101, Quantity: 5}})

	client := newClientBook()
	client.applySnapshot(1, 1, nil, nil)

	epoch, first, last, bids, asks, ok := coalescer.TakeBookDelta()
	if !ok {
		t.Fatal("expected a delta")
	}
	client.applyDelta(epoch, first, last, bids, asks)
	if client.applied != 2 {
		t.Fatalf("client applied = %d, want 2", client.applied)
	}

	// Re-deliver the identical range: it must be inert.
	client.applyDelta(epoch, first, last, bids, asks)
	if client.applied != 2 {
		t.Fatalf("a duplicate range advanced the client to %d", client.applied)
	}
	if client.staleDeltas != 1 {
		t.Fatalf("stale delta count = %d, want 1", client.staleDeltas)
	}
}

func TestCoalescer_TradeBatchingReportsOmissions(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)

	for i := range 10 {
		coalescer.OnTrade(domain.Trade{ID: uint64(i), Price: domain.Price(100 + i), Quantity: 1}, 1)
	}
	trades, omitted, ok := coalescer.TakeTrades()
	if !ok {
		t.Fatal("expected a trade batch")
	}
	if len(trades) != 1 {
		t.Fatalf("batch holds %d trades, want 1", len(trades))
	}
	if omitted != 9 {
		t.Fatalf("omitted = %d, want 9", omitted)
	}
	// The trade that survives must be the newest: the price the UI shows is the
	// current price, so an old trade is the least valuable thing to keep.
	if trades[0].ID != 9 {
		t.Fatalf("kept trade %d, want the newest (9)", trades[0].ID)
	}
	// A second flush has nothing left to send.
	if _, _, ok := coalescer.TakeTrades(); ok {
		t.Fatal("the trade batch was not cleared by the flush")
	}
}

func TestCoalescer_UpdateIDNeverGoesBackwards(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	coalescer.SnapshotSent(1, 0)

	last := uint64(0)
	for i := 1; i <= 50; i++ {
		coalescer.OnBookWindow(1, uint64(i),
			[]domain.Level{{Price: domain.Price(6_742_000 + i), Quantity: domain.Qty(i)}},
			[]domain.Level{{Price: domain.Price(6_742_100 + i), Quantity: domain.Qty(i)}})
		_, _, emitted, _, _, ok := coalescer.TakeBookDelta()
		if !ok {
			continue
		}
		if emitted < last {
			t.Fatalf("update id went backwards: %d then %d", last, emitted)
		}
		last = emitted
	}
	if last != 50 {
		t.Fatalf("final update id = %d, want 50", last)
	}
}

func TestCoalescer_ResetRequiresSnapshot(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	coalescer.SnapshotSent(1, 5)
	coalescer.Reset()
	if !coalescer.NeedsSnapshot() {
		t.Fatal("a reset must require a fresh snapshot")
	}
}

func TestCoalescer_CandleKeepsNewestValueOnly(t *testing.T) {
	t.Parallel()
	coalescer := delivery.NewCoalescer(domain.BTCUSDT)
	start := domain.Interval1m.BucketStart(domain.Trade{}.Timestamp)
	_ = start

	first := domain.Candle{Interval: domain.Interval1m, Open: 100, High: 100, Low: 100, Close: 100, Volume: 1, TradeCount: 1, SourceSequence: 1}
	second := domain.Candle{Interval: domain.Interval1m, Open: 100, High: 130, Low: 90, Close: 120, Volume: 5, TradeCount: 4, SourceSequence: 4}

	coalescer.OnCandle(first)
	coalescer.OnCandle(second)

	got, ok := coalescer.TakeCandle(domain.Interval1m)
	if !ok {
		t.Fatal("expected a candle")
	}
	if got.SourceSequence != 4 || got.High != 130 {
		t.Fatalf("coalescer kept %+v, want the newest candle", got)
	}

	// An older candle must not overwrite a newer one.
	coalescer.OnCandle(second)
	coalescer.OnCandle(first)
	if got, ok := coalescer.TakeCandle(domain.Interval1m); ok {
		if got.SourceSequence == 1 {
			t.Fatal("an older candle replaced a newer one")
		}
	}
}

// --- manager behaviour -------------------------------------------------------

func TestManagerAssignsUniqueSessionIDsAndTracksCounts(t *testing.T) {
	t.Parallel()
	manager := delivery.NewManager(delivery.ManagerConfig{DefaultSymbol: domain.BTCUSDT})
	seen := map[string]bool{}

	for range 200 {
		session := manager.Register(stubConn{}, nil)
		if seen[session.ID()] {
			t.Fatalf("duplicate session id %s", session.ID())
		}
		seen[session.ID()] = true
		if len(session.ShortID()) != 6 {
			t.Fatalf("short id %q is not six characters", session.ShortID())
		}
		if session.Tier() != domain.TierFull {
			t.Fatalf("a new session should start at FULL, got %s", session.Tier())
		}
		manager.Unregister(session.ID())
	}
	if manager.Count() != 0 {
		t.Fatalf("manager still holds %d sessions", manager.Count())
	}
	if manager.TotalSessions() != 200 {
		t.Fatalf("total sessions = %d, want 200", manager.TotalSessions())
	}
}

func TestManagerFaultsAndDropTargetOneSession(t *testing.T) {
	t.Parallel()
	manager := delivery.NewManager(delivery.ManagerConfig{DefaultSymbol: domain.BTCUSDT})
	a := manager.Register(stubConn{}, nil)
	b := manager.Register(stubConn{}, nil)

	if !manager.ApplyFaults(a.ID(), delivery.FaultConfig{SkipBookDeltas: 3}) {
		t.Fatal("applying faults to a live session failed")
	}
	if manager.ApplyFaults("sess_missing", delivery.FaultConfig{}) {
		t.Fatal("applying faults to an unknown session should fail")
	}
	if !manager.Drop(b.ID(), "debug") {
		t.Fatal("dropping a live session failed")
	}
	if manager.Drop("sess_missing", "debug") {
		t.Fatal("dropping an unknown session should fail")
	}
}

// stubConn is an inert delivery.Conn used where a real socket is not needed.
type stubConn struct{}

func (stubConn) WriteMessage(context.Context, []byte) error { return nil }
func (stubConn) ReadMessage(context.Context) ([]byte, error) {
	return nil, fmt.Errorf("stub: no reads")
}
func (stubConn) Close() error       { return nil }
func (stubConn) RemoteAddr() string { return "stub:0" }
