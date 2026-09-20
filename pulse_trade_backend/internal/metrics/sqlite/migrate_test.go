package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/pulsetrade/pulse-trade-backend/internal/metrics"
	"github.com/pulsetrade/pulse-trade-backend/internal/observability"
)

// batchWithEngineEvent is a single-row batch used to prove data survives a reopen.
func batchWithEngineEvent() metrics.Batch {
	return metrics.Batch{EngineEvts: []observability.EngineEvent{{
		Event: "WARMUP_COMPLETE",
		At:    time.Now().UTC(),
	}}}
}

// openRaw opens the database the same way Open does but without running
// migrations, so a test can inspect or corrupt the migration bookkeeping.
func openRaw(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open(DriverName, buildDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	db.SetMaxOpenConns(1)
	if err := applyPragmas(context.Background(), db); err != nil {
		t.Fatalf("applyPragmas: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// TestMigrateAppliesAndRecordsChecksum proves migrations are applied in a
// transaction and recorded with a checksum and an application time.
func TestMigrateAppliesAndRecordsChecksum(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "migrations.db")

	repo, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	appliedVersion := repo.SchemaVersion()
	if appliedVersion < 1 {
		t.Fatalf("SchemaVersion() = %d, want at least 1 (every embedded migration applied)", appliedVersion)
	}
	if err := repo.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	db := openRaw(t, path)
	var (
		version   int
		appliedAt string
		checksum  string
	)
	if err := db.QueryRowContext(ctx, `SELECT version, applied_at, checksum FROM schema_migrations`).
		Scan(&version, &appliedAt, &checksum); err != nil {
		t.Fatalf("read schema_migrations: %v", err)
	}
	if version != 1 {
		t.Fatalf("recorded version = %d, want 1", version)
	}
	if len(checksum) != 64 {
		t.Fatalf("checksum = %q, want a 64-character hex digest", checksum)
	}
	if _, err := time.Parse(timeLayout, appliedAt); err != nil {
		t.Fatalf("applied_at = %q is not in the store's timestamp layout: %v", appliedAt, err)
	}

	// Every table from the embedded migrations must exist.
	for table := range knownTables {
		var name string
		err := db.QueryRowContext(ctx, `SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name)
		if err != nil {
			t.Fatalf("table %s is missing: %v", table, err)
		}
	}
}

// TestMigrateReopenIsNoop proves reopening an existing database does not re-apply
// migrations: re-running the schema would fail on the first CREATE TABLE, so a
// clean reopen is the proof.
func TestMigrateReopenIsNoop(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "reopen.db")

	first, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	// Record something so the reopen is proven to land on the same file.
	if err := first.WriteBatch(ctx, batchWithEngineEvent()); err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("first Close: %v", err)
	}

	second, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("second Open (reopen) must be a no-op: %v", err)
	}
	defer func() { _ = second.Close() }()
	firstVersion := 2 // the number of embedded migrations; reopen must not exceed it
	if got := second.SchemaVersion(); got != firstVersion {
		t.Fatalf("SchemaVersion() after reopen = %d, want %d: an already-applied migration must not re-apply",
			got, firstVersion)
	}

	rows, err := second.CountRowsForTest(ctx, "engine_events")
	if err != nil {
		t.Fatalf("CountRowsForTest: %v", err)
	}
	if rows != 1 {
		t.Fatalf("engine_events = %d after reopen, want the pre-existing row to survive", rows)
	}

	db := openRaw(t, path)
	var applied int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations`).Scan(&applied); err != nil {
		t.Fatalf("count schema_migrations: %v", err)
	}
	if applied != firstVersion {
		t.Fatalf("schema_migrations has %d rows but SchemaVersion() reports %d: reopen re-applied a migration",
			applied, firstVersion)
	}
}

// TestMigrateChecksumMismatchIsFatal proves a tampered migration record is a fatal
// error rather than a silent re-apply.
func TestMigrateChecksumMismatchIsFatal(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "tampered.db")

	repo, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := repo.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	db := openRaw(t, path)
	if _, err := db.ExecContext(ctx, `UPDATE schema_migrations SET checksum = 'tampered' WHERE version = 1`); err != nil {
		t.Fatalf("tamper with the checksum: %v", err)
	}
	if _, err := db.ExecContext(ctx, "PRAGMA schema_version = 2"); err != nil {
		t.Fatalf("bump schema_version: %v", err)
	}

	if _, err := Open(ctx, path); !errors.Is(err, ErrMigrationChecksum) {
		t.Fatalf("Open after tampering returned %v, want ErrMigrationChecksum", err)
	}
}

// TestMigrationFilesAreWellFormed checks the embedded files parse and that exactly
// one version 1 migration exists, so a malformed name fails at test time rather
// than at a live server's first startup.
func TestMigrationFilesAreWellFormed(t *testing.T) {
	files, err := migrationFiles()
	if err != nil {
		t.Fatalf("migrationFiles: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("no embedded migrations")
	}
	if files[0].Version != 1 {
		t.Fatalf("first migration version = %d, want 1", files[0].Version)
	}
	for i := 1; i < len(files); i++ {
		if files[i].Version <= files[i-1].Version {
			t.Fatalf("migrations are not strictly ordered: %d after %d", files[i].Version, files[i-1].Version)
		}
	}
}
