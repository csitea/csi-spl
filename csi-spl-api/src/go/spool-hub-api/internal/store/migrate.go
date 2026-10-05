package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// migrateLockKey serialises concurrent migrators (pg_advisory_lock).
const migrateLockKey = 0x5b001

// Applied is one migration the runner applied or skipped.
type Applied struct {
	File    string
	Skipped bool // already applied with the same sha256
}

// Migrate applies every *.sql file in dir to the database, in filename order,
// each in its own transaction, recording (filename, sha256) in
// spool_schema_migrations. An applied file whose bytes changed is a hard
// error (forward-only). Re-running is a no-op. The SQL source of truth is
// csi-spl-rdb/src/sql/postgres/spool-hub/, read at runtime (go:embed cannot
// reach outside the Go module).
func Migrate(ctx context.Context, pool *pgxpool.Pool, dir string) ([]Applied, error) {
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
	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS spool_schema_migrations (
		filename   text        PRIMARY KEY,
		sha256     text        NOT NULL,
		applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, err
	}

	var out []Applied
	for _, f := range files {
		name := filepath.Base(f)
		raw, err := os.ReadFile(f)
		if err != nil {
			return out, err
		}
		sum := sha256.Sum256(raw)
		hash := hex.EncodeToString(sum[:])

		var have string
		err = conn.QueryRow(ctx, `SELECT sha256 FROM spool_schema_migrations WHERE filename = $1`, name).Scan(&have)
		switch {
		case err == nil && have == hash:
			out = append(out, Applied{File: name, Skipped: true})
			continue
		case err == nil:
			return out, fmt.Errorf("migration %s was applied with sha256 %s but the file now hashes %s (forward-only: add a new file instead)", name, have, hash)
		case err != pgx.ErrNoRows:
			return out, err
		}
		if strings.TrimSpace(string(raw)) == "" {
			return out, fmt.Errorf("migration %s is empty", name)
		}
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			// A data migration sees every tenant (rdb 0014 RLS); the scope is
			// transaction-local, like store.asOperator's.
			if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, string(raw)); err != nil {
				return fmt.Errorf("apply %s: %w", name, err)
			}
			_, err := tx.Exec(ctx, `INSERT INTO spool_schema_migrations (filename, sha256) VALUES ($1, $2)`, name, hash)
			return err
		})
		if err != nil {
			return out, err
		}
		out = append(out, Applied{File: name})
	}
	return out, nil
}
