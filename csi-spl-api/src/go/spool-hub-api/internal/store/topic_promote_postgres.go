package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of the topic promote (topic_promote.go, 8f588edd). Every
// statement runs in the tenant scope. The move columns follow markRow, so the
// promoted card is indistinguishable from a moved row to the view reads; the
// four writes are promote's own:
//
//	1. record home     moved_from_task / moved_from_parent on the promoted row
//	                   and every sub-thread row hung off the source task (first
//	                   move keeps the home)
//	2. re-seat card    the promoted row -> the new task, is_parent 1, and a
//	                   same-channel mark (moved_from_channel = channel, at/by)
//	3. repoint         a sub-thread's parent off the source task onto the new one
//
// The sub-thread rows are NOT re-channelled and carry no moved_at, so they show
// no provenance; only their home columns are set, for the undo.

func (s *Postgres) PromoteMessage(ctx context.Context, tenant, srcMsgID, srcTask, newTask, by string, at time.Time) (MoveResult, error) {
	if !canonUUIDRe.MatchString(srcMsgID) || !canonUUIDRe.MatchString(srcTask) || !canonUUIDRe.MatchString(newTask) {
		return MoveResult{}, ErrNotFound
	}
	var res MoveResult
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		set, err := topicTx(ctx, tx, tenant, srcMsgID, "") // locks the row FOR UPDATE, walks its own thread
		if err != nil {
			return err
		}
		for _, tk := range set.TaskIDs {
			if tk == newTask {
				return ErrMoveCycle
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET
				moved_from_parent = CASE WHEN moved_from_task IS NULL THEN parent_task_id ELSE moved_from_parent END,
				moved_from_task   = COALESCE(moved_from_task, task_id)
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])
			  AND (msg_id = $3::uuid OR parent_task_id = $4::uuid)`,
			tenant, set.MsgIDs, srcMsgID, srcTask); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET task_id = $3::uuid, parent_task_id = NULL, is_parent = 1,
				moved_from_channel = CASE WHEN moved_at IS NULL THEN channel ELSE moved_from_channel END,
				moved_at = $4, moved_by = $5
			WHERE tenant_id = $1 AND msg_id = $2::uuid`,
			tenant, srcMsgID, newTask, at, by); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET parent_task_id = $3::uuid
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND msg_id <> $4::uuid AND parent_task_id = $5::uuid`,
			tenant, set.MsgIDs, newTask, srcMsgID, srcTask); err != nil {
			return err
		}
		res.MsgIDs, res.TaskIDs, res.Moved = set.MsgIDs, set.TaskIDs, true
		_, res.ReceivedAt, err = movedTx(ctx, tx, tenant, srcMsgID)
		return err
	})
	if err != nil {
		return MoveResult{}, err
	}
	return res, nil
}

func (s *Postgres) DemoteTopic(ctx context.Context, tenant, srcMsgID string, msgIDs []string) error {
	if !canonUUIDRe.MatchString(srcMsgID) {
		return ErrNotFound
	}
	ids := make([]string, 0, len(msgIDs))
	for _, id := range msgIDs {
		if canonUUIDRe.MatchString(id) {
			ids = append(ids, id)
		}
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE messages SET
				task_id        = moved_from_task,
				parent_task_id = moved_from_parent,
				channel        = CASE WHEN moved_at IS NOT NULL AND moved_from_channel IS NOT NULL THEN moved_from_channel ELSE channel END,
				moved_at = NULL, moved_by = NULL, moved_from_channel = NULL,
				moved_from_task = NULL, moved_from_parent = NULL
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND moved_from_task IS NOT NULL`,
			tenant, ids); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE messages SET is_parent = 0 WHERE tenant_id = $1 AND msg_id = $2::uuid`,
			tenant, srcMsgID)
		return err
	})
}
