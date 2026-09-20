// Command server runs the PulseTrade market-data backend: a deterministic
// synthetic market, a canonical market engine, adaptive per-connection delivery,
// a WebSocket and REST surface, and a metrics store that records every latency
// sample and operational event.
package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/config"
	"github.com/pulsetrade/pulse-trade-backend/internal/delivery"
	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/faultinject"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/replay"
	"github.com/pulsetrade/pulse-trade-backend/internal/exchange/synthetic"
	"github.com/pulsetrade/pulse-trade-backend/internal/market"
	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	// The SQLite driver registers itself; importing it here is what makes the
	// default METRICS_DRIVER=sqlite resolvable.
	_ "github.com/pulsetrade/pulse-trade-backend/internal/metrics/sqlite"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
	transporthttp "github.com/pulsetrade/pulse-trade-backend/internal/transport/http"
	"github.com/pulsetrade/pulse-trade-backend/internal/transport/websocket"
)

// version is overridable at build time with -ldflags "-X main.version=...".
var version = "1.0.0"

func main() {
	if err := run(); err != nil {
		// The fatal record is JSON like every other one. It is the line an
		// operator most needs to grep, and a plain-text `fatal:` prefix made it
		// the only record that `jq` could not read. The logger is rebuilt here
		// instead of being handed out of run() because run() can fail before a
		// logger exists at all — `config.Load()` is its first statement.
		//
		// It goes to stderr, which is where a failed process belongs; stdout stays
		// the clean record stream for a pipe.
		observability.New("error", version, false, os.Stderr).
			Error(observability.MsgStartupFailed,
				observability.FieldError, err.Error(),
				observability.FieldFatal, true,
			)
		os.Exit(1)
	}
}

func run() error {
	startedAt := time.Now().UTC()

	cfg, err := config.Load()
	if err != nil {
		// Configuration is validated before anything else exists, so a bad value
		// fails fast with every problem listed at once.
		return err
	}

	logger := observability.New(cfg.LogLevel, version, cfg.DebugBuild, os.Stdout)
	logger.Component(observability.ComponentConfig).Info(observability.MsgConfigLoaded,
		observability.FieldDebugBuild, cfg.DebugBuild,
		observability.FieldDebugControls, cfg.DebugControlsActive(),
		observability.FieldMetricsDriver, cfg.MetricsDriver,
	)

	symbol, err := domain.Lookup(cfg.Symbol)
	if err != nil {
		return fmt.Errorf("SYMBOL=%q: %w", cfg.Symbol, err)
	}

	// The first record that names what this process is about to serve. It is
	// emitted after the symbol is resolved so a rejected SYMBOL fails without
	// having already claimed to be starting.
	logger.Component(observability.ComponentEngine).Info(observability.MsgServerStarting,
		observability.FieldSeed, cfg.GeneratorSeed,
		observability.FieldSymbol, symbol.ID,
	)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	registry := observability.NewRegistry()

	// The metrics database lives in a directory the operator configures, so it is
	// created here. Failing with SQLite's "unable to open database file" would hide
	// the real reason from whoever is starting the server.
	if cfg.MetricsEnabled && cfg.MetricsDriver == "sqlite" && cfg.MetricsDBPath != "" {
		if dir := filepath.Dir(cfg.MetricsDBPath); dir != "." && dir != "" {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return fmt.Errorf("create metrics directory %s: %w", dir, err)
			}
		}
	}

	store, err := metrics.Open(ctx, metricsConfig(cfg), logger)
	if err != nil {
		return fmt.Errorf("open metrics store: %w", err)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
		defer cancel()
		if err := store.Close(shutdownCtx); err != nil {
			logger.Warn(observability.MsgMetricsCloseFailed, observability.FieldError, err.Error())
		}
	}()
	clock := domain.SystemClock()

	// Every roster market gets its own engine and its own bus, so markets are
	// independent: a stall or reset in one cannot reach another. The seed is
	// derived per symbol, so the whole roster is reproducible from one configured
	// seed while the markets do not move identically.
	markets := make([]*market.Engine, 0, len(domain.AllSymbols()))
	for _, sym := range domain.AllSymbols() {
		seed := domain.DerivedSeed(cfg.GeneratorSeed, sym.ID)
		provider, err := buildProvider(cfg, sym, seed, clock)
		if err != nil {
			return err
		}
		engine, err := market.New(ctx, market.Config{
			Symbol:              sym,
			Seed:                seed,
			BookLevels:          cfg.BookLevels,
			BookDeltaWindow:     cfg.BookDeltaWindow,
			BookRefreshHz:       cfg.BookRefreshHz,
			WarmupEvents:        cfg.WarmupMaxEvents,
			RecentTradesCap:     cfg.RecentTradesCap,
			HistoryDepth:        cfg.HistoryLimitMax,
			VolatilityBurstRate: cfg.VolatilityBurstRate,
			BusCapacity:         cfg.SessionOutboundCap,
		}, provider, market.NewBus(), store.Recorder(), clock)
		if err != nil {
			return fmt.Errorf("build market engine for %s: %w", sym.ID, err)
		}
		markets = append(markets, engine)
	}
	marketRegistry := market.NewRegistry(markets...)

	manager := delivery.NewManager(delivery.ManagerConfig{
		Registry:         marketRegistry,
		DefaultSymbol:    symbol,
		ServerVersion:    version,
		Policy:           buildPolicy(cfg),
		Logger:           logger,
		MetricsRegistry:  registry,
		Recorder:         store.Recorder(),
		Clock:            clock,
		OutboundCapacity: cfg.SessionOutboundCap,
		WriteTimeout:     cfg.SessionWriteTimeout,
		ClientMsgPerSec:  cfg.WSClientMsgPerSec,
		ReadLimitBytes:   cfg.WSReadLimitBytes,
		BookWindow:       cfg.BookDeltaWindow,
		HistoryLimit:     cfg.HistoryLimitMax,
		TradesLimit:      50,
		DebugControls:    cfg.DebugControlsActive(),
		BusCapacity:      cfg.SessionOutboundCap,
	})

	debugState := transporthttp.NewDebugState()

	wsHandler := websocket.NewHandler(websocket.Config{
		Path:         cfg.WSPath,
		ReadLimit:    cfg.WSReadLimitBytes,
		WriteTimeout: cfg.SessionWriteTimeout,
	}, manager, symbolEngine(marketRegistry, symbol), logger, registry)

	router := transporthttp.NewRouter(transporthttp.RouterConfig{
		Registry:       marketRegistry,
		DefaultSymbol:  symbol,
		Manager:        manager,
		Metrics:        store.Querier(),
		Debug:          debugState,
		Logger:         logger,
		RegistryGauges: registry,
		Version:        version,
		StartedAt:      startedAt,
		Clock:          clock,
		HistoryMax:     cfg.HistoryLimitMax,
		EnableDebug:    cfg.DebugControlsActive(),
		MetricsHealth: func() transporthttp.MetricsHealth {
			// The store's own health is mapped here so the transport layer does not
			// depend on the metrics package.
			health := store.Health()
			return transporthttp.MetricsHealth{
				Driver:        health.Driver,
				Status:        health.Status,
				QueueDepth:    health.QueueDepth,
				Capacity:      health.Capacity,
				DroppedTotal:  health.DroppedTotal,
				WriteFailures: health.WriteFailures,
				RowsWritten:   health.RowsWritten,
				LastFlushMs:   health.LastFlushMs,
				SchemaVersion: health.SchemaVersion,
			}
		},
	})

	// Bind before anything expensive happens. A port conflict is the most likely
	// way this process fails to start, and warmup is its most expensive step, so
	// the socket is claimed first and the error surfaces in milliseconds. Binding
	// here also means the `listening` record below is only ever emitted for a
	// socket that really opened, rather than announcing a listener that then
	// failed on `address already in use`.
	listener, err := net.Listen("tcp", cfg.HTTPAddr)
	if err != nil {
		return fmt.Errorf("http server: listen %s: %w", cfg.HTTPAddr, err)
	}
	defer func() { _ = listener.Close() }()

	// Every engine runs in its own goroutine: warmup first, then live trading.
	// The markets are independent, so their warmups run concurrently and the
	// process waits for the slowest market rather than for their sum.
	engineErr := make(chan error, len(markets))
	for _, engine := range markets {
		engine := engine
		go func() {
			err := engine.Run(ctx)
			if err != nil && !errors.Is(err, context.Canceled) {
				logger.Error(observability.MsgEngineStopped,
					observability.FieldSymbol, engine.Symbol().ID,
					observability.FieldError, err.Error())
			}
			engineErr <- err
		}()
	}

	waitForWarmup(ctx, markets, logger)

	go reportGauges(ctx, marketRegistry, symbol, manager, registry, clock)

	mux := http.NewServeMux()
	mux.Handle(cfg.WSPath, wsHandler)
	mux.Handle("/", router)

	server := &http.Server{
		Addr:         cfg.HTTPAddr,
		Handler:      mux,
		ReadTimeout:  cfg.HTTPReadTimeout,
		WriteTimeout: cfg.HTTPWriteTimeout,
		IdleTimeout:  60 * time.Second,
	}

	listenErr := make(chan error, 1)
	go func() {
		// The configured address, not `listener.Addr()`: Go reports a dual-stack
		// bind as `[::]:8080`, which is less readable than the `0.0.0.0:8080` the
		// operator wrote. The bind has already succeeded here, so echoing the
		// request is accurate.
		logger.Component(observability.ComponentTransport).Info(observability.MsgListening,
			observability.FieldAddr, cfg.HTTPAddr,
			observability.FieldWSPath, cfg.WSPath,
			observability.FieldSeed, cfg.GeneratorSeed,
			observability.FieldSymbol, symbol.ID,
		)
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			listenErr <- err
		}
	}()

	select {
	case err := <-listenErr:
		return fmt.Errorf("http server: %w", err)
	case err := <-engineErr:
		if err != nil && !errors.Is(err, context.Canceled) {
			logger.Warn(observability.MsgEngineEndedEarly, observability.FieldError, err.Error())
		}
	case <-ctx.Done():
	}

	// Shutdown order: stop accepting work, drain sessions, stop the engine, drain
	// metrics. Each step is bounded so a stuck step cannot hang the process.
	logger.Component(observability.ComponentTransport).Info(observability.MsgShutdownStarted)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()

	manager.CloseAll("server_shutdown", cfg.ShutdownGrace/2)
	if err := server.Shutdown(shutdownCtx); err != nil {
		logger.Warn(observability.MsgHTTPShutdownIncomplete, observability.FieldError, err.Error())
	}
	if err := store.Flush(shutdownCtx); err != nil {
		logger.Warn(observability.MsgMetricsFlushIncomplete, observability.FieldError, err.Error())
	}
	logger.Component(observability.ComponentTransport).Info(observability.MsgShutdownComplete,
		observability.FieldDurationMs, time.Since(startedAt).Milliseconds(),
	)
	return nil
}

// buildProvider selects the market source. The synthetic generator is the product;
// the replay provider exists for deterministic tests and controller demonstrations.
func buildProvider(cfg config.Config, symbol domain.Symbol, seed int64, clock domain.Clock) (exchange.MarketDataProvider, error) {
	var provider exchange.MarketDataProvider

	switch os.Getenv("MARKET_PROVIDER") {
	case "replay":
		path := os.Getenv("REPLAY_FIXTURE")
		if path == "" {
			path = "../fixtures/replay/trades_basic.jsonl"
		}
		replayed, err := replay.New(replay.Config{
			Path: path, Symbol: symbol, Interval: 100 * time.Millisecond, Loop: true,
		}, clock)
		if err != nil {
			return nil, fmt.Errorf("replay provider: %w", err)
		}
		provider = replayed
	default:
		provider = synthetic.New(synthetic.Config{
			Symbol:              symbol,
			Seed:                seed,
			TradesPerSecond:     cfg.TradesPerSecond,
			WarmupSpan:          cfg.WarmupSpan,
			WarmupMaxEvents:     cfg.WarmupMaxEvents,
			VolatilityBurstRate: cfg.VolatilityBurstRate,
			BookLevels:          cfg.BookLevels,
		}, clock)
	}

	// Fault injection wraps the chosen provider rather than forking it, so the
	// engine behaves identically with faults enabled and disabled.
	if schedule := faultScheduleFromEnv(); len(schedule.Faults) > 0 {
		provider = faultinject.New(provider, schedule, nil, clock)
	}
	return provider, nil
}

// symbolEngine returns the engine a new session is bound to before it subscribes.
func symbolEngine(registry *market.Registry, sym domain.Symbol) *market.Engine {
	engine, _ := registry.Lookup(sym)
	return engine
}

func faultScheduleFromEnv() faultinject.Schedule {
	// The schedule is supplied by tests; the running server injects faults through
	// the debug endpoints instead, which are per session rather than global.
	return faultinject.Schedule{}
}

func buildPolicy(cfg config.Config) delivery.Policy {
	return delivery.NewDefaultPolicy(delivery.Thresholds{
		FullMaxRTTMs:       cfg.TierFullMaxRTTMs,
		FullMaxJitterMs:    cfg.TierFullMaxJitterMs,
		MinimalMinRTTMs:    cfg.TierMinimalMinRTTMs,
		MinimalMinJitterMs: cfg.TierMinimalMinJitterMs,
		DegradeStreak:      cfg.TierDegradeStreak,
		RecoverStreak:      cfg.TierRecoverStreak,
		ReportHold:         cfg.HealthReportHold,
		ReportDegrade:      cfg.HealthReportDegrade,
	}, cfg.TierRateFullPerSec, cfg.TierRateDegradedPerSec, cfg.TierRateMinimalPerSec)
}

func metricsConfig(cfg config.Config) metrics.Config {
	return metrics.Config{
		Enabled:           cfg.MetricsEnabled,
		Driver:            cfg.MetricsDriver,
		DSN:               cfg.MetricsDBPath,
		QueueCapacity:     cfg.MetricsQueueCapacity,
		BatchSize:         cfg.MetricsBatchSize,
		FlushInterval:     cfg.MetricsFlushInterval,
		RetentionEnabled:  cfg.MetricsRetentionEnabled,
		RetentionLatency:  cfg.MetricsRetentionLatency,
		RetentionEvents:   cfg.MetricsRetentionEvents,
		RetentionSessions: cfg.MetricsRetentionSessions,
		PruneInterval:     cfg.MetricsPruneInterval,
		PruneBatch:        cfg.MetricsPruneBatch,
	}
}

// waitForWarmup gives history time to build so the first client sees a populated
// chart. It waits for every market, and is bounded: a slow warmup logs a warning
// and the server starts anyway, because refusing to serve is worse than serving a
// partially filled chart.
func waitForWarmup(ctx context.Context, engines []*market.Engine, logger *observability.Logger) {
	const budget = 10 * time.Second
	started := time.Now()
	deadline := started.Add(budget)
	for time.Now().Before(deadline) {
		warm := 0
		for _, engine := range engines {
			if engine.WarmupComplete() {
				warm++
			}
		}
		if warm == len(engines) {
			logger.Component(observability.ComponentEngine).Info(observability.MsgWarmupComplete,
				observability.FieldEventIndex, engines[len(engines)-1].EventIndex(),
				observability.FieldUpdateID, engines[len(engines)-1].UpdateID(),
				observability.FieldDetail, fmt.Sprintf("markets=%d", len(engines)),
				observability.FieldDurationMs, time.Since(started).Milliseconds(),
			)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(20 * time.Millisecond):
		}
	}
	logger.Component(observability.ComponentEngine).Warn(observability.MsgWarmupComplete,
		observability.FieldTimedOut, true,
		observability.FieldDetail, fmt.Sprintf("markets=%d", len(engines)),
		observability.FieldDurationMs, budget.Milliseconds())
}

// reportGauges publishes engine and session gauges once a second so the health and
// diagnostics endpoints can show them without walking an engine on every request.
// The single-value engine gauges track the default market; the subscriber gauge is
// a process total across every market's bus.
func reportGauges(ctx context.Context, registry *market.Registry, defaultSymbol domain.Symbol, manager *delivery.Manager, gauges *observability.Registry, clock domain.Clock) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if engine, ok := registry.Lookup(defaultSymbol); ok {
				gauges.SetGauge(observability.GaugeEngineEventIndex, int64(engine.EventIndex()))
				gauges.SetGauge(observability.GaugeEngineUpdateID, int64(engine.UpdateID()))
				gauges.SetGauge(observability.GaugeEngineEpoch, int64(engine.Epoch()))
			}
			var subscribers int
			for _, engine := range registry.Engines() {
				subscribers += engine.Bus().SubscriberCount()
			}
			gauges.SetGauge(observability.GaugeSessionsActive, int64(manager.Count()))
			gauges.SetGauge(observability.GaugeBusSubscribers, int64(subscribers))
			_ = clock
		}
	}
}
