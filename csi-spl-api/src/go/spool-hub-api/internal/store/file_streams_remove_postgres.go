package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres removal of a file from the view (file_streams.go, spec 160
// 3.10, rdb 0268). Every statement runs in the tenant's scope and names
// tenant_id in its WHERE.

// setFileStreamRemoved runs update ($1 the tenant, $2 the id, then args; it
// must match only the rows the action may change) and writes a, with the row's
// box, key and path, in one transaction; ErrNotFound when no row of tenant
// matches, with no audit row.
func (s *Postgres) setFileStreamRemoved(ctx context.Context, tenant, id, update string, a FileStreamGlobAuditRow, args ...any) (FileStream, error) {
	if !uuidRe.MatchString(id) {
		return FileStream{}, ErrNotFound
	}
	var f FileStream
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		if f, err = scanFileStream(tx.QueryRow(ctx, update+` RETURNING `+fileStreamCols, append([]any{tenant, id}, args...)...)); err != nil {
			return err
		}
		a.Box, a.Key, a.Glob = f.Box, f.StreamKey, f.Path
		return insertFileStreamGlobAudit(ctx, tx, tenant, a)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return FileStream{}, ErrNotFound
	}
	return f, err
}

// RemoveFileStream is FileStreamStore.RemoveFileStream.
func (s *Postgres) RemoveFileStream(ctx context.Context, tenant, id, actor string, now time.Time) (FileStream, error) {
	return s.setFileStreamRemoved(ctx, tenant, id, `UPDATE file_streams
		SET removed_at = $3, state = 'gone', reason = '' WHERE tenant_id = $1 AND id = $2::uuid AND removed_at IS NULL`,
		FileStreamGlobAuditRow{Action: FileStreamAuditFileRemove, Actor: actor, At: now}, now)
}

// RestoreFileStream is FileStreamStore.RestoreFileStream.
func (s *Postgres) RestoreFileStream(ctx context.Context, tenant, id, actor string, now time.Time) (FileStream, error) {
	return s.setFileStreamRemoved(ctx, tenant, id, `UPDATE file_streams
		SET removed_at = NULL WHERE tenant_id = $1 AND id = $2::uuid AND removed_at IS NOT NULL`,
		FileStreamGlobAuditRow{Action: FileStreamAuditFileRestore, Actor: actor, At: now})
}

// RemovedFileStreamKeys is FileStreamStore.RemovedFileStreamKeys.
func (s *Postgres) RemovedFileStreamKeys(ctx context.Context, tenant, box string) ([]string, error) {
	out := []string{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT stream_key FROM file_streams
			WHERE tenant_id = $1 AND box_id = $2 AND removed_at IS NOT NULL ORDER BY stream_key`, []any{tenant, box}, func(r pgx.Rows) error {
			var k string
			err := r.Scan(&k)
			out = append(out, k)
			return err
		})
	})
	return out, err
}
