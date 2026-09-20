package http

import (
	"net/http"
	"strconv"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// metricsHandler serves the metrics query API. Every query is bounded so a reviewer
// cannot accidentally ask the database for a year of samples.
type metricsHandler struct {
	querier MetricsQuerier
	clock   domain.Clock
}

const (
	defaultMetricsWindow = 15 * time.Minute
	maxMetricsRange      = 24 * time.Hour
	maxMetricsLimit      = 1000
)

func (h *metricsHandler) unavailable(w http.ResponseWriter, r *http.Request) bool {
	if h.querier == nil {
		writeError(w, r, http.StatusServiceUnavailable, "METRICS_UNAVAILABLE",
			"the metrics store is disabled on this server")
		return true
	}
	return false
}

func (h *metricsHandler) summary(w http.ResponseWriter, r *http.Request) {
	if h.unavailable(w, r) {
		return
	}
	window := windowFrom(r, defaultMetricsWindow)
	summary, err := h.querier.Summary(r.Context(), window)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "could not read the metrics summary")
		return
	}
	writeJSON(w, http.StatusOK, summary)
}

func (h *metricsHandler) latency(w http.ResponseWriter, r *http.Request) {
	if h.unavailable(w, r) {
		return
	}
	from, to, err := parseTimeRange(r, defaultMetricsWindow, maxMetricsRange)
	if err != nil {
		mapDomainError(w, r, err)
		return
	}
	bucket := bucketFrom(r, 5*time.Second)

	buckets, err := h.querier.LatencyBuckets(r.Context(), r.URL.Query().Get("sessionId"), from, to, bucket)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "could not read latency samples")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"sessionId": r.URL.Query().Get("sessionId"),
		"from":      from.Format(time.RFC3339),
		"to":        to.Format(time.RFC3339),
		"bucketMs":  bucket.Milliseconds(),
		"buckets":   buckets,
	})
}

func (h *metricsHandler) tiers(w http.ResponseWriter, r *http.Request) {
	if h.unavailable(w, r) {
		return
	}
	from, to, err := parseTimeRange(r, time.Hour, maxMetricsRange)
	if err != nil {
		mapDomainError(w, r, err)
		return
	}
	limit := limitOrDefault(r, 200)
	transitions, err := h.querier.TierTransitions(r.Context(), from, to, limit)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "could not read tier transitions")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"from":        from.Format(time.RFC3339),
		"to":          to.Format(time.RFC3339),
		"transitions": transitions,
	})
}

func (h *metricsHandler) sessions(w http.ResponseWriter, r *http.Request) {
	if h.unavailable(w, r) {
		return
	}
	limit := limitOrDefault(r, 50)
	sessions, err := h.querier.Sessions(r.Context(), limit)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "could not read sessions")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions})
}

func (h *metricsHandler) delivery(w http.ResponseWriter, r *http.Request) {
	if h.unavailable(w, r) {
		return
	}
	from, to, err := parseTimeRange(r, defaultMetricsWindow, maxMetricsRange)
	if err != nil {
		mapDomainError(w, r, err)
		return
	}
	limit := limitOrDefault(r, 200)
	windows, err := h.querier.DeliveryWindows(r.Context(), r.URL.Query().Get("sessionId"), from, to, limit)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "could not read delivery windows")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"sessionId": r.URL.Query().Get("sessionId"),
		"from":      from.Format(time.RFC3339),
		"to":        to.Format(time.RFC3339),
		"windows":   windows,
	})
}

// LiveMetrics returns the in-process counters, which are available even when the
// database is disabled. The diagnostics screen reads this for the "live" numbers
// and the query API for history.
func LiveMetrics(registry *observability.Registry) map[string]int64 {
	if registry == nil {
		return map[string]int64{}
	}
	return registry.Snapshot()
}

func windowFrom(r *http.Request, def time.Duration) time.Duration {
	raw := r.URL.Query().Get("window")
	if raw == "" {
		return def
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return def
	}
	if parsed > maxMetricsRange {
		return maxMetricsRange
	}
	return parsed
}

func bucketFrom(r *http.Request, def time.Duration) time.Duration {
	raw := r.URL.Query().Get("bucket")
	if raw == "" {
		return def
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil || parsed <= 0 {
		return def
	}
	if parsed < time.Second {
		return time.Second
	}
	return parsed
}

func limitOrDefault(r *http.Request, def int) int {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return def
	}
	parsed, err := strconv.Atoi(raw)
	if err != nil || parsed < 1 {
		return def
	}
	if parsed > maxMetricsLimit {
		return maxMetricsLimit
	}
	return parsed
}
