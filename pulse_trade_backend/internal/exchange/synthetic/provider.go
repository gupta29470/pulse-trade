// Package synthetic is the deterministic market simulator that backs the running
// product. Every value it produces is a pure function of the configured seed and
// the event index, so a session is reproducible, faults are reproducible, and a
// bug report is reproducible from the seed alone.
package synthetic

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange"
)

// Config configures the provider.
type Config struct {
	Symbol              domain.Symbol
	Seed                int64
	TradesPerSecond     float64
	WarmupSpan          time.Duration
	WarmupMaxEvents     int
	VolatilityBurstRate float64
	BookLevels          int
	// StreamBuffer is the event channel capacity. The consumer is the engine's
	// tick loop, which never blocks on I/O, so a full buffer means the engine is
	// unhealthy and stalling the producer is the correct back-pressure signal.
	StreamBuffer int
}

func (c Config) withDefaults() Config {
	if c.TradesPerSecond <= 0 {
		c.TradesPerSecond = 10
	}
	if c.WarmupSpan <= 0 {
		c.WarmupSpan = 720 * time.Hour
	}
	if c.WarmupMaxEvents <= 0 {
		c.WarmupMaxEvents = 200_000
	}
	if c.BookLevels <= 0 {
		c.BookLevels = 100
	}
	if c.StreamBuffer <= 0 {
		c.StreamBuffer = 256
	}
	return c
}

// WarmupStep returns the virtual time each warmup event advances.
func (c Config) WarmupStep() time.Duration {
	c = c.withDefaults()
	return c.WarmupSpan / time.Duration(c.WarmupMaxEvents)
}

// WarmupRate returns the average events per second the warmup replay represents.
// It is lower than the live rate, which is why historical candles are exact for
// the trades that exist but coarser inside a bucket than live data. That
// trade-off is documented in the README.
func (c Config) WarmupRate() float64 {
	c = c.withDefaults()
	return float64(c.WarmupMaxEvents) / c.WarmupSpan.Seconds()
}

// Provider generates the canonical trade stream.
type Provider struct {
	cfg   Config
	clock domain.Clock
	gen   *Generator

	mu        sync.Mutex
	pace      exchange.Pace
	paused    bool
	wakeup    chan struct{}
	virtualAt time.Time
	// warmupEnd is the instant live generation starts. The warmup timeline is
	// clamped to it, which is what keeps the two phases ordered in time.
	warmupEnd time.Time
	emitted   uint64
	streaming bool

	ladderMu   sync.Mutex
	bootMid    domain.Price
	bootBids   []domain.Level
	bootAsks   []domain.Level
	ladderRNG  *rand.Rand
	ladderDone bool
}

var _ exchange.MarketDataProvider = (*Provider)(nil)
var _ exchange.PaceController = (*Provider)(nil)
var _ exchange.Pauser = (*Provider)(nil)
var _ exchange.Burster = (*Provider)(nil)

// New builds a provider. The virtual timeline for warmup starts one full span
// before now so the handover to live generation is seamless.
func New(cfg Config, clock domain.Clock) *Provider {
	cfg = cfg.withDefaults()
	if clock == nil {
		clock = domain.SystemClock()
	}
	start := clock.Now()
	return &Provider{
		cfg:       cfg,
		clock:     clock,
		gen:       NewGenerator(GeneratorConfig{Symbol: cfg.Symbol, Seed: cfg.Seed, VolatilityBurstRate: cfg.VolatilityBurstRate}),
		pace:      exchange.PaceFast,
		wakeup:    make(chan struct{}, 1),
		virtualAt: start.Add(-cfg.WarmupSpan),
		warmupEnd: start,
		ladderRNG: rand.New(rand.NewPCG(uint64(cfg.Seed)^0x5DEECE66D, 0x2545F4914F6CDD1D)),
	}
}

// Config returns the effective configuration.
func (p *Provider) Config() Config { return p.cfg }

// Generator exposes the underlying generator for tests and debug controls.
func (p *Provider) Generator() *Generator { return p.gen }

// SetPace switches between compressed warmup replay and wall-clock generation.
func (p *Provider) SetPace(pace exchange.Pace) {
	p.mu.Lock()
	p.pace = pace
	p.mu.Unlock()
	p.signal()
}

// Pace reports the current pacing mode.
func (p *Provider) Pace() exchange.Pace {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pace
}

// Pause stops emission without tearing down the stream.
func (p *Provider) Pause() {
	p.mu.Lock()
	p.paused = true
	p.mu.Unlock()
}

// Resume restarts emission.
func (p *Provider) Resume() {
	p.mu.Lock()
	p.paused = false
	p.mu.Unlock()
	p.signal()
}

// Paused reports whether generation is stopped.
func (p *Provider) Paused() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.paused
}

// ForceBurst forces a volatility burst for the given duration.
func (p *Provider) ForceBurst(d time.Duration) {
	p.gen.ForceBurst(p.clock.Now(), d)
}

// Emitted returns how many events have been produced by this provider.
func (p *Provider) Emitted() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.emitted
}

func (p *Provider) signal() {
	select {
	case p.wakeup <- struct{}{}:
	default:
	}
}

// Snapshot returns the ladder the canonical book is bootstrapped from. It is
// built once, from the anchor price, and cached so repeated calls are stable.
func (p *Provider) Snapshot(ctx context.Context, symbol string) (domain.OrderBookSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return domain.OrderBookSnapshot{}, err
	}
	if symbol != p.cfg.Symbol.ID {
		return domain.OrderBookSnapshot{}, fmt.Errorf("%w: asked for %s, provider serves %s",
			exchange.ErrSymbolMismatch, symbol, p.cfg.Symbol.ID)
	}

	p.ladderMu.Lock()
	defer p.ladderMu.Unlock()
	if !p.ladderDone {
		mid := p.gen.LastPrice()
		bids, asks := BuildLadder(p.cfg.Symbol, mid, DefaultLadderConfig(p.cfg.BookLevels), p.ladderRNG)
		p.bootMid = mid
		p.bootBids = bids
		p.bootAsks = asks
		p.ladderDone = true
	}

	return domain.OrderBookSnapshot{
		Symbol:     p.cfg.Symbol.ID,
		Epoch:      0,
		UpdateID:   0,
		Bids:       append([]domain.Level(nil), p.bootBids...),
		Asks:       append([]domain.Level(nil), p.bootAsks...),
		ServerTime: p.clock.Now(),
	}, nil
}

// Stream returns the normalised event channel. Exactly one stream may be active
// at a time: two consumers would interleave the deterministic sequence and
// corrupt the market.
func (p *Provider) Stream(ctx context.Context, symbol string) (<-chan exchange.MarketEvent, error) {
	if symbol != p.cfg.Symbol.ID {
		return nil, fmt.Errorf("%w: asked for %s, provider serves %s",
			exchange.ErrSymbolMismatch, symbol, p.cfg.Symbol.ID)
	}

	p.mu.Lock()
	if p.streaming {
		p.mu.Unlock()
		return nil, exchange.ErrAlreadyStreaming
	}
	p.streaming = true
	p.mu.Unlock()

	out := make(chan exchange.MarketEvent, p.cfg.StreamBuffer)
	go p.run(ctx, out)
	return out, nil
}

func (p *Provider) run(ctx context.Context, out chan<- exchange.MarketEvent) {
	defer close(out)
	for {
		if !p.waitForTurn(ctx) {
			return
		}

		ts := p.nextTimestamp()
		trade := p.gen.Next(ts)

		select {
		case <-ctx.Done():
			return
		case out <- exchange.TradeEvent{Trade: trade}:
		}

		p.mu.Lock()
		p.emitted++
		p.mu.Unlock()
	}
}

// waitForTurn blocks until the provider may emit the next event. In realtime
// mode it waits one jittered inter-arrival interval; in fast mode it returns
// immediately so warmup is bounded by CPU rather than by the clock.
func (p *Provider) waitForTurn(ctx context.Context) bool {
	for {
		p.mu.Lock()
		paused, pace := p.paused, p.pace
		p.mu.Unlock()

		if !paused {
			if pace == exchange.PaceFast {
				return true
			}
			select {
			case <-ctx.Done():
				return false
			case <-time.After(p.nextInterval()):
				return true
			case <-p.wakeup:
				continue
			}
		}

		select {
		case <-ctx.Done():
			return false
		case <-p.wakeup:
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// nextInterval returns a jittered inter-arrival time. Jitter around the mean
// rate makes coalescing behaviour realistic rather than metronomic.
func (p *Provider) nextInterval() time.Duration {
	mean := time.Duration(float64(time.Second) / p.cfg.TradesPerSecond)
	if mean <= 0 {
		mean = 100 * time.Millisecond
	}
	factor := 0.4 + 1.2*p.gen.rng.Float64() // uniform in [0.4, 1.6], mean 1.0
	d := time.Duration(float64(mean) * factor)
	if d < time.Millisecond {
		d = time.Millisecond
	}
	return d
}

// nextTimestamp returns the timestamp for the next event: a virtual timeline
// position during warmup, the wall clock during live generation.
func (p *Provider) nextTimestamp() time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.pace == exchange.PaceFast {
		// The producer runs ahead of the consumer, so it can generate more events
		// than the warmup consumes. Without this clamp those surplus events carry
		// timestamps past the moment live generation begins, which pushes the
		// short-interval aggregators' active buckets into the future and makes every
		// subsequent real trade look like a late trade. Clamping keeps the two
		// phases ordered in time: surplus events simply land in the final bucket.
		if !p.virtualAt.Before(p.warmupEnd) {
			return p.warmupEnd
		}
		ts := p.virtualAt
		p.virtualAt = p.virtualAt.Add(p.cfg.WarmupStep())
		return ts
	}
	return p.clock.Now()
}

// WarmupEvents returns how many events a full warmup replays.
func (p *Provider) WarmupEvents() int { return p.cfg.WarmupMaxEvents }

// ErrNoStream is returned by helpers that require an active stream.
var ErrNoStream = errors.New("synthetic: no active stream")
