package synthetic

import (
	"math"
	"math/rand/v2"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
)

// LadderConfig describes how the synthetic book is shaped.
type LadderConfig struct {
	Levels int
	// HalfSpreadTicks is the distance from the mid to the best bid/ask in ticks.
	HalfSpreadTicks int
	// MinQuantity and MaxQuantity bound a level's size.
	MinQuantity float64
	MaxQuantity float64
}

// DefaultLadderConfig returns the ladder shape used for every market.
func DefaultLadderConfig(levels int) LadderConfig {
	if levels < 20 {
		levels = 100
	}
	return LadderConfig{
		Levels:          levels,
		HalfSpreadTicks: 2,
		MinQuantity:     0.02,
		MaxQuantity:     50,
	}
}

// BuildLadder produces a self-consistent book around a mid price: bids strictly
// descending, asks strictly ascending, best bid below best ask, and deeper
// levels carrying larger size. It is used to bootstrap the canonical book and to
// serve the provider's snapshot.
func BuildLadder(sym domain.Symbol, mid domain.Price, cfg LadderConfig, rng *rand.Rand) (bids, asks []domain.Level) {
	if cfg.Levels <= 0 {
		cfg = DefaultLadderConfig(cfg.Levels)
	}
	half := cfg.HalfSpreadTicks
	if half < 1 {
		half = 1
	}
	bestBid := domain.Price(int64(mid) - int64(half))
	bestAsk := domain.Price(int64(mid) + int64(half))
	if bestBid <= 0 {
		bestBid = 1
	}
	if bestAsk <= bestBid {
		bestAsk = bestBid + 1
	}

	bids = make([]domain.Level, 0, cfg.Levels)
	asks = make([]domain.Level, 0, cfg.Levels)

	gap := 0
	for i := range cfg.Levels {
		gap += 1 + rng.IntN(2) // 1..2 ticks between consecutive levels
		bp := domain.Price(int64(bestBid) - int64(gap))
		ap := domain.Price(int64(bestAsk) + int64(gap))
		if bp <= 0 {
			bp = domain.Price(1 + int64(cfg.Levels-i))
		}
		bids = append(bids, domain.Level{Price: bp, Quantity: levelSize(sym, i, cfg, rng)})
		asks = append(asks, domain.Level{Price: ap, Quantity: levelSize(sym, i, cfg, rng)})
	}
	return bids, asks
}

// levelSize grows with depth, as a real book does: liquidity thins near the
// touch and thickens further out.
func levelSize(sym domain.Symbol, depth int, cfg LadderConfig, rng *rand.Rand) domain.Qty {
	base := cfg.MinQuantity * math.Exp(float64(depth)/25)
	noise := math.Exp((rng.Float64()*2 - 1) * 0.6)
	q := base * noise
	if q < cfg.MinQuantity {
		q = cfg.MinQuantity
	}
	if q > cfg.MaxQuantity {
		q = cfg.MaxQuantity
	}
	scaled := int64(math.Round(q * float64(sym.QtyScale)))
	if scaled < 1 {
		scaled = 1
	}
	return domain.Qty(scaled)
}
