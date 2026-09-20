// Package sqlite is the durable metrics driver. It owns one SQLite file, a
// single write connection, and the numbered migrations that create its schema.
//
// Hand-written SQL only: the schema in migrations/0001_init.sql is the contract;
// an ORM would hide the exact column list that the audit trail depends on.
package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite" // pure-Go driver, registered as "sqlite"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// DriverName is the value Config.Driver must carry for this driver.
const DriverName = "sqlite"

// maxRowsPerStatement bounds how many rows one bulk INSERT carries. Every
// statement therefore stays well under SQLite's parameter limit while a batch
// still commits as a single transaction.
const maxRowsPerStatement = 500

// timeLayout is how every timestamp column is written: UTC, RFC3339 with
// milliseconds, matching the wire format used everywhere else in the system.
// Because it is fixed-width and the zone is always the literal "Z", lexicographic
// TEXT comparison is also chronological comparison — the property every windowed
// query and the prune cutoff rely on.
const timeLayout = "2006-01-02T15:04:05.000Z"

// ErrDatabaseClosed is returned by operations issued after Close.
var ErrDatabaseClosed = errors.New("metrics/sqlite: database is closed")

// Repository is the SQLite-backed metrics store. All access goes through one
// *sql.DB whose pool is pinned to a single connection: SQLite has one writer, and
// letting database/sql open a second connection would turn concurrent access into
// SQLITE_BUSY instead of serialisation.
type Repository struct {
	db   *sql.DB
	path string

	mu         sync.Mutex
	version    int
	closed     bool
	writerOpts WriterOptions
}

// Open opens (creating if needed) the database at path, applies every embedded
// migration, and returns a ready repository. An empty path is an error: an
// in-memory SQLite database would silently lose every metric on restart, which is
// exactly the failure mode the persisted store exists to prevent.
func Open(ctx context.Context, path string) (*Repository, error) {
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("metrics/sqlite: database path is required")
	}
	db, err := sql.Open(DriverName, buildDSN(path))
	if err != nil {
		return nil, fmt.Errorf("metrics/sqlite: open %s: %w", path, err)
	}
	// Single writer: the store's writer goroutine is the only producer, and one
	// connection removes lock contention between writes and reads.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)

	if err := applyPragmas(ctx, db); err != nil {
		_ = db.Close()
		return nil, err
	}

	repo := &Repository{db: db, path: path}
	version, err := migrate(ctx, db)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	repo.version = version
	return repo, nil
}

// buildDSN turns a file path into a modernc.org/sqlite URI carrying the pragmas
// the store requires. Setting them in the DSN means the driver applies them while
// it holds the connection, so no query can interleave before journal_mode is active.
func buildDSN(path string) string {
	q := url.Values{}
	// Every transaction begins as a writer, which avoids the upgrade deadlock
	// where two deferred transactions both hold read locks and both want to write.
	q.Set("_txlock", "immediate")
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(NORMAL)")
	q.Add("_pragma", "foreign_keys(ON)")
	q.Add("_pragma", "temp_store(MEMORY)")
	q.Add("_pragma", "mmap_size(67108864)")
	return "file:" + path + "?" + q.Encode()
}

// applyPragmas verifies the settings that are not expressible in the DSN and that
// the store's correctness assumptions depend on.
func applyPragmas(ctx context.Context, db *sql.DB) error {
	var journal string
	if err := db.QueryRowContext(ctx, "PRAGMA journal_mode=WAL").Scan(&journal); err != nil {
		return fmt.Errorf("metrics/sqlite: set journal_mode: %w", err)
	}
	if !strings.EqualFold(journal, "wal") {
		// WAL is what lets the query path read while the writer holds a
		// transaction; without it every read would block behind the write lock.
		return fmt.Errorf("metrics/sqlite: journal_mode is %q, want wal", journal)
	}
	for _, stmt := range []string{
		"PRAGMA synchronous=NORMAL",
		"PRAGMA busy_timeout=5000",
		"PRAGMA foreign_keys=ON",
		"PRAGMA temp_store=MEMORY",
	} {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("metrics/sqlite: %s: %w", stmt, err)
		}
	}
	return nil
}

// Checkpoint truncates the write-ahead log. It runs on a slow timer in the writer
// goroutine so a long-running demo cannot grow the -wal file without bound.
func (r *Repository) Checkpoint(ctx context.Context) error {
	if _, err := r.db.ExecContext(ctx, "PRAGMA wal_checkpoint(TRUNCATE)"); err != nil {
		return fmt.Errorf("metrics/sqlite: wal checkpoint: %w", err)
	}
	return nil
}

// UpsertSession writes one session row outside a batch. It is the path used for
// session starts that must not wait for the batch boundary.
func (r *Repository) UpsertSession(ctx context.Context, row observability.SessionRow) error {
	return r.WriteBatch(ctx, metrics.Batch{Sessions: []metrics.SessionWrite{{Row: row}}})
}

// EndSession closes a session row.
func (r *Repository) EndSession(ctx context.Context, row observability.SessionRow) error {
	return r.WriteBatch(ctx, metrics.Batch{Sessions: []metrics.SessionWrite{{Row: row, End: true}}})
}

// Ping reports whether the database is still reachable.
func (r *Repository) Ping(ctx context.Context) error {
	if r.isClosed() {
		return ErrDatabaseClosed
	}
	if err := r.db.PingContext(ctx); err != nil {
		return fmt.Errorf("metrics/sqlite: ping: %w", err)
	}
	return nil
}

// SchemaVersion returns the highest applied migration version.
func (r *Repository) SchemaVersion() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.version
}

// Path returns the database file this repository owns.
func (r *Repository) Path() string { return r.path }

func (r *Repository) isClosed() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.closed
}

// Close releases the prepared statements and the connection. Closing twice is
// safe so a caller can defer it after an explicit shutdown path.
func (r *Repository) Close() error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	r.mu.Unlock()
	if err := r.db.Close(); err != nil {
		return fmt.Errorf("metrics/sqlite: close %s: %w", r.path, err)
	}
	return nil
}

// QueryRowForTest runs a single-row read against the raw database. It exists so
// the metrics package's tests can prove the exact text stored in a column (for
// example that a price is an exact decimal string, not a rounded REAL) without
// adding a public query surface for it.
func (r *Repository) QueryRowForTest(ctx context.Context, query string, dest ...any) error {
	if err := r.db.QueryRowContext(ctx, query).Scan(dest...); err != nil {
		return fmt.Errorf("metrics/sqlite: test query %q: %w", summariseSQL(query), err)
	}
	return nil
}

// ForceWriteFailureForTest removes a table from this database so every
// subsequent write to it fails with "no such table".
//
// It is a deliberately blunt test seam: the metrics store's failure-containment
// path (degrade, count, keep accepting) cannot be exercised by a read-only file
// or a full disk reliably across platforms, and a store that is tested only on its
// happy path is not tested at all. The table name is validated against the
// schema's table list, so the seam cannot be used to run arbitrary SQL.
func (r *Repository) ForceWriteFailureForTest(ctx context.Context, table string) error {
	if !knownTables[table] {
		return fmt.Errorf("metrics/sqlite: unknown table %q", table)
	}
	if _, err := r.db.ExecContext(ctx, "PRAGMA writable_schema=ON"); err != nil {
		return fmt.Errorf("metrics/sqlite: enable writable_schema: %w", err)
	}
	if _, err := r.db.ExecContext(ctx, "DELETE FROM sqlite_master WHERE type='table' AND name=?", table); err != nil {
		return fmt.Errorf("metrics/sqlite: drop %s from schema: %w", table, err)
	}
	if _, err := r.db.ExecContext(ctx, "PRAGMA writable_schema=OFF"); err != nil {
		return fmt.Errorf("metrics/sqlite: disable writable_schema: %w", err)
	}
	// Bumping the schema version makes the already-open store connection drop its
	// cached schema, so the next statement fails instead of silently succeeding.
	if _, err := r.db.ExecContext(ctx, "PRAGMA schema_version = 2"); err != nil {
		return fmt.Errorf("metrics/sqlite: bump schema_version: %w", err)
	}
	return nil
}

// TamperChecksumForTest corrupts the recorded checksum of the first migration so a
// test can prove that Open refuses to continue after a modified migration.
func (r *Repository) TamperChecksumForTest(ctx context.Context) error {
	if _, err := r.db.ExecContext(ctx, `UPDATE schema_migrations SET checksum = 'tampered'`); err != nil {
		return fmt.Errorf("metrics/sqlite: tamper checksum: %w", err)
	}
	return nil
}

// CountRowsForTest returns the row count of one table. The table name is
// validated against the schema's table list so an interpolated identifier can
// never become an injection point.
func (r *Repository) CountRowsForTest(ctx context.Context, table string) (int64, error) {
	if !knownTables[table] {
		return 0, fmt.Errorf("metrics/sqlite: unknown table %q", table)
	}
	var n int64
	if err := r.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+table).Scan(&n); err != nil {
		return 0, fmt.Errorf("metrics/sqlite: count %s: %w", table, err)
	}
	return n, nil
}

// knownTables is the schema's table list. It validates identifier interpolation
// in the prune rule table and in the test helpers.
var knownTables = map[string]bool{
	"sessions":          true,
	"latency_samples":   true,
	"health_reports":    true,
	"tier_transitions":  true,
	"delivery_windows":  true,
	"book_sync_events":  true,
	"protocol_events":   true,
	"engine_events":     true,
	"candle_closes":     true,
	"fault_injections":  true,
	"schema_migrations": true,
}

// writeBatchInTx executes one multi-row INSERT inside tx.
//
// Statements are prepared on the transaction, never on *sql.DB. The pool is
// pinned to a single connection so the writer goroutine owns it exclusively, and
// a database-level Prepare would need a second connection for the duration of the
// transaction — which it could never get, deadlocking the writer. Preparing
// inside the transaction also guarantees the statement is discarded even if the
// transaction rolls back.
func writeBatchInTx(ctx context.Context, tx *sql.Tx, ins bulkInsert) error {
	if ins.rows == 0 {
		return nil
	}
	perChunk := maxRowsPerStatement
	if ins.columns > 0 {
		if limit := 30000 / ins.columns; limit < perChunk {
			perChunk = limit
		}
	}
	if perChunk < 1 {
		perChunk = 1
	}
	for start := 0; start < ins.rows; start += perChunk {
		count := perChunk
		if start+count > ins.rows {
			count = ins.rows - start
		}
		sqlText := expandInsert(ins.prefix, ins.columns, count)
		args := make([]any, 0, count*ins.columns)
		for i := start; i < start+count; i++ {
			args = append(args, ins.bind(i)...)
		}
		if _, err := tx.ExecContext(ctx, sqlText, args...); err != nil {
			return fmt.Errorf("metrics/sqlite: insert into %s: %w", insertTable(ins.prefix), err)
		}
	}
	return nil
}

// WriteBatch persists every record of the batch in one immediate transaction.
// One transaction per batch is the whole point of the write path: it turns N
// fsync-bound commits into one and keeps the WAL short.
func (r *Repository) WriteBatch(ctx context.Context, b metrics.Batch) error {
	if b.Len() == 0 {
		return nil
	}
	if r.isClosed() {
		return ErrDatabaseClosed
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("metrics/sqlite: begin transaction: %w", err)
	}
	if err := r.writeAll(ctx, tx, b); err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("metrics/sqlite: commit batch: %w", err)
	}
	return nil
}

func (r *Repository) writeAll(ctx context.Context, tx *sql.Tx, b metrics.Batch) error {
	if err := r.writeSessions(ctx, tx, b.Sessions); err != nil {
		return err
	}
	if err := r.writeLatency(ctx, tx, b.Latency); err != nil {
		return err
	}
	if err := r.writeHealth(ctx, tx, b.Health); err != nil {
		return err
	}
	if err := r.writeTiers(ctx, tx, b.Tiers); err != nil {
		return err
	}
	if err := r.writeDelivery(ctx, tx, b.Delivery); err != nil {
		return err
	}
	if err := r.writeBookEvents(ctx, tx, b.BookEvents); err != nil {
		return err
	}
	if err := r.writeProtocol(ctx, tx, b.Protocol); err != nil {
		return err
	}
	if err := r.writeEngineEvents(ctx, tx, b.EngineEvts); err != nil {
		return err
	}
	if err := r.writeCandleCloses(ctx, tx, b.CandleClose); err != nil {
		return err
	}
	return r.writeFaults(ctx, tx, b.Faults)
}

// bulkInsert describes one multi-row statement: the fixed SQL prefix, how many
// rows it will carry, and a binder that pulls the values for row i.
type bulkInsert struct {
	prefix  string
	columns int
	rows    int
	bind    func(idx int) []any
}

// expandInsert turns "INSERT INTO t (a,b) VALUES (?,?)" into the same statement
// with count repeated value tuples.
func expandInsert(prefix string, columns, count int) string {
	tuple := "(?" + strings.Repeat(",?", columns-1) + ")"
	var sb strings.Builder
	sb.Grow(len(prefix) + count*len(tuple) + count)
	sb.WriteString(prefix)
	sb.WriteString(" VALUES ")
	for i := 0; i < count; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(tuple)
	}
	return sb.String()
}

// insertTable extracts the table name for error messages without another parser.
func insertTable(prefix string) string {
	const marker = "INSERT INTO "
	rest, ok := strings.CutPrefix(prefix, marker)
	if !ok {
		return "unknown"
	}
	if i := strings.IndexAny(rest, " ("); i >= 0 {
		return rest[:i]
	}
	return rest
}

func summariseSQL(query string) string {
	query = strings.Join(strings.Fields(query), " ")
	if len(query) > 90 {
		return query[:90] + "..."
	}
	return query
}

func (r *Repository) writeSessions(ctx context.Context, tx *sql.Tx, batch []metrics.SessionWrite) error {
	if len(batch) == 0 {
		return nil
	}
	// Ordering is load-bearing: a "start" row is an INSERT and an "end" row is an
	// UPDATE, so every insert must happen before any update. A batch can legitimately
	// contain both when a connection opens and closes inside one flush window.
	startRows := make([]observability.SessionRow, 0, len(batch))
	endRows := make([]observability.SessionRow, 0, len(batch))
	for _, s := range batch {
		if s.End {
			endRows = append(endRows, s.Row)
			continue
		}
		startRows = append(startRows, s.Row)
	}

	if len(startRows) > 0 {
		const prefix = `INSERT INTO sessions (
			session_id, device_id, client_version, platform, remote_addr, symbol, interval,
			connected_at, disconnected_at, disconnect_reason, initial_tier, final_tier,
			override_tier, uptime_ms, messages_sent, messages_received, bytes_sent, protocol_errors
		)`
		if err := writeBatchInTx(ctx, tx, bulkInsert{
			prefix: prefix, columns: 18, rows: len(startRows),
			bind: func(i int) []any { return sessionArgs(startRows[i]) },
		}); err != nil {
			return err
		}
	}
	for _, row := range endRows {
		if _, err := tx.ExecContext(ctx, `
			UPDATE sessions SET
				disconnected_at = ?, disconnect_reason = ?, final_tier = ?, override_tier = ?,
				uptime_ms = ?, messages_sent = ?, messages_received = ?, bytes_sent = ?, protocol_errors = ?
			WHERE session_id = ?`,
			encodeTimePtr(row.DisconnectedAt), row.DisconnectReason, row.FinalTier, row.OverrideTier,
			row.UptimeMs, row.MessagesSent, row.MessagesReceived, row.BytesSent, row.ProtocolErrors,
			row.SessionID,
		); err != nil {
			return fmt.Errorf("metrics/sqlite: end session %s: %w", row.SessionID, err)
		}
	}
	return nil
}

func sessionArgs(row observability.SessionRow) []any {
	return []any{
		row.SessionID, row.DeviceID, row.ClientVersion, row.Platform, row.RemoteAddr,
		row.Symbol, row.Interval, encodeTime(row.ConnectedAt), encodeTimePtr(row.DisconnectedAt),
		row.DisconnectReason, row.InitialTier, row.FinalTier, row.OverrideTier, row.UptimeMs,
		row.MessagesSent, row.MessagesReceived, row.BytesSent, row.ProtocolErrors,
	}
}

func (r *Repository) writeLatency(ctx context.Context, tx *sql.Tx, rows []observability.LatencySample) error {
	const prefix = `INSERT INTO latency_samples (
		session_id, seq, rtt_ms, jitter_ms, samples, client_time, server_time, capped, missed_pong
	)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 9, rows: len(rows),
		bind: func(i int) []any {
			s := rows[i]
			var clientTime any
			if s.ClientTimeMs != 0 {
				clientTime = encodeTime(time.UnixMilli(s.ClientTimeMs))
			}
			return []any{
				s.SessionID, s.Seq, s.RTTMs, s.JitterMs, s.Samples,
				clientTime, encodeTime(s.ServerTime), boolToInt(s.Capped), boolToInt(s.MissedPong),
			}
		},
	})
}

func (r *Repository) writeHealth(ctx context.Context, tx *sql.Tx, rows []observability.HealthReportRow) error {
	const prefix = `INSERT INTO health_reports (
		session_id, received_at, rtt_ms, jitter_ms, age_since_last_ms, band
	)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 6, rows: len(rows),
		bind: func(i int) []any {
			h := rows[i]
			return []any{h.SessionID, encodeTime(h.ReceivedAt), h.RTTMs, h.JitterMs, h.AgeSinceLastMs, h.Band}
		},
	})
}

func (r *Repository) writeTiers(ctx context.Context, tx *sql.Tx, rows []observability.TierTransitionRow) error {
	const prefix = `INSERT INTO tier_transitions (
		session_id, at, from_tier, to_tier, reason, rtt_ms, jitter_ms, streak, override
	)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 9, rows: len(rows),
		bind: func(i int) []any {
			t := rows[i]
			return []any{
				t.SessionID, encodeTime(t.At), t.From, t.To, t.Reason,
				t.RTTMs, t.JitterMs, t.Streak, t.Override,
			}
		},
	})
}

func (r *Repository) writeDelivery(ctx context.Context, tx *sql.Tx, rows []observability.DeliveryWindow) error {
	const prefix = `INSERT INTO delivery_windows (
		session_id, window_start, window_ms, tier, target_rate, candle_updates, trade_messages,
		book_deltas, health_messages, coalesced_count, suppressed_count, bytes_sent, effective_rate
	)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 13, rows: len(rows),
		bind: func(i int) []any {
			w := rows[i]
			return []any{
				w.SessionID, encodeTime(w.WindowStart), w.WindowMs, w.Tier, w.TargetRate,
				w.CandleUpdates, w.TradeMessages, w.BookDeltas, w.HealthMessages,
				w.Coalesced, w.Suppressed, w.BytesSent, w.EffectiveRate,
			}
		},
	})
}

func (r *Repository) writeBookEvents(ctx context.Context, tx *sql.Tx, rows []observability.BookSyncEvent) error {
	const prefix = `INSERT INTO book_sync_events (
		at, session_id, scope, event, epoch, from_update_id, to_update_id, gap_size, duration_ms, attempt
	)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 10, rows: len(rows),
		bind: func(i int) []any {
			e := rows[i]
			return []any{
				encodeTime(e.At), nullableText(e.SessionID), e.Scope, e.Event, e.Epoch,
				e.FromUpdateID, e.ToUpdateID, e.GapSize, e.DurationMs, e.Attempt,
			}
		},
	})
}

func (r *Repository) writeProtocol(ctx context.Context, tx *sql.Tx, rows []observability.ProtocolEvent) error {
	const prefix = `INSERT INTO protocol_events (at, session_id, kind, detail, count)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 5, rows: len(rows),
		bind: func(i int) []any {
			e := rows[i]
			count := e.Count
			if count <= 0 {
				count = 1
			}
			return []any{encodeTime(e.At), nullableText(e.SessionID), e.Kind, e.Detail, count}
		},
	})
}

func (r *Repository) writeEngineEvents(ctx context.Context, tx *sql.Tx, rows []observability.EngineEvent) error {
	const prefix = `INSERT INTO engine_events (
		at, event, epoch, event_index, update_id, trade_id, detail, duration_ms
	)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 8, rows: len(rows),
		bind: func(i int) []any {
			e := rows[i]
			return []any{
				encodeTime(e.At), e.Event, e.Epoch, e.EventIndex, e.UpdateID,
				e.TradeID, e.Detail, e.DurationMs,
			}
		},
	})
}

func (r *Repository) writeCandleCloses(ctx context.Context, tx *sql.Tx, rows []metrics.CandleCloseRow) error {
	const prefix = `INSERT OR REPLACE INTO candle_closes (
		symbol, interval, start_time, open, high, low, close, volume, trade_count, closed_at, epoch
	)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 11, rows: len(rows),
		bind: func(i int) []any {
			c := rows[i]
			return []any{
				c.Symbol, c.Interval, encodeTime(c.StartTime), c.Open, c.High, c.Low, c.Close,
				c.Volume, c.TradeCount, encodeTime(c.ClosedAt), c.Epoch,
			}
		},
	})
}

func (r *Repository) writeFaults(ctx context.Context, tx *sql.Tx, rows []observability.FaultInjectionRow) error {
	const prefix = `INSERT INTO fault_injections (at, session_id, fault, parameters, applied)`
	return writeBatchInTx(ctx, tx, bulkInsert{
		prefix: prefix, columns: 5, rows: len(rows),
		bind: func(i int) []any {
			f := rows[i]
			return []any{encodeTime(f.At), nullableText(f.SessionID), f.Fault, f.Parameters, boolToInt(f.Applied)}
		},
	})
}

// nullableText keeps an absent session id NULL rather than an empty string, so
// "engine-internal event" stays distinguishable from "session unknown".
func nullableText(v string) any {
	if v == "" {
		return nil
	}
	return v
}

// encodeTime renders a timestamp in the store's fixed layout. A zero time becomes
// an empty string so a NULL round-trip stays distinguishable from a real value.
//
// Timestamps are stored as fixed-width text, which is what makes an indexed range
// scan a plain string comparison. The price of that is truncation to
// millisecond precision: two instants inside one millisecond encode equal.
//
// So a window **ends inclusively**: a query for "up to `to`" must compare
// `column <= encodeTime(to)`. A half-open `column < encodeTime(to)` drops the
// whole millisecond that `to` falls in, which is the millisecond a caller
// asking for "up to now" has most likely just written into. The in-memory driver compares with `!at.After(to)`.
// `TestWindowBoundsAreInclusiveOnBothDrivers` holds both to it.
func encodeTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(timeLayout)
}

func encodeTimePtr(t *time.Time) any {
	if t == nil || t.IsZero() {
		return nil
	}
	return t.UTC().Format(timeLayout)
}

func decodeTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	t, err := time.Parse(timeLayout, s)
	if err != nil {
		// A value written by another layout still sorts and displays; a parse
		// failure is not worth failing an entire read over.
		if alt, altErr := time.Parse(time.RFC3339Nano, s); altErr == nil {
			return alt.UTC()
		}
		return time.Time{}
	}
	return t.UTC()
}

func decodeTimePtr(s sql.NullString) *time.Time {
	if !s.Valid || s.String == "" {
		return nil
	}
	t := decodeTime(s.String)
	if t.IsZero() {
		return nil
	}
	return &t
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func intToBool(v int64) bool { return v != 0 }

// compile-time proof that the driver satisfies the store's contract.
var _ metrics.Repository = (*Repository)(nil)
