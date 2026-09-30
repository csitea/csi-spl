package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of the topic merge (topic_merge.go, 714c7028). Every statement
// runs in the tenant scope. The move columns follow markRow exactly, so a
// merged row is indistinguishable from a moved one to the view reads; only the
// order of the four writes is merge's own:
//
//	1. record home     moved_from_task / moved_from_parent on every row whose
//	                   task_id or parent_task_id is the source task (first move
//	                   keeps the home)
//	2. re-home         top-level rows (task_id = source) -> the target task, the
//	                   opener/any card demoted to is_parent 0
//	3. repoint         a sub-thread's parent off the source task onto the target
//	4. re-channel      markTx on every row, then clearHome for a no-op row

func (s *Postgres) MergeTopic(ctx context.Context, tenant, srcMsgID, srcTask, targetTask, toChannel, by string, at time.Time) (MergeResult, error) {
	if !canonUUIDRe.MatchString(srcMsgID) || !canonUUIDRe.MatchString(srcTask) || !canonUUIDRe.MatchString(targetTask) {
		return MergeResult{}, ErrNotFound
	}
	var res MergeResult
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		set, err := topicTx(ctx, tx, tenant, srcMsgID, srcTask) // locks the source card FOR UPDATE
		if err != nil {
			return err
		}
		for _, tk := range set.TaskIDs {
			if tk == targetTask {
				return ErrMergeCycle
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET
				moved_from_parent = CASE WHEN moved_from_task IS NULL THEN parent_task_id ELSE moved_from_parent END,
				moved_from_task   = COALESCE(moved_from_task, task_id)
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])
			  AND (task_id = $3::uuid OR parent_task_id = $3::uuid)`,
			tenant, set.MsgIDs, srcTask); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET task_id = $4::uuid, parent_task_id = NULL, is_parent = 0
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND task_id = $3::uuid`,
			tenant, set.MsgIDs, srcTask, targetTask); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET parent_task_id = $4::uuid
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND task_id <> $3::uuid AND parent_task_id = $3::uuid`,
			tenant, set.MsgIDs, srcTask, targetTask); err != nil {
			return err
		}
		if err = markTx(ctx, tx, tenant, set.MsgIDs, toChannel, by, at); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, clearHome, tenant, set.MsgIDs); err != nil {
			return err
		}
		res.MsgIDs, res.TaskIDs = set.MsgIDs, set.TaskIDs
		_, res.At, err = movedTx(ctx, tx, tenant, srcMsgID)
		return err
	})
	if err != nil {
		return MergeResult{}, err
	}
	return res, nil
}

func (s *Postgres) UnmergeTopic(ctx context.Context, tenant, srcMsgID string, msgIDs []string) error {
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
				task_id = moved_from_task, parent_task_id = moved_from_parent, channel = moved_from_channel,
				moved_at = NULL, moved_by = NULL, moved_from_channel = NULL,
				moved_from_task = NULL, moved_from_parent = NULL
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND moved_from_task IS NOT NULL`,
			tenant, ids); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE messages SET channel = moved_from_channel,
				moved_at = NULL, moved_by = NULL, moved_from_channel = NULL
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND moved_from_task IS NULL AND moved_at IS NOT NULL`,
			tenant, ids); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE messages SET is_parent = 1 WHERE tenant_id = $1 AND msg_id = $2::uuid`,
			tenant, srcMsgID)
		return err
	})
}
