// Package metrics is the asynchronous, non-blocking telemetry store described below.
// It is an observer: producers hand it records and never wait for I/O, and
// the HTTP layer reads aggregates back through a separate query interface.
//
// Three properties shape the whole design:
//
// - A producer must never block. Every Record* method is a non-blocking send into
// a bounded queue, and overflow drops the oldest record and counts it.
// Blocking a tick or delivery loop is never acceptable.
// - Loss is never silent. Dropped rows, write failures and pruned rows are all
// counted and surfaced through Health.
// - The store is never a single point of failure. A broken database degrades
// health and keeps the system running; it does not stop the market.
package metrics

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/domain"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// Driver names accepted by Open.
const (
	DriverSQLite = "sqlite"
	DriverMemory = "memory"
)

// Health status values.
const (
	StatusOK       = "ok"
	StatusDegraded = "degraded"
	StatusDisabled = "disabled"
)

// Defaults for the tunables in Config. They match the store's write path:
// a 4096-record queue drained in batches of 128 or every 250 ms.
const (
	DefaultQueueCapacity    = 4096
	DefaultBatchSize        = 128
	DefaultFlushInterval    = 250 * time.Millisecond
	DefaultPruneInterval    = 10 * time.Minute
	DefaultPruneBatch       = 5000
	DefaultRetention        = 24 * time.Hour
	DefaultEventRetention   = 7 * 24 * time.Hour
	DefaultSessionRetention = 90 * 24 * time.Hour
)

// warnInterval is the floor between two overflow warnings. A full queue produces
// one drop per record, and one log line per drop would turn a degraded store into
// a log flood that hides the cause.
const warnInterval = time.Minute

// Config configures the metrics store.
type Config struct {
	// Enabled is the master switch. When false, Open still returns a usable
	// store whose Recorder is a no-op and whose queries return empty results, so
	// every caller can be wired unconditionally.
	Enabled bool
	// Driver selects the backing store: "sqlite" (durable) or "memory" (tests).
	Driver string
	// DSN is the SQLite database file path. It is required for the sqlite
	// driver and ignored by the memory driver.
	DSN string
	// QueueCapacity bounds the in-process queue. Overflow drops the oldest
	// record rather than blocking a producer.
	QueueCapacity int
	// BatchSize is the number of queued records that forces a commit.
	BatchSize int
	// FlushInterval bounds how long a record may wait for a batch boundary.
	FlushInterval time.Duration
	// RetentionEnabled turns the pruning pass on or off.
	RetentionEnabled bool
	// RetentionLatency bounds the high-volume sample tables.
	RetentionLatency time.Duration
	// RetentionEvents bounds the medium-volume operational tables.
	RetentionEvents time.Duration
	// RetentionSessions bounds the low-volume lifecycle tables.
	RetentionSessions time.Duration
	// PruneInterval is how often retention runs.
	PruneInterval time.Duration
	// PruneBatch bounds one prune statement so a large table cannot hold the
	// write lock for the length of an unbounded DELETE.
	PruneBatch int
}

func (c Config) withDefaults() Config {
	if strings.TrimSpace(c.Driver) == "" {
		c.Driver = DriverSQLite
	}
	if c.QueueCapacity <= 0 {
		c.QueueCapacity = DefaultQueueCapacity
	}
	if c.BatchSize <= 0 {
		c.BatchSize = DefaultBatchSize
	}
	if c.FlushInterval <= 0 {
		c.FlushInterval = DefaultFlushInterval
	}
	if c.RetentionLatency <= 0 {
		c.RetentionLatency = DefaultRetention
	}
	if c.RetentionEvents <= 0 {
		c.RetentionEvents = DefaultEventRetention
	}
	if c.RetentionSessions <= 0 {
		c.RetentionSessions = DefaultSessionRetention
	}
	if c.PruneInterval <= 0 {
		c.PruneInterval = DefaultPruneInterval
	}
	if c.PruneBatch <= 0 {
		c.PruneBatch = DefaultPruneBatch
	}
	return c
}

// validate rejects a configuration that cannot work, at startup rather than at
// the first record. Panicking is reserved for compile-time-style mistakes; a bad
// operator configuration is an error.
func (c Config) validate() error {
	if !c.Enabled {
		return nil
	}
	switch c.Driver {
	case DriverSQLite:
		if strings.TrimSpace(c.DSN) == "" {
			return errors.New("metrics: sqlite driver requires a database path")
		}
	case DriverMemory:
		// Nothing further: the memory driver has no external configuration.
	default:
		return fmt.Errorf("metrics: unknown driver %q", c.Driver)
	}
	return nil
}

// Health is the store's own health signal. It is what /health reports for the
// metrics subsystem: the counters are the evidence that loss was counted rather
// than hidden.
type Health struct {
	Driver        string `json:"driver"`
	Status        string `json:"status"` // "ok" | "degraded" | "disabled"
	QueueDepth    int    `json:"queueDepth"`
	Capacity      int    `json:"queueCapacity"`
	DroppedTotal  int64  `json:"droppedTotal"`
	WriteFailures int64  `json:"writeFailures"`
	RowsWritten   int64  `json:"rowsWritten"`
	LastFlushMs   int64  `json:"lastFlushMs"`
	SchemaVersion int    `json:"schemaVersion"`
}

// Recorder is the write surface. The engine already declares the two
// observability methods (see market.Recorder); this interface is the full set the
// delivery layer uses. The method set is exactly this and must not grow without a
// matching reader, because every method is a promise that the record is durable
// or counted as lost.
type Recorder interface {
	RecordLatency(observability.LatencySample)
	RecordHealthReport(observability.HealthReportRow)
	RecordTierTransition(observability.TierTransitionRow)
	RecordDeliveryWindow(observability.DeliveryWindow)
	RecordBookEvent(observability.BookSyncEvent)
	RecordProtocolEvent(observability.ProtocolEvent)
	RecordSessionStart(observability.SessionRow)
	RecordSessionEnd(observability.SessionRow)
	RecordFaultInjection(observability.FaultInjectionRow)

	// The engine's two methods complete the market.Recorder contract so a single
	// Recorder value can be handed to both the engine and the delivery layer.
	RecordEngineEvent(observability.EngineEvent)
	RecordCandleClose(domain.Candle)
}

// Querier is the read surface used by the HTTP metrics handlers. All methods are
// bounded: reads share the single write connection, so an unbounded read would
// delay the write path.
type Querier interface {
	Summary(ctx context.Context, window time.Duration) (observability.MetricsSummary, error)
	LatencyBuckets(ctx context.Context, sessionID string, from, to time.Time, bucket time.Duration) ([]observability.LatencyBucket, error)
	TierTransitions(ctx context.Context, from, to time.Time, limit int) ([]observability.TierTransitionRow, error)
	Sessions(ctx context.Context, limit int) ([]observability.SessionRow, error)
	DeliveryWindows(ctx context.Context, sessionID string, from, to time.Time, limit int) ([]observability.DeliveryWindow, error)
}

// Store is the metrics facade. It owns the queue, the single writer goroutine and
// the counters that prove nothing was lost silently.
type Store struct {
	cfg    Config
	repo   Repository
	logger *observability.Logger
	opened time.Time

	queue   *recordQueue
	writer  *writerHandle
	dropped atomic.Int64

	// bgCtx owns the writer goroutine's lifetime. It is separate from the
	// context passed to Open so a caller's short-lived startup context cannot
	// silently kill the writer.
	bgCtx    context.Context
	bgCancel context.CancelFunc

	writeFailures atomic.Int64
	rowsWritten   atomic.Int64
	prunedRows    atomic.Int64
	lastFlushMs   atomic.Int64
	lastWarnUnix  atomic.Int64
	closed        atomic.Bool
	closeOnce     sync.Once

	// statusMu guards the degraded flag, which the writer's callbacks set and
	// Health reads from a different goroutine.
	statusMu sync.Mutex
	writeErr error
}

// writerHandle abstracts the driver's batching writer so Store does not know
// which driver is behind it.
type writerHandle struct {
	flush  func(ctx context.Context) error
	wait   func()
	stop   func() error
	health func() (schemaVersion int, err error)
}

// Open builds a store. When Config.Enabled is false the returned store is fully
// functional but records nowhere: Recorder methods are no-ops, Querier methods
// return empty results, and Health reports "disabled".
func Open(ctx context.Context, cfg Config, logger *observability.Logger) (*Store, error) {
	cfg = cfg.withDefaults()
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	if logger == nil {
		logger = observability.New("info", "unknown", false, nil)
	}

	s := &Store{
		cfg:    cfg,
		logger: logger.Component(observability.ComponentMetrics),
		opened: time.Now(),
	}
	if !cfg.Enabled {
		return s, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}

	repo, err := openRepository(ctx, cfg, logger)
	if err != nil {
		return nil, err
	}
	s.repo = repo
	s.queue = newRecordQueue(cfg.QueueCapacity)
	s.writer = s.startWriter(repo)

	s.logger.Info(observability.MsgMetricsStoreReady,
		observability.FieldDriver, cfg.Driver,
		observability.FieldPath, cfg.DSN,
		observability.FieldCapacity, cfg.QueueCapacity,
		observability.FieldBatchSize, cfg.BatchSize,
		observability.FieldSchemaVersion, repo.SchemaVersion(),
	)

	// The store starts in a healthy state and only degrades after a real failure:
	// a store that has never written is not reported as broken.
	s.setWriteError(nil)
	return s, nil
}

// driverFactory builds a driver's repository. Drivers register themselves so this
// package never imports them: the engine and delivery layers depend on this
// package only, and a driver that imported it back would otherwise create a cycle
// (memory.Repository implements Repository, which is declared here).
type driverFactory func(ctx context.Context, cfg Config, logger *observability.Logger) (Repository, error)

var (
	driverMu        sync.RWMutex
	driverFactories = map[string]driverFactory{}
)

// RegisterDriver installs a driver factory. It is called from a driver package's
// init function; a duplicate registration for the same name replaces the previous
// factory, which keeps tests that swap drivers from panicking.
func RegisterDriver(name string, factory driverFactory) {
	if factory == nil {
		return
	}
	driverMu.Lock()
	driverFactories[strings.ToLower(strings.TrimSpace(name))] = factory
	driverMu.Unlock()
}

// openRepository builds the driver selected by cfg.Driver.
func openRepository(ctx context.Context, cfg Config, logger *observability.Logger) (Repository, error) {
	driverMu.RLock()
	factory, ok := driverFactories[strings.ToLower(cfg.Driver)]
	driverMu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("metrics: unknown driver %q (no implementation registered)", cfg.Driver)
	}
	// The default DSN is ./data/pulsetrade.db, and a fresh checkout has no data
	// directory. The driver creates the file but not its parent, so the store
	// creates the directory first: refusing to start because ./data is missing
	// would make the default configuration a trap.
	if err := ensureParentDir(cfg.DSN); err != nil {
		return nil, err
	}
	return factory(ctx, cfg, logger)
}

// ensureParentDir creates the directory the DSN's file lives in. It is a no-op
// for a DSN with no directory component or for a driver that ignores the DSN.
func ensureParentDir(dsn string) error {
	if strings.TrimSpace(dsn) == "" {
		return nil
	}
	dir := filepath.Dir(dsn)
	if dir == "" || dir == "." || dir == string(filepath.Separator) {
		return nil
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("metrics: create database directory %s: %w", dir, err)
	}
	return nil
}

// startWriter wires the driver's batching writer to the store's counters and
// starts the single writer goroutine. A driver that needs no batching (the
// in-memory driver writes synchronously) reports that through its options.
func (s *Store) startWriter(repo Repository) *writerHandle {
	opts := WriterOptions{
		BatchSize:     s.cfg.BatchSize,
		FlushInterval: s.cfg.FlushInterval,
		Retention: Retention{
			Enabled:  s.cfg.RetentionEnabled,
			Latency:  s.cfg.RetentionLatency,
			Events:   s.cfg.RetentionEvents,
			Sessions: s.cfg.RetentionSessions,
		},
		PruneInterval: s.cfg.PruneInterval,
		PruneBatch:    s.cfg.PruneBatch,
		Logger:        s.logger,
		OnWriteFailure: func(err error) {
			s.writeFailures.Add(1)
			s.setWriteError(err)
		},
		OnWriteSuccess: func(rows int64) {
			s.rowsWritten.Add(rows)
			s.setWriteError(nil)
		},
		OnPruned:    func(rows int64) { s.prunedRows.Add(rows) },
		OnFlushDone: func(d time.Duration) { s.lastFlushMs.Store(d.Milliseconds()) },
	}
	if provider, ok := repo.(WriterProvider); ok {
		opts.Repository = repo
		provider.ConfigureWriter(opts)
		opts = provider.WriterOptions()
	}
	if opts.Repository == nil {
		opts.Repository = repo
	}
	s.bgCtx, s.bgCancel = context.WithCancel(context.Background())
	w := newBatchWriter(s.queue, opts)
	go w.start(s.bgCtx)
	return &writerHandle{
		flush:  w.flush,
		wait:   func() { <-w.done },
		stop:   s.stopBackground,
		health: func() (int, error) { return repo.SchemaVersion(), w.err() },
	}
}

// stopBackground cancels the writer goroutine's context. The goroutine then runs
// its own bounded final drain before it exits, so cancellation does not discard
// records that are already queued.
func (s *Store) stopBackground() error {
	if s.bgCancel != nil {
		s.bgCancel()
	}
	return nil
}

// Recorder returns the non-blocking write surface.
func (s *Store) Recorder() Recorder { return s }

// Querier returns the read surface used by the metrics HTTP handlers.
func (s *Store) Querier() Querier { return (*querier)(s) }

// Dropped reports how many records were discarded because the queue was full.
func (s *Store) Dropped() int64 { return s.dropped.Load() }

// QueueDepth reports the current queue occupancy.
func (s *Store) QueueDepth() int {
	if s.queue == nil {
		return 0
	}
	return s.queue.Depth()
}

// Health reports the store's own status.
func (s *Store) Health() Health {
	h := Health{
		Driver:        s.cfg.Driver,
		Status:        StatusOK,
		QueueDepth:    s.QueueDepth(),
		Capacity:      s.cfg.QueueCapacity,
		DroppedTotal:  s.dropped.Load(),
		WriteFailures: s.writeFailures.Load(),
		RowsWritten:   s.rowsWritten.Load(),
		LastFlushMs:   s.lastFlushMs.Load(),
	}
	if !s.cfg.Enabled {
		h.Driver = driverNameOrDisabled(s.cfg.Driver)
		h.Status = StatusDisabled
		h.Capacity = 0
		return h
	}
	if s.repo != nil {
		h.SchemaVersion = s.repo.SchemaVersion()
	}
	s.statusMu.Lock()
	degraded := s.writeErr != nil
	s.statusMu.Unlock()
	if degraded {
		h.Status = StatusDegraded
	}
	return h
}

// Close drains the queue with a deadline, then closes the database. It is safe to
// call more than once: the second call observes the same result as the first.
func (s *Store) Close(ctx context.Context) error {
	var err error
	s.closeOnce.Do(func() {
		s.closed.Store(true)
		if ctx == nil {
			ctx = context.Background()
		}
		// The drain gets its own deadline derived from the caller's context, so a
		// shutdown that is already past its budget does not block on a slow disk.
		drainCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()

		if s.writer != nil {
			if ferr := s.writer.flush(drainCtx); ferr != nil {
				err = ferr
			}
			if stopErr := s.writer.stop(); stopErr != nil && err == nil {
				err = stopErr
			}
			s.writer.wait()
		}
		if s.repo != nil {
			if cerr := s.repo.Close(); cerr != nil && err == nil {
				err = cerr
			}
		}
	})
	return err
}

// Flush forces a drain: after it returns, every record queued before the call is
// committed or counted as a failure. It exists for tests and for shutdown; the
// hot path never calls it.
func (s *Store) Flush(ctx context.Context) error {
	if !s.cfg.Enabled || s.writer == nil {
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	return s.writer.flush(ctx)
}

// RowsPruned reports how many rows retention has removed.
func (s *Store) RowsPruned() int64 { return s.prunedRows.Load() }

// --- Recorder implementation -------------------------------------------------

// RecordLatency queues one latency sample. The value is checked for the session
// relation at write time, not here: a producer must not do I/O or lookups.
func (s *Store) RecordLatency(v observability.LatencySample) { s.enqueue(record{latency: &v}) }

// RecordHealthReport queues one raw health report.
func (s *Store) RecordHealthReport(v observability.HealthReportRow) { s.enqueue(record{health: &v}) }

// RecordTierTransition queues one tier change.
func (s *Store) RecordTierTransition(v observability.TierTransitionRow) {
	s.enqueue(record{tier: &v})
}

// RecordDeliveryWindow queues one delivered-versus-target window.
func (s *Store) RecordDeliveryWindow(v observability.DeliveryWindow) {
	s.enqueue(record{delivery: &v})
}

// RecordBookEvent queues one order-book synchronization event.
func (s *Store) RecordBookEvent(v observability.BookSyncEvent) { s.enqueue(record{book: &v}) }

// RecordProtocolEvent queues one protocol anomaly.
func (s *Store) RecordProtocolEvent(v observability.ProtocolEvent) {
	s.enqueue(record{protocol: &v})
}

// RecordSessionStart queues a session lifecycle row. It is an upsert, so a
// reconnect that reuses an id refreshes the row instead of duplicating it.
func (s *Store) RecordSessionStart(v observability.SessionRow) {
	s.enqueue(record{session: &SessionWrite{Row: v}})
}

// RecordSessionEnd queues the closing half of a session row.
func (s *Store) RecordSessionEnd(v observability.SessionRow) {
	s.enqueue(record{session: &SessionWrite{Row: v, End: true}})
}

// RecordFaultInjection queues one injected fault.
func (s *Store) RecordFaultInjection(v observability.FaultInjectionRow) {
	s.enqueue(record{fault: &v})
}

// RecordEngineEvent queues one engine lifecycle event.
//
// EngineEvent carries no timestamp of its own in some call sites, so a zero time
// is replaced with now: an event with no time cannot be windowed or pruned.
func (s *Store) RecordEngineEvent(v observability.EngineEvent) {
	if v.At.IsZero() {
		v.At = time.Now().UTC()
	}
	s.enqueue(record{engine: &v})
}

// RecordCandleClose queues one closed candle. Prices are rendered as exact
// decimal strings here, in the producer's goroutine, because only the store knows
// the symbol registry, and formatting is pure arithmetic — no I/O.
func (s *Store) RecordCandleClose(c domain.Candle) {
	row := CandleCloseRow{
		Symbol:     c.Symbol,
		Interval:   string(c.Interval),
		StartTime:  c.StartTime,
		TradeCount: int64(c.TradeCount),
		ClosedAt:   time.Now().UTC(),
	}
	if sym, err := domain.Lookup(c.Symbol); err == nil {
		row.Open = sym.FormatPrice(c.Open)
		row.High = sym.FormatPrice(c.High)
		row.Low = sym.FormatPrice(c.Low)
		row.Close = sym.FormatPrice(c.Close)
		row.Volume = sym.FormatQty(c.Volume)
	} else {
		// An unknown symbol still gets a row: losing the audit trail because the
		// registry changed would be worse than an unformatted value.
		row.Open = fmt.Sprintf("%d", c.Open)
		row.High = fmt.Sprintf("%d", c.High)
		row.Low = fmt.Sprintf("%d", c.Low)
		row.Close = fmt.Sprintf("%d", c.Close)
		row.Volume = fmt.Sprintf("%d", c.Volume)
	}
	s.enqueue(record{candle: &row})
}

// enqueue is the single non-blocking hand-off into the store. It must stay cheap:
// it runs on the engine tick loop and on every session's delivery loop.
func (s *Store) enqueue(r record) {
	if !s.cfg.Enabled {
		return
	}
	if s.closed.Load() {
		// After shutdown the queue has no consumer, so accepting a record would
		// only grow memory. It is counted as dropped, which is the truthful
		// answer: it will not be persisted.
		s.noteDrop()
		return
	}
	if s.queue == nil {
		return
	}
	if s.queue.push(r) {
		return
	}
	s.noteDrop()
}

// noteDrop counts a discarded record and emits a rate-limited warning. The rate
// limit is the whole point: a saturated store drops one record per producer
// iteration, and an unrate-limited WARN would bury every other diagnostic.
func (s *Store) noteDrop() {
	dropped := s.dropped.Add(1)
	now := time.Now().Unix()
	last := s.lastWarnUnix.Load()
	if last != 0 && now-last < int64(warnInterval/time.Second) {
		return
	}
	if !s.lastWarnUnix.CompareAndSwap(last, now) {
		return
	}
	s.logger.Warn(observability.MsgMetricsDropped,
		observability.FieldDropped, dropped,
		observability.FieldQueueDepth, s.QueueDepth(),
		observability.FieldReason, "queue_full",
	)
}

func (s *Store) setWriteError(err error) {
	s.statusMu.Lock()
	s.writeErr = err
	s.statusMu.Unlock()
}

// driverNameOrDisabled reports the configured driver even when metrics are off, so
// /health can explain that the store exists but is not writing.
func driverNameOrDisabled(driver string) string {
	if strings.TrimSpace(driver) == "" {
		return DriverMemory
	}
	return driver
}
