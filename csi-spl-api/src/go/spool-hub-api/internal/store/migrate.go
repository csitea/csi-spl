package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// migrateLockKey serialises concurrent migrators (pg_advisory_lock).
const migrateLockKey = 0x5b001

// Applied is one migration the runner applied or skipped. In a dry run an
// entry that is not Skipped is pending: it ran inside a transaction that was
// rolled back, and was not applied.
type Applied struct {
	File    string
	Skipped bool   // already applied with the same sha256
	SHA256  string // hex sha256 of the file's bytes
}

// MigrateOption changes how Migrate runs.
type MigrateOption int

// DryRun is Migrate's pre-upgrade check (spool migrate --dry-run, SPL-2166).
// It takes and releases the same advisory lock and verifies the sha256 pin
// of every applied file. It then runs the pending files, in filename order,
// inside ONE transaction that it always rolls back, so a file that does not
// parse or does not apply on this schema is reported by name. It creates no
// ledger table and records nothing. Until the rollback, the pending DDL holds
// the same table locks that a real run would take.
const DryRun MigrateOption = 1

// Migrate applies every *.sql file in dir to the database, in filename order,
// each in its own transaction, recording (filename, sha256) in
// spool_schema_migrations. An applied file whose bytes changed is a hard
// error (forward-only). Re-running is a no-op. The SQL source of truth is
// csi-spl-rdb/src/sql/postgres/spool-hub/, read at runtime (go:embed cannot
// reach outside the Go module).
func Migrate(ctx context.Context, pool *pgxpool.Pool, dir string, opts ...MigrateOption) ([]Applied, error) {
	dryRun := slices.Contains(opts, DryRun)
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no *.sql migrations in %s", dir)
	}
	sort.Strings(files)

	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrateLockKey); err != nil {
		return nil, err
	}
	defer func() {
		// The unlock must survive a cancelled ctx (or the lock outlives the run
		// on a pooled conn), but bounded: a dead DB must not hang the caller.
		uctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		conn.Exec(uctx, `SELECT pg_advisory_unlock($1)`, migrateLockKey) //nolint:errcheck
	}()
	ledger, err := migrationLedger(ctx, conn, dryRun)
	if err != nil {
		return nil, err
	}

	// A data migration sees every tenant (rdb 0014 RLS); the scope is
	// transaction-local, like store.asOperator's.
	scope := pgScopeOperator
	var out []Applied
	var pending []pendingFile
	for _, f := range files {
		a, raw, err := checkMigrationPin(ctx, conn, ledger, f)
		if err != nil {
			return out, err
		}
		switch {
		case a.Skipped:
		case dryRun:
			pending = append(pending, pendingFile{name: a.File, sql: raw})
		default:
			if err := applyMigration(ctx, conn, scope, a, raw); err != nil {
				return out, err
			}
		}
		out = append(out, a)
	}
	if len(pending) > 0 {
		return out, tryPending(ctx, conn, scope, pending)
	}
	return out, nil
}

// migrationLedger makes sure spool_schema_migrations exists and reports
// whether it does. A dry run creates nothing: with no ledger table every
// file is pending.
func migrationLedger(ctx context.Context, conn *pgxpool.Conn, dryRun bool) (bool, error) {
	if dryRun {
		var ok bool
		err := conn.QueryRow(ctx, `SELECT to_regclass('spool_schema_migrations') IS NOT NULL`).Scan(&ok)
		return ok, err
	}
	_, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS spool_schema_migrations (
		filename   text        PRIMARY KEY,
		sha256     text        NOT NULL,
		applied_at timestamptz NOT NULL DEFAULT now())`)
	return err == nil, err
}

// checkMigrationPin reads one file and compares its sha256 with the ledger:
// Skipped when applied with the same bytes, an error when the bytes changed
// (forward-only) or the file is empty, else a pending entry and its SQL.
func checkMigrationPin(ctx context.Context, conn *pgxpool.Conn, ledger bool, path string) (Applied, string, error) {
	name := filepath.Base(path)
	raw, err := os.ReadFile(path)
	if err != nil {
		return Applied{}, "", err
	}
	sum := sha256.Sum256(raw)
	a := Applied{File: name, SHA256: hex.EncodeToString(sum[:])}

	var have string
	err = pgx.ErrNoRows
	if ledger {
		err = conn.QueryRow(ctx, `SELECT sha256 FROM spool_schema_migrations WHERE filename = $1`, name).Scan(&have)
	}
	switch {
	case err == nil && have == a.SHA256:
		a.Skipped = true
		return a, "", nil
	case err == nil:
		return a, "", fmt.Errorf("migration %s was applied with sha256 %s but the file now hashes %s (forward-only: add a new file instead)", name, have, a.SHA256)
	case err != pgx.ErrNoRows:
		return a, "", err
	}
	if strings.TrimSpace(string(raw)) == "" {
		return a, "", fmt.Errorf("migration %s is empty", name)
	}
	return a, string(raw), nil
}

// applyMigration applies one file and records it, in one transaction.
func applyMigration(ctx context.Context, conn *pgxpool.Conn, scope string, a Applied, sql string) error {
	return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, scope); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, sql); err != nil {
			return fmt.Errorf("apply %s: %w", a.File, err)
		}
		_, err := tx.Exec(ctx, `INSERT INTO spool_schema_migrations (filename, sha256) VALUES ($1, $2)`, a.File, a.SHA256)
		return err
	})
}

// pendingFile is one dry-run migration not yet in the ledger.
type pendingFile struct {
	name, sql string
}

// tryPending runs the dry run's pending files in order, in one transaction
// that it always rolls back; each file sees the ones before it, as in a real
// run. The pins were all checked before the first file runs.
func tryPending(ctx context.Context, conn *pgxpool.Conn, scope string, pending []pendingFile) error {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.WithoutCancel(ctx)) //nolint:errcheck
	if _, err := tx.Exec(ctx, scope); err != nil {
		return err
	}
	for _, p := range pending {
		if _, err := tx.Exec(ctx, p.sql); err != nil {
			return fmt.Errorf("dry run: %s does not apply: %w", p.name, err)
		}
	}
	return tx.Rollback(ctx)
}
