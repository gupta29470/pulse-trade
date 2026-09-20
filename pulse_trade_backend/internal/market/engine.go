package market

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// State is the engine's lifecycle state.
type State string

const (
	StateStarting State = "STARTING"
	StateWarming  State = "WARMING"
	StateLive     State = "LIVE"
	StatePaused   State = "PAUSED"
	StateDegraded State = "DEGRADED"
	StateStopped  State = "STOPPED"
)

// ErrProviderClosed is returned when the upstream event stream ends.
var ErrProviderClosed = errors.New("market: provider stream closed")

// Recorder is the narrow metrics surface the engine needs. It is declared here,
// by the consumer, so this package never depends on the metrics implementation.
type Recorder interface {
	RecordEngineEvent(observability.EngineEvent)
	RecordCandleClose(domain.Candle)
}

// Config configures the engine.
type Config struct {
	Symbol              domain.Symbol
	Seed                int64
	BookLevels          int
	BookDeltaWindow     int
	BookRefreshHz       float64
	WarmupEvents        int
	RecentTradesCap     int
	HistoryDepth        int
	VolatilityBurstRate float64
	BusCapacity         int
}

func (c Config) withDefaults() Config {
	if c.BookLevels < 15 {
		c.BookLevels = 100
	}
	if c.BookDeltaWindow < 10 {
		c.BookDeltaWindow = 15
	}
	if c.BookRefreshHz <= 0 {
		c.BookRefreshHz = 10
	}
	if c.RecentTradesCap < 50 {
		c.RecentTradesCap = 200
	}
	if c.HistoryDepth <= 0 {
		c.HistoryDepth = 500
	}
	if c.BusCapacity <= 0 {
		c.BusCapacity = 256
	}
	return c
}

// Engine owns the canonical market state. Exactly one goroutine writes it (the
// tick loop); every other accessor takes the read lock only long enough to copy
// what it needs.
type Engine struct {
	cfg      Config
	symbol   domain.Symbol
	provider exchange.MarketDataProvider
	clock    domain.Clock
	bus      *Bus
	recorder Recorder

	book        *OrderBook
	aggregators []*CandleAggregator
	byInterval  map[domain.Interval]*CandleAggregator
	summary     *Summary24h
	trades      *TradeRing

	rng *rand.Rand

	mu         sync.RWMutex
	epoch      uint64
	eventIndex uint64
	state      State
	lastPrice  domain.Price
	warmupDone bool
	lastErr    error
}

// New builds an engine and bootstraps the canonical book from the provider's
// snapshot. The book is seeded before any trade is applied so the first client
// always sees a complete, valid book.
func New(ctx context.Context, cfg Config, provider exchange.MarketDataProvider, bus *Bus, recorder Recorder, clock domain.Clock) (*Engine, error) {
	cfg = cfg.withDefaults()
	if clock == nil {
		clock = domain.SystemClock()
	}
	if bus == nil {
		bus = NewBus()
	}
	if recorder == nil {
		recorder = nopRecorder{}
	}

	e := &Engine{
		cfg:        cfg,
		symbol:     cfg.Symbol,
		provider:   provider,
		clock:      clock,
		bus:        bus,
		recorder:   recorder,
		summary:    NewSummary24h(cfg.Symbol),
		trades:     NewTradeRing(cfg.RecentTradesCap),
		byInterval: make(map[domain.Interval]*CandleAggregator),
		// The book's churn randomness is seeded separately from the trade stream
		// so the two sequences do not correlate, while both stay reproducible.
		rng:   rand.New(rand.NewPCG(uint64(cfg.Seed)^0x2545F4914F6CDD1D, uint64(cfg.Seed))),
		state: StateStarting,
	}

	for _, iv := range domain.Intervals() {
		agg := NewCandleAggregator(cfg.Symbol, iv, cfg.HistoryDepth)
		e.aggregators = append(e.aggregators, agg)
		e.byInterval[iv] = agg
	}

	e.book = NewOrderBook(cfg.Symbol, cfg.BookLevels, cfg.BookDeltaWindow)

	snap, err := provider.Snapshot(ctx, cfg.Symbol.ID)
	if err != nil {
		return nil, fmt.Errorf("market: bootstrap snapshot: %w", err)
	}
	if err := e.book.Install(snap.Epoch, snap.UpdateID, snap.Bids, snap.Asks); err != nil {
		return nil, fmt.Errorf("market: install bootstrap book: %w", err)
	}
	return e, nil
}

// --- lifecycle --------------------------------------------------------------

// Run replays the warmup window, then processes live events until ctx ends.
//
// Warmup uses the same aggregation code path as live trading; the only
// difference is that events are not published and not recorded, because there are
// no clients yet and the metrics would only be a startup artifact.
func (e *Engine) Run(ctx context.Context) error {
	stream, err := e.provider.Stream(ctx, e.symbol.ID)
	if err != nil {
		return fmt.Errorf("market: open provider stream: %w", err)
	}

	if err := e.warmup(ctx, stream); err != nil {
		return err
	}

	e.setState(StateLive)
	e.publishStatus("live")

	refreshEvery := time.Duration(float64(time.Second) / e.cfg.BookRefreshHz)
	ticker := time.NewTicker(refreshEvery)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			e.setState(StateStopped)
			e.publishStatus("stopped")
			return nil
		case <-ticker.C:
			if e.State() == StatePaused {
				continue
			}
			e.refreshBook()
		case ev, ok := <-stream:
			if !ok {
				e.setState(StateDegraded)
				e.lastErr = ErrProviderClosed
				e.publishStatus("provider_closed")
				return ErrProviderClosed
			}
			if e.State() == StatePaused {
				continue
			}
			e.applyEvent(ev, true)
		}
	}
}

func (e *Engine) warmup(ctx context.Context, stream <-chan exchange.MarketEvent) error {
	e.setState(StateWarming)
	if pc, ok := e.provider.(exchange.PaceController); ok {
		pc.SetPace(exchange.PaceFast)
	}

	budget := e.cfg.WarmupEvents
	if budget <= 0 {
		budget = 200_000
	}
	start := e.clock.Now()

	for i := 0; i < budget; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-stream:
			if !ok {
				return ErrProviderClosed
			}
			// emit=false: aggregate silently, do not publish or record.
			e.applyEvent(ev, false)
		}
	}

	if pc, ok := e.provider.(exchange.PaceController); ok {
		pc.SetPace(exchange.PaceRealtime)
	}

	e.mu.Lock()
	e.warmupDone = true
	e.mu.Unlock()

	e.recorder.RecordEngineEvent(observability.EngineEvent{
		Event:      "WARMUP_COMPLETE",
		Epoch:      e.Epoch(),
		EventIndex: e.EventIndex(),
		UpdateID:   e.UpdateID(),
		DurationMs: e.clock.Now().Sub(start).Milliseconds(),
		Detail:     fmt.Sprintf("events=%d", budget),
		At:         e.clock.Now(),
	})
	return nil
}

// applyEvent is the single write path into canonical state.
func (e *Engine) applyEvent(ev exchange.MarketEvent, emit bool) {
	switch evt := ev.(type) {
	case exchange.TradeEvent:
		e.applyTrade(evt.Trade, emit)
	case exchange.BookDeltaEvent:
		e.applyProviderDelta(evt, emit)
	case exchange.FaultEvent:
		e.recorder.RecordEngineEvent(observability.EngineEvent{
			Event: "FAULT_INJECTED", Epoch: e.Epoch(), Detail: evt.Kind + ": " + evt.Description, At: evt.At(),
		})
	case exchange.HeartbeatEvent:
		// Liveness only; nothing to apply.
	}
}

// applyTrade folds one trade into the canonical state. The order of operations is
// part of the contract: state is fully updated before anything is published, so a
// subscriber reacting to the trade always observes post-trade values.
func (e *Engine) applyTrade(t domain.Trade, emit bool) {
	// The whole canonical mutation happens under the write lock. Readers take the
	// read lock only long enough to copy what they need, so holding it for the
	// duration of one trade keeps every reader consistent with the writer.
	e.mu.Lock()
	e.eventIndex++
	e.lastPrice = t.Price
	mutation := e.book.ApplyTrade(t, e.rng)
	if mutation != nil && mutation.Err != nil {
		err := mutation.Err
		e.mu.Unlock()
		e.recordInvariant(err, t)
		return
	}

	var closedCandles []domain.Candle
	var changedCandles []domain.Candle
	for _, agg := range e.aggregators {
		changed, closed := agg.Apply(t)
		if changed {
			if active, ok := agg.Active(); ok {
				changedCandles = append(changedCandles, active)
			}
		}
		if closed != nil {
			if err := closed.Validate(); err != nil {
				e.mu.Unlock()
				e.recordInvariant(err, t)
				e.mu.Lock()
			}
			closedCandles = append(closedCandles, *closed)
		}
	}

	e.summary.Apply(t)
	e.trades.Push(t)
	e.mu.Unlock()

	if !emit {
		return
	}

	for _, c := range closedCandles {
		e.recorder.RecordCandleClose(c)
		e.bus.Publish(Event{Kind: EventCandleClosed, Candle: &c})
	}
	if mutation != nil {
		window := BookWindow{
			Symbol:      mutation.Symbol,
			Epoch:       mutation.Epoch,
			UpdateID:    mutation.LastUpdate,
			Bids:        mutation.Bids,
			Asks:        mutation.Asks,
			At:          mutation.At,
			Description: "trade",
		}
		e.bus.Publish(Event{Kind: EventBookWindow, Book: &window})
	}
	for i := range changedCandles {
		e.bus.Publish(Event{Kind: EventCandleChanged, Candle: &changedCandles[i]})
	}
	e.bus.Publish(Event{Kind: EventTrade, Trade: &t})
}

func (e *Engine) applyProviderDelta(evt exchange.BookDeltaEvent, emit bool) {
	e.mu.Lock()
	mutation, err := e.book.ApplyDelta(evt.Epoch, evt.FirstUpdate, evt.LastUpdate, evt.Bids, evt.Asks, evt.Timestamp)
	e.mu.Unlock()
	if err != nil {
		e.recorder.RecordEngineEvent(observability.EngineEvent{
			Event: "PROVIDER_DELTA_REJECTED", Epoch: e.Epoch(), Detail: err.Error(), At: evt.Timestamp,
		})
		return
	}
	if emit && mutation != nil {
		window := BookWindow{
			Symbol: mutation.Symbol, Epoch: mutation.Epoch, UpdateID: mutation.LastUpdate,
			Bids: mutation.Bids, Asks: mutation.Asks, At: mutation.At, Description: "provider",
		}
		e.bus.Publish(Event{Kind: EventBookWindow, Book: &window})
	}
}

// refreshBook applies periodic depth churn that is independent of trades, which
// is what makes a live book look alive during a quiet market.
func (e *Engine) refreshBook() {
	e.mu.Lock()
	mid := e.lastPrice
	if mid == 0 {
		if best, ok := e.book.BestBid(); ok {
			mid = best.Price
		}
	}
	mutation := e.book.Refresh(e.rng, mid, e.clock.Now())
	e.mu.Unlock()
	if mutation == nil {
		return
	}
	if mutation.Err != nil {
		e.recordInvariant(mutation.Err, domain.Trade{})
		return
	}
	window := BookWindow{
		Symbol: mutation.Symbol, Epoch: mutation.Epoch, UpdateID: mutation.LastUpdate,
		Bids: mutation.Bids, Asks: mutation.Asks, At: mutation.At, Description: "refresh",
	}
	e.bus.Publish(Event{Kind: EventBookWindow, Book: &window})
}

// Step applies one event synchronously. It exists for tests and for the replay
// demo, where the caller controls the clock instead of the tick loop.
func (e *Engine) Step(ev exchange.MarketEvent) { e.applyEvent(ev, true) }

// StepTrade applies one trade synchronously, for tests.
func (e *Engine) StepTrade(t domain.Trade) { e.applyTrade(t, true) }

// RefreshBook exposes one churn cycle, for tests.
func (e *Engine) RefreshBook() { e.refreshBook() }

// recordInvariant must be called without the engine lock held: it reads engine
// state through the public accessors, which take the read lock themselves.
func (e *Engine) recordInvariant(err error, t domain.Trade) {
	e.recorder.RecordEngineEvent(observability.EngineEvent{
		Event:      "INVARIANT_VIOLATION",
		Epoch:      e.Epoch(),
		EventIndex: e.EventIndex(),
		UpdateID:   e.UpdateID(),
		TradeID:    t.ID,
		Detail:     err.Error(),
		At:         e.clock.Now(),
	})
}

// --- debug controls ---------------------------------------------------------

// Pause stops market generation. Sockets stay open; clients see a PAUSED status.
func (e *Engine) Pause() {
	if p, ok := e.provider.(exchange.Pauser); ok {
		p.Pause()
	}
	e.setState(StatePaused)
	e.publishStatus("generator paused")
}

// Resume restarts market generation.
func (e *Engine) Resume() {
	if p, ok := e.provider.(exchange.Pauser); ok {
		p.Resume()
	}
	e.setState(StateLive)
	e.publishStatus("generator resumed")
}

// Burst forces a volatility burst for the given duration.
func (e *Engine) Burst(d time.Duration) {
	if b, ok := e.provider.(exchange.Burster); ok {
		b.ForceBurst(d)
	}
	e.recorder.RecordEngineEvent(observability.EngineEvent{
		Event: "BURST_START", Epoch: e.Epoch(), Detail: d.String(), At: e.clock.Now(),
	})
}

// Reset returns the market to its bootstrap state: a new epoch, a fresh book from
// the provider snapshot, and cleared candles, summary and trade tape. Sessions
// keep their tiers, because a reset is a market event and not a connection event.
func (e *Engine) Reset(ctx context.Context) error {
	snap, err := e.provider.Snapshot(ctx, e.symbol.ID)
	if err != nil {
		return fmt.Errorf("market: reset snapshot: %w", err)
	}

	// The locked section is scoped rather than deferred: publishStatus reads engine
	// state through the accessors, which take the read lock, and sync.RWMutex is
	// not reentrant.
	epoch, err := func() (uint64, error) {
		e.mu.Lock()
		defer e.mu.Unlock()

		e.epoch++
		if err := e.book.Install(e.epoch, snap.UpdateID, snap.Bids, snap.Asks); err != nil {
			return 0, fmt.Errorf("market: reset book: %w", err)
		}
		e.eventIndex = 0
		e.lastPrice = 0

		for _, agg := range e.aggregators {
			agg.Reset()
		}
		e.summary.Reset()
		e.trades.Reset()
		return e.epoch, nil
	}()
	if err != nil {
		return err
	}

	e.recorder.RecordEngineEvent(observability.EngineEvent{
		Event: "RESET", Epoch: epoch, UpdateID: e.UpdateID(), At: e.clock.Now(),
	})
	e.publishStatus("market reset")
	return nil
}

// --- read API ---------------------------------------------------------------

// Book returns a deep copy of the canonical book.
func (e *Engine) Book() domain.OrderBookSnapshot {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.book.Snapshot(e.clock.Now())
}

// BookWindow returns the currently published window.
func (e *Engine) BookWindow() BookWindow {
	e.mu.RLock()
	defer e.mu.RUnlock()
	bids, asks := e.book.windowLocked()
	return BookWindow{
		Symbol:   e.symbol.ID,
		Epoch:    e.book.Epoch(),
		UpdateID: e.book.UpdateID(),
		Bids:     bids,
		Asks:     asks,
		At:       e.clock.Now(),
	}
}

// Candles returns history for one interval, ascending, including the active
// bucket, and reports whether the final element **is** that still-forming
// bucket.
//
// The flag is answered here rather than derived by the caller so the history and
// the verdict on its last element come from one read lock. Two separate calls
// would let a bucket roll in between and label a finalised candle as active.
func (e *Engine) Candles(iv domain.Interval, limit int) ([]domain.Candle, bool, error) {
	agg, ok := e.byInterval[iv]
	if !ok {
		return nil, false, fmt.Errorf("%w: %q", domain.ErrUnsupportedInterval, string(iv))
	}
	e.mu.RLock()
	defer e.mu.RUnlock()
	history := agg.HistoryWithActive(limit)
	active, hasActive := agg.Active()
	lastIsActive := hasActive && len(history) > 0 &&
		history[len(history)-1].StartTime.Equal(active.StartTime)
	return history, lastIsActive, nil
}

// ActiveCandle returns the in-progress candle for one interval.
func (e *Engine) ActiveCandle(iv domain.Interval) (domain.Candle, bool) {
	agg, ok := e.byInterval[iv]
	if !ok {
		return domain.Candle{}, false
	}
	e.mu.RLock()
	defer e.mu.RUnlock()
	return agg.Active()
}

// Summary returns the rolling 24h view.
func (e *Engine) Summary() domain.MarketSummary {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.summary.Snapshot(e.clock.Now())
}

// RecentTrades returns the newest trades first.
func (e *Engine) RecentTrades(limit int) []domain.Trade {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.trades.Recent(limit)
}

// LastPrice returns the most recent trade price.
func (e *Engine) LastPrice() domain.Price {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.lastPrice != 0 {
		return e.lastPrice
	}
	if t, ok := e.trades.Last(); ok {
		return t.Price
	}
	if bid, ok := e.book.BestBid(); ok {
		return bid.Price
	}
	return 0
}

// State returns the lifecycle state.
func (e *Engine) State() State {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.state
}

// Epoch returns the reset generation.
func (e *Engine) Epoch() uint64 {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.epoch
}

// EventIndex returns how many events have been applied.
func (e *Engine) EventIndex() uint64 {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.eventIndex
}

// UpdateID returns the canonical book's last mutation id.
func (e *Engine) UpdateID() uint64 {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.book.UpdateID()
}

// WarmupComplete reports whether history has been built.
func (e *Engine) WarmupComplete() bool {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.warmupDone
}

// Err returns the error that moved the engine out of LIVE, if any.
func (e *Engine) Err() error {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.lastErr
}

// Symbol returns the market this engine serves.
func (e *Engine) Symbol() domain.Symbol { return e.symbol }

// Bus exposes the canonical event bus so the delivery layer can subscribe.
func (e *Engine) Bus() *Bus { return e.bus }

// Subscribe attaches a subscriber to the canonical bus.
func (e *Engine) Subscribe(name string, capacity int) *Subscription {
	return e.bus.Subscribe(name, capacity)
}

func (e *Engine) setState(s State) {
	e.mu.Lock()
	e.state = s
	e.mu.Unlock()
}

func (e *Engine) publishStatus(message string) {
	status := MarketStatus{State: e.State(), Epoch: e.Epoch(), Message: message, At: e.clock.Now()}
	e.bus.Publish(Event{Kind: EventMarketStatus, Status: &status})
}

// nopRecorder keeps the engine usable without optional wiring.
type nopRecorder struct{}

func (nopRecorder) RecordEngineEvent(observability.EngineEvent) {}
func (nopRecorder) RecordCandleClose(domain.Candle)             {}
