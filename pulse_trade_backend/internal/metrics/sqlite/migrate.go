package sqlite

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"
)

// migrationsDir is embedded so the binary carries its own schema: there is no
// runtime path dependency and no way to start against a half-written migrations
// directory.
//
//go:embed migrations/*.sql
var migrationsDir embed.FS

// migrate applies every embedded migration that has not been applied yet.
//
// It returns the highest applied version. A checksum mismatch is fatal: a
// migration file that changed after being applied means the schema on disk and
// the schema in the binary disagree, and silently continuing would corrupt the
// audit trail.
//
// schema_migrations is created here, not in a migration file, because a migration
// file cannot record its own application.
func migrate(ctx context.Context, db *sql.DB) (int, error) {
	if _, err := db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    INTEGER PRIMARY KEY,
			applied_at TIMESTAMP NOT NULL,
			checksum   TEXT NOT NULL
		)`); err != nil {
		return 0, fmt.Errorf("metrics/sqlite: create schema_migrations: %w", err)
	}

	applied, err := appliedMigrations(ctx, db)
	if err != nil {
		return 0, err
	}

	files, err := migrationFiles()
	if err != nil {
		return 0, err
	}

	version := 0
	for _, m := range files {
		if appliedVersion, ok := applied[m.Version]; ok {
			if appliedVersion != m.Checksum {
				return 0, fmt.Errorf(
					"%w: migration %04d_%s recorded %s, embedded %s (a migration is immutable; reset ./data to rebuild)",
					ErrMigrationChecksum, m.Version, m.Name, appliedVersion, m.Checksum)
			}
			version = m.Version
			continue
		}
		if err := applyMigration(ctx, db, m); err != nil {
			return 0, err
		}
		version = m.Version
	}
	return version, nil
}

// migration is one embedded numbered SQL file.
type migration struct {
	Version  int
	Name     string
	Checksum string
	SQL      string
}

// migrationFiles reads, validates and orders the embedded migrations.
func migrationFiles() ([]migration, error) {
	entries, err := fs.ReadDir(migrationsDir, "migrations")
	if err != nil {
		return nil, fmt.Errorf("metrics/sqlite: read embedded migrations: %w", err)
	}
	out := make([]migration, 0, len(entries))
	seen := map[int]string{}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		body, err := migrationsDir.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return nil, fmt.Errorf("metrics/sqlite: read migration %s: %w", entry.Name(), err)
		}
		version, name, err := parseMigrationName(entry.Name())
		if err != nil {
			return nil, err
		}
		if other, dup := seen[version]; dup {
			return nil, fmt.Errorf("metrics/sqlite: duplicate migration version %d (%s and %s)", version, other, entry.Name())
		}
		seen[version] = entry.Name()
		sum := sha256.Sum256(body)
		out = append(out, migration{
			Version:  version,
			Name:     name,
			Checksum: hex.EncodeToString(sum[:]),
			SQL:      string(body),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	return out, nil
}

// parseMigrationName splits "0001_init.sql" into (1, "init").
func parseMigrationName(name string) (int, string, error) {
	stem := strings.TrimSuffix(name, ".sql")
	prefix, rest, ok := strings.Cut(stem, "_")
	if !ok {
		return 0, "", fmt.Errorf("metrics/sqlite: migration %q must be named <version>_<name>.sql", name)
	}
	version, err := strconv.Atoi(prefix)
	if err != nil || version <= 0 {
		return 0, "", fmt.Errorf("metrics/sqlite: migration %q has a non-numeric version prefix", name)
	}
	return version, rest, nil
}

// appliedMigrations reads the recorded version -> checksum map.
func appliedMigrations(ctx context.Context, db *sql.DB) (map[int]string, error) {
	rows, err := db.QueryContext(ctx, `SELECT version, checksum FROM schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("metrics/sqlite: read schema_migrations: %w", err)
	}
	defer func() { _ = rows.Close() }()

	out := map[int]string{}
	for rows.Next() {
		var version int
		var checksum string
		if err := rows.Scan(&version, &checksum); err != nil {
			return nil, fmt.Errorf("metrics/sqlite: scan schema_migrations: %w", err)
		}
		out[version] = checksum
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("metrics/sqlite: iterate schema_migrations: %w", err)
	}
	return out, nil
}

// applyMigration runs one migration and records it, both inside one transaction.
// The transaction is explicit in the SQL because the driver executes the file as
// a multi-statement script: a failure anywhere in the script must leave the
// database exactly as it was.
func applyMigration(ctx context.Context, db *sql.DB, m migration) error {
	script := "BEGIN;\n" + m.SQL + "\n" +
		`INSERT INTO schema_migrations (version, applied_at, checksum) VALUES (` +
		strconv.Itoa(m.Version) + `, '` + encodeTime(time.Now().UTC()) + `', '` + m.Checksum + `');` +
		"\nCOMMIT;"
	if _, err := db.ExecContext(ctx, script); err != nil {
		// A rolled-back script leaves the transaction open on some drivers, so
		// the rollback is best-effort and its own error is deliberately ignored.
		_, _ = db.ExecContext(ctx, "ROLLBACK")
		return fmt.Errorf("metrics/sqlite: apply migration %04d_%s: %w", m.Version, m.Name, err)
	}
	return nil
}

// ErrMigrationChecksum mirrors ErrDatabaseClosed's shape for callers that want to
// test for a tampered migration without string matching.
var ErrMigrationChecksum = errors.New("metrics/sqlite: migration checksum mismatch")
