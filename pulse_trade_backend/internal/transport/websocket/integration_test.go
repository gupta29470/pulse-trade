package websocket_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	gorillaws "github.com/gorilla/websocket"

	"github.com/pulsetrade/pulse-trade-backend/internal/delivery"
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/synthetic"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	"github.com/pulsetrade/pulse-trade-backend/internal/protocol"
	transporthttp "github.com/pulsetrade/pulse-trade-backend/internal/transport/http"
	"github.com/pulsetrade/pulse-trade-backend/internal/transport/websocket"
)

// stack is a fully wired backend instance served over an in-process HTTP server.
type stack struct {
	registry *market.Registry
	engines  map[string]*market.Engine
	manager  *delivery.Manager
	server   *httptest.Server
	logger   *observability.Logger
}

// newStack wires a single-market backend: BTCUSDT is both the default market and
// the only registered one.
func newStack(t *testing.T) *stack {
	t.Helper()
	return newStackWithSymbols(t, domain.BTCUSDT)
}

// newStackWithSymbols wires one engine per symbol. Every market runs its own feed,
// which is what a client switching markets is served from.
func newStackWithSymbols(t *testing.T, symbols ...domain.Symbol) *stack {
	t.Helper()
	logger := observability.New("error", "test", true, nil)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	engines := make(map[string]*market.Engine, len(symbols))
	list := make([]*market.Engine, 0, len(symbols))
	for _, symbol := range symbols {
		provider := synthetic.New(synthetic.Config{
			Symbol:              symbol,
			Seed:                domain.DerivedSeed(4242, symbol.ID),
			TradesPerSecond:     400,
			WarmupSpan:          720 * time.Hour,
			WarmupMaxEvents:     5_000,
			VolatilityBurstRate: 4,
			BookLevels:          100,
		}, nil)

		engine, err := market.New(ctx, market.Config{
			Symbol: symbol, Seed: domain.DerivedSeed(4242, symbol.ID), BookLevels: 100, BookDeltaWindow: 15,
			WarmupEvents: 500, BookRefreshHz: 50, RecentTradesCap: 200, HistoryDepth: 500,
		}, provider, nil, nil, nil)
		if err != nil {
			t.Fatalf("engine %s: %v", symbol.ID, err)
		}
		engines[symbol.ID] = engine
		list = append(list, engine)
		go func(engine *market.Engine) { _ = engine.Run(ctx) }(engine)
	}

	deadline := time.Now().Add(5 * time.Second)
	for _, engine := range list {
		for time.Now().Before(deadline) && !engine.WarmupComplete() {
			time.Sleep(5 * time.Millisecond)
		}
		if !engine.WarmupComplete() {
			t.Fatalf("warmup for %s did not finish", engine.Symbol().ID)
		}
	}

	registry := market.NewRegistry(list...)

	manager := delivery.NewManager(delivery.ManagerConfig{
		Registry:         registry,
		DefaultSymbol:    symbols[0],
		Policy:           delivery.NewDefaultPolicy(delivery.Thresholds{FullMaxRTTMs: 150, FullMaxJitterMs: 50, MinimalMinRTTMs: 500, MinimalMinJitterMs: 150, DegradeStreak: 3, RecoverStreak: 5, ReportHold: 5 * time.Second, ReportDegrade: 10 * time.Second}, 10, 2, 0.5),
		Logger:           logger,
		MetricsRegistry:  observability.NewRegistry(),
		BookWindow:       15,
		DebugControls:    true,
		OutboundCapacity: 512,
	})

	handler := websocket.NewHandler(websocket.Config{Path: "/ws"}, manager, list[0], logger, nil)
	router := transporthttp.NewRouter(transporthttp.RouterConfig{
		Registry: registry, DefaultSymbol: symbols[0], Manager: manager, Logger: logger, Version: "test",
		StartedAt: time.Now(), Clock: domain.SystemClock(),
		Metrics: nil, Debug: transporthttp.NewDebugState(),
	})

	mux := http.NewServeMux()
	mux.Handle("/ws", handler)
	mux.Handle("/", router)

	server := httptest.NewServer(mux)
	t.Cleanup(func() {
		server.Close()
		manager.CloseAll("test_over", time.Second)
	})

	return &stack{registry: registry, engines: engines, manager: manager, server: server, logger: logger}
}

type frame struct {
	Type    string          `json:"type"`
	Version int             `json:"version"`
	Seq     uint64          `json:"seq"`
	Payload json.RawMessage `json:"payload"`
}

// clientReader reads frames in the background and exposes them as a channel.
type clientReader struct {
	conn   *gorillaws.Conn
	frames chan frame
	errors chan error
}

func dial(t *testing.T, server *httptest.Server) *clientReader {
	t.Helper()
	url := "ws" + strings.TrimPrefix(server.URL, "http") + "/ws"
	conn, resp, err := gorillaws.DefaultDialer.Dial(url, nil)
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("dial %s: %v (status %d)", url, err, status)
	}
	reader := &clientReader{conn: conn, frames: make(chan frame, 512), errors: make(chan error, 1)}
	go func() {
		for {
			_, data, err := conn.ReadMessage()
			if err != nil {
				reader.errors <- err
				close(reader.frames)
				return
			}
			var f frame
			if err := json.Unmarshal(data, &f); err != nil {
				reader.errors <- err
				continue
			}
			reader.frames <- f
		}
	}()
	t.Cleanup(func() { _ = conn.Close() })
	return reader
}

func (c *clientReader) send(t *testing.T, payload any) {
	t.Helper()
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := c.conn.WriteMessage(gorillaws.TextMessage, data); err != nil {
		t.Fatalf("write: %v", err)
	}
}

// waitFor returns the first frame of the given type within the budget.
func (c *clientReader) waitFor(t *testing.T, kind protocol.MessageType, budget time.Duration) frame {
	t.Helper()
	deadline := time.After(budget)
	for {
		select {
		case f, ok := <-c.frames:
			if !ok {
				t.Fatalf("socket closed while waiting for %s", kind)
			}
			if f.Type == string(kind) {
				return f
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s", kind)
		}
	}
}

func TestSessionDeliversSnapshotThenContiguousDeltas(t *testing.T) {
	t.Parallel()
	stack := newStack(t)
	reader := dial(t, stack.server)

	welcome := reader.waitFor(t, protocol.TypeWelcome, 2*time.Second)
	var welcomePayload protocol.WelcomePayload
	if err := json.Unmarshal(welcome.Payload, &welcomePayload); err != nil {
		t.Fatalf("welcome payload: %v", err)
	}
	if welcomePayload.Symbol != domain.BTCUSDT.ID {
		t.Fatalf("welcome symbol = %q", welcomePayload.Symbol)
	}
	if welcomePayload.ProtocolMax != protocol.Version {
		t.Fatalf("welcome protocol version = %d", welcomePayload.ProtocolMax)
	}
	if len(welcomePayload.Intervals) < 2 {
		t.Fatalf("welcome advertised %d intervals, want at least 2", len(welcomePayload.Intervals))
	}
	// The welcome frame must not be empty: the snapshot follows it.
	if welcomePayload.SessionID == "" || welcomePayload.ShortID == "" {
		t.Fatal("welcome did not carry session identifiers")
	}

	reader.send(t, map[string]any{
		"type": "subscribe", "symbol": domain.BTCUSDT.ID, "interval": "1m",
		"channels": []string{"order_book", "trades", "candles", "summary", "health"},
	})

	snapshotFrame := reader.waitFor(t, protocol.TypeOrderBookSnapshot, 2*time.Second)
	var snapshot protocol.OrderBookSnapshotPayload
	if err := json.Unmarshal(snapshotFrame.Payload, &snapshot); err != nil {
		t.Fatalf("snapshot payload: %v", err)
	}
	if len(snapshot.Bids) < 10 || len(snapshot.Asks) < 10 {
		t.Fatalf("snapshot has %d bids and %d asks; the client displays ten of each",
			len(snapshot.Bids), len(snapshot.Asks))
	}

	subscribed := reader.waitFor(t, protocol.TypeSubscribed, 2*time.Second)
	var sub protocol.SubscribedPayload
	if err := json.Unmarshal(subscribed.Payload, &sub); err != nil {
		t.Fatalf("subscribed payload: %v", err)
	}
	if sub.Interval != "1m" {
		t.Fatalf("subscribed interval = %q, want 1m", sub.Interval)
	}

	// Apply every delta the way the app does, and require perfect contiguity.
	applied := snapshot.UpdateID
	bids := map[string]float64{}
	asks := map[string]float64{}
	deltas := 0
	trades := 0
	candles := 0
	deadline := time.After(3 * time.Second)

	for deltas < 5 || trades < 1 || candles < 1 {
		select {
		case f, ok := <-reader.frames:
			if !ok {
				t.Fatal("socket closed early")
			}
			switch protocol.MessageType(f.Type) {
			case protocol.TypeOrderBookDelta:
				var delta protocol.OrderBookDeltaPayload
				if err := json.Unmarshal(f.Payload, &delta); err != nil {
					t.Fatalf("delta payload: %v", err)
				}
				if delta.Epoch != snapshot.Epoch {
					t.Fatalf("delta epoch %d != snapshot epoch %d", delta.Epoch, snapshot.Epoch)
				}
				if delta.FirstUpdateID > applied+1 {
					t.Fatalf("sequence gap: applied=%d but delta starts at %d", applied, delta.FirstUpdateID)
				}
				if delta.LastUpdateID <= applied {
					t.Fatalf("stale delta: applied=%d but delta ends at %d", applied, delta.LastUpdateID)
				}
				for _, level := range delta.Bids {
					if level[1] == "0" || level[1] == "0.00000000" {
						delete(bids, level[0])
						continue
					}
					bids[level[0]] = 1
				}
				for _, level := range delta.Asks {
					if level[1] == "0" || level[1] == "0.00000000" {
						delete(asks, level[0])
						continue
					}
					asks[level[0]] = 1
				}
				applied = delta.LastUpdateID
				deltas++
			case protocol.TypeTrade, protocol.TypeTradeBatch:
				trades++
			case protocol.TypeCandleUpdate:
				var candle protocol.CandleUpdatePayload
				if err := json.Unmarshal(f.Payload, &candle); err != nil {
					t.Fatalf("candle payload: %v", err)
				}
				if candle.Interval != "1m" {
					t.Fatalf("received a candle for interval %q on a 1m subscription", candle.Interval)
				}
				if candle.Candle.Open == "" || candle.Candle.Volume == "" {
					t.Fatalf("candle payload is missing values: %+v", candle.Candle)
				}
				candles++
			}
		case <-deadline:
			t.Fatalf("timed out: deltas=%d trades=%d candles=%d", deltas, trades, candles)
		}
	}

	if deltas < 5 {
		t.Fatalf("only %d deltas arrived", deltas)
	}
	if applied <= snapshot.UpdateID {
		t.Fatalf("applied sequence did not advance past the snapshot (%d)", applied)
	}
	// Every server frame must carry the envelope, which is what makes the client
	// parser and the protocol trace possible.
	if snapshotFrame.Version != protocol.Version || snapshotFrame.Seq == 0 {
		t.Fatalf("snapshot frame is missing the envelope: %+v", snapshotFrame)
	}
}

func TestSessionRejectsMalformedFramesAndStaysUsable(t *testing.T) {
	t.Parallel()
	stack := newStack(t)
	reader := dial(t, stack.server)
	reader.waitFor(t, protocol.TypeWelcome, 2*time.Second)

	reader.send(t, map[string]any{
		"type": "subscribe", "symbol": domain.BTCUSDT.ID, "interval": "1m",
	})
	reader.waitFor(t, protocol.TypeSubscribed, 2*time.Second)

	// Four independent malformed inputs.
	raws := []string{
		`{not json at all`,
		`{"type":"   "}`,
		`{"type":"subscribe","symbol":"BTCUSDT","interval":"3m"}`,
		`{"type":"no_such_type"}`,
	}
	for _, raw := range raws {
		if err := reader.conn.WriteMessage(gorillaws.TextMessage, []byte(raw)); err != nil {
			t.Fatalf("write %q: %v", raw, err)
		}
		f := reader.waitFor(t, protocol.TypeError, 2*time.Second)
		var payload protocol.ErrorPayload
		if err := json.Unmarshal(f.Payload, &payload); err != nil {
			t.Fatalf("error payload: %v", err)
		}
		if payload.Code == "" {
			t.Fatalf("error frame for %q has no code", raw)
		}
		if payload.Fatal {
			t.Fatalf("error frame for %q was fatal; a single bad frame must not close a healthy socket", raw)
		}
	}

	// The socket must still work: a valid command is served normally.
	reader.send(t, map[string]any{"type": "set_interval", "interval": "5m"})
	f := reader.waitFor(t, protocol.TypeSubscribed, 2*time.Second)
	var sub protocol.SubscribedPayload
	if err := json.Unmarshal(f.Payload, &sub); err != nil {
		t.Fatalf("subscribed payload: %v", err)
	}
	if sub.Interval != "5m" {
		t.Fatalf("interval after recovery = %q, want 5m", sub.Interval)
	}
}

// The tier is the backend's decision, and the client must be able to observe it
// change from its own health reports - and to override it deliberately.
func TestTierFollowsHealthReportsAndOverride(t *testing.T) {
	t.Parallel()
	stack := newStack(t)
	reader := dial(t, stack.server)
	reader.waitFor(t, protocol.TypeWelcome, 2*time.Second)

	reader.send(t, map[string]any{"type": "subscribe", "symbol": domain.BTCUSDT.ID, "interval": "1m"})
	reader.waitFor(t, protocol.TypeSubscribed, 2*time.Second)

	health := reader.waitFor(t, protocol.TypeHealth, 2*time.Second)
	var initial protocol.HealthPayload
	if err := json.Unmarshal(health.Payload, &initial); err != nil {
		t.Fatalf("health payload: %v", err)
	}
	if initial.Tier != string(domain.TierFull) {
		t.Fatalf("initial tier = %s, want FULL", initial.Tier)
	}
	if initial.TargetRatePerSec <= 0 {
		t.Fatalf("health did not report a target rate: %+v", initial)
	}

	// Consecutive poor reports walk the tier down. The machine spends one streak
	// leaving FULL and the next leaving DEGRADED, so reaching MINIMAL takes four
	// minimal-band reports rather than one.
	for range 4 {
		reader.send(t, map[string]any{
			"type": "latency_report", "rttMs": 620.0, "jitterMs": 30.0,
			"samples": 10, "clientTimeMs": time.Now().UnixMilli(), "window": "rolling-10",
		})
		time.Sleep(80 * time.Millisecond)
	}

	degraded := waitForTier(t, reader, string(domain.TierMinimal), 3*time.Second)
	if degraded.Reason == "" {
		t.Fatalf("tier transition did not carry a reason: %+v", degraded)
	}

	// A debug override pins the tier regardless of the reports.
	reader.send(t, map[string]any{"type": "tier_override", "tier": "FULL"})
	overridden := waitForTier(t, reader, string(domain.TierFull), 3*time.Second)
	if overridden.Override != string(domain.TierFull) {
		t.Fatalf("override field = %q, want FULL", overridden.Override)
	}

	// Clearing the override returns to the automatic tier.
	reader.send(t, map[string]any{"type": "tier_override", "tier": "AUTO"})
	auto := waitForOverrideCleared(t, reader, 3*time.Second)
	if auto.Override != "" {
		t.Fatalf("override was not cleared: %q", auto.Override)
	}
}

func waitForTier(t *testing.T, reader *clientReader, tier string, budget time.Duration) protocol.HealthPayload {
	t.Helper()
	deadline := time.After(budget)
	for {
		select {
		case f, ok := <-reader.frames:
			if !ok {
				t.Fatalf("socket closed while waiting for tier %s", tier)
			}
			if f.Type != string(protocol.TypeHealth) {
				continue
			}
			var payload protocol.HealthPayload
			if err := json.Unmarshal(f.Payload, &payload); err != nil {
				t.Fatalf("health payload: %v", err)
			}
			if payload.Tier == tier {
				return payload
			}
		case <-deadline:
			t.Fatalf("timed out waiting for tier %s", tier)
		}
	}
}

func waitForOverrideCleared(t *testing.T, reader *clientReader, budget time.Duration) protocol.HealthPayload {
	t.Helper()
	deadline := time.After(budget)
	for {
		select {
		case f, ok := <-reader.frames:
			if !ok {
				t.Fatal("socket closed while waiting for the override to clear")
			}
			if f.Type != string(protocol.TypeHealth) {
				continue
			}
			var payload protocol.HealthPayload
			if err := json.Unmarshal(f.Payload, &payload); err != nil {
				t.Fatalf("health payload: %v", err)
			}
			if payload.Override == "" {
				return payload
			}
		case <-deadline:
			t.Fatal("timed out waiting for the override to clear")
		}
	}
}

func TestPingProducesMatchingPong(t *testing.T) {
	t.Parallel()
	stack := newStack(t)
	reader := dial(t, stack.server)
	reader.waitFor(t, protocol.TypeWelcome, 2*time.Second)

	sent := time.Now().UnixMilli()
	reader.send(t, map[string]any{"type": "ping", "id": 17, "clientTimeMs": sent})

	f := reader.waitFor(t, protocol.TypePong, 2*time.Second)
	var pong protocol.PongPayload
	if err := json.Unmarshal(f.Payload, &pong); err != nil {
		t.Fatalf("pong payload: %v", err)
	}
	if pong.ID != 17 {
		t.Fatalf("pong id = %d, want 17", pong.ID)
	}
	if pong.ClientTimeMs != sent {
		t.Fatalf("pong echoed clientTimeMs = %d, want %d", pong.ClientTimeMs, sent)
	}
	if pong.ServerTimeMs == 0 {
		t.Fatal("pong did not carry the server time")
	}
}

// Two sessions must be independent: one connection's override cannot change the
// other's tier or delivery.
func TestSessionsAreIsolated(t *testing.T) {
	t.Parallel()
	stack := newStack(t)
	first := dial(t, stack.server)
	second := dial(t, stack.server)

	first.waitFor(t, protocol.TypeWelcome, 2*time.Second)
	second.waitFor(t, protocol.TypeWelcome, 2*time.Second)

	for _, reader := range []*clientReader{first, second} {
		reader.send(t, map[string]any{"type": "subscribe", "symbol": domain.BTCUSDT.ID, "interval": "1m"})
		reader.waitFor(t, protocol.TypeSubscribed, 2*time.Second)
	}

	first.send(t, map[string]any{"type": "tier_override", "tier": "MINIMAL"})
	waitForTier(t, first, string(domain.TierMinimal), 3*time.Second)

	// The second session must still be FULL: an override is per connection.
	health := waitForTier(t, second, string(domain.TierFull), 3*time.Second)
	if health.Override != "" {
		t.Fatalf("the second session inherited an override: %q", health.Override)
	}
	if stack.manager.Count() != 2 {
		t.Fatalf("manager reports %d sessions, want 2", stack.manager.Count())
	}
}
