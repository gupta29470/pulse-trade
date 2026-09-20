package websocket_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/protocol"
)

// A session follows the market the client asks for. Subscribing to a second
// market rebinds the bus subscription, the coalescer and the symbol every payload
// is scaled and labelled with, so the snapshot and candle that follow describe the
// new market.
func TestSessionRebindsToTheSubscribedMarket(t *testing.T) {
	t.Parallel()
	stack := newStackWithSymbols(t, domain.BTCUSDT, domain.ADAUSDT)
	reader := dial(t, stack.server)
	reader.waitFor(t, protocol.TypeWelcome, 2*time.Second)

	reader.send(t, map[string]any{"type": "subscribe", "symbol": domain.BTCUSDT.ID, "interval": "1m"})
	waitForSymbol(t, reader, protocol.TypeOrderBookSnapshot, domain.BTCUSDT.ID, 3*time.Second)
	waitForSymbol(t, reader, protocol.TypeSubscribed, domain.BTCUSDT.ID, 3*time.Second)
	btc := candleFrom(t, waitForSymbol(t, reader, protocol.TypeCandleUpdate, domain.BTCUSDT.ID, 3*time.Second))
	if got := decimals(btc.Candle.Open); got != domain.BTCUSDT.PriceDigits {
		t.Fatalf("BTC candle open %q has %d decimals, want %d", btc.Candle.Open, got, domain.BTCUSDT.PriceDigits)
	}

	// The same session now switches market. ADAUSDT has a different price scale,
	// so the frames that follow prove both the symbol and the scale moved.
	reader.send(t, map[string]any{"type": "subscribe", "symbol": domain.ADAUSDT.ID, "interval": "1m"})
	waitForSymbol(t, reader, protocol.TypeOrderBookSnapshot, domain.ADAUSDT.ID, 3*time.Second)
	waitForSymbol(t, reader, protocol.TypeSubscribed, domain.ADAUSDT.ID, 3*time.Second)
	adaFrame := waitForSymbol(t, reader, protocol.TypeCandleUpdate, domain.ADAUSDT.ID, 3*time.Second)
	ada := candleFrom(t, adaFrame)
	if ada.Symbol != domain.ADAUSDT.ID {
		t.Fatalf("candle payload symbol = %q, want %s", ada.Symbol, domain.ADAUSDT.ID)
	}
	if got := decimals(ada.Candle.Open); got != domain.ADAUSDT.PriceDigits {
		t.Fatalf("ADA candle open %q has %d decimals, want %d", ada.Candle.Open, got, domain.ADAUSDT.PriceDigits)
	}
	// The price round-trips at ADA's scale, which is what proves the payload was
	// rendered for the market the session rebound to.
	scaled, err := domain.ADAUSDT.ParsePrice(ada.Candle.Open)
	if err != nil {
		t.Fatalf("ADA price %q does not parse at ADA's scale: %v", ada.Candle.Open, err)
	}
	if rendered := domain.ADAUSDT.FormatPrice(scaled); rendered != ada.Candle.Open {
		t.Fatalf("ADA price %q did not round-trip at ADA's scale (got %q)", ada.Candle.Open, rendered)
	}

	// set_interval keeps acting on the market the session is bound to.
	reader.send(t, map[string]any{"type": "set_interval", "interval": "5m"})
	switched := waitForSymbol(t, reader, protocol.TypeSubscribed, domain.ADAUSDT.ID, 3*time.Second)
	var sub protocol.SubscribedPayload
	if err := json.Unmarshal(switched.Payload, &sub); err != nil {
		t.Fatalf("subscribed payload: %v", err)
	}
	if sub.Interval != "5m" {
		t.Fatalf("interval after set_interval = %q, want 5m", sub.Interval)
	}
}

// An unknown symbol is still rejected, and the session stays usable on the market
// it was already bound to.
func TestSessionRejectsAnUnknownSymbol(t *testing.T) {
	t.Parallel()
	stack := newStackWithSymbols(t, domain.BTCUSDT)
	reader := dial(t, stack.server)
	reader.waitFor(t, protocol.TypeWelcome, 2*time.Second)

	reader.send(t, map[string]any{"type": "subscribe", "symbol": "DOGEUSDT", "interval": "1m"})
	errFrame := reader.waitFor(t, protocol.TypeError, 2*time.Second)
	var perr protocol.ErrorPayload
	if err := json.Unmarshal(errFrame.Payload, &perr); err != nil {
		t.Fatalf("error payload: %v", err)
	}
	if perr.Code != protocol.CodeUnsupportedSymbol {
		t.Fatalf("error code = %q, want %s", perr.Code, protocol.CodeUnsupportedSymbol)
	}
	if perr.Fatal {
		t.Fatal("an unknown symbol must not be fatal")
	}

	reader.send(t, map[string]any{"type": "subscribe", "symbol": domain.BTCUSDT.ID, "interval": "1m"})
	waitForSymbol(t, reader, protocol.TypeOrderBookSnapshot, domain.BTCUSDT.ID, 3*time.Second)
}

// waitForSymbol returns the first frame of the given type whose payload names the
// requested symbol, discarding frames for any other market.
func waitForSymbol(t *testing.T, reader *clientReader, kind protocol.MessageType, symbol string, budget time.Duration) frame {
	t.Helper()
	deadline := time.After(budget)
	for {
		select {
		case f, ok := <-reader.frames:
			if !ok {
				t.Fatalf("socket closed while waiting for %s %s", kind, symbol)
			}
			if f.Type != string(kind) {
				continue
			}
			var head struct {
				Symbol string `json:"symbol"`
			}
			if err := json.Unmarshal(f.Payload, &head); err != nil {
				t.Fatalf("%s payload: %v", kind, err)
			}
			if head.Symbol == symbol {
				return f
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s %s", kind, symbol)
		}
	}
}

func candleFrom(t *testing.T, f frame) protocol.CandleUpdatePayload {
	t.Helper()
	var payload protocol.CandleUpdatePayload
	if err := json.Unmarshal(f.Payload, &payload); err != nil {
		t.Fatalf("candle payload: %v", err)
	}
	if payload.Candle.Open == "" {
		t.Fatalf("candle payload has no open price: %+v", payload)
	}
	return payload
}

// decimals counts the fractional digits of a fixed-point price string.
func decimals(price string) int {
	if dot := strings.IndexByte(price, '.'); dot >= 0 {
		return len(price) - dot - 1
	}
	return 0
}
