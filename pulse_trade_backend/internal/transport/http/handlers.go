// Package http exposes the backend's REST surface: market data, health, metrics
// queries and (in debug builds) fault injection. Handlers validate, map and write;
// they hold no business rules.
package http

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	"github.com/pulsetrade/pulse-trade-backend/internal/protocol"
)

// Error codes for the REST surface. They mirror the WebSocket vocabulary so a
// client can map one code table for both transports.
const (
	codeSymbolNotFound      = "SYMBOL_NOT_FOUND"
	codeInvalidSymbol       = "INVALID_SYMBOL"
	codeInvalidLimit        = "INVALID_LIMIT"
	codeUnsupportedInterval = "UNSUPPORTED_INTERVAL"
	codeNotFound            = "NOT_FOUND"
	codeMethodNotAllowed    = "METHOD_NOT_ALLOWED"
	codePayloadTooLarge     = "PAYLOAD_TOO_LARGE"
	codeTimeout             = "TIMEOUT"
	codeInternal            = "INTERNAL"
)

// errorBody is the uniform error envelope.
type errorBody struct {
	Error errorDetail `json:"error"`
}

type errorDetail struct {
	Code          string `json:"code"`
	Message       string `json:"message"`
	CorrelationID string `json:"correlationId,omitempty"`
}

// writeJSON writes a successful JSON response.
func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if payload == nil {
		return
	}
	enc := json.NewEncoder(w)
	// The payloads are small and already validated; an encode failure here can only
	// mean the client went away, which the access log records.
	_ = enc.Encode(payload)
}

// writeError writes the uniform error envelope.
func writeError(w http.ResponseWriter, r *http.Request, status int, code, format string, args ...any) {
	writeJSON(w, status, errorBody{Error: errorDetail{
		Code:          code,
		Message:       fmt.Sprintf(format, args...),
		CorrelationID: CorrelationID(r.Context()),
	}})
}

// mapDomainError converts a domain sentinel into an HTTP status and code. Keeping
// the mapping in one place is what makes the status codes consistent across
// handlers.
func mapDomainError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, domain.ErrSymbolNotFound):
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "%v", err)
	case errors.Is(err, domain.ErrUnsupportedInterval):
		writeError(w, r, http.StatusBadRequest, codeUnsupportedInterval, "%v", err)
	case errors.Is(err, domain.ErrInvalidLimit):
		writeError(w, r, http.StatusBadRequest, codeInvalidLimit, "%v", err)
	default:
		writeError(w, r, http.StatusInternalServerError, codeInternal, "internal error")
	}
}

// symbolFrom resolves the {symbol} path parameter and validates it.
func symbolFrom(r *http.Request) (domain.Symbol, bool) {
	raw := chi.URLParam(r, "symbol")
	if raw == "" {
		return domain.Symbol{}, false
	}
	sym, err := domain.Lookup(raw)
	if err != nil {
		return domain.Symbol{}, false
	}
	return sym, true
}

// limitFrom parses a bounded limit query parameter.
func limitFrom(r *http.Request, def, max int) (int, error) {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return def, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%w: %q is not a number", domain.ErrInvalidLimit, raw)
	}
	if value < 1 || value > max {
		return 0, fmt.Errorf("%w: must be between 1 and %d", domain.ErrInvalidLimit, max)
	}
	return value, nil
}

// marketResponse is one roster entry served to the app. Every entry is a live
// market, so lastPrice and changeBasisPoints always carry the engine's numbers.
type marketResponse struct {
	Symbol            string `json:"symbol"`
	Display           string `json:"display"`
	Name              string `json:"name"`
	Glyph             string `json:"glyph"`
	Live              bool   `json:"live"`
	PriceDigits       int    `json:"priceDigits"`
	QuantityDigits    int    `json:"quantityDigits"`
	LastPrice         string `json:"lastPrice"`
	ChangeBasisPoints int64  `json:"changeBasisPoints"`
}

// marketHandler serves the symbol registry and per-market data. It resolves the
// engine for each request from the path symbol, because every market is live and
// each one is served by its own engine.
type marketHandler struct {
	registry *market.Registry
	clock    domain.Clock
	// debug is nil in a release build, so the empty-history switch costs nothing
	// and cannot be reached there.
	debug *DebugState
}

// engineFrom resolves the {symbol} path parameter to the engine serving it.
func (h *marketHandler) engineFrom(r *http.Request) (domain.Symbol, *market.Engine, bool) {
	sym, ok := symbolFrom(r)
	if !ok {
		return domain.Symbol{}, nil, false
	}
	engine, ok := h.registry.Lookup(sym)
	if !ok {
		return domain.Symbol{}, nil, false
	}
	return sym, engine, true
}

func (h *marketHandler) list(w http.ResponseWriter, r *http.Request) {
	symbols := h.registry.Symbols()
	out := make([]marketResponse, 0, len(symbols))
	for _, s := range symbols {
		engine, ok := h.registry.Lookup(s)
		if !ok {
			continue
		}
		summary := engine.Summary()
		out = append(out, marketResponse{
			Symbol:            s.ID,
			Display:           s.Display,
			Name:              s.Name,
			Glyph:             s.Glyph,
			Live:              true,
			PriceDigits:       s.PriceDigits,
			QuantityDigits:    s.QtyDigits,
			LastPrice:         s.FormatPrice(summary.Last),
			ChangeBasisPoints: summary.ChangeBP,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"markets": out})
}

func (h *marketHandler) summary(w http.ResponseWriter, r *http.Request) {
	sym, engine, ok := h.engineFrom(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	payload := protocol.SummaryPayloadFrom(sym, engine.Summary())
	writeJSON(w, http.StatusOK, payload)
}

func (h *marketHandler) orderBook(w http.ResponseWriter, r *http.Request) {
	sym, engine, ok := h.engineFrom(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	snapshot := engine.Book()
	payload := protocol.SnapshotPayloadFrom(sym, snapshot)
	writeJSON(w, http.StatusOK, payload)
}

func (h *marketHandler) candles(w http.ResponseWriter, r *http.Request) {
	sym, engine, ok := h.engineFrom(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	rawInterval := r.URL.Query().Get("interval")
	if rawInterval == "" {
		rawInterval = string(domain.Interval1m)
	}
	iv, err := domain.ParseInterval(rawInterval)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, codeUnsupportedInterval,
			"interval %q is not supported; supported: %v", rawInterval, domain.IntervalIDs())
		return
	}
	limit, err := limitFrom(r, 500, 1000)
	if err != nil {
		mapDomainError(w, r, err)
		return
	}

	if h.debug != nil && h.debug.EmptyHistory() {
		// Deliberately returns a valid empty series, which is how the app's
		// empty-history state is demonstrated without breaking the contract.
		writeJSON(w, http.StatusOK, map[string]any{
			"symbol": sym.ID, "interval": string(iv), "limit": limit,
			"candles": []any{}, "serverTime": protocol.FormatTime(h.clock.Now()),
		})
		return
	}

	candles, lastIsActive, err := engine.Candles(iv, limit)
	if err != nil {
		mapDomainError(w, r, err)
		return
	}
	// History includes the in-progress bucket, so the response has to say which
	// one it is: a client that assumed the whole list was finalised would treat
	// the newest candle as immutable and drop every live update for it.
	out := make([]protocol.CandlePayload, 0, len(candles))
	for i, c := range candles {
		out = append(out, protocol.CandlePayloadFrom(sym, c, lastIsActive && i == len(candles)-1))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"symbol":     sym.ID,
		"interval":   string(iv),
		"limit":      limit,
		"candles":    out,
		"serverTime": protocol.FormatTime(h.clock.Now()),
	})
}

func (h *marketHandler) trades(w http.ResponseWriter, r *http.Request) {
	sym, engine, ok := h.engineFrom(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	limit, err := limitFrom(r, 50, 200)
	if err != nil {
		mapDomainError(w, r, err)
		return
	}
	trades := engine.RecentTrades(limit)
	out := make([]protocol.TradePayload, 0, len(trades))
	for _, t := range trades {
		out = append(out, protocol.TradePayloadFrom(sym, t))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"symbol":     sym.ID,
		"limit":      limit,
		"trades":     out,
		"serverTime": protocol.FormatTime(h.clock.Now()),
	})
}

// healthPayload is the detailed health document. It separates process, engine,
// upstream and metrics-store health so a reviewer can see which layer is unhappy
// instead of a single boolean.
type healthPayload struct {
	Status   string         `json:"status"`
	Reasons  []string       `json:"reasons,omitempty"`
	Version  string         `json:"version"`
	UptimeMs int64          `json:"uptimeMs"`
	Engine   engineHealth   `json:"engine"`
	Metrics  MetricsHealth  `json:"metrics"`
	Sessions sessionsHealth `json:"sessions"`
	Time     string         `json:"time"`
}

type engineHealth struct {
	State          string `json:"state"`
	Symbol         string `json:"symbol"`
	Epoch          uint64 `json:"epoch"`
	EventIndex     uint64 `json:"eventIndex"`
	UpdateID       uint64 `json:"updateId"`
	WarmupComplete bool   `json:"warmupComplete"`
	LastError      string `json:"lastError,omitempty"`
}

// MetricsHealth is the metrics-store status reported by /health.
type MetricsHealth struct {
	Driver        string `json:"driver"`
	Status        string `json:"status"`
	QueueDepth    int    `json:"queueDepth"`
	Capacity      int    `json:"queueCapacity"`
	DroppedTotal  int64  `json:"droppedTotal"`
	WriteFailures int64  `json:"writeFailures"`
	RowsWritten   int64  `json:"rowsWritten"`
	LastFlushMs   int64  `json:"lastFlushMs"`
	SchemaVersion int    `json:"schemaVersion"`
}

type sessionsHealth struct {
	Active int   `json:"active"`
	Total  int64 `json:"total"`
}

// healthHandler serves process, engine and metrics health. It reports the
// default market in detail and grades every registered market into the overall
// status, so one unhealthy engine is visible even when another is fine.
type healthHandler struct {
	registry      *market.Registry
	defaultSymbol domain.Symbol
	manager       sessionCounter
	metricsHealth func() MetricsHealth
	version       string
	startedAt     time.Time
	clock         domain.Clock
	logger        *observability.Logger
}

type sessionCounter interface {
	Count() int
	TotalSessions() int64
}

func (h *healthHandler) liveness(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "time": protocol.FormatTime(h.clock.Now())})
}

func (h *healthHandler) detailed(w http.ResponseWriter, r *http.Request) {
	metrics := MetricsHealth{Status: "disabled"}
	if h.metricsHealth != nil {
		metrics = h.metricsHealth()
	}

	payload := healthPayload{
		Status:   "ok",
		Version:  h.version,
		UptimeMs: h.clock.Now().Sub(h.startedAt).Milliseconds(),
		Metrics:  metrics,
		Sessions: sessionsHealth{
			Active: h.manager.Count(),
			Total:  h.manager.TotalSessions(),
		},
		Time: protocol.FormatTime(h.clock.Now()),
	}

	if engine, ok := h.registry.Lookup(h.defaultSymbol); ok {
		payload.Engine = engineHealth{
			State:          string(engine.State()),
			Symbol:         engine.Symbol().ID,
			Epoch:          engine.Epoch(),
			EventIndex:     engine.EventIndex(),
			UpdateID:       engine.UpdateID(),
			WarmupComplete: engine.WarmupComplete(),
		}
		if err := engine.Err(); err != nil {
			payload.Engine.LastError = err.Error()
		}
	}

	// Process, engine and metrics store are graded independently: a degraded
	// metrics store must not be reported as a broken market feed, and a broken
	// feed names the market it belongs to.
	for _, sym := range h.registry.Symbols() {
		engine, ok := h.registry.Lookup(sym)
		if !ok {
			continue
		}
		if state := engine.State(); state == market.StateStopped || state == market.StateDegraded {
			payload.Status = "degraded"
			payload.Reasons = append(payload.Reasons, "engine_"+string(state)+":"+sym.ID)
		}
	}
	if metrics.Status == "degraded" {
		payload.Status = "degraded"
		payload.Reasons = append(payload.Reasons, "metrics_store_degraded")
	}

	status := http.StatusOK
	if payload.Status != "ok" {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, payload)
}

// notFound and methodNotAllowed keep error shapes uniform for router-level misses.
func notFound(w http.ResponseWriter, r *http.Request) {
	writeError(w, r, http.StatusNotFound, codeNotFound, "no route matches %s %s", r.Method, r.URL.Path)
}

func methodNotAllowed(w http.ResponseWriter, r *http.Request) {
	writeError(w, r, http.StatusMethodNotAllowed, codeMethodNotAllowed, "%s is not allowed on %s", r.Method, r.URL.Path)
}

// parseTimeRange reads from/to query parameters, defaulting to the last hour.
func parseTimeRange(r *http.Request, def time.Duration, max time.Duration) (time.Time, time.Time, error) {
	now := time.Now().UTC()
	from := now.Add(-def)
	to := now

	if raw := r.URL.Query().Get("from"); raw != "" {
		parsed, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("%w: from must be RFC3339", domain.ErrInvalidLimit)
		}
		from = parsed.UTC()
	}
	if raw := r.URL.Query().Get("to"); raw != "" {
		parsed, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("%w: to must be RFC3339", domain.ErrInvalidLimit)
		}
		to = parsed.UTC()
	}
	if to.Before(from) {
		return time.Time{}, time.Time{}, fmt.Errorf("%w: to must be after from", domain.ErrInvalidLimit)
	}
	if max > 0 && to.Sub(from) > max {
		return time.Time{}, time.Time{}, fmt.Errorf("%w: range must not exceed %s", domain.ErrInvalidLimit, max)
	}
	return from, to, nil
}
