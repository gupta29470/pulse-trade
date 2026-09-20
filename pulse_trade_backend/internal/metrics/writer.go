package metrics

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// Writer defaults. They mirror the store's write path: drain up to 128
// records or wait 250 ms, then commit one transaction.
const (
	defaultBatchSize          = 128
	defaultFlushInterval      = 250 * time.Millisecond
	defaultRetryBackoff       = 50 * time.Millisecond
	defaultPruneInterval      = 10 * time.Minute
	defaultPruneBatch         = 5000
	defaultCheckpointInterval = 5 * time.Minute
	// maxDrainPerBatch bounds one drain call so a large backlog cannot make a
	// flush request run unboundedly long.
	maxDrainPerBatch = 10000
)

// Retention describes how long each table's rows are kept.
type Retention struct {
	// Enabled is the master switch. A disabled retention keeps everything.
	Enabled bool
	// Latency bounds the high-volume sample tables.
	Latency time.Duration
	// Events bounds the medium-volume operational tables.
	Events time.Duration
	// Sessions bounds the low-volume lifecycle tables.
	Sessions time.Duration
}

// WriterOptions configures the batching writer.
type WriterOptions struct {
	// Repository is the driver the writer commits batches to.
	Repository Repository
	// BatchSize is the row count that forces a commit without waiting for
	// FlushInterval. Smaller batches mean lower latency and more fsyncs.
	BatchSize int
	// FlushInterval bounds how long a record can sit uncommitted.
	FlushInterval time.Duration
	// RetryBackoff is the pause before a failed batch is retried once.
	RetryBackoff time.Duration
	// Retention is applied by the pruning pass.
	Retention Retention
	// PruneInterval is how often the pruning pass runs.
	PruneInterval time.Duration
	// PruneBatch bounds one prune statement.
	PruneBatch int
	// CheckpointInterval bounds the write-ahead log's growth.
	CheckpointInterval time.Duration

	// OnWriteFailure is called once per batch that failed twice, so the store can
	// flip its health status without polling.
	OnWriteFailure func(error)
	// OnWriteSuccess is called after a batch commits, with the row count.
	OnWriteSuccess func(rows int64)
	// OnPruned is called after a pruning pass removed rows.
	OnPruned func(rows int64)
	// OnFlushDone records how long a drain took. It is the store's own latency
	// signal, and a slow flush is the first evidence of a struggling disk.
	OnFlushDone func(time.Duration)
	// Logger receives the rate-limited failure and prune records.
	Logger *observability.Logger
}

func (o WriterOptions) withDefaults() WriterOptions {
	if o.BatchSize <= 0 {
		o.BatchSize = defaultBatchSize
	}
	if o.FlushInterval <= 0 {
		o.FlushInterval = defaultFlushInterval
	}
	if o.RetryBackoff <= 0 {
		o.RetryBackoff = defaultRetryBackoff
	}
	if o.PruneInterval <= 0 {
		o.PruneInterval = defaultPruneInterval
	}
	if o.PruneBatch <= 0 {
		o.PruneBatch = defaultPruneBatch
	}
	if o.CheckpointInterval <= 0 {
		o.CheckpointInterval = defaultCheckpointInterval
	}
	return o
}

// WriterProvider lets a driver customise the batching writer and supply
// driver-specific steps (SQLite's pruning and WAL checkpointing). A driver that
// does not implement it gets the plain batching writer.
type WriterProvider interface {
	// ConfigureWriter is called once with the store's configuration so the driver
	// can fill in the steps it owns.
	ConfigureWriter(opts WriterOptions)
	// WriterOptions returns the options the writer should actually run with.
	WriterOptions() WriterOptions
}

// Pruner is implemented by drivers with retention support.
//
// The method is named PruneForStore, not Prune, because Go method sets are exact:
// a driver wants its own Prune to return the driver's concrete result type (so
// callers keep their per-table detail), and a method returning a concrete type
// cannot satisfy an interface whose result is any. The driver therefore exposes
// one name for direct callers and one for the store.
type Pruner interface {
	// PruneForStore deletes rows older than the retention windows in bounded
	// batches and returns a driver-specific result.
	PruneForStore(ctx context.Context, now time.Time, ret Retention, batch int) (result any, err error)
}

// PrunedCounter is what a Pruner's result must expose: how many rows the pass
// removed. Any driver-specific result type satisfies it with one method.
type PrunedCounter interface {
	// PrunedTotal is the number of rows removed by the pass.
	PrunedTotal() int64
}

// Checkpointer is implemented by drivers whose log needs periodic truncation.
type Checkpointer interface {
	// Checkpoint bounds the write-ahead log's size.
	Checkpoint(ctx context.Context) error
}

// batchWriter is the single writer goroutine. It owns the batching policy: commit
// once BatchSize records are pending, or once FlushInterval passes with something
// pending, whichever comes first.
//
// Records that were pulled but did not fill a batch stay in pending. Re-queueing
// them would reorder the stream, and committing them immediately would defeat
// batching — so the writer holds them and waits for the timer, which is what makes
// "one transaction per configured batch" observable rather than approximate.
type batchWriter struct {
	queue *recordQueue
	opts  WriterOptions

	reqs chan flushRequest
	done chan struct{}

	// pending is owned by the writer goroutine. It is read by Flush only while
	// the writer is inside that flush request, so it is never touched
	// concurrently.
	pending []record
	pulls   uint64

	mu      sync.Mutex
	lastErr error
}

// flushRequest asks the writer to drain everything queued at the time of the call.
type flushRequest struct {
	ctx  context.Context
	done chan error
}

func newBatchWriter(queue *recordQueue, opts WriterOptions) *batchWriter {
	opts = opts.withDefaults()
	return &batchWriter{
		queue: queue,
		opts:  opts,
		reqs:  make(chan flushRequest),
		done:  make(chan struct{}),
	}
}

// start runs the batching loop until ctx is cancelled, then performs a bounded
// final drain so shutdown does not silently discard records that still fit in the
// shutdown budget.
func (w *batchWriter) start(ctx context.Context) {
	defer close(w.done)
	defer w.finish()

	flush := time.NewTimer(w.opts.FlushInterval)
	defer flush.Stop()
	prune := time.NewTicker(w.opts.PruneInterval)
	defer prune.Stop()
	checkpoint := time.NewTicker(w.opts.CheckpointInterval)
	defer checkpoint.Stop()

	for {
		// Always pull before waiting: a wake-up may have arrived while this
		// goroutine was committing the previous batch.
		w.pull()
		// A flush request outranks batch filling: a caller waiting in Flush must
		// not wait for a full batch that may never arrive.
		select {
		case req := <-w.reqs:
			req.done <- w.drain(req.ctx, true)
			resetTimer(flush, w.opts.FlushInterval)
			continue
		default:
		}
		if len(w.pending) >= w.opts.BatchSize {
			w.drain(ctx, false)
			resetTimer(flush, w.opts.FlushInterval)
			continue
		}

		select {
		case <-ctx.Done():
			return
		case req := <-w.reqs:
			req.done <- w.drain(req.ctx, true)
			resetTimer(flush, w.opts.FlushInterval)
		case <-flush.C:
			w.drain(ctx, false)
			resetTimer(flush, w.opts.FlushInterval)
		case <-prune.C:
			w.prune(ctx)
		case <-checkpoint.C:
			w.checkpoint(ctx)
		}
	}
}

// pull takes the whole queue in one call. Taking everything the ring holds keeps
// the producers' dropped-oldest policy honest and lets the writer choose batch
// boundaries instead of inheriting whatever slice the queue happened to hold.
func (w *batchWriter) pull() int {
	w.pulls++
	if w.pulls%(1<<20) == 0 {
		// A safety valve: a pull counter that large means the loop has been
		// spinning, so yield once rather than monopolising the scheduler.
		time.Sleep(0)
	}
	records := w.queue.Drain(maxDrainPerBatch)
	if len(records) == 0 {
		return 0
	}
	for _, r := range records {
		if rec, ok := r.(record); ok {
			w.pending = append(w.pending, rec)
		}
	}
	return len(records)
}

// takePending removes and returns the first n pending records as a batch. Commit
// boundaries are cut here, in arrival order, so a session row is always written in
// the same transaction as (or before) the samples that reference it.
func (w *batchWriter) takePending(n int) Batch {
	if n <= 0 || len(w.pending) == 0 {
		return Batch{}
	}
	if n > len(w.pending) {
		n = len(w.pending)
	}
	out := toBatch(w.pending[:n])
	// Clear the consumed slots so the backing array does not pin record pointers.
	for i := 0; i < n; i++ {
		w.pending[i] = record{}
	}
	w.pending = w.pending[n:]
	return out
}

// drain writes queued records. When all is true — the Flush contract — it keeps
// going until the queue is empty and less than a full batch is left, then commits
// that remainder so nothing queued before the call is still waiting.
func (w *batchWriter) drain(ctx context.Context, all bool) error {
	started := time.Now()
	var failure error
	written := 0

	for written < maxDrainPerBatch {
		for len(w.pending) >= w.opts.BatchSize {
			batch := w.takePending(w.opts.BatchSize)
			if err := w.commit(ctx, batch); err != nil {
				// The failure is recorded but not returned as fatal on its own:
				// Flush must not turn "the database is gone" into "the queue is
				// stuck forever".
				failure = err
			}
			written += batch.Len()
		}
		if !all {
			break
		}
		// Stop when the queue is empty and what is left cannot form another full
		// batch; the remainder is committed below. Without the second condition
		// this loop would spin forever on a partial batch.
		if pulled := w.pull(); pulled == 0 && len(w.pending) < w.opts.BatchSize {
			break
		}
		select {
		case <-ctx.Done():
			written = maxDrainPerBatch
		default:
		}
	}

	if len(w.pending) > 0 {
		// Whatever is left is committed, whether this was an explicit Flush or the
		// periodic timer. Committing only a full batch would make the timer path a
		// no-op whenever fewer than BatchSize records are pending, which is the
		// normal case for a quiet server: rows would sit in the WAL of an open
		// transaction where no reader could see them. The timer exists to bound how
		// long a record waits, so it commits the remainder.
		batch := w.takePending(len(w.pending))
		if err := w.commit(ctx, batch); err != nil {
			failure = err
		}
	}

	if w.opts.OnFlushDone != nil {
		w.opts.OnFlushDone(time.Since(started))
	}
	return failure
}

// commit writes one batch, retrying once with a short backoff. A second failure
// drops the batch: metrics are best-effort, and a store that blocked or spun on a
// broken database would take the market loop down with it.
func (w *batchWriter) commit(ctx context.Context, batch Batch) error {
	if w.opts.Repository == nil {
		return errors.New("metrics: writer has no repository")
	}
	err := w.opts.Repository.WriteBatch(ctx, batch)
	if err == nil {
		w.succeeded(batch)
		return nil
	}

	select {
	case <-ctx.Done():
	case <-time.After(w.opts.RetryBackoff):
	}
	retryErr := w.opts.Repository.WriteBatch(ctx, batch)
	if retryErr == nil {
		w.succeeded(batch)
		return nil
	}
	err = errors.Join(err, retryErr)

	w.setErr(err)
	if w.opts.OnWriteFailure != nil {
		w.opts.OnWriteFailure(err)
	}
	if w.opts.Logger != nil {
		w.opts.Logger.Warn(observability.MsgMetricsDegraded,
			observability.FieldError, err.Error(),
			observability.FieldRows, batch.Len(),
		)
	}
	return fmt.Errorf("metrics: batch write failed after retry: %w", err)
}

func (w *batchWriter) succeeded(batch Batch) {
	if w.opts.OnWriteSuccess != nil {
		w.opts.OnWriteSuccess(int64(batch.Len()))
	}
}

// prune runs one bounded retention pass. A failure is logged and swallowed:
// pruning is housekeeping, and a transient error must not degrade the store's
// health or interrupt the write path.
func (w *batchWriter) prune(ctx context.Context) {
	pruner, ok := w.opts.Repository.(Pruner)
	if !ok {
		return
	}
	result, err := pruner.PruneForStore(ctx, time.Now().UTC(), w.opts.Retention, w.opts.PruneBatch)
	total := int64(0)
	if counter, ok := result.(PrunedCounter); ok {
		total = counter.PrunedTotal()
	}
	if err != nil {
		if w.opts.Logger != nil {
			w.opts.Logger.Warn(observability.MsgMetricsPruned,
				observability.FieldError, err.Error(), observability.FieldRows, total)
		}
		return
	}
	if total == 0 {
		return
	}
	if w.opts.OnPruned != nil {
		w.opts.OnPruned(total)
	}
	if w.opts.Logger != nil {
		w.opts.Logger.Info(observability.MsgMetricsPruned, observability.FieldRows, total)
	}
}

func (w *batchWriter) checkpoint(ctx context.Context) {
	checkpointer, ok := w.opts.Repository.(Checkpointer)
	if !ok {
		return
	}
	if err := checkpointer.Checkpoint(ctx); err != nil && w.opts.Logger != nil {
		w.opts.Logger.Warn(observability.MsgMetricsFlushSlow,
			observability.FieldError, err.Error(),
			observability.FieldOperation, "wal_checkpoint",
		)
	}
}

// finish drains what is left at shutdown with its own deadline. It uses a fresh
// context: the loop exits precisely because ctx was cancelled, so reusing that
// context would make the final drain a no-op.
func (w *batchWriter) finish() {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	written := 0
	for written < maxDrainPerBatch {
		w.pull()
		if len(w.pending) == 0 && w.queue.Depth() == 0 {
			return
		}
		batch := w.takePending(len(w.pending))
		if batch.Len() == 0 {
			return
		}
		written += batch.Len()
		if err := w.commit(ctx, batch); err != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}

func (w *batchWriter) flush(ctx context.Context) error {
	req := flushRequest{ctx: ctx, done: make(chan error, 1)}
	select {
	case w.reqs <- req:
	case <-w.done:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("metrics: flush: %w", ctx.Err())
	}
	select {
	case err := <-req.done:
		return err
	case <-w.done:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("metrics: flush: %w", ctx.Err())
	}
}

func (w *batchWriter) err() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.lastErr
}

func (w *batchWriter) setErr(err error) {
	w.mu.Lock()
	w.lastErr = err
	w.mu.Unlock()
}

// resetTimer restarts a timer, draining a possibly-pending tick first so the next
// select cannot immediately fire on a stale value.
func resetTimer(t *time.Timer, d time.Duration) {
	if !t.Stop() {
		select {
		case <-t.C:
		default:
		}
	}
	t.Reset(d)
}
