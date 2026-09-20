package market_test

import (
	"context"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/synthetic"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
)

// Every roster symbol is independently live: each one has an engine that accepts
// its own trades and produces its own book, candles and 24h summary. The markets
// must not report the same numbers, which is what the per-symbol feed seed buys.
func TestEveryRosterSymbolHasAnIndependentEngine(t *testing.T) {
	t.Parallel()
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)

	engines := make([]*market.Engine, 0, len(domain.AllSymbols()))
	for _, sym := range domain.AllSymbols() {
		engine := newEngineForSymbol(t, sym, 20260917)
		// Two trades per market: one at the seed price, one a percent above it.
		seedPrice, ok := domain.SeedPrice(sym.ID)
		if !ok {
			t.Fatalf("%s has no seed price", sym.ID)
		}
		prices := []domain.Price{seedPrice, domain.Price(int64(seedPrice) + int64(seedPrice)/100)}
		for i, price := range prices {
			engine.StepTrade(domain.Trade{
				ID:        uint64(i + 1),
				Symbol:    sym.ID,
				Timestamp: base.Add(time.Duration(i) * time.Second),
				Price:     price,
				Quantity:  domain.Qty(sym.QtyScale / 10),
				Side:      domain.SideBuy,
			})
		}
		engines = append(engines, engine)
	}

	registry := market.NewRegistry(engines...)
	if registry.Len() != len(domain.AllSymbols()) {
		t.Fatalf("registry holds %d markets, want %d", registry.Len(), len(domain.AllSymbols()))
	}

	lasts := map[string]string{}
	for _, sym := range domain.AllSymbols() {
		engine, ok := registry.Lookup(sym)
		if !ok {
			t.Fatalf("no engine registered for %s", sym.ID)
		}
		if engine.Symbol().ID != sym.ID {
			t.Fatalf("engine registered for %s reports %s", sym.ID, engine.Symbol().ID)
		}
		if err := engine.Book().Validate(); err != nil {
			t.Fatalf("%s book invalid: %v", sym.ID, err)
		}
		history, _, err := engine.Candles(domain.Interval1m, 10)
		if err != nil {
			t.Fatalf("%s candles: %v", sym.ID, err)
		}
		if len(history) == 0 {
			t.Fatalf("%s produced no candles", sym.ID)
		}
		summary := engine.Summary()
		if summary.Last == 0 || summary.ChangeBP == 0 {
			t.Fatalf("%s summary is empty: %+v", sym.ID, summary)
		}
		last := sym.FormatPrice(summary.Last)
		if previous, dup := lasts[last]; dup {
			t.Fatalf("%s and %s report the same last price %s", previous, sym.ID, last)
		}
		lasts[last] = sym.ID
	}
}

// The registry answers only for the markets it was built over.
func TestRegistryLookupRejectsAnUnregisteredMarket(t *testing.T) {
	t.Parallel()
	engine := newEngineForSymbol(t, domain.BTCUSDT, 7)
	registry := market.NewRegistry(engine)

	if _, ok := registry.Lookup(domain.BTCUSDT); !ok {
		t.Fatal("BTCUSDT should be registered")
	}
	if _, ok := registry.Lookup(domain.ETHUSDT); ok {
		t.Fatal("ETHUSDT was never registered")
	}
	if _, ok := registry.Lookup(domain.Symbol{ID: "DOGEUSDT"}); ok {
		t.Fatal("an unknown market resolved to an engine")
	}
}

func newEngineForSymbol(t *testing.T, sym domain.Symbol, baseSeed int64) *market.Engine {
	t.Helper()
	seed := domain.DerivedSeed(baseSeed, sym.ID)
	provider := synthetic.New(synthetic.Config{
		Symbol:              sym,
		Seed:                seed,
		TradesPerSecond:     10,
		WarmupSpan:          720 * time.Hour,
		WarmupMaxEvents:     100,
		VolatilityBurstRate: 4,
		BookLevels:          100,
	}, nil)
	engine, err := market.New(context.Background(), market.Config{
		Symbol: sym, Seed: seed, BookLevels: 100, BookDeltaWindow: 15,
		WarmupEvents: 10, RecentTradesCap: 200, HistoryDepth: 500,
	}, provider, nil, nil, nil)
	if err != nil {
		t.Fatalf("engine %s: %v", sym.ID, err)
	}
	return engine
}
