package http_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/synthetic"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	transporthttp "github.com/pulsetrade/pulse-trade-backend/internal/transport/http"
)

// /api/v1/markets is the watchlist: every roster market is live and every row
// carries that market's own last price and 24h change, never a fixed placeholder.
func TestMarketsEndpointServesLiveDataForEveryRow(t *testing.T) {
	t.Parallel()
	registry := testRegistry(t)
	router := transporthttp.NewRouter(transporthttp.RouterConfig{
		Registry:      registry,
		DefaultSymbol: domain.BTCUSDT,
		Logger:        observability.New("error", "test", false, nil),
		Version:       "test",
		StartedAt:     time.Now(),
		Clock:         domain.SystemClock(),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/markets", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/markets = %d, body %s", rec.Code, rec.Body.String())
	}

	var body struct {
		Markets []struct {
			Symbol            string `json:"symbol"`
			Live              bool   `json:"live"`
			LastPrice         string `json:"lastPrice"`
			ChangeBasisPoints *int64 `json:"changeBasisPoints"`
		} `json:"markets"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode markets: %v", err)
	}
	if len(body.Markets) != len(domain.AllSymbols()) {
		t.Fatalf("served %d markets, want %d", len(body.Markets), len(domain.AllSymbols()))
	}

	seen := map[string]bool{}
	lastPrices := map[string]string{}
	for _, row := range body.Markets {
		sym, err := domain.Lookup(row.Symbol)
		if err != nil {
			t.Fatalf("row names unknown market %q", row.Symbol)
		}
		if !row.Live {
			t.Fatalf("%s is not marked live", row.Symbol)
		}
		if row.LastPrice == "" {
			t.Fatalf("%s has an empty lastPrice", row.Symbol)
		}
		if _, err := sym.ParsePrice(row.LastPrice); err != nil {
			t.Fatalf("%s lastPrice %q does not parse at its scale: %v", row.Symbol, row.LastPrice, err)
		}
		if row.ChangeBasisPoints == nil {
			t.Fatalf("%s has no changeBasisPoints", row.Symbol)
		}
		if previous, dup := lastPrices[row.LastPrice]; dup {
			t.Fatalf("%s and %s report the same lastPrice %s", previous, row.Symbol, row.LastPrice)
		}
		lastPrices[row.LastPrice] = row.Symbol
		seen[row.Symbol] = true
	}
	for _, sym := range domain.AllSymbols() {
		if !seen[sym.ID] {
			t.Fatalf("%s is missing from /api/v1/markets", sym.ID)
		}
	}
}

// The response keeps the {"markets":[...]} envelope and no longer carries the
// fixed reference price field.
func TestMarketsEndpointDropsReferencePrice(t *testing.T) {
	t.Parallel()
	registry := testRegistry(t)
	router := transporthttp.NewRouter(transporthttp.RouterConfig{
		Registry:      registry,
		DefaultSymbol: domain.BTCUSDT,
		Logger:        observability.New("error", "test", false, nil),
		Version:       "test",
		StartedAt:     time.Now(),
		Clock:         domain.SystemClock(),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/markets", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if _, ok := envelope["markets"]; !ok {
		t.Fatal("response is missing the markets key")
	}
	if _, ok := envelope["referencePrice"]; ok {
		t.Fatal("response still carries a top-level referencePrice")
	}
	var rows []map[string]json.RawMessage
	if err := json.Unmarshal(envelope["markets"], &rows); err != nil {
		t.Fatalf("decode rows: %v", err)
	}
	for _, row := range rows {
		if _, ok := row["referencePrice"]; ok {
			t.Fatalf("row %s still carries referencePrice", row["symbol"])
		}
		if _, ok := row["lastPrice"]; !ok {
			t.Fatalf("row %s has no lastPrice", row["symbol"])
		}
	}
}

// testRegistry builds one live engine per roster market with a deterministic
// starting trade.
func testRegistry(t *testing.T) *market.Registry {
	t.Helper()
	base := time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)
	engines := make([]*market.Engine, 0, len(domain.AllSymbols()))
	for _, sym := range domain.AllSymbols() {
		seed := domain.DerivedSeed(20260917, sym.ID)
		provider := synthetic.New(synthetic.Config{
			Symbol: sym, Seed: seed, TradesPerSecond: 10,
			WarmupSpan: 720 * time.Hour, WarmupMaxEvents: 100, BookLevels: 100,
		}, nil)
		engine, err := market.New(context.Background(), market.Config{
			Symbol: sym, Seed: seed, BookLevels: 100, BookDeltaWindow: 15,
			WarmupEvents: 10, RecentTradesCap: 200, HistoryDepth: 500,
		}, provider, nil, nil, nil)
		if err != nil {
			t.Fatalf("engine %s: %v", sym.ID, err)
		}
		seedPrice, _ := domain.SeedPrice(sym.ID)
		engine.StepTrade(domain.Trade{
			ID:        1,
			Symbol:    sym.ID,
			Timestamp: base,
			Price:     seedPrice,
			Quantity:  domain.Qty(sym.QtyScale / 10),
			Side:      domain.SideBuy,
		})
		engines = append(engines, engine)
	}
	return market.NewRegistry(engines...)
}
