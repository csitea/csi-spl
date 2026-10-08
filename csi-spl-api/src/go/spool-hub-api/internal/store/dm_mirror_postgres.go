package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of spec 067 L4 (dm_mirror.go). The reads walk the partial
// indexes rdb 0112 added (messages_ref_task, messages_mirror_of).

func (s *Postgres) DMRefTask(ctx context.Context, tenant, taskID string) (string, error) {
	if !canonUUIDRe.MatchString(taskID) {
		return "", nil
	}
	var ref string
	err := s.queryRowTenant(ctx, tenant, `SELECT ref_task_id::text FROM messages
		WHERE tenant_id = $1 AND task_id = $2 AND ref_task_id IS NOT NULL AND channel IS NULL
		ORDER BY received_at, msg_id LIMIT 1`, []any{tenant, taskID}, &ref)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return ref, err
}

// errDMNotNew rolls InsertMirrored's transaction back when dm was stored
// before: the plain insert then answers the resend (or the conflict).
var errDMNotNew = errors.New("dm already stored")

// InsertMirrored: see DMMirror. Both rows go through insertMessage's own
// statement, so each writes its flow events and wakes the browsers on commit.
func (s *Postgres) InsertMirrored(ctx context.Context, dm Message, dmSent time.Time, cp Message, cpSent time.Time) (bool, error) {
	// The DM is the post; its copy writes no minute. Built before the
	// transaction: the hours probe must not wait on the pool inside it.
	dmSQL, dmArgs := s.insertMessageStmt(ctx, dm, dmSent)
	err := s.inTenant(ctx, dm.TenantID, func(tx pgx.Tx) error {
		var inserted bool
		var old []byte
		var notified int64
		sql, args := dmSQL, dmArgs
		if err := tx.QueryRow(ctx, sql, args...).Scan(&inserted, &old, &notified); err != nil {
			return mapFK(err)
		}
		if !inserted {
			return errDMNotNew
		}
		sql, args = insertMessageArgs(cp, cpSent)
		if err := tx.QueryRow(ctx, sql, args...).Scan(&inserted, &old, &notified); err != nil {
			return err
		}
		if !inserted {
			return fmt.Errorf("mirror %s of %s: %w", cp.MsgID, dm.MsgID, ErrConflict)
		}
		return nil
	})
	if errors.Is(err, errDMNotNew) {
		return s.insertMessage(ctx, dm, dmSent)
	}
	return err == nil, err
}

// editMirrorsTx applies the DM edit e to every copy of msgID inside tx
// (applyEditTx). A copy has no copies of its own (the copy is a channel row,
// and only a DM is mirrored), so the walk is one level deep.
func editMirrorsTx(ctx context.Context, tx pgx.Tx, tenant, msgID string, e Edit) error {
	type copyRow struct {
		id  string
		env []byte
	}
	var copies []copyRow
	if err := eachRow(ctx, tx, `SELECT msg_id::text, env FROM messages
		WHERE tenant_id = $1 AND mirror_of = $2 AND msg_id <> $2 FOR UPDATE`, []any{tenant, msgID}, func(rows pgx.Rows) error {
		var c copyRow
		if err := rows.Scan(&c.id, &c.env); err != nil {
			return err
		}
		copies = append(copies, c)
		return nil
	}); err != nil {
		return err
	}
	for _, c := range copies {
		ce, err := mirrorEdit(c.env, e)
		if err != nil {
			return fmt.Errorf("mirror %s of %s: %w", c.id, msgID, err)
		}
		if _, err := applyEditTx(ctx, tx, tenant, c.id, ce); err != nil {
			return err
		}
	}
	return nil
}

// archiveMirrorsTx is SetArchived's flag write on every copy of msgID.
func archiveMirrorsTx(ctx context.Context, tx pgx.Tx, tenant, msgID, by string, at time.Time, archived bool) error {
	var err error
	if archived {
		_, err = tx.Exec(ctx, `UPDATE messages SET archived_at = COALESCE(archived_at, $3),
			archived_by = CASE WHEN archived_at IS NULL THEN $4 ELSE archived_by END
			WHERE tenant_id = $1 AND mirror_of = $2`, tenant, msgID, at, by)
	} else {
		_, err = tx.Exec(ctx, `UPDATE messages SET archived_at = NULL, archived_by = NULL
			WHERE tenant_id = $1 AND mirror_of = $2`, tenant, msgID)
	}
	return err
}
