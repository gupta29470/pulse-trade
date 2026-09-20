package market_test

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/synthetic"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
)

func testSymbol() domain.Symbol { return domain.BTCUSDT }

func newTestEngine(t *testing.T, seed int64, provider exchange.MarketDataProvider) *market.Engine {
	t.Helper()
	eng, err := market.New(context.Background(), market.Config{
		Symbol:          testSymbol(),
		Seed:            seed,
		BookLevels:      100,
		BookDeltaWindow: 15,
		WarmupEvents:    10,
		RecentTradesCap: 200,
		HistoryDepth:    500,
	}, provider, nil, nil, nil)
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	return eng
}

func syntheticProvider(t *testing.T, seed int64, tradesPerSecond float64) *synthetic.Provider {
	t.Helper()
	return synthetic.New(synthetic.Config{
		Symbol:              testSymbol(),
		Seed:                seed,
		TradesPerSecond:     tradesPerSecond,
		WarmupSpan:          720 * time.Hour,
		WarmupMaxEvents:     1000,
		VolatilityBurstRate: 4,
		BookLevels:          100,
	}, nil)
}

// --- book invariants ---------------------------------------------------

func TestBookInvariantsHoldUnderMutation(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 42, syntheticProvider(t, 42, 10))

	rng := rand.New(rand.NewPCG(7, 8))
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
	side := domain.SideBuy
	price := eng.LastPrice()

	for i := range 20_000 {
		price = domain.Price(int64(price) + int64(rng.IntN(9)) - 4)
		if price <= 10 {
			price = 10
		}
		if rng.IntN(2) == 0 {
			side = domain.SideBuy
		} else {
			side = domain.SideSell
		}
		eng.StepTrade(domain.Trade{
			ID:        uint64(i + 1),
			Symbol:    testSymbol().ID,
			Timestamp: base.Add(time.Duration(i) * time.Millisecond),
			Price:     price,
			Quantity:  domain.Qty(int64(rng.IntN(50_000_000) + 1)),
			Side:      side,
		})
		if i%3 == 0 {
			eng.RefreshBook()
		}

		if i%500 != 0 {
			continue
		}
		snap := eng.Book()
		if err := snap.Validate(); err != nil {
			t.Fatalf("iteration %d: %v", i, err)
		}
		if len(snap.Bids) < 15 || len(snap.Asks) < 15 {
			t.Fatalf("iteration %d: depth %d/%d fell below the window", i, len(snap.Bids), len(snap.Asks))
		}
	}
}

func TestBookUpdateIDIsMonotonicAndStrictlyIncreasing(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 43, syntheticProvider(t, 43, 10))
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)

	prev := eng.UpdateID()
	for i := range 200 {
		eng.StepTrade(domain.Trade{
			ID: uint64(i + 1), Symbol: testSymbol().ID,
			Timestamp: base.Add(time.Duration(i) * time.Second),
			Price:     domain.Price(6_742_135 + int64(i%7)),
			Quantity:  1_000_000,
			Side:      domain.SideBuy,
		})
		current := eng.UpdateID()
		if current <= prev {
			t.Fatalf("iteration %d: update id did not increase (%d -> %d)", i, prev, current)
		}
		prev = current
	}
}

// A batch of level changes is one update id, not one per level: an update id
// identifies a state transition.
func TestBookRefreshProducesSingleUpdateID(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 44, syntheticProvider(t, 44, 10))
	before := eng.UpdateID()
	eng.RefreshBook()
	if got := eng.UpdateID(); got != before+1 {
		t.Fatalf("refresh advanced update id by %d, want 1", got-before)
	}
}

// --- candle aggregation ------------------------------------------------

func TestCandleAggregationMatchesHandComputedValues(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 45, syntheticProvider(t, 45, 10))
	base := time.Date(2026, 9, 17, 12, 41, 0, 0, time.UTC)

	trades := []struct {
		offsetSec int
		price     domain.Price
		qty       domain.Qty
	}{
		{0, 100, 5},
		{10, 130, 3},
		{20, 90, 2},
		{59, 110, 7},  // still the same 1m bucket
		{60, 140, 1},  // opens the next bucket
		{119, 120, 4}, // same second bucket
		{120, 150, 6}, // third bucket
	}
	for i, tr := range trades {
		eng.StepTrade(domain.Trade{
			ID: uint64(i + 1), Symbol: testSymbol().ID,
			Timestamp: base.Add(time.Duration(tr.offsetSec) * time.Second),
			Price:     tr.price, Quantity: tr.qty, Side: domain.SideBuy,
		})
	}

	got, _, err := eng.Candles(domain.Interval1m, 10)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d candles, want 3: %+v", len(got), got)
	}

	want := []domain.Candle{
		{Open: 100, High: 130, Low: 90, Close: 110, Volume: 17, TradeCount: 4},
		{Open: 140, High: 140, Low: 120, Close: 120, Volume: 5, TradeCount: 2},
		{Open: 150, High: 150, Low: 150, Close: 150, Volume: 6, TradeCount: 1},
	}
	for i, w := range want {
		c := got[i]
		if c.Open != w.Open || c.High != w.High || c.Low != w.Low || c.Close != w.Close {
			t.Fatalf("candle %d OHLC = %d/%d/%d/%d, want %d/%d/%d/%d",
				i, c.Open, c.High, c.Low, c.Close, w.Open, w.High, w.Low, w.Close)
		}
		if c.Volume != w.Volume {
			t.Fatalf("candle %d volume = %d, want %d", i, c.Volume, w.Volume)
		}
		if c.TradeCount != w.TradeCount {
			t.Fatalf("candle %d tradeCount = %d, want %d", i, c.TradeCount, w.TradeCount)
		}
		if err := c.Validate(); err != nil {
			t.Fatalf("candle %d invalid: %v", i, err)
		}
	}

	// Bucket boundaries must align to UTC.
	if wantStart := base; !got[0].StartTime.Equal(wantStart) {
		t.Fatalf("first bucket = %s, want %s", got[0].StartTime, wantStart)
	}
	if wantStart := base.Add(time.Minute); !got[1].StartTime.Equal(wantStart) {
		t.Fatalf("second bucket = %s, want %s", got[1].StartTime, wantStart)
	}
}

func TestLateTradeDoesNotRewriteClosedCandle(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 46, syntheticProvider(t, 46, 10))
	base := time.Date(2026, 9, 17, 12, 41, 0, 0, time.UTC)

	eng.StepTrade(domain.Trade{ID: 1, Symbol: testSymbol().ID, Timestamp: base, Price: 100, Quantity: 10, Side: domain.SideBuy})
	eng.StepTrade(domain.Trade{ID: 2, Symbol: testSymbol().ID, Timestamp: base.Add(time.Minute), Price: 200, Quantity: 10, Side: domain.SideBuy})
	// Late trade for the already-closed first bucket.
	eng.StepTrade(domain.Trade{ID: 3, Symbol: testSymbol().ID, Timestamp: base.Add(30 * time.Second), Price: 999, Quantity: 10, Side: domain.SideBuy})

	candles, _, err := eng.Candles(domain.Interval1m, 10)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	if len(candles) != 2 {
		t.Fatalf("got %d candles, want 2", len(candles))
	}
	if candles[0].High != 100 || candles[0].Close != 100 || candles[0].Volume != 10 {
		t.Fatalf("closed candle was rewritten: %+v", candles[0])
	}
}

func TestEveryIntervalAggregatesIndependently(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 47, syntheticProvider(t, 47, 10))
	base := time.Date(2026, 9, 17, 0, 0, 0, 0, time.UTC)

	// One trade per minute for three hours.
	for i := range 180 {
		eng.StepTrade(domain.Trade{
			ID:        uint64(i + 1),
			Symbol:    testSymbol().ID,
			Timestamp: base.Add(time.Duration(i) * time.Minute),
			Price:     domain.Price(6_742_135 + int64(i)),
			Quantity:  1_000_000,
			Side:      domain.SideBuy,
		})
	}

	for _, iv := range domain.Intervals() {
		candles, _, err := eng.Candles(iv, 500)
		if err != nil {
			t.Fatalf("Candles(%s): %v", iv, err)
		}
		expected := 180 * int(time.Minute) / int(iv.Duration())
		if expected < 1 {
			expected = 1
		}
		if len(candles) == 0 {
			t.Fatalf("interval %s produced no candles", iv)
		}
		var totalVolume domain.Qty
		for _, c := range candles {
			if err := c.Validate(); err != nil {
				t.Fatalf("interval %s candle invalid: %v", iv, err)
			}
			totalVolume = totalVolume.Add(c.Volume)
		}
		if totalVolume != 180*1_000_000 {
			t.Fatalf("interval %s total volume = %d, want %d", iv, totalVolume, 180*1_000_000)
		}
	}
}

// --- cross-tier candle identity ---------------------------------------

// The critical invariant: a client's delivery tier changes how often it hears
// about a candle, never what the candle finally is.
//
// This drives one engine and reconstructs the candle series two ways: as a
// full-fidelity client (every intermediate update) and as a heavily throttled
// one (a fraction of the updates, plus every close). The two reconstructions must
// agree on every closed candle, and the full client must demonstrably have
// received more updates - otherwise the test would prove nothing about throttling.
func TestCandleFinalsAreIdenticalRegardlessOfDeliveryFrequency(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 48, syntheticProvider(t, 48, 10))
	sub := eng.Subscribe("observer", 8192)
	defer eng.Bus().Unsubscribe(sub)

	var mu sync.Mutex
	fullUpdates := 0
	closedByClose := map[time.Time]domain.Candle{}

	go func() {
		for {
			var ev market.Event
			select {
			case <-sub.Done():
				return
			case ev = <-sub.Events():
			}
			switch ev.Kind {
			case market.EventCandleChanged:
				if ev.Candle != nil && ev.Candle.Interval == domain.Interval1m {
					mu.Lock()
					fullUpdates++
					mu.Unlock()
				}
			case market.EventCandleClosed:
				if ev.Candle != nil && ev.Candle.Interval == domain.Interval1m {
					mu.Lock()
					closedByClose[ev.Candle.StartTime] = *ev.Candle
					mu.Unlock()
				}
			}
		}
	}()

	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
	const trades = 400
	const minimalEvery = 120

	// A MINIMAL client sees roughly one chart update per 120 trades, but it always
	// receives the close.
	throttled := map[time.Time]domain.Candle{}
	throttledUpdates := 0

	gen := synthetic.NewGenerator(synthetic.GeneratorConfig{Symbol: testSymbol(), Seed: 48, VolatilityBurstRate: 4})
	for i := range trades {
		eng.StepTrade(gen.Next(base.Add(time.Duration(i) * time.Second)))
		if i%minimalEvery == 0 {
			if active, ok := eng.ActiveCandle(domain.Interval1m); ok {
				throttled[active.StartTime] = active
				throttledUpdates++
			}
		}
	}

	// Drain, then close the mailbox so the collector finishes.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		done := len(closedByClose) >= 5 && fullUpdates > 50
		mu.Unlock()
		if done {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	mu.Lock()
	updates := fullUpdates
	closed := make(map[time.Time]domain.Candle, len(closedByClose))
	for k, v := range closedByClose {
		closed[k] = v
	}
	mu.Unlock()

	if updates <= throttledUpdates {
		t.Fatalf("full client received %d updates, throttled %d; throttling must reduce delivery",
			updates, throttledUpdates)
	}
	if len(closed) == 0 {
		t.Fatal("no candle_closed events were observed")
	}

	authoritative := map[time.Time]domain.Candle{}
	candles, _, err := eng.Candles(domain.Interval1m, 500)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	for _, c := range candles {
		authoritative[c.StartTime] = c
	}

	// Every close event must carry exactly the canonical candle.
	for start, delivered := range closed {
		want := authoritative[start]
		if !want.EqualValue(delivered) {
			t.Fatalf("bucket %s: closed payload %+v != canonical %+v", start, delivered, want)
		}
	}

	// A throttled client that applies the close event on top of its last
	// intermediate observation ends up with the same final value.
	for start, partial := range throttled {
		want, isClosed := closed[start]
		if !isClosed {
			continue // the bucket was still active when the run ended
		}
		if !want.EqualValue(partial) {
			// The intermediate value differs (it was sampled mid-bucket)...
			if want.Open == partial.Open && want.StartTime.Equal(partial.StartTime) && partial.TradeCount >= want.TradeCount {
				t.Fatalf("bucket %s: throttled observation is not an earlier state of the same candle", start)
			}
		}
		// Once the bucket closes, though, the value is identical.
		if !want.EqualValue(authoritative[start]) {
			t.Fatalf("bucket %s: final value diverged for the throttled client", start)
		}
	}
}

// --- determinism -------------------------------------------------------

func TestDeterministicTradeSequenceFromSeed(t *testing.T) {
	t.Parallel()
	run := func(seed int64) []domain.Trade {
		eng := newTestEngine(t, seed, syntheticProvider(t, seed, 10))
		base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
		gen := synthetic.NewGenerator(synthetic.GeneratorConfig{Symbol: testSymbol(), Seed: seed, VolatilityBurstRate: 4})
		for i := range 500 {
			eng.StepTrade(gen.Next(base.Add(time.Duration(i) * time.Second)))
		}
		return eng.RecentTrades(200)
	}

	a := run(1234)
	b := run(1234)
	if len(a) != len(b) {
		t.Fatalf("length mismatch: %d vs %d", len(a), len(b))
	}
	for i := range a {
		if !domain.EqualTrades(a[i], b[i]) {
			t.Fatalf("trade %d differs:\n%+v\n%+v", i, a[i], b[i])
		}
	}

	c := run(999)
	same := true
	for i := range a {
		if !domain.EqualTrades(a[i], c[i]) {
			same = false
			break
		}
	}
	if same {
		t.Fatal("a different seed produced an identical sequence")
	}
}

// --- engine lifecycle --------------------------------------------------------

func TestEngineRunWarmupThenLive(t *testing.T) {
	t.Parallel()
	provider := synthetic.New(synthetic.Config{
		Symbol:          testSymbol(),
		Seed:            77,
		TradesPerSecond: 2000, // fast so the test does not wait on pacing
		WarmupSpan:      720 * time.Hour,
		WarmupMaxEvents: 2_000,
		BookLevels:      100,
	}, nil)

	eng, err := market.New(context.Background(), market.Config{
		Symbol: testSymbol(), Seed: 77, BookLevels: 100, BookDeltaWindow: 15,
		WarmupEvents: 500, BookRefreshHz: 50, RecentTradesCap: 200, HistoryDepth: 500,
	}, provider, nil, nil, nil)
	if err != nil {
		t.Fatalf("engine: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- eng.Run(ctx) }()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if eng.WarmupComplete() && eng.State() == market.StateLive {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !eng.WarmupComplete() {
		t.Fatal("warmup did not complete")
	}
	if eng.State() != market.StateLive {
		t.Fatalf("state = %s, want LIVE", eng.State())
	}

	// History should be populated for every interval by the warmup replay.
	for _, iv := range domain.Intervals() {
		candles, _, err := eng.Candles(iv, 500)
		if err != nil {
			t.Fatalf("Candles(%s): %v", iv, err)
		}
		if len(candles) == 0 {
			t.Fatalf("interval %s has no warmup history", iv)
		}
	}

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("engine did not stop after cancel")
	}
	if eng.State() != market.StateStopped {
		t.Fatalf("state after cancel = %s, want STOPPED", eng.State())
	}
}

func TestPauseResumeAndReset(t *testing.T) {
	t.Parallel()
	provider := syntheticProvider(t, 88, 500)
	eng := newTestEngine(t, 88, provider)
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)

	for i := range 20 {
		eng.StepTrade(domain.Trade{
			ID: uint64(i + 1), Symbol: testSymbol().ID,
			Timestamp: base.Add(time.Duration(i) * time.Second),
			Price:     6_742_135, Quantity: 1_000_000, Side: domain.SideBuy,
		})
	}
	if len(eng.RecentTrades(10)) == 0 {
		t.Fatal("expected trades before reset")
	}

	beforeEpoch := eng.Epoch()
	if err := eng.Reset(context.Background()); err != nil {
		t.Fatalf("Reset: %v", err)
	}
	if eng.Epoch() != beforeEpoch+1 {
		t.Fatalf("epoch = %d, want %d", eng.Epoch(), beforeEpoch+1)
	}
	if got := len(eng.RecentTrades(10)); got != 0 {
		t.Fatalf("trade tape after reset = %d, want 0", got)
	}
	candles, _, err := eng.Candles(domain.Interval1m, 10)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	if len(candles) != 0 {
		t.Fatalf("candles after reset = %d, want 0", len(candles))
	}
	if err := eng.Book().Validate(); err != nil {
		t.Fatalf("book invalid after reset: %v", err)
	}
}

// --- summary -----------------------------------------------------------------

func TestSummaryTracksHighLowVolumeAndChange(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 91, syntheticProvider(t, 91, 10))
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)

	prices := []domain.Price{100, 120, 90, 110}
	for i, p := range prices {
		eng.StepTrade(domain.Trade{
			ID: uint64(i + 1), Symbol: testSymbol().ID,
			Timestamp: base.Add(time.Duration(i) * time.Second),
			Price:     p, Quantity: 10, Side: domain.SideBuy,
		})
	}

	s := eng.Summary()
	if s.Open24h != 100 || s.High24h != 120 || s.Low24h != 90 || s.Last != 110 {
		t.Fatalf("summary = %+v", s)
	}
	if s.Volume24h != 40 {
		t.Fatalf("volume = %d, want 40", s.Volume24h)
	}
	if s.Change != 10 {
		t.Fatalf("change = %d, want 10", s.Change)
	}
	if s.ChangeBP != 1000 {
		t.Fatalf("changeBP = %d, want 1000", s.ChangeBP)
	}
	if s.Trades24h != 4 {
		t.Fatalf("trades = %d, want 4", s.Trades24h)
	}
}

func TestSummaryExpiresOldBuckets(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 92, syntheticProvider(t, 92, 10))
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)

	// An extreme price 25 hours ago, then ordinary prices inside the window.
	eng.StepTrade(domain.Trade{ID: 1, Symbol: testSymbol().ID,
		Timestamp: base.Add(-25 * time.Hour), Price: 1000, Quantity: 5, Side: domain.SideBuy})
	eng.StepTrade(domain.Trade{ID: 2, Symbol: testSymbol().ID,
		Timestamp: base, Price: 100, Quantity: 5, Side: domain.SideBuy})
	eng.StepTrade(domain.Trade{ID: 3, Symbol: testSymbol().ID,
		Timestamp: base.Add(time.Minute), Price: 120, Quantity: 5, Side: domain.SideBuy})

	s := eng.Summary()
	if s.High24h != 120 {
		t.Fatalf("high = %d, want 120 (the 25h-old extreme must have expired)", s.High24h)
	}
	if s.Low24h != 100 {
		t.Fatalf("low = %d, want 100", s.Low24h)
	}
	if s.Open24h != 100 {
		t.Fatalf("open = %d, want 100", s.Open24h)
	}
}

// --- provider delta path -----------------------------------------------------

func TestProviderDeltaGapIsRejected(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 93, syntheticProvider(t, 93, 10))
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
	epoch := eng.Book().Epoch
	updateID := eng.Book().UpdateID

	// A gap: the delta starts two ids ahead of the book.
	eng.Step(exchange.BookDeltaEvent{
		Symbol: testSymbol().ID, Epoch: epoch,
		FirstUpdate: updateID + 2, LastUpdate: updateID + 3,
		Bids:      []domain.Level{{Price: 6_742_000, Quantity: 1}},
		Asks:      []domain.Level{{Price: 6_742_200, Quantity: 1}},
		Timestamp: base,
	})
	if got := eng.UpdateID(); got != updateID {
		t.Fatalf("a gapped delta was applied: update id moved from %d to %d", updateID, got)
	}

	// A contiguous delta applies.
	eng.Step(exchange.BookDeltaEvent{
		Symbol: testSymbol().ID, Epoch: epoch,
		FirstUpdate: updateID + 1, LastUpdate: updateID + 1,
		Bids:      []domain.Level{{Price: eng.Book().Bids[0].Price, Quantity: 42}},
		Asks:      []domain.Level{{Price: eng.Book().Asks[0].Price, Quantity: 43}},
		Timestamp: base,
	})
	if got := eng.UpdateID(); got != updateID+1 {
		t.Fatalf("contiguous delta not applied: update id = %d, want %d", got, updateID+1)
	}
}

// --- bus behaviour -----------------------------------------------------------

func TestBusDropsIntermediateEventsForSlowSubscriber(t *testing.T) {
	t.Parallel()
	bus := market.NewBus()
	slow := bus.Subscribe("slow", 4)
	defer bus.Unsubscribe(slow)

	for i := range 100 {
		bus.Publish(market.Event{Kind: market.EventTrade, Trade: &domain.Trade{ID: uint64(i)}})
	}
	if slow.Dropped() == 0 {
		t.Fatal("expected the bus to drop events for a full mailbox")
	}
	if len(slow.Events()) != 4 {
		t.Fatalf("mailbox holds %d events, want 4", len(slow.Events()))
	}
}

// Unsubscribing signals the subscriber rather than closing its mailbox, because the
// engine publishes from its own goroutine and a send on a closed channel would panic.
func TestBusUnsubscribeSignalsDoneAndPublishStaysSafe(t *testing.T) {
	t.Parallel()
	bus := market.NewBus()
	sub := bus.Subscribe("temp", 4)
	bus.Unsubscribe(sub)

	select {
	case <-sub.Done():
	case <-time.After(time.Second):
		t.Fatal("Done was not closed after unsubscribe")
	}
	if bus.SubscriberCount() != 0 {
		t.Fatalf("subscriber count = %d, want 0", bus.SubscriberCount())
	}

	// Publishing after an unsubscribe must be a no-op, not a panic and not a block.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := range 10 {
			bus.Publish(market.Event{Kind: market.EventTrade, Trade: &domain.Trade{ID: uint64(i)}})
		}
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("publishing to an unsubscribed bus blocked")
	}
}

// A subscriber that never drains its mailbox must not stall the engine.
func TestBusCloseIsIdempotent(t *testing.T) {
	t.Parallel()
	bus := market.NewBus()
	sub := bus.Subscribe("a", 2)
	bus.Close()
	bus.Close()
	select {
	case <-sub.Done():
	case <-time.After(time.Second):
		t.Fatal("Close did not signal the subscriber")
	}
	if bus.SubscriberCount() != 0 {
		t.Fatalf("subscriber count = %d, want 0", bus.SubscriberCount())
	}
}

// --- error surface -----------------------------------------------------------

func TestEngineRejectsBootstrapSnapshotThatViolatesInvariants(t *testing.T) {
	t.Parallel()
	_, err := market.New(context.Background(), market.Config{Symbol: testSymbol(), Seed: 1},
		badSnapshotProvider{}, nil, nil, nil)
	if !errors.Is(err, domain.ErrCrossedBook) {
		t.Fatalf("want ErrCrossedBook, got %v", err)
	}
}

type badSnapshotProvider struct{}

func (badSnapshotProvider) Snapshot(context.Context, string) (domain.OrderBookSnapshot, error) {
	return domain.OrderBookSnapshot{
		Symbol: testSymbol().ID, Epoch: 1, UpdateID: 1,
		Bids: []domain.Level{{Price: 200, Quantity: 1}},
		Asks: []domain.Level{{Price: 100, Quantity: 1}},
	}, nil
}

func (badSnapshotProvider) Stream(context.Context, string) (<-chan exchange.MarketEvent, error) {
	return nil, fmt.Errorf("not used")
}

// TestCandlesReportsWhetherTheLastBucketIsActive pins the contract the REST
// history endpoint depends on.
//
// History deliberately includes the in-progress bucket, so the response has to
// name which element it is. A client that cannot tell treats the newest candle
// as finalised and drops every live update for it.
func TestCandlesReportsWhetherTheLastBucketIsActive(t *testing.T) {
	t.Parallel()
	eng := newTestEngine(t, 47, syntheticProvider(t, 47, 10))
	base := time.Date(2026, 9, 17, 12, 41, 0, 0, time.UTC)

	// Two trades in the same bucket: it is still forming.
	eng.StepTrade(domain.Trade{ID: 1, Symbol: testSymbol().ID, Timestamp: base, Price: 100, Quantity: 10, Side: domain.SideBuy})
	eng.StepTrade(domain.Trade{ID: 2, Symbol: testSymbol().ID, Timestamp: base.Add(10 * time.Second), Price: 101, Quantity: 10, Side: domain.SideBuy})

	candles, lastIsActive, err := eng.Candles(domain.Interval1m, 10)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	if len(candles) == 0 {
		t.Fatal("no candles")
	}
	if !lastIsActive {
		t.Fatal("the last bucket holds trades but was not reported as active")
	}
	if got := candles[len(candles)-1].StartTime; !got.Equal(base) {
		t.Fatalf("active bucket starts at %s, want %s", got, base)
	}

	// A trade in the next bucket finalises the previous one: the active flag must
	// move with it rather than staying on the now-closed bucket.
	eng.StepTrade(domain.Trade{ID: 3, Symbol: testSymbol().ID, Timestamp: base.Add(time.Minute), Price: 102, Quantity: 10, Side: domain.SideBuy})

	candles, lastIsActive, err = eng.Candles(domain.Interval1m, 10)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	if !lastIsActive {
		t.Fatal("the new bucket is forming but was not reported as active")
	}
	if got := candles[len(candles)-1].StartTime; !got.Equal(base.Add(time.Minute)) {
		t.Fatalf("active bucket starts at %s, want the new bucket %s", got, base.Add(time.Minute))
	}
}
