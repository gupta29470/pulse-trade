package sqlite

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
)

// Retention describes how long each table's rows are kept. It is the store's type,
// re-exported so a caller of this package does not need both imports.
type Retention = metrics.Retention

// PruneResult reports what one pruning pass removed. Pruned rows are counted per
// table so the metrics summary can show which retention rule fired, and partial
// failures are reported without discarding the counts of the tables that worked.
type PruneResult struct {
	Rows   map[string]int64
	Total  int64
	Errors []error
}

// PrunedTotal reports how many rows the pass removed. It satisfies the store's
// PrunedCounter, which is how the driver's per-table detail reaches the store
// without the store knowing this type.
func (r PruneResult) PrunedTotal() int64 { return r.Total }

// PruneForStore is the adapter the store's writer calls, which needs the result
// as any so it can stay driver-agnostic. Prune itself keeps the concrete
// PruneResult for callers that want the per-table detail.
func (r *Repository) PruneForStore(ctx context.Context, now time.Time, ret metrics.Retention, batch int) (any, error) {
	result, err := r.Prune(ctx, now, ret, batch)
	if err != nil {
		return result, fmt.Errorf("metrics/sqlite: prune: %w", err)
	}
	return result, nil
}

// Prune deletes rows older than the retention windows, in bounded batches.
//
// It runs inside the writer goroutine's own transaction, so it can never race
// the batch writer, and it deletes in LIMIT-sized chunks because one unbounded
// DELETE would hold the write lock for as long as the table is large — which, for
// this store, means blocking every metric write behind it.
//
// now is injected so a test can prune rows with old timestamps without waiting
// for real time to pass.
func (r *Repository) Prune(ctx context.Context, now time.Time, ret Retention, batch int) (PruneResult, error) {
	result := PruneResult{Rows: map[string]int64{}}
	if !ret.Enabled {
		return result, nil
	}
	if r.isClosed() {
		return result, ErrDatabaseClosed
	}
	if batch <= 0 {
		batch = 5000
	}
	now = now.UTC()

	type rule struct {
		table  string
		column string
		window time.Duration
	}
	rules := []rule{
		{"latency_samples", "server_time", ret.Latency},
		{"health_reports", "received_at", ret.Latency},
		{"delivery_windows", "window_start", ret.Events},
		{"protocol_events", "at", ret.Events},
		{"book_sync_events", "at", ret.Events},
		{"tier_transitions", "at", ret.Events},
		{"engine_events", "at", ret.Sessions},
		{"fault_injections", "at", ret.Sessions},
		// sessions are pruned on disconnect time so an in-flight session is never
		// deleted out from under a running delivery loop.
		{"sessions", "disconnected_at", ret.Sessions},
	}

	for _, ru := range rules {
		if ru.window <= 0 {
			continue
		}
		cutoff := encodeTime(now.Add(-ru.window))
		deleted, err := r.pruneTable(ctx, ru.table, ru.column, cutoff, batch)
		if err != nil {
			result.Errors = append(result.Errors, err)
			continue
		}
		if deleted > 0 {
			result.Rows[ru.table] += deleted
			result.Total += deleted
		}
	}
	if len(result.Errors) > 0 {
		return result, fmt.Errorf("metrics/sqlite: prune: %w", errors.Join(result.Errors...))
	}
	return result, nil
}

// pruneTable deletes one table's expired rows in LIMIT-sized batches until a pass
// removes fewer rows than the batch size, which means the table is clean.
func (r *Repository) pruneTable(ctx context.Context, table, column, cutoff string, batch int) (int64, error) {
	// The identifiers are compile-time constants from Prune's rule table, never
	// caller input, so the interpolation cannot be influenced from outside.
	stmt := fmt.Sprintf(
		"DELETE FROM %s WHERE rowid IN (SELECT rowid FROM %s WHERE %s IS NOT NULL AND %s <> '' AND %s < ? LIMIT ?)",
		table, table, column, column, column)

	var total int64
	for {
		res, err := r.db.ExecContext(ctx, stmt, cutoff, batch)
		if err != nil {
			return total, fmt.Errorf("prune %s: %w", table, err)
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return total, fmt.Errorf("prune %s: rows affected: %w", table, err)
		}
		total += affected
		if affected < int64(batch) {
			return total, nil
		}
		select {
		case <-ctx.Done():
			return total, fmt.Errorf("prune %s: %w", table, ctx.Err())
		default:
		}
	}
}
