package domain

import (
	"fmt"
	"hash/fnv"
)

// Symbol describes one tradable market: identity, display metadata and the
// fixed-point scales every Price/Qty for that market is expressed in.
type Symbol struct {
	ID          string
	Base        string
	Quote       string
	Display     string // "BTC/USDT"
	Name        string // "Bitcoin / USDT"
	Glyph       string // "₿"
	PriceScale  int64  // 100 => two decimal places
	QtyScale    int64  // 100_000_000 => eight decimal places
	PriceDigits int
	QtyDigits   int
	Live        bool
}

// Tick returns the smallest representable price increment.
func (s Symbol) Tick() int64 { return 1 }

// Step returns the smallest representable quantity increment.
func (s Symbol) Step() int64 { return 1 }

func (s Symbol) FormatPrice(p Price) string { return FormatScaled(int64(p), s.PriceDigits) }
func (s Symbol) FormatQty(q Qty) string     { return FormatScaled(int64(q), s.QtyDigits) }

func (s Symbol) ParsePrice(v string) (Price, error) {
	scaled, err := ParseScaled(v, s.PriceScale, s.PriceDigits)
	if err != nil {
		return 0, fmt.Errorf("symbol %s price %q: %w", s.ID, v, err)
	}
	return Price(scaled), nil
}

func (s Symbol) ParseQty(v string) (Qty, error) {
	scaled, err := ParseScaled(v, s.QtyScale, s.QtyDigits)
	if err != nil {
		return 0, fmt.Errorf("symbol %s quantity %q: %w", s.ID, v, err)
	}
	return Qty(scaled), nil
}

// IsTickAligned reports whether a price sits exactly on the symbol's tick grid.
func (s Symbol) IsTickAligned(p Price) bool { return int64(p)%s.Tick() == 0 }

// IsStepAligned reports whether a quantity sits exactly on the symbol's step grid.
func (s Symbol) IsStepAligned(q Qty) bool { return int64(q)%s.Step() == 0 }

// MarketSeed is the starting price a synthetic feed anchors to. It is generator
// input rather than market data: the live price is whatever the engine has
// traded to.
type MarketSeed struct {
	Symbol Symbol
	Price  Price
}

// The market roster. Every symbol is live: each one has its own engine, feed and
// client-facing data.
var (
	BTCUSDT = Symbol{
		ID: "BTCUSDT", Base: "BTC", Quote: "USDT", Display: "BTC/USDT",
		Name: "Bitcoin / USDT", Glyph: "₿",
		PriceScale: 100, QtyScale: 100_000_000, PriceDigits: 2, QtyDigits: 8, Live: true,
	}
	ETHUSDT = Symbol{
		ID: "ETHUSDT", Base: "ETH", Quote: "USDT", Display: "ETH/USDT",
		Name: "Ethereum / USDT", Glyph: "Ξ",
		PriceScale: 1000, QtyScale: 100_000_000, PriceDigits: 3, QtyDigits: 8, Live: true,
	}
	SOLUSDT = Symbol{
		ID: "SOLUSDT", Base: "SOL", Quote: "USDT", Display: "SOL/USDT",
		Name: "Solana / USDT", Glyph: "S",
		PriceScale: 10000, QtyScale: 100_000_000, PriceDigits: 4, QtyDigits: 8, Live: true,
	}
	BNBUSDT = Symbol{
		ID: "BNBUSDT", Base: "BNB", Quote: "USDT", Display: "BNB/USDT",
		Name: "BNB Chain / USDT", Glyph: "B",
		PriceScale: 10000, QtyScale: 100_000_000, PriceDigits: 4, QtyDigits: 8, Live: true,
	}
	AVAXUSDT = Symbol{
		ID: "AVAXUSDT", Base: "AVAX", Quote: "USDT", Display: "AVAX/USDT",
		Name: "Avalanche / USDT", Glyph: "A",
		PriceScale: 10000, QtyScale: 100_000_000, PriceDigits: 4, QtyDigits: 8, Live: true,
	}
	ADAUSDT = Symbol{
		ID: "ADAUSDT", Base: "ADA", Quote: "USDT", Display: "ADA/USDT",
		Name: "Cardano / USDT", Glyph: "D",
		PriceScale: 10000, QtyScale: 100_000_000, PriceDigits: 4, QtyDigits: 8, Live: true,
	}
)

var (
	allSymbols = []Symbol{BTCUSDT, ETHUSDT, SOLUSDT, BNBUSDT, AVAXUSDT, ADAUSDT}
	seedBy     = map[string]MarketSeed{}
)

func init() {
	seedBy[BTCUSDT.ID] = MarketSeed{Symbol: BTCUSDT, Price: 6_742_135}
	seedBy[ETHUSDT.ID] = MarketSeed{Symbol: ETHUSDT, Price: 3_421_200}
	seedBy[SOLUSDT.ID] = MarketSeed{Symbol: SOLUSDT, Price: 1_824_000}
	seedBy[BNBUSDT.ID] = MarketSeed{Symbol: BNBUSDT, Price: 5_941_000}
	seedBy[AVAXUSDT.ID] = MarketSeed{Symbol: AVAXUSDT, Price: 287_500}
	seedBy[ADAUSDT.ID] = MarketSeed{Symbol: ADAUSDT, Price: 4_820}
}

// AllSymbols returns every known market in roster order.
func AllSymbols() []Symbol { return append([]Symbol(nil), allSymbols...) }

// Lookup returns a symbol by wire id.
func Lookup(id string) (Symbol, error) {
	for _, s := range allSymbols {
		if s.ID == id {
			return s, nil
		}
	}
	return Symbol{}, fmt.Errorf("%w: %s", ErrSymbolNotFound, id)
}

// Seed returns the generator seed row for a market.
func Seed(id string) (MarketSeed, bool) {
	seed, ok := seedBy[id]
	return seed, ok
}

// SeedPrice returns the starting price a synthetic feed for this market is
// anchored at. The price is the mean the walk reverts to, not a quote served to
// clients.
func SeedPrice(id string) (Price, bool) {
	seed, ok := seedBy[id]
	if !ok {
		return 0, false
	}
	return seed.Price, true
}

// DerivedSeed mixes a market id into a base seed so every market runs its own
// price path and book churn while one configured seed still reproduces the whole
// roster.
func DerivedSeed(base int64, symbolID string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(symbolID))
	return base ^ int64(h.Sum64())
}
