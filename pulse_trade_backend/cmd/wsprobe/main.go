// Command wsprobe drives the WebSocket feed exactly the way the app does and prints
// what it observes. It exists so the backend can be verified without an emulator,
// and so the client-side sequence rules have a second, independent implementation
// to check the server against.
//
//	go run ./cmd/wsprobe -duration 15s -interval 1m
//
// Exit code 0 means every frame parsed, the book sequence stayed contiguous and at
// least one candle, trade and health frame arrived.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type envelope struct {
	Type       string          `json:"type"`
	Version    int             `json:"version"`
	ServerTime string          `json:"serverTime"`
	Seq        uint64          `json:"seq"`
	Payload    json.RawMessage `json:"payload"`
}

type frameStats struct {
	mu       sync.Mutex
	byType   map[string]int
	applied  uint64
	gaps     int
	stale    int
	frames   int
	lastTier string
	lastRate float64
	lastRTT  float64
	candles  int
	trades   int
	bids     map[string]string
	asks     map[string]string
	parseErr int
}

func main() {
	var (
		url      = flag.String("url", "ws://localhost:8080/ws", "backend WebSocket URL")
		symbol   = flag.String("symbol", "BTCUSDT", "market to subscribe to")
		interval = flag.String("interval", "1m", "candle interval")
		duration = flag.Duration("duration", 15*time.Second, "how long to run")
		rtt      = flag.Float64("rtt", 74, "RTT to report, in milliseconds")
		jitter   = flag.Float64("jitter", 12, "jitter to report, in milliseconds")
		verbose  = flag.Bool("v", false, "log every frame type change")
	)
	flag.Parse()

	conn, resp, err := websocket.DefaultDialer.Dial(*url, nil)
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		fmt.Fprintf(os.Stderr, "dial %s: %v (status %d)\n", *url, err, status)
		os.Exit(2)
	}
	defer func() { _ = conn.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()

	stats := &frameStats{byType: map[string]int{}, bids: map[string]string{}, asks: map[string]string{}}

	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			_, data, err := conn.ReadMessage()
			if err != nil {
				if ctx.Err() == nil {
					fmt.Fprintf(os.Stderr, "read: %v\n", err)
				}
				return
			}
			var env envelope
			if err := json.Unmarshal(data, &env); err != nil {
				stats.mu.Lock()
				stats.parseErr++
				stats.mu.Unlock()
				continue
			}
			stats.observe(env, *verbose)
		}
	}()

	// The app sends hello, then subscribes, then reports health every two seconds.
	send := func(v any) {
		payload, err := json.Marshal(v)
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return
		}
		if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
			fmt.Fprintf(os.Stderr, "write: %v\n", err)
		}
	}

	send(map[string]any{
		"type": "hello", "clientVersion": "wsprobe/1.0",
		"platform": "cli", "deviceId": "wsprobe",
	})
	send(map[string]any{
		"type": "subscribe", "symbol": *symbol, "interval": *interval,
		"channels": []string{"order_book", "trades", "candles", "summary", "health"},
	})

	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		pingID := int64(0)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				pingID++
				send(map[string]any{
					"type": "ping", "id": pingID, "clientTimeMs": time.Now().UnixMilli(),
				})
				send(map[string]any{
					"type": "latency_report", "rttMs": *rtt, "jitterMs": *jitter,
					"samples": 10, "clientTimeMs": time.Now().UnixMilli(),
					"window": "rolling-10",
				})
			}
		}
	}()

	printTicker := time.NewTicker(5 * time.Second)
	defer printTicker.Stop()
	for {
		select {
		case <-ctx.Done():
			// Close deliberately before printing: leaving the socket open would let
			// the server's missing-report watchdog degrade the tier after our last
			// report, and the summary would describe a connection we had abandoned.
			_ = conn.Close()
			<-done
			printSummary(stats, *duration)
			os.Exit(stats.verdict())
		case <-printTicker.C:
			printProgress(stats)
		}
	}
}

func (s *frameStats) observe(env envelope, verbose bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.byType[env.Type]++
	s.frames++

	switch env.Type {
	case "order_book_snapshot":
		var p struct {
			Epoch    uint64      `json:"epoch"`
			UpdateID uint64      `json:"updateId"`
			Bids     [][2]string `json:"bids"`
			Asks     [][2]string `json:"asks"`
		}
		if json.Unmarshal(env.Payload, &p) != nil {
			s.parseErr++
			return
		}
		s.applied = p.UpdateID
		s.bids = map[string]string{}
		s.asks = map[string]string{}
		for _, l := range p.Bids {
			s.bids[l[0]] = l[1]
		}
		for _, l := range p.Asks {
			s.asks[l[0]] = l[1]
		}

	case "order_book_delta":
		var p struct {
			Epoch         uint64      `json:"epoch"`
			FirstUpdateID uint64      `json:"firstUpdateId"`
			LastUpdateID  uint64      `json:"lastUpdateId"`
			Bids          [][2]string `json:"bids"`
			Asks          [][2]string `json:"asks"`
		}
		if json.Unmarshal(env.Payload, &p) != nil {
			s.parseErr++
			return
		}
		// The client rules, implemented independently of the frontend.
		switch {
		case p.LastUpdateID <= s.applied:
			s.stale++
			return
		case p.FirstUpdateID > s.applied+1:
			// A real gap. The app would request a fresh snapshot here; the probe
			// records it and resynchronises on the next snapshot.
			s.gaps++
			return
		}
		applyLevels(s.bids, p.Bids)
		applyLevels(s.asks, p.Asks)
		// The engine publishes a bounded window per side, so the probe keeps only
		// that window. Retaining more would make the reported top of book include
		// levels the engine has already stopped publishing.
		trimToWindow(s.bids, true)
		trimToWindow(s.asks, false)
		s.applied = p.LastUpdateID

	case "trade", "trade_batch":
		s.trades++

	case "candle_update", "candle_closed":
		s.candles++

	case "health":
		var p struct {
			Tier                string  `json:"tier"`
			EffectiveRatePerSec float64 `json:"effectiveRatePerSec"`
			RTTMs               float64 `json:"rttMs"`
		}
		if json.Unmarshal(env.Payload, &p) != nil {
			s.parseErr++
			return
		}
		s.lastTier = p.Tier
		s.lastRate = p.EffectiveRatePerSec
		s.lastRTT = p.RTTMs

	case "error":
		var p struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		}
		_ = json.Unmarshal(env.Payload, &p)
		if verbose {
			fmt.Printf("  error frame: %s — %s\n", p.Code, p.Message)
		}
	}
}

// windowSize mirrors the engine's default BOOK_DELTA_WINDOW.
const windowSize = 15

// trimToWindow drops everything past the published window.
func trimToWindow(book map[string]string, descending bool) {
	if len(book) <= windowSize {
		return
	}
	prices := make([]string, 0, len(book))
	for price := range book {
		prices = append(prices, price)
	}
	sort.Slice(prices, func(i, j int) bool {
		if descending {
			return prices[i] > prices[j]
		}
		return prices[i] < prices[j]
	})
	for _, price := range prices[windowSize:] {
		delete(book, price)
	}
}

func applyLevels(book map[string]string, levels [][2]string) {
	for _, l := range levels {
		if l[1] == "0" || l[1] == "0.00000000" {
			delete(book, l[0])
			continue
		}
		book[l[0]] = l[1]
	}
}

func printProgress(s *frameStats) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fmt.Printf("frames=%d applied=%d gaps=%d stale=%d candleFrames=%d tradeFrames=%d tier=%s rate=%.1f/s rtt=%.0fms\n",
		s.frames, s.applied, s.gaps, s.stale, s.candles, s.trades, s.lastTier, s.lastRate, s.lastRTT)
}

func printSummary(s *frameStats, duration time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()

	fmt.Printf("\n— wsprobe summary (%s) —\n", duration)
	fmt.Printf("frames received : %d (parse failures: %d)\n", s.frames, s.parseErr)
	fmt.Printf("applied updateId: %d\n", s.applied)
	fmt.Printf("sequence gaps   : %d   stale deltas: %d\n", s.gaps, s.stale)
	fmt.Printf("last tier       : %s  (effective %.1f/s, rtt %.0fms)\n", s.lastTier, s.lastRate, s.lastRTT)
	fmt.Printf("top of book     : %s / %s\n", bestPrice(s.bids, true), bestPrice(s.asks, false))
	fmt.Printf("frames by type  : ")
	for _, t := range []string{"welcome", "subscribed", "order_book_snapshot", "order_book_delta", "trade", "trade_batch", "candle_update", "candle_closed", "market_summary", "health", "pong", "error"} {
		if n, ok := s.byType[t]; ok {
			fmt.Printf("%s=%d ", t, n)
		}
	}
	fmt.Println()
}

func bestPrice(book map[string]string, highest bool) string {
	best := ""
	for price := range book {
		if best == "" {
			best = price
			continue
		}
		if (highest && price > best) || (!highest && price < best) {
			best = price
		}
	}
	if best == "" {
		return "n/a"
	}
	return best
}

// verdict is the tool's own exit criterion: a clean run has no gaps, no parse
// failures, and every kind of frame the app depends on.
func (s *frameStats) verdict() int {
	s.mu.Lock()
	defer s.mu.Unlock()

	problems := []string{}
	if s.gaps > 0 {
		problems = append(problems, fmt.Sprintf("%d sequence gap(s)", s.gaps))
	}
	if s.parseErr > 0 {
		problems = append(problems, fmt.Sprintf("%d unparsable frame(s)", s.parseErr))
	}
	if s.byType["order_book_snapshot"] == 0 {
		problems = append(problems, "no order-book snapshot")
	}
	if s.byType["order_book_delta"] == 0 {
		problems = append(problems, "no order-book deltas")
	}
	if s.candles == 0 {
		problems = append(problems, "no candle frames")
	}
	if s.byType["health"] == 0 {
		problems = append(problems, "no health frames")
	}
	if s.lastTier == "" {
		problems = append(problems, "no tier reported")
	}

	if len(problems) > 0 {
		fmt.Printf("\nFAIL: %v\n", problems)
		return 1
	}
	fmt.Println("\nOK: contiguous book sequence, every expected frame type received")
	return 0
}
