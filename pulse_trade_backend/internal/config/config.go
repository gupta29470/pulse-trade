// Package config loads and validates the backend's configuration. Everything is
// parsed once at startup, all problems are reported together, and the result is
// a typed struct rather than a map of strings.
package config

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Config is the effective configuration of a running backend.
type Config struct {
	// Engine
	GeneratorSeed       int64
	Symbol              string
	TradesPerSecond     float64
	BookRefreshHz       float64
	BookLevels          int
	BookDeltaWindow     int
	HistoryLimitMax     int
	WarmupSpan          time.Duration
	WarmupMaxEvents     int
	VolatilityBurstRate float64
	RecentTradesCap     int

	// Transport
	HTTPAddr          string
	WSPath            string
	WSReadLimitBytes  int64
	WSClientMsgPerSec int
	HTTPReadTimeout   time.Duration
	HTTPWriteTimeout  time.Duration
	ShutdownGrace     time.Duration

	// Delivery and tiers
	TierFullMaxRTTMs        float64
	TierFullMaxJitterMs     float64
	TierMinimalMinRTTMs     float64
	TierMinimalMinJitterMs  float64
	TierRateFullPerSec      float64
	TierRateDegradedPerSec  float64
	TierRateMinimalPerSec   float64
	TierDegradeStreak       int
	TierRecoverStreak       int
	HealthReportHold        time.Duration
	HealthReportDegrade     time.Duration
	HealthWatchdog          time.Duration
	SessionOutboundCap      int
	SessionWriteTimeout     time.Duration
	MaxSessionSubscriptions int

	// Metrics
	MetricsEnabled           bool
	MetricsDriver            string
	MetricsDBPath            string
	MetricsQueueCapacity     int
	MetricsBatchSize         int
	MetricsFlushInterval     time.Duration
	MetricsRetentionEnabled  bool
	MetricsRetentionLatency  time.Duration
	MetricsRetentionEvents   time.Duration
	MetricsRetentionSessions time.Duration
	MetricsPruneInterval     time.Duration
	MetricsPruneBatch        int

	// Debug and observability
	EnableDebugControls bool
	DebugBuild          bool
	LogLevel            string
}

// envKeys is the single source of truth for the documented configuration. The
// .env.example file is checked against it by a test so the docs cannot drift.
var envKeys = []string{
	"GENERATOR_SEED", "SYMBOL", "TRADES_PER_SECOND", "BOOK_REFRESH_HZ",
	"BOOK_LEVELS", "BOOK_DELTA_WINDOW", "HISTORY_LIMIT_MAX", "WARMUP_SPAN",
	"WARMUP_MAX_EVENTS", "VOLATILITY_BURST_RATE", "RECENT_TRADES_CAPACITY",
	"HTTP_ADDR", "WS_PATH", "WS_READ_LIMIT_BYTES", "WS_CLIENT_MSG_PER_SEC",
	"HTTP_READ_TIMEOUT", "HTTP_WRITE_TIMEOUT", "SHUTDOWN_GRACE",
	"TIER_FULL_MAX_RTT_MS", "TIER_FULL_MAX_JITTER_MS", "TIER_MINIMAL_MIN_RTT_MS",
	"TIER_MINIMAL_MIN_JITTER_MS", "TIER_RATE_FULL_PER_SEC", "TIER_RATE_DEGRADED_PER_SEC",
	"TIER_RATE_MINIMAL_PER_SEC", "TIER_DEGRADE_STREAK", "TIER_RECOVER_STREAK",
	"HEALTH_REPORT_HOLD", "HEALTH_REPORT_DEGRADE", "HEALTH_WATCHDOG_INTERVAL",
	"SESSION_OUTBOUND_CAPACITY", "SESSION_WRITE_TIMEOUT", "MAX_SESSION_SUBSCRIPTIONS",
	"METRICS_ENABLED", "METRICS_DRIVER", "METRICS_DB_PATH", "METRICS_QUEUE_CAPACITY",
	"METRICS_BATCH_SIZE", "METRICS_FLUSH_INTERVAL", "METRICS_RETENTION_ENABLED",
	"METRICS_RETENTION_LATENCY", "METRICS_RETENTION_EVENTS", "METRICS_RETENTION_SESSIONS",
	"METRICS_PRUNE_INTERVAL", "METRICS_PRUNE_BATCH",
	"ENABLE_DEBUG_CONTROLS", "DEBUG_BUILD", "LOG_LEVEL",
}

// EnvKeys returns every recognised environment variable name, sorted.
func EnvKeys() []string {
	out := append([]string(nil), envKeys...)
	sort.Strings(out)
	return out
}

// Default returns the documented defaults.
func Default() Config {
	return Config{
		GeneratorSeed:       20260917,
		Symbol:              "BTCUSDT",
		TradesPerSecond:     10,
		BookRefreshHz:       10,
		BookLevels:          100,
		BookDeltaWindow:     15,
		HistoryLimitMax:     500,
		WarmupSpan:          720 * time.Hour,
		WarmupMaxEvents:     1_000_000,
		VolatilityBurstRate: 4,
		RecentTradesCap:     200,

		HTTPAddr:          "0.0.0.0:8080",
		WSPath:            "/ws",
		WSReadLimitBytes:  16 * 1024,
		WSClientMsgPerSec: 20,
		HTTPReadTimeout:   10 * time.Second,
		HTTPWriteTimeout:  15 * time.Second,
		ShutdownGrace:     5 * time.Second,

		TierFullMaxRTTMs:        150,
		TierFullMaxJitterMs:     50,
		TierMinimalMinRTTMs:     500,
		TierMinimalMinJitterMs:  150,
		TierRateFullPerSec:      10,
		TierRateDegradedPerSec:  2,
		TierRateMinimalPerSec:   0.5,
		TierDegradeStreak:       3,
		TierRecoverStreak:       5,
		HealthReportHold:        5 * time.Second,
		HealthReportDegrade:     10 * time.Second,
		HealthWatchdog:          250 * time.Millisecond,
		SessionOutboundCap:      256,
		SessionWriteTimeout:     5 * time.Second,
		MaxSessionSubscriptions: 8,

		MetricsEnabled:           true,
		MetricsDriver:            "sqlite",
		MetricsDBPath:            "./data/pulsetrade.db",
		MetricsQueueCapacity:     4096,
		MetricsBatchSize:         128,
		MetricsFlushInterval:     250 * time.Millisecond,
		MetricsRetentionEnabled:  true,
		MetricsRetentionLatency:  24 * time.Hour,
		MetricsRetentionEvents:   168 * time.Hour,
		MetricsRetentionSessions: 2160 * time.Hour,
		MetricsPruneInterval:     10 * time.Minute,
		MetricsPruneBatch:        5000,

		EnableDebugControls: true,
		DebugBuild:          true,
		LogLevel:            "info",
	}
}

// Load reads configuration from the environment (and, when DEBUG_BUILD is set,
// from a .env file in the working directory if one exists).
func Load() (Config, error) {
	cfg := Default()

	debugBuild := cfg.DebugBuild
	if v, ok := os.LookupEnv("DEBUG_BUILD"); ok {
		if parsed, err := strconv.ParseBool(strings.TrimSpace(v)); err == nil {
			debugBuild = parsed
		}
	}
	if debugBuild {
		loadDotEnv(".env", false)
	}

	r := &reader{values: map[string]string{}}
	for _, k := range envKeys {
		if v, ok := os.LookupEnv(k); ok {
			r.values[k] = strings.TrimSpace(v)
		}
	}

	cfg.GeneratorSeed = r.int64("GENERATOR_SEED", cfg.GeneratorSeed)
	cfg.Symbol = r.str("SYMBOL", cfg.Symbol)
	cfg.TradesPerSecond = r.float("TRADES_PER_SECOND", cfg.TradesPerSecond)
	cfg.BookRefreshHz = r.float("BOOK_REFRESH_HZ", cfg.BookRefreshHz)
	cfg.BookLevels = r.int("BOOK_LEVELS", cfg.BookLevels)
	cfg.BookDeltaWindow = r.int("BOOK_DELTA_WINDOW", cfg.BookDeltaWindow)
	cfg.HistoryLimitMax = r.int("HISTORY_LIMIT_MAX", cfg.HistoryLimitMax)
	cfg.WarmupSpan = r.duration("WARMUP_SPAN", cfg.WarmupSpan)
	cfg.WarmupMaxEvents = r.int("WARMUP_MAX_EVENTS", cfg.WarmupMaxEvents)
	cfg.VolatilityBurstRate = r.float("VOLATILITY_BURST_RATE", cfg.VolatilityBurstRate)
	cfg.RecentTradesCap = r.int("RECENT_TRADES_CAPACITY", cfg.RecentTradesCap)

	cfg.HTTPAddr = r.str("HTTP_ADDR", cfg.HTTPAddr)
	cfg.WSPath = r.str("WS_PATH", cfg.WSPath)
	cfg.WSReadLimitBytes = r.int64("WS_READ_LIMIT_BYTES", cfg.WSReadLimitBytes)
	cfg.WSClientMsgPerSec = r.int("WS_CLIENT_MSG_PER_SEC", cfg.WSClientMsgPerSec)
	cfg.HTTPReadTimeout = r.duration("HTTP_READ_TIMEOUT", cfg.HTTPReadTimeout)
	cfg.HTTPWriteTimeout = r.duration("HTTP_WRITE_TIMEOUT", cfg.HTTPWriteTimeout)
	cfg.ShutdownGrace = r.duration("SHUTDOWN_GRACE", cfg.ShutdownGrace)

	cfg.TierFullMaxRTTMs = r.float("TIER_FULL_MAX_RTT_MS", cfg.TierFullMaxRTTMs)
	cfg.TierFullMaxJitterMs = r.float("TIER_FULL_MAX_JITTER_MS", cfg.TierFullMaxJitterMs)
	cfg.TierMinimalMinRTTMs = r.float("TIER_MINIMAL_MIN_RTT_MS", cfg.TierMinimalMinRTTMs)
	cfg.TierMinimalMinJitterMs = r.float("TIER_MINIMAL_MIN_JITTER_MS", cfg.TierMinimalMinJitterMs)
	cfg.TierRateFullPerSec = r.float("TIER_RATE_FULL_PER_SEC", cfg.TierRateFullPerSec)
	cfg.TierRateDegradedPerSec = r.float("TIER_RATE_DEGRADED_PER_SEC", cfg.TierRateDegradedPerSec)
	cfg.TierRateMinimalPerSec = r.float("TIER_RATE_MINIMAL_PER_SEC", cfg.TierRateMinimalPerSec)
	cfg.TierDegradeStreak = r.int("TIER_DEGRADE_STREAK", cfg.TierDegradeStreak)
	cfg.TierRecoverStreak = r.int("TIER_RECOVER_STREAK", cfg.TierRecoverStreak)
	cfg.HealthReportHold = r.duration("HEALTH_REPORT_HOLD", cfg.HealthReportHold)
	cfg.HealthReportDegrade = r.duration("HEALTH_REPORT_DEGRADE", cfg.HealthReportDegrade)
	cfg.HealthWatchdog = r.duration("HEALTH_WATCHDOG_INTERVAL", cfg.HealthWatchdog)
	cfg.SessionOutboundCap = r.int("SESSION_OUTBOUND_CAPACITY", cfg.SessionOutboundCap)
	cfg.SessionWriteTimeout = r.duration("SESSION_WRITE_TIMEOUT", cfg.SessionWriteTimeout)
	cfg.MaxSessionSubscriptions = r.int("MAX_SESSION_SUBSCRIPTIONS", cfg.MaxSessionSubscriptions)

	cfg.MetricsEnabled = r.boolean("METRICS_ENABLED", cfg.MetricsEnabled)
	cfg.MetricsDriver = r.str("METRICS_DRIVER", cfg.MetricsDriver)
	cfg.MetricsDBPath = r.str("METRICS_DB_PATH", cfg.MetricsDBPath)
	cfg.MetricsQueueCapacity = r.int("METRICS_QUEUE_CAPACITY", cfg.MetricsQueueCapacity)
	cfg.MetricsBatchSize = r.int("METRICS_BATCH_SIZE", cfg.MetricsBatchSize)
	cfg.MetricsFlushInterval = r.duration("METRICS_FLUSH_INTERVAL", cfg.MetricsFlushInterval)
	cfg.MetricsRetentionEnabled = r.boolean("METRICS_RETENTION_ENABLED", cfg.MetricsRetentionEnabled)
	cfg.MetricsRetentionLatency = r.duration("METRICS_RETENTION_LATENCY", cfg.MetricsRetentionLatency)
	cfg.MetricsRetentionEvents = r.duration("METRICS_RETENTION_EVENTS", cfg.MetricsRetentionEvents)
	cfg.MetricsRetentionSessions = r.duration("METRICS_RETENTION_SESSIONS", cfg.MetricsRetentionSessions)
	cfg.MetricsPruneInterval = r.duration("METRICS_PRUNE_INTERVAL", cfg.MetricsPruneInterval)
	cfg.MetricsPruneBatch = r.int("METRICS_PRUNE_BATCH", cfg.MetricsPruneBatch)

	cfg.EnableDebugControls = r.boolean("ENABLE_DEBUG_CONTROLS", cfg.EnableDebugControls)
	cfg.DebugBuild = debugBuild
	cfg.LogLevel = r.str("LOG_LEVEL", cfg.LogLevel)

	if errs := r.errs; len(errs) > 0 {
		return Config{}, fmt.Errorf("invalid configuration: %w", errors.Join(errs...))
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Validate checks ranges and cross-field constraints.
func (c Config) Validate() error {
	var errs []error
	require := func(cond bool, format string, args ...any) {
		if !cond {
			errs = append(errs, fmt.Errorf(format, args...))
		}
	}

	require(c.Symbol != "", "SYMBOL must not be empty")
	require(c.TradesPerSecond > 0 && c.TradesPerSecond <= 200, "TRADES_PER_SECOND must be in (0, 200], got %v", c.TradesPerSecond)
	require(c.BookRefreshHz > 0 && c.BookRefreshHz <= 100, "BOOK_REFRESH_HZ must be in (0, 100], got %v", c.BookRefreshHz)
	require(c.BookLevels >= 15, "BOOK_LEVELS must be at least 15 so the display window stays correct, got %d", c.BookLevels)
	require(c.BookDeltaWindow >= 10, "BOOK_DELTA_WINDOW must be at least 10, got %d", c.BookDeltaWindow)
	require(c.BookDeltaWindow < c.BookLevels, "BOOK_DELTA_WINDOW (%d) must be smaller than BOOK_LEVELS (%d)", c.BookDeltaWindow, c.BookLevels)
	require(c.HistoryLimitMax > 0 && c.HistoryLimitMax <= 1000, "HISTORY_LIMIT_MAX must be in (0, 1000], got %d", c.HistoryLimitMax)
	require(c.WarmupSpan > 0, "WARMUP_SPAN must be positive")
	require(c.WarmupMaxEvents > 0, "WARMUP_MAX_EVENTS must be positive")
	require(c.RecentTradesCap >= 50, "RECENT_TRADES_CAPACITY must be at least 50, got %d", c.RecentTradesCap)

	require(c.HTTPAddr != "", "HTTP_ADDR must not be empty")
	require(strings.HasPrefix(c.WSPath, "/"), "WS_PATH must start with '/', got %q", c.WSPath)
	require(c.WSReadLimitBytes >= 1024, "WS_READ_LIMIT_BYTES must be at least 1024, got %d", c.WSReadLimitBytes)
	require(c.WSClientMsgPerSec > 0, "WS_CLIENT_MSG_PER_SEC must be positive")
	require(c.HTTPReadTimeout > 0 && c.HTTPWriteTimeout > 0, "HTTP timeouts must be positive")
	require(c.ShutdownGrace > 0, "SHUTDOWN_GRACE must be positive")

	require(c.TierFullMaxRTTMs > 0, "TIER_FULL_MAX_RTT_MS must be positive")
	require(c.TierMinimalMinRTTMs > c.TierFullMaxRTTMs,
		"TIER_MINIMAL_MIN_RTT_MS (%v) must be greater than TIER_FULL_MAX_RTT_MS (%v)", c.TierMinimalMinRTTMs, c.TierFullMaxRTTMs)
	require(c.TierMinimalMinJitterMs > c.TierFullMaxJitterMs,
		"TIER_MINIMAL_MIN_JITTER_MS (%v) must be greater than TIER_FULL_MAX_JITTER_MS (%v)", c.TierMinimalMinJitterMs, c.TierFullMaxJitterMs)
	require(c.TierRateFullPerSec > 0 && c.TierRateDegradedPerSec > 0 && c.TierRateMinimalPerSec > 0,
		"tier target rates must all be positive")
	require(c.TierRateFullPerSec > c.TierRateDegradedPerSec && c.TierRateDegradedPerSec > c.TierRateMinimalPerSec,
		"tier target rates must be strictly decreasing: full=%v degraded=%v minimal=%v",
		c.TierRateFullPerSec, c.TierRateDegradedPerSec, c.TierRateMinimalPerSec)
	require(c.TierDegradeStreak >= 1, "TIER_DEGRADE_STREAK must be at least 1")
	require(c.TierRecoverStreak >= 1, "TIER_RECOVER_STREAK must be at least 1")
	require(c.HealthReportHold > 0, "HEALTH_REPORT_HOLD must be positive")
	require(c.HealthReportDegrade > c.HealthReportHold,
		"HEALTH_REPORT_DEGRADE (%v) must be greater than HEALTH_REPORT_HOLD (%v)", c.HealthReportDegrade, c.HealthReportHold)
	require(c.HealthWatchdog > 0, "HEALTH_WATCHDOG_INTERVAL must be positive")
	require(c.SessionOutboundCap >= 16, "SESSION_OUTBOUND_CAPACITY must be at least 16, got %d", c.SessionOutboundCap)
	require(c.SessionWriteTimeout > 0, "SESSION_WRITE_TIMEOUT must be positive")
	require(c.MaxSessionSubscriptions >= 1, "MAX_SESSION_SUBSCRIPTIONS must be at least 1")

	switch c.MetricsDriver {
	case "sqlite", "memory":
	default:
		errs = append(errs, fmt.Errorf("METRICS_DRIVER must be one of sqlite|memory, got %q", c.MetricsDriver))
	}
	if c.MetricsEnabled {
		require(c.MetricsDBPath != "" || c.MetricsDriver == "memory", "METRICS_DB_PATH is required for the sqlite driver")
		require(c.MetricsQueueCapacity >= 64, "METRICS_QUEUE_CAPACITY must be at least 64, got %d", c.MetricsQueueCapacity)
		require(c.MetricsBatchSize >= 1, "METRICS_BATCH_SIZE must be at least 1")
		require(c.MetricsFlushInterval > 0, "METRICS_FLUSH_INTERVAL must be positive")
		require(c.MetricsPruneBatch >= 1, "METRICS_PRUNE_BATCH must be at least 1")
	}

	switch c.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		errs = append(errs, fmt.Errorf("LOG_LEVEL must be one of debug|info|warn|error, got %q", c.LogLevel))
	}

	if len(errs) > 0 {
		return fmt.Errorf("invalid configuration:\n  - %w", errors.Join(errs...))
	}
	return nil
}

// DebugControlsActive reports whether fault injection may be exposed. A release
// build can never enable it, whatever the environment says.
func (c Config) DebugControlsActive() bool { return c.DebugBuild && c.EnableDebugControls }

// --- parsing helpers --------------------------------------------------------

type reader struct {
	values map[string]string
	errs   []error
}

func (r *reader) raw(key string) (string, bool) {
	v, ok := r.values[key]
	return v, ok
}

func (r *reader) str(key, def string) string {
	if v, ok := r.raw(key); ok {
		return v
	}
	return def
}

func (r *reader) fail(key, value, want string, err error) {
	r.errs = append(r.errs, fmt.Errorf("%s=%q is not a valid %s: %v", key, value, want, err))
}

func (r *reader) int(key string, def int) int {
	v, ok := r.raw(key)
	if !ok {
		return def
	}
	parsed, err := strconv.Atoi(v)
	if err != nil {
		r.fail(key, v, "integer", err)
		return def
	}
	return parsed
}

func (r *reader) int64(key string, def int64) int64 {
	v, ok := r.raw(key)
	if !ok {
		return def
	}
	parsed, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		r.fail(key, v, "integer", err)
		return def
	}
	return parsed
}

func (r *reader) float(key string, def float64) float64 {
	v, ok := r.raw(key)
	if !ok {
		return def
	}
	parsed, err := strconv.ParseFloat(v, 64)
	if err != nil {
		r.fail(key, v, "number", err)
		return def
	}
	return parsed
}

func (r *reader) boolean(key string, def bool) bool {
	v, ok := r.raw(key)
	if !ok {
		return def
	}
	parsed, err := strconv.ParseBool(v)
	if err != nil {
		r.fail(key, v, "boolean", err)
		return def
	}
	return parsed
}

func (r *reader) duration(key string, def time.Duration) time.Duration {
	v, ok := r.raw(key)
	if !ok {
		return def
	}
	parsed, err := time.ParseDuration(v)
	if err != nil {
		r.fail(key, v, "duration (e.g. 250ms, 5s, 24h)", err)
		return def
	}
	return parsed
}

// loadDotEnv applies KEY=VALUE lines from a dotenv file. Existing environment
// variables win, so an explicit export always overrides the file. Parse errors
// are ignored: the file is a developer convenience, and any value it provides
// still has to pass Validate.
func loadDotEnv(path string, override bool) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		if _, exists := os.LookupEnv(key); exists && !override {
			continue
		}
		if err := os.Setenv(key, value); err != nil {
			return
		}
	}
}
