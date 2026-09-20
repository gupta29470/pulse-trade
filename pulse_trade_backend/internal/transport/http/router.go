package http

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/pulsetrade/pulse-trade-backend/internal/delivery"
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

type contextKey string

const correlationKey contextKey = "correlationId"

// CorrelationID returns the request's correlation id, or an empty string.
func CorrelationID(ctx context.Context) string {
	if v, ok := ctx.Value(correlationKey).(string); ok {
		return v
	}
	return ""
}

// newCorrelationID returns a short random identifier. A random value is enough
// here: it only has to be unique among the requests a reviewer is looking at, and
// it appears in both the response body and the log line.
func newCorrelationID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "cid-fallback"
	}
	return "01J" + strings.ToUpper(hex.EncodeToString(b[:]))
}

// withCorrelation attaches an id to the request context and echoes it in the
// response header, so a client error can be matched to one server log line.
func withCorrelation(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Correlation-Id")
		if id == "" {
			id = newCorrelationID()
		}
		w.Header().Set("X-Correlation-Id", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), correlationKey, id)))
	})
}

// statusRecorder captures the status code for the access log.
type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (s *statusRecorder) WriteHeader(status int) {
	s.status = status
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	n, err := s.ResponseWriter.Write(b)
	s.bytes += n
	return n, err
}

// withAccessLog emits one structured record per request. It sits outside the panic
// recoverer so a recovered panic still produces an access-log line.
func withAccessLog(logger *observability.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			started := time.Now()
			recorder := &statusRecorder{ResponseWriter: w}
			next.ServeHTTP(recorder, r)
			if recorder.status == 0 {
				recorder.status = http.StatusOK
			}
			logger.Info(observability.MsgHTTPRequest,
				observability.FieldMethod, r.Method,
				observability.FieldPath, r.URL.Path,
				observability.FieldStatus, recorder.status,
				observability.FieldDurationMs, time.Since(started).Milliseconds(),
				observability.FieldBytes, recorder.bytes,
				observability.FieldCorrelationID, CorrelationID(r.Context()),
			)
		})
	}
}

// withRecover converts a panic into a 500 with a correlation id. One bad request
// must not take down the process.
func withRecover(logger *observability.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					logger.Error(observability.MsgHTTPPanic,
						observability.FieldPath, r.URL.Path,
						observability.FieldError, strings.TrimSpace(string(debug.Stack())),
						observability.FieldCorrelationID, CorrelationID(r.Context()),
					)
					writeError(w, r, http.StatusInternalServerError, codeInternal,
						"internal error; quote correlation id %s", CorrelationID(r.Context()))
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// withBodyLimit caps request bodies. The API is read-only, so the limit exists only
// to stop a client from allocating memory with a huge upload.
func withBodyLimit(limit int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Body != nil {
				r.Body = http.MaxBytesReader(w, r.Body, limit)
			}
			next.ServeHTTP(w, r)
		})
	}
}

// withCORS allows the local development origins. A production deployment terminates
// TLS and restricts this to the app's own origin.
func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Correlation-Id")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// RouterConfig carries every dependency the HTTP surface needs.
type RouterConfig struct {
	// Registry resolves the engine serving each market for per-symbol requests.
	Registry *market.Registry
	// DefaultSymbol is the market /api/v1/health reports in detail.
	DefaultSymbol  domain.Symbol
	Manager        *delivery.Manager
	Metrics        MetricsQuerier
	MetricsHealth  func() MetricsHealth
	Debug          *DebugState
	Logger         *observability.Logger
	RegistryGauges *observability.Registry
	Version        string
	StartedAt      time.Time
	Clock          domain.Clock
	HistoryMax     int
	BodyLimit      int64
	EnableDebug    bool
}

// NewRouter builds the HTTP router.
//
// Middleware order matters: the correlation id is attached first so every later
// layer can log it, the access log wraps the recoverer so a panic still produces a
// request line, and the body limit wraps the routes.
func NewRouter(cfg RouterConfig) http.Handler {
	if cfg.BodyLimit <= 0 {
		cfg.BodyLimit = 64 * 1024
	}
	if cfg.HistoryMax <= 0 {
		cfg.HistoryMax = 500
	}
	logger := cfg.Logger.Component(observability.ComponentTransport)

	router := chi.NewRouter()
	router.Use(withCorrelation)
	router.Use(withAccessLog(logger))
	router.Use(withRecover(logger))
	router.Use(withBodyLimit(cfg.BodyLimit))
	router.Use(withCORS)
	router.NotFound(notFound)
	router.MethodNotAllowed(methodNotAllowed)

	marketAPI := &marketHandler{registry: cfg.Registry, clock: cfg.Clock, debug: cfg.Debug}
	healthAPI := &healthHandler{
		registry:      cfg.Registry,
		defaultSymbol: cfg.DefaultSymbol,
		manager:       cfg.Manager,
		metricsHealth: cfg.MetricsHealth,
		version:       cfg.Version,
		startedAt:     cfg.StartedAt,
		clock:         cfg.Clock,
		logger:        logger,
	}

	router.Get("/health", healthAPI.liveness)
	router.Get("/api/v1/health", healthAPI.detailed)
	// Android fetches this to decide whether an https link to this host opens the
	// app; chat clients will not dispatch the custom scheme.
	router.Get("/.well-known/assetlinks.json", appLinks)

	router.Route("/api/v1", func(api chi.Router) {
		api.Get("/markets", marketAPI.list)
		api.Route("/markets/{symbol}", func(m chi.Router) {
			m.Get("/summary", marketAPI.summary)
			m.Get("/orderbook", marketAPI.orderBook)
			m.Get("/candles", marketAPI.candles)
			m.Get("/trades", marketAPI.trades)
		})

		metricsAPI := &metricsHandler{querier: cfg.Metrics, clock: cfg.Clock}
		api.Route("/metrics", func(m chi.Router) {
			m.Get("/summary", metricsAPI.summary)
			m.Get("/latency", metricsAPI.latency)
			m.Get("/tiers", metricsAPI.tiers)
			m.Get("/sessions", metricsAPI.sessions)
			m.Get("/delivery", metricsAPI.delivery)
		})

		if cfg.EnableDebug && cfg.Debug != nil {
			debugAPI := &debugHandler{
				registry:       cfg.Registry,
				defaultSymbol:  cfg.DefaultSymbol,
				manager:        cfg.Manager,
				debug:          cfg.Debug,
				logger:         logger,
				registryGauges: cfg.RegistryGauges,
			}
			api.Route("/debug", debugAPI.routes)
			logger.Info(observability.MsgDebugRoutesEnabled)
		}
	})

	return router
}
