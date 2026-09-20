package synthetic

import (
	"fmt"
	"math"
	"math/rand/v2"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// Price-process constants. Volatility is a fraction of the market's anchor price
// rather than a count of scaled units: four units is four cents on BTCUSDT but
// 0.8% of a half-dollar market, so a fixed count would make the cheap markets
// thousands of times more volatile than the expensive ones. A volatility burst
// scales the base sigma by GeneratorConfig.VolatilityBurstRate.
const (
	// relativeVolatility is the per-step standard deviation as a fraction of the
	// anchor price: 1e-5 is a tenth of a basis point, which keeps a minute candle
	// a small, readable fraction of the price on every market.
	relativeVolatility = 1e-5

	// meanReversionDivisor controls the pull toward the anchor price. Larger is
	// weaker: 4096 gives a half-life of roughly 2,800 events.
	meanReversionDivisor = 4096

	// driftDivisor scales the accumulated reversion error into the step.
	driftDivisor = 64

	// maxDeviationBps bounds the walk at ±15% of the anchor so a long session
	// cannot drift into absurd prices.
	maxDeviationBps = 1500

	// burstEnterProbability and burstStayProbability define the volatility
	// Markov chain: a burst lasts ~200 events on average.
	burstEnterProbability = 0.005
	burstStayProbability  = 0.995

	// quantityMedianBTC is the median trade size; the distribution is
	// log-normal, clamped to a plausible range.
	quantityMedianBTC = 0.05
	quantitySigma     = 0.9
	quantityMinBTC    = 0.0001
	quantityMaxBTC    = 5.0
)

// InitialTradeID keeps generated ids clear of the small numbers a replay
// fixture might use, so a mixed run cannot produce a colliding duplicate.
const InitialTradeID uint64 = 1_000_000

// Generator produces the deterministic trade sequence. It owns price, size and
// side; it deliberately does not own time — the caller supplies the timestamp —
// which keeps it trivially testable and lets warmup and live generation share
// exactly one code path.
type Generator struct {
	symbol domain.Symbol
	rng    *rand.Rand
	gauss  gaussian

	anchor domain.Price
	last   domain.Price
	drift  int64

	// residual carries the fraction of a step that is smaller than the market's
	// tick. A cheap market's tick is coarse next to its volatility, so without the
	// carry every step would round to zero and its price would freeze.
	residual float64

	burstUntil int64 // unix nanoseconds; 0 = not forced
	bursting   bool

	side        domain.Side
	lastDelta   int
	nextTradeID uint64

	// burstRate scales the base volatility while a burst is active. It comes
	// from VOLATILITY_BURST_RATE and is a documented, tunable knob.
	burstRate float64
}

// GeneratorConfig configures the price process.
type GeneratorConfig struct {
	Symbol              domain.Symbol
	Seed                int64
	VolatilityBurstRate float64
}

// NewGenerator builds a generator anchored at the symbol's seed price.
func NewGenerator(cfg GeneratorConfig) *Generator {
	burstRate := cfg.VolatilityBurstRate
	if burstRate <= 0 {
		burstRate = 4
	}
	anchor := anchorPrice(cfg.Symbol)
	// The trade stream and the Gaussian sampler share one source so the whole
	// price path is reproducible from the seed alone.
	rng := rand.New(rand.NewPCG(uint64(cfg.Seed), uint64(cfg.Seed)^0x9E3779B97F4A7C15))
	return &Generator{
		symbol:      cfg.Symbol,
		rng:         rng,
		gauss:       gaussian{rng: rng},
		anchor:      anchor,
		last:        anchor,
		side:        domain.SideBuy,
		nextTradeID: InitialTradeID,
		burstRate:   burstRate,
	}
}

// anchorPrice is the price every session starts from: the market's seed price,
// which the walk reverts to.
func anchorPrice(sym domain.Symbol) domain.Price {
	if seed, ok := domain.SeedPrice(sym.ID); ok {
		return seed
	}
	return domain.Price(sym.PriceScale * 100)
}

// Symbol returns the market this generator produces.
func (g *Generator) Symbol() domain.Symbol { return g.symbol }

// Anchor returns the mean-reversion anchor.
func (g *Generator) Anchor() domain.Price { return g.anchor }

// LastPrice returns the most recent generated price.
func (g *Generator) LastPrice() domain.Price { return g.last }

// ForceBurst makes the next d worth of events a volatility burst. Passing a
// non-positive duration clears any forced burst.
func (g *Generator) ForceBurst(now time.Time, d time.Duration) {
	if d <= 0 {
		g.burstUntil = 0
		return
	}
	g.burstUntil = now.Add(d).UnixNano()
}

// Next produces the next trade at the given timestamp. The event index is
// implicit in the generator's RNG state, so replaying the same seed reproduces
// the same sequence exactly.
func (g *Generator) Next(ts time.Time) domain.Trade {
	g.stepVolatility(ts)

	sigma := relativeVolatility * float64(g.anchor)
	if g.bursting {
		sigma *= g.burstRate
	}

	// Mean reversion: accumulate the error between the anchor and the current
	// price, then feed a fraction of it back into the step.
	g.drift = (g.drift*(meanReversionDivisor-1) + (int64(g.anchor) - int64(g.last))) / meanReversionDivisor
	// The random part is carried across steps, so a tick coarser than the step
	// moves the price by whole ticks at the right average speed instead of
	// rounding every step away.
	g.residual += g.gauss.next() * sigma
	gaussianStep := int64(math.Round(g.residual))
	g.residual -= float64(gaussianStep)
	step := gaussianStep + g.drift/driftDivisor

	next := domain.Price(int64(g.last) + step)
	next = g.clamp(next)

	// The side is the direction of this move, so it has to be read before the
	// price is advanced.
	side := g.sideForDelta(int64(next) - int64(g.last))
	g.last = next
	g.side = side

	trade := domain.Trade{
		ID:        g.nextTradeID,
		Symbol:    g.symbol.ID,
		Timestamp: ts.UTC(),
		Price:     next,
		Quantity:  g.quantity(),
		Side:      side,
	}
	g.nextTradeID++
	return trade
}

// NextID returns the id the next trade will carry.
func (g *Generator) NextID() uint64 { return g.nextTradeID }

func (g *Generator) stepVolatility(now time.Time) {
	if g.burstUntil != 0 && now.UnixNano() >= g.burstUntil {
		g.burstUntil = 0
		g.bursting = false
	}
	if g.burstUntil != 0 {
		g.bursting = true
		return
	}
	if g.bursting {
		if g.rng.Float64() < burstStayProbability {
			return
		}
		g.bursting = false
		return
	}
	if g.rng.Float64() < burstEnterProbability {
		g.bursting = true
	}
}

func (g *Generator) clamp(p domain.Price) domain.Price {
	deviation := int64(g.anchor) * maxDeviationBps / 10_000
	lo := domain.Price(int64(g.anchor) - deviation)
	hi := domain.Price(int64(g.anchor) + deviation)
	if p < lo {
		return lo
	}
	if p > hi {
		return hi
	}
	return p
}

func (g *Generator) sideForDelta(delta int64) domain.Side {
	switch {
	case delta > 0:
		g.lastDelta = 1
		return domain.SideBuy
	case delta < 0:
		g.lastDelta = -1
		return domain.SideSell
	default:
		// Flat move: keep the previous direction half the time so the tape does
		// not alternate mechanically.
		if g.rng.Float64() < 0.5 {
			g.lastDelta = -g.lastDelta
		}
		if g.lastDelta >= 0 {
			return domain.SideBuy
		}
		return domain.SideSell
	}
}

// quantity draws a log-normal size and converts it to an exact scaled integer.
// Rounding here is generation, not wire parsing: the resulting quantity is an
// exact integer in the domain, which is what the rest of the system requires.
func (g *Generator) quantity() domain.Qty {
	raw := quantityMedianBTC * math.Exp(g.gauss.next()*quantitySigma)
	if raw < quantityMinBTC {
		raw = quantityMinBTC
	}
	if raw > quantityMaxBTC {
		raw = quantityMaxBTC
	}
	scaled := int64(math.Round(raw * float64(g.symbol.QtyScale)))
	if scaled < 1 {
		scaled = 1
	}
	return domain.Qty(scaled)
}

// gaussian is a Box-Muller generator with a cached spare value. It is
// implemented here rather than taken from the standard library so that the
// determinism contract does not depend on an implementation detail that could
// change between Go releases: the same seed produces the same sequence for as
// long as this code exists.
type gaussian struct {
	rng      *rand.Rand
	spare    float64
	hasSpare bool
}

func (g *gaussian) next() float64 {
	if g.hasSpare {
		g.hasSpare = false
		return g.spare
	}
	u1 := g.rng.Float64()
	if u1 < 1e-12 {
		u1 = 1e-12
	}
	u2 := g.rng.Float64()
	r := math.Sqrt(-2 * math.Log(u1))
	g.spare = r * math.Sin(2*math.Pi*u2)
	g.hasSpare = true
	return r * math.Cos(2*math.Pi*u2)
}

// String is a debugging aid.
func (g *Generator) String() string {
	return fmt.Sprintf("generator{symbol=%s anchor=%s nextID=%d}",
		g.symbol.ID, g.symbol.FormatPrice(g.anchor), g.nextTradeID)
}
