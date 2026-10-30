package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The Postgres web globs (file_stream_globs.go, rdb 0242). Every statement
// runs in the tenant's scope and names tenant_id in its WHERE; the one
// exception is PruneFileStreamGlobAudit (operatorCallers).

const fileStreamGlobCols = `id::text, tenant_id, box_id, key, glob, created_by, created_at, removed_at,
	box_state, box_reason, matched, followed, over_cap, reported_at`

func scanFileStreamGlob(r pgx.Row) (FileStreamGlob, error) {
	var g FileStreamGlob
	err := r.Scan(&g.ID, &g.Tenant, &g.Box, &g.Key, &g.Glob, &g.CreatedBy, &g.CreatedAt, &g.RemovedAt,
		&g.State, &g.Reason, &g.Matched, &g.Followed, &g.OverCap, &g.ReportedAt)
	return g, err
}

const fileStreamFolderCols = `box_id, path, state, reason, reported_at`

func scanFileStreamFolder(r pgx.Row) (FileStreamFolder, error) {
	var f FileStreamFolder
	err := r.Scan(&f.Box, &f.Path, &f.State, &f.Reason, &f.ReportedAt)
	return f, err
}

const fileStreamGlobAuditInsert = `INSERT INTO file_stream_glob_audit (tenant_id, id, glob_id, box_id, action, key, glob, actor, reason, at)
	VALUES ($1, $2::uuid, NULLIF($3, '')::uuid, $4, $5, $6, $7, $8, $9, $10)`

func insertFileStreamGlobAudit(ctx context.Context, tx pgx.Tx, tenant string, a FileStreamGlobAuditRow) error {
	a = fileStreamAuditRow(a)
	_, err := tx.Exec(ctx, fileStreamGlobAuditInsert, tenant, uuid.New(), a.GlobID, a.Box, a.Action, a.Key, a.Glob, a.Actor, a.Reason, a.At)
	return err
}

// FileStreamBoxFolders is FileStreamGlobStore.FileStreamBoxFolders.
func (s *Postgres) FileStreamBoxFolders(ctx context.Context, tenant, box string) (bool, []FileStreamFolder, error) {
	var known bool
	out := []FileStreamFolder{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM file_streams WHERE tenant_id = $1 AND box_id = $2)
			OR EXISTS (SELECT 1 FROM file_stream_folders WHERE tenant_id = $1 AND box_id = $2)`, tenant, box).Scan(&known); err != nil {
			return err
		}
		return eachRow(ctx, tx, `SELECT `+fileStreamFolderCols+` FROM file_stream_folders WHERE tenant_id = $1 AND box_id = $2 ORDER BY path`,
			[]any{tenant, box}, func(r pgx.Rows) error {
				f, err := scanFileStreamFolder(r)
				out = append(out, f)
				return err
			})
	})
	return known, out, err
}

// AddFileStreamGlob is FileStreamGlobStore.AddFileStreamGlob. A transaction
// advisory lock on (tenant, box) serializes a box's adds, so two racing adds
// never both pass the count.
func (s *Postgres) AddFileStreamGlob(ctx context.Context, tenant string, in FileStreamGlobAdd, now time.Time) (FileStreamGlob, error) {
	var g FileStreamGlob
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('file_stream_globs/' || $1 || '/' || $2, 0))`, tenant, in.Box); err != nil {
			return err
		}
		var one int
		if err := tx.QueryRow(ctx, `SELECT 1 FROM boxes WHERE tenant_id = $1 AND box_id = $2`, tenant, in.Box).Scan(&one); err != nil {
			return err
		}
		var n int
		var taken bool
		if err := tx.QueryRow(ctx, `SELECT count(*), coalesce(bool_or(key = $3), false) FROM file_stream_globs
			WHERE tenant_id = $1 AND box_id = $2 AND removed_at IS NULL`, tenant, in.Box, in.Key).Scan(&n, &taken); err != nil {
			return err
		}
		switch {
		case taken:
			return ErrFileStreamGlobKeyTaken
		case n >= in.Max:
			return ErrFileStreamGlobsFull
		}
		var err error
		g, err = scanFileStreamGlob(tx.QueryRow(ctx, `INSERT INTO file_stream_globs (tenant_id, id, box_id, key, glob, created_by, created_at)
			VALUES ($1, $2::uuid, $3, $4, $5, $6, $7) RETURNING `+fileStreamGlobCols, tenant, uuid.New(), in.Box, in.Key, in.Glob, in.Actor, now))
		if err != nil {
			return err
		}
		return insertFileStreamGlobAudit(ctx, tx, tenant, FileStreamGlobAuditRow{GlobID: g.ID, Box: g.Box, Action: FileStreamGlobAuditAdd,
			Key: g.Key, Glob: g.Glob, Actor: in.Actor, At: now})
	})
	if errors.Is(err, pgx.ErrNoRows) { // no boxes row of tenant
		return FileStreamGlob{}, ErrNotFound
	}
	return g, err
}

// RemoveFileStreamGlob is FileStreamGlobStore.RemoveFileStreamGlob.
func (s *Postgres) RemoveFileStreamGlob(ctx context.Context, tenant, id, actor string, now time.Time) (FileStreamGlob, error) {
	if !uuidRe.MatchString(id) {
		return FileStreamGlob{}, ErrNotFound
	}
	var g FileStreamGlob
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		g, err = scanFileStreamGlob(tx.QueryRow(ctx, `UPDATE file_stream_globs SET removed_at = $3
			WHERE tenant_id = $1 AND id = $2::uuid AND removed_at IS NULL RETURNING `+fileStreamGlobCols, tenant, id, now))
		if err != nil {
			return err
		}
		return insertFileStreamGlobAudit(ctx, tx, tenant, FileStreamGlobAuditRow{GlobID: g.ID, Box: g.Box, Action: FileStreamGlobAuditRemove,
			Key: g.Key, Glob: g.Glob, Actor: actor, At: now})
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return FileStreamGlob{}, ErrNotFound
	}
	return g, err
}

// AuditFileStreamGlobRefusal is FileStreamGlobStore.AuditFileStreamGlobRefusal.
func (s *Postgres) AuditFileStreamGlobRefusal(ctx context.Context, tenant string, a FileStreamGlobAuditRow) error {
	a.GlobID, a.Action = "", FileStreamGlobAuditRefused
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return insertFileStreamGlobAudit(ctx, tx, tenant, a)
	})
}

// ListFileStreamGlobs is FileStreamGlobStore.ListFileStreamGlobs.
func (s *Postgres) ListFileStreamGlobs(ctx context.Context, tenant string) ([]FileStreamGlob, []FileStreamFolder, error) {
	globs, folders := []FileStreamGlob{}, []FileStreamFolder{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		err := eachRow(ctx, tx, `SELECT `+fileStreamGlobCols+` FROM file_stream_globs
			WHERE tenant_id = $1 AND removed_at IS NULL ORDER BY box_id, key`, []any{tenant}, func(r pgx.Rows) error {
			g, err := scanFileStreamGlob(r)
			globs = append(globs, g)
			return err
		})
		if err != nil {
			return err
		}
		return eachRow(ctx, tx, `SELECT `+fileStreamFolderCols+` FROM file_stream_folders WHERE tenant_id = $1 ORDER BY box_id, path`,
			[]any{tenant}, func(r pgx.Rows) error {
				f, err := scanFileStreamFolder(r)
				folders = append(folders, f)
				return err
			})
	})
	return globs, folders, err
}

// FileStreamGlobAudit is FileStreamGlobStore.FileStreamGlobAudit.
func (s *Postgres) FileStreamGlobAudit(ctx context.Context, tenant string, before *time.Time, limit int) ([]FileStreamGlobAuditRow, error) {
	out := []FileStreamGlobAuditRow{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT id::text, coalesce(glob_id::text, ''), box_id, action, key, glob, actor, reason, at
			FROM file_stream_glob_audit WHERE tenant_id = $1 AND ($2::timestamptz IS NULL OR at < $2)
			ORDER BY at DESC, id DESC LIMIT $3`, []any{tenant, before, fileStreamAuditLimit(limit)}, func(r pgx.Rows) error {
			var a FileStreamGlobAuditRow
			err := r.Scan(&a.ID, &a.GlobID, &a.Box, &a.Action, &a.Key, &a.Glob, &a.Actor, &a.Reason, &a.At)
			out = append(out, a)
			return err
		})
	})
	return out, err
}

// BoxFileStreamGlobs is FileStreamGlobStore.BoxFileStreamGlobs.
func (s *Postgres) BoxFileStreamGlobs(ctx context.Context, tenant, box string) ([]FileStreamGlob, error) {
	out := []FileStreamGlob{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT `+fileStreamGlobCols+` FROM file_stream_globs
			WHERE tenant_id = $1 AND box_id = $2 AND removed_at IS NULL ORDER BY created_at, id`, []any{tenant, box}, func(r pgx.Rows) error {
			g, err := scanFileStreamGlob(r)
			out = append(out, g)
			return err
		})
	})
	return out, err
}

// ReportFileStreamGlobs is FileStreamGlobStore.ReportFileStreamGlobs.
func (s *Postgres) ReportFileStreamGlobs(ctx context.Context, tenant, box string, folders []wire.FileStreamFolderReport, globs []wire.FileStreamGlobReport, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		for _, r := range globs {
			if _, err := tx.Exec(ctx, `UPDATE file_stream_globs SET box_state = $4, box_reason = $5, matched = $6, followed = $7,
				over_cap = $8, reported_at = $9 WHERE tenant_id = $1 AND box_id = $2 AND id = $3::uuid AND removed_at IS NULL`,
				tenant, box, r.ID, r.State, r.Reason, r.Matched, r.Followed, r.OverCap, now); err != nil {
				return err
			}
		}
		if folders == nil {
			return nil
		}
		if _, err := tx.Exec(ctx, `DELETE FROM file_stream_folders WHERE tenant_id = $1 AND box_id = $2`, tenant, box); err != nil {
			return err
		}
		for _, f := range folders {
			if _, err := tx.Exec(ctx, `INSERT INTO file_stream_folders (tenant_id, box_id, path, state, reason, reported_at)
				VALUES ($1, $2, $3, $4, $5, $6)`, tenant, box, f.Path, f.State, f.Reason, now); err != nil {
				return err
			}
		}
		return nil
	})
}

// PruneFileStreamGlobAudit is FileStreamGlobStore.PruneFileStreamGlobAudit:
// one delete across every workspace, under the operator scope (the hub's
// sweeper; no route).
func (s *Postgres) PruneFileStreamGlobAudit(ctx context.Context, before time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM file_stream_glob_audit WHERE at < $1`, before)
		n = int(tag.RowsAffected())
		return err
	})
	return n, err
}
