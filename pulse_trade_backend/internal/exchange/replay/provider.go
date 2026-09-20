// Package replay plays a checked-in fixture through the provider contract so
// tests and demonstrations are deterministic and need no network.
package replay

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/synthetic"
)

// fixtureLine is one JSONL record. Two record kinds are supported: a trade and a
// book delta with an explicit update range.
type fixtureLine struct {
	Type        string      `json:"type"`
	TradeID     uint64      `json:"tradeId"`
	Timestamp   string      `json:"timestamp"`
	Price       string      `json:"price"`
	Quantity    string      `json:"quantity"`
	Side        string      `json:"side"`
	Epoch       uint64      `json:"epoch"`
	FirstUpdate uint64      `json:"firstUpdateId"`
	LastUpdate  uint64      `json:"lastUpdateId"`
	Bids        [][2]string `json:"bids"`
	Asks        [][2]string `json:"asks"`
}

// Config configures replay.
type Config struct {
	Path   string
	Symbol domain.Symbol
	// Interval between events. Zero replays as fast as the consumer drains.
	Interval time.Duration
	// Loop restarts the fixture when it is exhausted. Used by long-running demos.
	Loop bool
}

// Provider replays a fixture.
type Provider struct {
	cfg    Config
	events []exchange.MarketEvent
	clock  domain.Clock

	mu        sync.Mutex
	pace      exchange.Pace
	streaming bool
	index     int
}

var _ exchange.MarketDataProvider = (*Provider)(nil)
var _ exchange.PaceController = (*Provider)(nil)
var _ exchange.RecentTradesProvider = (*Provider)(nil)

// New loads a fixture from disk.
func New(cfg Config, clock domain.Clock) (*Provider, error) {
	if clock == nil {
		clock = domain.SystemClock()
	}
	events, err := Load(cfg.Path, cfg.Symbol)
	if err != nil {
		return nil, err
	}
	return &Provider{cfg: cfg, events: events, clock: clock, pace: exchange.PaceFast}, nil
}

// NewFromEvents builds a provider over in-memory events, for tests.
func NewFromEvents(sym domain.Symbol, events []exchange.MarketEvent, clock domain.Clock) *Provider {
	if clock == nil {
		clock = domain.SystemClock()
	}
	return &Provider{cfg: Config{Symbol: sym}, events: events, clock: clock, pace: exchange.PaceFast}
}

// Load parses a JSONL fixture into normalised events.
func Load(path string, sym domain.Symbol) ([]exchange.MarketEvent, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%w: %s: %w", exchange.ErrInvalidFixture, path, err)
	}
	defer func() { _ = f.Close() }()

	var events []exchange.MarketEvent
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "//") {
			continue
		}
		var rec fixtureLine
		if err := json.Unmarshal([]byte(text), &rec); err != nil {
			return nil, fmt.Errorf("%w: %s:%d: %w", exchange.ErrInvalidFixture, path, line, err)
		}
		event, err := rec.toEvent(sym)
		if err != nil {
			return nil, fmt.Errorf("%w: %s:%d: %w", exchange.ErrInvalidFixture, path, line, err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("%w: %s: %w", exchange.ErrInvalidFixture, path, err)
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("%w: %s contains no events", exchange.ErrInvalidFixture, path)
	}
	return events, nil
}

func (r fixtureLine) toEvent(sym domain.Symbol) (exchange.MarketEvent, error) {
	ts, err := time.Parse(time.RFC3339Nano, r.Timestamp)
	if err != nil {
		return nil, fmt.Errorf("invalid timestamp %q: %w", r.Timestamp, err)
	}
	switch r.Type {
	case "trade":
		price, err := sym.ParsePrice(r.Price)
		if err != nil {
			return nil, err
		}
		qty, err := sym.ParseQty(r.Quantity)
		if err != nil {
			return nil, err
		}
		side := domain.SideBuy
		if r.Side != "" {
			side, err = domain.ParseSide(r.Side)
			if err != nil {
				return nil, err
			}
		}
		return exchange.TradeEvent{Trade: domain.Trade{
			ID: r.TradeID, Symbol: sym.ID, Timestamp: ts.UTC(),
			Price: price, Quantity: qty, Side: side,
		}}, nil
	case "book_delta", "order_book_delta":
		bids, err := parseLevels(sym, r.Bids, true)
		if err != nil {
			return nil, err
		}
		asks, err := parseLevels(sym, r.Asks, false)
		if err != nil {
			return nil, err
		}
		return exchange.BookDeltaEvent{
			Symbol: sym.ID, Epoch: r.Epoch,
			FirstUpdate: r.FirstUpdate, LastUpdate: r.LastUpdate,
			Bids: bids, Asks: asks, Timestamp: ts.UTC(),
		}, nil
	default:
		return nil, fmt.Errorf("unknown fixture record type %q", r.Type)
	}
}

func parseLevels(sym domain.Symbol, raw [][2]string, bid bool) ([]domain.Level, error) {
	out := make([]domain.Level, 0, len(raw))
	for _, pair := range raw {
		price, err := sym.ParsePrice(pair[0])
		if err != nil {
			return nil, err
		}
		qty, err := sym.ParseQty(pair[1])
		if err != nil {
			return nil, err
		}
		if bid && qty.IsNegative() {
			return nil, fmt.Errorf("bid quantity must not be negative")
		}
		out = append(out, domain.Level{Price: price, Quantity: qty})
	}
	return out, nil
}

// SetPace switches pacing mode.
func (p *Provider) SetPace(pace exchange.Pace) {
	p.mu.Lock()
	p.pace = pace
	p.mu.Unlock()
}

// Pace reports the pacing mode.
func (p *Provider) Pace() exchange.Pace {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pace
}

// Snapshot returns a bootstrap ladder built from the first trade price.
func (p *Provider) Snapshot(ctx context.Context, symbol string) (domain.OrderBookSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return domain.OrderBookSnapshot{}, err
	}
	if symbol != p.cfg.Symbol.ID {
		return domain.OrderBookSnapshot{}, fmt.Errorf("%w: %s", exchange.ErrSymbolMismatch, symbol)
	}
	mid := p.firstPrice()
	// A fixed ladder seed keeps the replayed bootstrap book identical between runs.
	rng := rand.New(rand.NewPCG(0x5EED, 0x1234))
	bids, asks := synthetic.BuildLadder(p.cfg.Symbol, mid, synthetic.DefaultLadderConfig(100), rng)
	return domain.OrderBookSnapshot{
		Symbol: symbol, Epoch: 1, UpdateID: 1, Bids: bids, Asks: asks, ServerTime: p.clock.Now(),
	}, nil
}

// RecentTrades returns the trades replayed so far, newest first.
func (p *Provider) RecentTrades(_ context.Context, symbol string, limit int) ([]domain.Trade, error) {
	if symbol != p.cfg.Symbol.ID {
		return nil, fmt.Errorf("%w: %s", exchange.ErrSymbolMismatch, symbol)
	}
	p.mu.Lock()
	upto := p.index
	p.mu.Unlock()

	var out []domain.Trade
	for i := upto - 1; i >= 0 && len(out) < limit; i-- {
		if t, ok := p.events[i].(exchange.TradeEvent); ok {
			out = append(out, t.Trade)
		}
	}
	return out, nil
}

// Stream replays the fixture. With Loop enabled it restarts from the beginning
// so a short fixture can drive a long-running demo.
func (p *Provider) Stream(ctx context.Context, symbol string) (<-chan exchange.MarketEvent, error) {
	if symbol != p.cfg.Symbol.ID {
		return nil, fmt.Errorf("%w: %s", exchange.ErrSymbolMismatch, symbol)
	}
	p.mu.Lock()
	if p.streaming {
		p.mu.Unlock()
		return nil, exchange.ErrAlreadyStreaming
	}
	p.streaming = true
	p.mu.Unlock()

	out := make(chan exchange.MarketEvent, 256)
	go func() {
		defer close(out)
		for {
			p.mu.Lock()
			if p.index >= len(p.events) {
				if !p.cfg.Loop {
					p.mu.Unlock()
					return
				}
				p.index = 0
			}
			ev := p.events[p.index]
			p.index++
			pace := p.pace
			p.mu.Unlock()

			if pace == exchange.PaceRealtime && p.cfg.Interval > 0 {
				select {
				case <-ctx.Done():
					return
				case <-time.After(p.cfg.Interval):
				}
			}
			select {
			case <-ctx.Done():
				return
			case out <- ev:
			}
		}
	}()
	return out, nil
}

func (p *Provider) firstPrice() domain.Price {
	for _, ev := range p.events {
		if t, ok := ev.(exchange.TradeEvent); ok {
			return t.Trade.Price
		}
	}
	if price, ok := domain.SeedPrice(p.cfg.Symbol.ID); ok {
		return price
	}
	return domain.Price(p.cfg.Symbol.PriceScale * 100)
}

// Len returns the number of events in the fixture.
func (p *Provider) Len() int { return len(p.events) }
