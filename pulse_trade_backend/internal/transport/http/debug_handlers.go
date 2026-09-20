package http

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/pulsetrade/pulse-trade-backend/internal/delivery"
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	"github.com/pulsetrade/pulse-trade-backend/internal/protocol"
)

// debugHandler exposes fault injection and generator controls. It is only ever
// registered when both the configuration flag and the build type allow it, so a
// release binary has no debug surface at all rather than a disabled one.
type debugHandler struct {
	registry *market.Registry
	// defaultSymbol is the market a control acts on when the request names none.
	defaultSymbol  domain.Symbol
	manager        *delivery.Manager
	debug          *DebugState
	logger         *observability.Logger
	registryGauges *observability.Registry
}

func (h *debugHandler) routes(r chi.Router) {
	r.Post("/generator/pause", h.pause)
	r.Post("/generator/resume", h.resume)
	r.Post("/generator/reset", h.reset)
	r.Post("/generator/burst", h.burst)
	r.Post("/generator/empty-history", h.emptyHistory)
	r.Post("/metrics/fail", h.metricsFail)

	r.Get("/sessions", h.listSessions)
	r.Post("/sessions/{id}/drop", h.dropSession)
	r.Post("/sessions/{id}/faults", h.applyFaults)
	r.Post("/sessions/{id}/tier", h.forceTier)
}

func (h *debugHandler) audit(r *http.Request, action, detail string) {
	h.logger.Info(observability.MsgDebugControl,
		observability.FieldEvent, action,
		observability.FieldDetail, detail,
		observability.FieldCorrelationID, CorrelationID(r.Context()),
	)
	if h.registryGauges != nil {
		h.registryGauges.Inc("debug_actions_total")
	}
}

// engineFor resolves the market a generator control acts on. It defaults to the
// configured market and can be aimed at any live market with ?symbol=.
func (h *debugHandler) engineFor(r *http.Request) (*market.Engine, domain.Symbol, bool) {
	sym := h.defaultSymbol
	if raw := r.URL.Query().Get("symbol"); raw != "" {
		parsed, err := domain.Lookup(raw)
		if err != nil {
			return nil, domain.Symbol{}, false
		}
		sym = parsed
	}
	engine, ok := h.registry.Lookup(sym)
	return engine, sym, ok
}

func (h *debugHandler) pause(w http.ResponseWriter, r *http.Request) {
	engine, _, ok := h.engineFor(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	engine.Pause()
	h.audit(r, "generator_pause", "")
	writeJSON(w, http.StatusOK, map[string]any{"state": string(engine.State())})
}

func (h *debugHandler) resume(w http.ResponseWriter, r *http.Request) {
	engine, _, ok := h.engineFor(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	engine.Resume()
	h.audit(r, "generator_resume", "")
	writeJSON(w, http.StatusOK, map[string]any{"state": string(engine.State())})
}

func (h *debugHandler) reset(w http.ResponseWriter, r *http.Request) {
	engine, _, ok := h.engineFor(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	if err := engine.Reset(r.Context()); err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "reset failed: %v", err)
		return
	}
	h.audit(r, "generator_reset", "")
	writeJSON(w, http.StatusOK, map[string]any{"epoch": engine.Epoch(), "updateId": engine.UpdateID()})
}

func (h *debugHandler) burst(w http.ResponseWriter, r *http.Request) {
	engine, _, ok := h.engineFor(r)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeSymbolNotFound, "unknown symbol")
		return
	}
	seconds := intFrom(r, "seconds", 5)
	engine.Burst(time.Duration(seconds) * time.Second)
	h.audit(r, "generator_burst", strconv.Itoa(seconds)+"s")
	writeJSON(w, http.StatusOK, map[string]any{"seconds": seconds})
}

func (h *debugHandler) emptyHistory(w http.ResponseWriter, r *http.Request) {
	on := boolFrom(r, "on", true)
	h.debug.SetEmptyHistory(on)
	h.audit(r, "empty_history", strconv.FormatBool(on))
	writeJSON(w, http.StatusOK, map[string]any{"emptyHistory": on})
}

func (h *debugHandler) metricsFail(w http.ResponseWriter, r *http.Request) {
	on := boolFrom(r, "on", true)
	h.debug.SetMetricsFailure(on)
	h.audit(r, "metrics_fail", strconv.FormatBool(on))
	writeJSON(w, http.StatusOK, map[string]any{"metricsFailure": on})
}

// sessionView is the live session document used by the debug console and by the
// diagnostics screen's "sessions" panel.
type sessionView struct {
	SessionID    string  `json:"sessionId"`
	ShortID      string  `json:"shortId"`
	RemoteAddr   string  `json:"remoteAddr"`
	Tier         string  `json:"tier"`
	Override     string  `json:"override"`
	RTTMs        float64 `json:"rttMs"`
	JitterMs     float64 `json:"jitterMs"`
	LastReportMs int64   `json:"lastReportAgeMs"`
	UptimeMs     int64   `json:"uptimeMs"`
	MessagesSent int64   `json:"messagesSent"`
	MessagesRecv int64   `json:"messagesReceived"`
}

func (h *debugHandler) listSessions(w http.ResponseWriter, r *http.Request) {
	sessions := h.manager.Sessions()
	out := make([]sessionView, 0, len(sessions))
	now := time.Now().UTC()
	for _, s := range sessions {
		health := s.Health()
		sent, received, _, _ := s.Stats()
		out = append(out, sessionView{
			SessionID:    s.ID(),
			ShortID:      s.ShortID(),
			RemoteAddr:   s.RemoteAddr(),
			Tier:         string(s.Tier()),
			Override:     s.Override(),
			RTTMs:        health.RTTMs,
			JitterMs:     health.JitterMs,
			LastReportMs: health.Age.Milliseconds(),
			UptimeMs:     now.Sub(s.ConnectedAt()).Milliseconds(),
			MessagesSent: sent,
			MessagesRecv: received,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"sessions":   out,
		"reconnects": h.manager.Reconnects(),
	})
}

func (h *debugHandler) dropSession(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if !h.manager.Drop(id, "debug_drop") {
		writeError(w, r, http.StatusNotFound, codeNotFound, "no live session %s", id)
		return
	}
	h.audit(r, "drop_session", id)
	writeJSON(w, http.StatusOK, map[string]any{"dropped": id})
}

// faultRequest is the body accepted by the fault endpoint. Every field is optional,
// so one request can describe exactly the anomaly the demo needs.
type faultRequest struct {
	SkipBookDeltas   int  `json:"skipBookDeltas"`
	DuplicateDelta   bool `json:"duplicateDelta"`
	ReverseDeltas    bool `json:"reverseDeltas"`
	MalformedFrames  int  `json:"malformedFrames"`
	WriteDelayMs     int  `json:"writeDelayMs"`
	WriteJitterMs    int  `json:"writeJitterMs"`
	HoldWritesMs     int  `json:"holdWritesMs"`
	SkipCandleClosed bool `json:"skipCandleClosed"`
}

func (h *debugHandler) applyFaults(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var req faultRequest
	if r.Body != nil {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && err.Error() != "EOF" {
			writeError(w, r, http.StatusBadRequest, codeValidationFailed, "invalid fault body: %v", err)
			return
		}
	}
	cfg := delivery.FaultConfig{
		SkipBookDeltas:   req.SkipBookDeltas,
		DuplicateDelta:   req.DuplicateDelta,
		ReverseDeltas:    req.ReverseDeltas,
		MalformedFrames:  req.MalformedFrames,
		WriteDelay:       time.Duration(req.WriteDelayMs) * time.Millisecond,
		WriteJitter:      time.Duration(req.WriteJitterMs) * time.Millisecond,
		HoldWrites:       time.Duration(req.HoldWritesMs) * time.Millisecond,
		SkipCandleClosed: req.SkipCandleClosed,
	}
	if !h.manager.ApplyFaults(id, cfg) {
		writeError(w, r, http.StatusNotFound, codeNotFound, "no live session %s", id)
		return
	}
	h.audit(r, "apply_faults", id)
	if h.registryGauges != nil {
		h.registryGauges.Inc(observability.CounterProviderFaultsTotal)
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessionId": id, "faults": req})
}

func (h *debugHandler) forceTier(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	tier := r.URL.Query().Get("tier")
	session, ok := h.manager.Session(id)
	if !ok {
		writeError(w, r, http.StatusNotFound, codeNotFound, "no live session %s", id)
		return
	}
	if tier == "" {
		writeError(w, r, http.StatusBadRequest, codeValidationFailed, "tier is required")
		return
	}
	// The override is injected as a command so the server-side path is identical
	// whether the app or a reviewer triggers it.
	if !session.InjectCommand(protocol.TierOverride{Tier: tier}) {
		writeError(w, r, http.StatusConflict, codeInternal, "the session command queue is full")
		return
	}
	h.audit(r, "force_tier", id+"="+tier)
	writeJSON(w, http.StatusOK, map[string]any{"sessionId": id, "tier": tier})
}

func intFrom(r *http.Request, key string, def int) int {
	raw := r.URL.Query().Get(key)
	if raw == "" {
		return def
	}
	parsed, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return parsed
}

func boolFrom(r *http.Request, key string, def bool) bool {
	raw := r.URL.Query().Get(key)
	if raw == "" {
		return def
	}
	parsed, err := strconv.ParseBool(raw)
	if err != nil {
		return def
	}
	return parsed
}

// codeValidationFailed is defined with the protocol codes; REST reuses the name so
// a client sees one vocabulary across both transports.
const codeValidationFailed = "VALIDATION_FAILED"
