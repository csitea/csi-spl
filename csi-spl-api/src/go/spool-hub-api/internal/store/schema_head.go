package store

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SchemaHead is the newest migration a database has applied next to the
// newest one an image bundles (spec 072 A45). Migrate applies files in name
// order, so comparing the two names says whether the schema is behind.
type SchemaHead struct {
	Bundled string // newest *.sql in the migrations dir
	Applied string // newest spool_schema_migrations.filename; "" = none
}

// Behind is a database that lacks the image's newest migration: the hub
// would start and then fail per request.
func (h SchemaHead) Behind() bool { return h.Applied < h.Bundled }

// Ahead is a database migrated past this image (an older image rolled back
// onto a newer schema): forward-only migrations keep it working, so a warning.
func (h SchemaHead) Ahead() bool { return h.Applied > h.Bundled }

// BehindError is the start refusal: it names both heads and the command
// that brings the database up to the image.
func (h SchemaHead) BehindError() error {
	applied := h.Applied
	if applied == "" {
		applied = "none"
	}
	return fmt.Errorf("database schema is behind this image: newest applied migration %s, the image bundles %s "+
		"-- run `spool migrate` first (compose: `docker compose up hub-init`)", applied, h.Bundled)
}

// BundledHead is the newest *.sql in dir, or "" when it holds none.
func BundledHead(dir string) (string, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil || len(files) == 0 {
		return "", err
	}
	sort.Strings(files)
	return filepath.Base(files[len(files)-1]), nil
}

// ReadSchemaHead reads both heads. A database that was never migrated has no
// spool_schema_migrations table: Applied is "" (behind any bundled file).
func ReadSchemaHead(ctx context.Context, pool *pgxpool.Pool, dir string) (SchemaHead, error) {
	var h SchemaHead
	var err error
	if h.Bundled, err = BundledHead(dir); err != nil {
		return h, err
	}
	if h.Bundled == "" {
		return h, fmt.Errorf("no *.sql migrations in %s", dir)
	}
	var exists bool
	if err := pool.QueryRow(ctx, `SELECT to_regclass('spool_schema_migrations') IS NOT NULL`).Scan(&exists); err != nil || !exists {
		return h, err
	}
	err = pool.QueryRow(ctx, `SELECT coalesce(max(filename), '') FROM spool_schema_migrations`).Scan(&h.Applied)
	return h, err
}
