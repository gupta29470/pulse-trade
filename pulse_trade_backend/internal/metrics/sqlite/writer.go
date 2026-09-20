package sqlite

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// WriterOptions configures the batching writer.
type WriterOptions struct {
	// BatchSize is the record count that forces a commit without waiting for
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
	// OnFlushDone records how long a drain took: the store's own latency signal.
	OnFlushDone func(time.Duration)
	// Logger receives failure, prune and checkpoint records.
	Logger *observability.Logger
}

func (o WriterOptions) withDefaults() WriterOptions {
	if o.BatchSize <= 0 {
		o.BatchSize = 128
	}
	if o.FlushInterval <= 0 {
		o.FlushInterval = 250 * time.Millisecond
	}
	if o.RetryBackoff <= 0 {
		o.RetryBackoff = 50 * time.Millisecond
	}
	if o.PruneInterval <= 0 {
		o.PruneInterval = 10 * time.Minute
	}
	if o.PruneBatch <= 0 {
		o.PruneBatch = 5000
	}
	if o.CheckpointInterval <= 0 {
		o.CheckpointInterval = 5 * time.Minute
	}
	return o
}

// ConfigureWriter stores the store's writer configuration so the driver's own
// steps (retention pruning, WAL checkpointing) run on the same cadence.
func (r *Repository) ConfigureWriter(opts WriterOptions) {
	r.mu.Lock()
	r.writerOpts = opts.withDefaults()
	r.mu.Unlock()
}

// WriterOptions returns the configuration the store should run the writer with.
func (r *Repository) WriterOptions() WriterOptions {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.writerOpts
}

// Writer is the SQLite batching writer: drain up to BatchSize records or wait
// FlushInterval, then commit one transaction.
//
// It is the SQLite-native form of the store's writer, and it exists so the
// batching policy lives next to the SQL it commits with — a change to chunking,
// retry or pruning has one file to touch. The store currently drives its
// driver-agnostic writer (internal/metrics/writer.go) for both drivers, so this
// type is the documented alternative rather than the live path; it shares the
// same protocol (bulk INSERT via writeBatchInTx, one transaction per batch, one
// retry, drop-and-count after that) and the same pruning rules in prune.go.
//
// Timing is driven by a channel-based request rather than a shared lock, so a
// Flush call can never observe a half-drained queue.
type Writer struct {
	repo   *Repository
	opts   WriterOptions
	queue  RecordQueue
	reqs   chan flushRequest
	closed chan struct{}
	lastMu chan struct{}
	err    error
}

// RecordQueue is the store's bounded queue as the writer sees it. Records cross
// the boundary boxed in any because the record type is internal to the store; the
// writer only ever hands them to metrics.ToBatch, so a driver cannot forge one.
type RecordQueue interface {
	// Drain removes up to max queued records in FIFO order.
	Drain(max int) []any
	// Depth reports the current occupancy.
	Depth() int
	// Notify returns the channel that wakes the writer.
	Notify() <-chan struct{}
}

// recordBatch turns an ordered run of drained records into a per-table batch.
func recordBatch(records []any) metrics.Batch { return metrics.ToBatch(records) }

// flushRequest asks the writer to drain everything currently queued.
type flushRequest struct {
	ctx  context.Context
	done chan error
}

// NewWriter creates the writer for a repository.
func NewWriter(repo *Repository, queue RecordQueue, opts WriterOptions) *Writer {
	return &Writer{
		repo:   repo,
		opts:   opts.withDefaults(),
		queue:  queue,
		reqs:   make(chan flushRequest),
		closed: make(chan struct{}),
		lastMu: make(chan struct{}, 1),
	}
}

// Start runs the batching loop until ctx is cancelled, then performs a bounded
// final drain so shutdown does not silently discard queued metrics that still fit
// in the budget.
func (w *Writer) Start(ctx context.Context) {
	defer close(w.closed)
	defer w.finish(context.WithoutCancel(ctx))

	flush := time.NewTimer(w.opts.FlushInterval)
	defer flush.Stop()
	prune := time.NewTimer(w.opts.PruneInterval)
	defer prune.Stop()
	checkpoint := time.NewTimer(w.opts.CheckpointInterval)
	defer checkpoint.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case req := <-w.reqs:
			err := w.drain(req.ctx, true)
			req.done <- err
			resetTimer(flush, w.opts.FlushInterval)
		case <-flush.C:
			_ = w.drain(ctx, false)
			resetTimer(flush, w.opts.FlushInterval)
		case <-prune.C:
			w.prune(ctx)
			resetTimer(prune, w.opts.PruneInterval)
		case <-checkpoint.C:
			if err := w.repo.Checkpoint(ctx); err != nil && w.opts.Logger != nil {
				w.opts.Logger.Warn(observability.MsgMetricsFlushSlow,
					observability.FieldError, err.Error(),
					observability.FieldOperation, "wal_checkpoint")
			}
			resetTimer(checkpoint, w.opts.CheckpointInterval)
		}
	}
}

// Done is closed when the writer has stopped, including its final drain.
func (w *Writer) Done() <-chan struct{} { return w.closed }

// drain writes queued records. When all is true it keeps taking batches until the
// queue is empty, which is the Flush contract: after Flush returns, everything
// queued before the call is durable or counted as a failure.
func (w *Writer) drain(ctx context.Context, all bool) error {
	started := time.Now()
	var failure error
	written := 0

	for written < maxDrainPerBatch {
		batch := recordBatch(w.queue.Drain(w.opts.BatchSize))
		if batch.Len() == 0 {
			break
		}
		written += batch.Len()
		if err := w.commit(ctx, batch); err != nil {
			// The failure is recorded but not returned as fatal: Flush must not
			// turn "the database is gone" into "the queue is stuck forever".
			failure = err
		}
		if !all && batch.Len() < w.opts.BatchSize {
			break
		}
		select {
		case <-ctx.Done():
			written = maxDrainPerBatch
		default:
		}
	}

	if w.opts.OnFlushDone != nil {
		w.opts.OnFlushDone(time.Since(started))
	}
	return failure
}

// maxDrainPerBatch bounds one drain call so a large backlog cannot make a flush
// request run unboundedly long.
const maxDrainPerBatch = 10000

// commit writes one batch, retrying once with a short backoff. A second failure
// drops the batch: metrics are best-effort, and a store that blocked or spun on a
// broken database would take the market loop down with it.
func (w *Writer) commit(ctx context.Context, batch metrics.Batch) error {
	err := w.repo.WriteBatch(ctx, batch)
	if err == nil {
		w.succeeded(batch)
		return nil
	}

	select {
	case <-ctx.Done():
	case <-time.After(w.opts.RetryBackoff):
	}
	retryErr := w.repo.WriteBatch(ctx, batch)
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
			observability.FieldError, err.Error(), observability.FieldRows, batch.Len())
	}
	return fmt.Errorf("metrics/sqlite: batch write failed after retry: %w", err)
}

func (w *Writer) succeeded(batch metrics.Batch) {
	if w.opts.OnWriteSuccess != nil {
		w.opts.OnWriteSuccess(int64(batch.Len()))
	}
}

// prune runs one bounded pruning pass. A failure is logged and swallowed: pruning
// is housekeeping, and a transient error must not degrade the store's health.
func (w *Writer) prune(ctx context.Context) {
	result, err := w.repo.Prune(ctx, time.Now().UTC(), w.opts.Retention, w.opts.PruneBatch)
	if err != nil {
		if w.opts.Logger != nil {
			w.opts.Logger.Warn(observability.MsgMetricsPruned,
				observability.FieldError, err.Error(), observability.FieldRows, result.Total)
		}
		return
	}
	if result.Total == 0 {
		return
	}
	if w.opts.OnPruned != nil {
		w.opts.OnPruned(result.Total)
	}
	if w.opts.Logger != nil {
		w.opts.Logger.Info(observability.MsgMetricsPruned, observability.FieldRows, result.Total)
	}
}

// finish drains what is left at shutdown with its own deadline. It deliberately
// uses a fresh context: the loop exits precisely because ctx was cancelled, so
// reusing it would make the final drain a no-op.
func (w *Writer) finish(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	written := 0
	for written < maxDrainPerBatch {
		batch := recordBatch(w.queue.Drain(w.opts.BatchSize))
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

// Flush asks the writer to drain. It returns when the drain completes, when the
// caller's context ends, or when the writer has stopped.
func (w *Writer) Flush(ctx context.Context) error {
	req := flushRequest{ctx: ctx, done: make(chan error, 1)}
	select {
	case w.reqs <- req:
	case <-w.closed:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("metrics/sqlite: flush: %w", ctx.Err())
	}
	select {
	case err := <-req.done:
		return err
	case <-w.closed:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("metrics/sqlite: flush: %w", ctx.Err())
	}
}

// Err returns the last batch error, if any. It is the writer's own record of why
// the store is degraded.
func (w *Writer) Err() error {
	select {
	case w.lastMu <- struct{}{}:
		defer func() { <-w.lastMu }()
		return w.err
	default:
		return nil
	}
}

func (w *Writer) setErr(err error) {
	select {
	case w.lastMu <- struct{}{}:
		w.err = err
		<-w.lastMu
	default:
	}
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
